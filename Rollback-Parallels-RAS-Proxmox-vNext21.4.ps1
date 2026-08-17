# Restores a Backup-vNext21.4-* snapshot created by the vNext21.4 installer.
[CmdletBinding()]
param(
    [string]$TargetDirectory = 'C:\CFP Scripts',
    [string]$BackupDirectory,
    [string]$ServiceName = 'RAS Provider Service'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Stop-StaleProviderProcesses {
    param([Parameter(Mandatory = $true)][string]$TargetScript)
    try {
        Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.Name -match '^(?:powershell|pwsh)\.exe$' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
                [string]$_.CommandLine -like "*$TargetScript*"
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    catch { Write-Warning "Could not enumerate stale provider processes: $($_.Exception.Message)" }
}

function Wait-ServiceState {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Running','Stopped')][string]$State,
        [int]$TimeoutSeconds = 90
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ([string]$service.Status -eq $State) { return }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Service [$Name] did not reach state [$State] within [$TimeoutSeconds] seconds"
}

function Test-PowerShellScript {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($null -ne $errors -and @($errors).Count -gt 0) {
        throw "Backup provider script failed PowerShell parser validation: $(@($errors | ForEach-Object Message) -join '; ')"
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this rollback script from an elevated PowerShell session.'
}

if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    $latest = Get-ChildItem -LiteralPath $TargetDirectory -Directory -Filter 'Backup-vNext21.4-*' -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { throw "No Backup-vNext21.4-* directory found below [$TargetDirectory]." }
    $BackupDirectory = $latest.FullName
}

if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) {
    throw "Backup directory not found: $BackupDirectory"
}

$backupScript = Join-Path $BackupDirectory 'Parallels-RAS-CPF-Proxmox-Advanced.ps1'
if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) {
    throw "Backup does not contain the provider script: $backupScript"
}
Test-PowerShellScript -Path $backupScript

$targetScript = Join-Path $TargetDirectory 'Parallels-RAS-CPF-Proxmox-Advanced.ps1'
$service = Get-Service -Name $ServiceName -ErrorAction Stop
$wasRunning = ($service.Status -eq 'Running')

try {
    if ($wasRunning) {
        Stop-Service -Name $ServiceName -Force
        Wait-ServiceState -Name $ServiceName -State Stopped
    }
    Stop-StaleProviderProcesses -TargetScript $targetScript

    Remove-Item -LiteralPath $targetScript -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $TargetDirectory -File -Filter 'Proxmox-RAS-*.json*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Get-ChildItem -LiteralPath $BackupDirectory -File |
        Where-Object {
            $_.Name -eq 'Parallels-RAS-CPF-Proxmox-Advanced.ps1' -or
            $_.Name -like 'Proxmox-RAS-*.json*'
        } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $TargetDirectory $_.Name) -Force
        }

    Test-PowerShellScript -Path $targetScript
    if ($wasRunning) {
        Start-Service -Name $ServiceName
        Wait-ServiceState -Name $ServiceName -State Running
    }
    Write-Host "Rollback completed from [$BackupDirectory]." -ForegroundColor Green
}
catch {
    if ($wasRunning) { Start-Service -Name $ServiceName -ErrorAction SilentlyContinue }
    throw
}
