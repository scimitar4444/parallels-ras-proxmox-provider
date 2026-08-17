# Installs or updates the Parallels RAS Proxmox CPF provider to vNext21.4.
# The installer validates the PowerShell source and JSON configuration, preserves
# the existing farm-specific configuration, creates a consistent backup while the
# provider is stopped, performs out-of-process smoke tests, and rolls back
# automatically if any step fails. Run elevated on the Parallels RAS provider host.
[CmdletBinding()]
param(
    [string]$SourceDirectory = $PSScriptRoot,
    [string]$TargetDirectory = 'C:\CFP Scripts',
    [string]$ServiceName = 'RAS Provider Service',
    [switch]$SkipServiceRestart,
    [switch]$ReplaceConfiguration,
    [switch]$RepairStuckMaintenance,
    [switch]$EnableNetworkCache,
    [switch]$DisableNetworkCache,
    [ValidateRange(1, 300)][int]$NetworkCacheSeconds = 30,
    [ValidateRange(0, 300)][int]$NetworkNegativeCacheSeconds = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($EnableNetworkCache -and $DisableNetworkCache) {
    throw '-EnableNetworkCache and -DisableNetworkCache cannot be used together.'
}

function ConvertTo-HashtableRecursive {
    param([object]$InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-HashtableRecursive -InputObject $InputObject[$key]
        }
        return $result
    }
    if ($InputObject -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-HashtableRecursive -InputObject $property.Value
        }
        return $result
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-HashtableRecursive -InputObject $item)
        }
        return ,$items
    }
    return $InputObject
}

function Read-JsonHashtable {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "JSON file [$Path] is empty" }
    return ConvertTo-HashtableRecursive -InputObject ($raw | ConvertFrom-Json -ErrorAction Stop)
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 50
    $null = $json | ConvertFrom-Json -ErrorAction Stop
    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temp = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    $replaceBackup = "$Path.$PID.replace.bak"
    try {
        [System.IO.File]::WriteAllText($temp, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($temp, $Path, $replaceBackup, $true)
        }
        else {
            [System.IO.File]::Move($temp, $Path)
        }
        $null = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
    }
}

function Repair-StuckMaintenanceState {
    param(
        [Parameter(Mandatory = $true)][string]$VersionStatePath,
        [Parameter(Mandatory = $true)][string]$VmId
    )

    if (-not (Test-Path -LiteralPath $VersionStatePath -PathType Leaf)) {
        throw "-RepairStuckMaintenance was requested, but version state file [$VersionStatePath] does not exist. No state was changed."
    }

    $state = Read-JsonHashtable -Path $VersionStatePath
    if (-not $state.ContainsKey('templates') -or $null -eq $state.templates -or
        -not $state.templates.ContainsKey([string]$VmId)) {
        throw "-RepairStuckMaintenance was requested, but VM [$VmId] has no template entry in [$VersionStatePath]. No state was changed."
    }

    $entry = $state.templates[[string]$VmId]
    $before = $false
    if ($entry.ContainsKey('is_template')) {
        try { $before = [System.Convert]::ToBoolean($entry.is_template) }
        catch { throw "VM [$VmId] has an invalid is_template value in [$VersionStatePath]: [$($entry.is_template)]" }
    }

    # Preserve current_version and every immutable RASIMG version record. Only
    # repair the premature logical transition written by vNext21.2.
    $entry.is_template = $false
    if (-not $entry.ContainsKey('versions') -or $null -eq $entry.versions) { $entry.versions = @{} }
    $state.templates[[string]$VmId] = $entry
    Write-JsonAtomic -Path $VersionStatePath -Value $state

    $verified = Read-JsonHashtable -Path $VersionStatePath
    if (-not $verified.templates.ContainsKey([string]$VmId) -or
        [System.Convert]::ToBoolean($verified.templates[[string]$VmId].is_template)) {
        throw "Maintenance-state repair for VM [$VmId] could not be verified after writing [$VersionStatePath]."
    }

    Write-Host "Recovered stuck maintenance state for VM [$VmId]: is_template [$before] -> [False]. Existing RASIMG versions were preserved." -ForegroundColor Yellow
}

function Copy-FileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $directory = Split-Path -Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temp = "$Destination.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    $replaceBackup = "$Destination.$PID.replace.bak"
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Force
        if (Test-Path -LiteralPath $Destination) {
            [System.IO.File]::Replace($temp, $Destination, $replaceBackup, $true)
        }
        else {
            [System.IO.File]::Move($temp, $Destination)
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
    }
}

function Test-PowerShellScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($null -ne $errors -and @($errors).Count -gt 0) {
        $messages = @($errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" }) -join [Environment]::NewLine
        throw "PowerShell parser rejected [$Path]:`n$messages"
    }
}

function Merge-ProviderConfiguration {
    param(
        [hashtable]$Existing,
        [Parameter(Mandatory = $true)][hashtable]$Template,
        [switch]$Replace
    )

    if ($Replace -or $null -eq $Existing) { return $Template }

    $merged = ConvertTo-HashtableRecursive -InputObject $Existing
    $legacyPool = $merged.ContainsKey('vmid_pool_start') -or $merged.ContainsKey('vmid_pool_end')
    $splitKeys = @('rasimg_vmid_pool_start','rasimg_vmid_pool_end','session_vmid_pool_start','session_vmid_pool_end')

    foreach ($key in $Template.Keys) {
        if ($key -eq '_documentation') {
            $merged[$key] = $Template[$key]
            continue
        }
        if ($legacyPool -and $splitKeys -contains $key) {
            # Preserve an explicitly configured legacy shared pool during an
            # in-place update. The provider itself validates incompatible mixes.
            continue
        }
        if (-not $merged.ContainsKey($key)) {
            $merged[$key] = $Template[$key]
        }
    }
    return $merged
}

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
            ForEach-Object {
                Write-Host "Stopping stale provider process PID $($_.ProcessId)..."
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    }
    catch {
        Write-Warning "Could not enumerate stale provider processes: $($_.Exception.Message)"
    }
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

function Get-PowerShellEnginePaths {
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = @()

    try {
        $current = (Get-Process -Id $PID -ErrorAction Stop).Path
        if (-not [string]::IsNullOrWhiteSpace($current) -and $paths.Add($current)) { $result += $current }
    }
    catch {}

    foreach ($name in @('powershell.exe','pwsh.exe')) {
        try {
            $command = Get-Command $name -ErrorAction Stop | Select-Object -First 1
            $path = if ($command.PSObject.Properties.Name -contains 'Source') { [string]$command.Source } else { [string]$command.Path }
            if (-not [string]::IsNullOrWhiteSpace($path) -and $paths.Add($path)) { $result += $path }
        }
        catch {}
    }

    return @($result)
}

function Invoke-ProviderInitializeSmokeTest {
    param(
        [Parameter(Mandatory = $true)][string]$EnginePath,
        [Parameter(Mandatory = $true)][string]$ProviderScript
    )

    Write-Host "Smoke-testing provider/initialize with [$EnginePath]..."
    $rawOutput = '{"method":"provider/initialize"}' |
        & $EnginePath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ProviderScript

    $lines = @($rawOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { throw "Provider initialize smoke test returned no JSON response under [$EnginePath]." }

    $response = $null
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        try {
            $response = ConvertTo-HashtableRecursive -InputObject ($lines[$index] | ConvertFrom-Json -ErrorAction Stop)
            break
        }
        catch {}
    }
    if ($null -eq $response) { throw "Provider initialize smoke test returned no parseable JSON response under [$EnginePath]." }
    if ($response.ContainsKey('error')) { throw "Provider initialize smoke test failed under [$EnginePath]: $($response.error.message)" }
    if (-not $response.ContainsKey('result') -or [string]$response.result.version -ne '1.0.0') {
        throw "Provider initialize smoke test returned an unexpected protocol response under [$EnginePath]."
    }
}

function Get-ProviderBackupCandidates {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $items = @()
    $mainScript = Join-Path $Directory 'Parallels-RAS-CPF-Proxmox-Advanced.ps1'
    if (Test-Path -LiteralPath $mainScript -PathType Leaf) { $items += Get-Item -LiteralPath $mainScript }

    $items += @(Get-ChildItem -LiteralPath $Directory -File -Filter 'Proxmox-RAS-*.json*' -ErrorAction SilentlyContinue)
    $log = Join-Path $Directory 'Proxmox-RAS-Provider.log'
    if (Test-Path -LiteralPath $log -PathType Leaf) { $items += Get-Item -LiteralPath $log }

    return @($items | Sort-Object FullName -Unique)
}

function Restore-ProviderFilesFromBackup {
    param(
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [Parameter(Mandatory = $true)][string]$TargetDirectory
    )

    $targetScript = Join-Path $TargetDirectory 'Parallels-RAS-CPF-Proxmox-Advanced.ps1'
    Remove-Item -LiteralPath $targetScript -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $TargetDirectory -File -Filter 'Proxmox-RAS-*.json*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Get-ChildItem -LiteralPath $BackupDirectory -File -ErrorAction Stop |
        Where-Object {
            $_.Name -eq 'Parallels-RAS-CPF-Proxmox-Advanced.ps1' -or
            $_.Name -like 'Proxmox-RAS-*.json*'
        } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $TargetDirectory $_.Name) -Force
        }
}

function Get-NewProviderLogLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][DateTime]$SinceUtc
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $result = @()
    foreach ($line in @(Get-Content -LiteralPath $Path -Tail 250 -ErrorAction SilentlyContinue)) {
        if ([string]$line -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+(.*)$') { continue }
        $timestamp = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$timestamp)) { continue }
        if ($timestamp.ToUniversalTime() -ge $SinceUtc) { $result += [string]$line }
    }
    return @($result)
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer from an elevated PowerShell session.'
}

$candidateScript = Join-Path $SourceDirectory 'Parallels-RAS-CPF-Proxmox-Versioning-vNext21.4.ps1'
$candidateConfig = Join-Path $SourceDirectory 'Proxmox-RAS-Provider-vNext21.4.json'
$targetScript = Join-Path $TargetDirectory 'Parallels-RAS-CPF-Proxmox-Advanced.ps1'
$targetConfig = Join-Path $TargetDirectory 'Proxmox-RAS-Provider.json'
$logPath = Join-Path $TargetDirectory 'Proxmox-RAS-Provider.log'

foreach ($required in @($candidateScript, $candidateConfig)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required installation file not found: $required" }
    Unblock-File -LiteralPath $required -ErrorAction SilentlyContinue
}

Write-Host 'Validating vNext21.4 provider and configuration...'
Test-PowerShellScript -Path $candidateScript
$candidateText = Get-Content -LiteralPath $candidateScript -Raw -Encoding UTF8
if ($candidateText -notmatch [regex]::Escape('$script:ImplementationVersion = ''vNext21.4''')) {
    throw 'Candidate provider does not contain the expected vNext21.4 implementation marker.'
}
if ($candidateText -match [regex]::Escape('must be powered off before leaving RAS maintenance')) {
    throw 'Candidate provider still contains the invalid provider-side power-off guard for leaving RAS maintenance.'
}
if ($candidateText -notmatch [regex]::Escape('Parallels RAS owns the gold VM power state')) {
    throw 'Candidate provider does not contain the vNext21.4 RAS power-ownership contract.'
}
if ($candidateText -notmatch [regex]::Escape('must be powered off before creating a RAS template version')) {
    throw 'Candidate provider no longer contains the required powered-off guard for immutable RASIMG publication.'
}
$convertStart = $candidateText.IndexOf('function Handle-GuestConvert', [System.StringComparison]::Ordinal)
$convertEnd = $candidateText.IndexOf('function ConvertTo-ProxmoxSnapshotName', [System.StringComparison]::Ordinal)
if ($convertStart -lt 0 -or $convertEnd -le $convertStart) {
    throw 'Candidate provider maintenance conversion function could not be isolated.'
}
$convertSource = $candidateText.Substring($convertStart, $convertEnd - $convertStart)
if ($convertSource -match 'Get-ProxmoxVmCurrentStatus' -or $convertSource -match '/status/(?:start|stop|shutdown)') {
    throw 'Candidate provider still makes guests/convert dependent on or mutates the gold VM power state.'
}
$versionRecordStart = $candidateText.IndexOf('function Set-VersionRecord', [System.StringComparison]::Ordinal)
$versionRecordEnd = $candidateText.IndexOf('function Get-VersionImageIds', [System.StringComparison]::Ordinal)
if ($versionRecordStart -lt 0 -or $versionRecordEnd -le $versionRecordStart) {
    throw 'Candidate provider version-record function could not be isolated.'
}
$versionRecordSource = $candidateText.Substring($versionRecordStart, $versionRecordEnd - $versionRecordStart)
if ($versionRecordSource -match [regex]::Escape('$tpl.is_template = $true') -or
    $versionRecordSource -notmatch [regex]::Escape('$tpl.is_template = $false') -or
    $versionRecordSource -notmatch [regex]::Escape('must enter RAS maintenance first') -or
    $versionRecordSource -notmatch [regex]::Escape('logical template state preserved')) {
    throw 'Candidate provider still lets RASIMG publication prematurely set is_template=true.'
}
if ($candidateText -notmatch [regex]::Escape('convert_to_template_requested') -or
    $candidateText -notmatch [regex]::Escape('Apply-DeferredTemplateConversionIfRequested')) {
    throw 'Candidate provider does not persist an explicit convert(true) request across an in-flight version publish.'
}
$networkCacheStart = $candidateText.IndexOf('function Get-ProxmoxVmNetworkData', [System.StringComparison]::Ordinal)
$networkCacheEnd = $candidateText.IndexOf('function Get-ProxmoxVmOsType', [System.StringComparison]::Ordinal)
if ($networkCacheStart -lt 0 -or $networkCacheEnd -le $networkCacheStart) {
    throw 'Candidate provider VM network-cache function could not be isolated.'
}
$networkCacheSource = $candidateText.Substring($networkCacheStart, $networkCacheEnd - $networkCacheStart)
if ($networkCacheSource -match [regex]::Escape('Copy-ObjectRecursive -InputObject $cached.value') -or
    $networkCacheSource -match [regex]::Escape('value       = Copy-ObjectRecursive -InputObject $result') -or
    $candidateText -notmatch [regex]::Escape('function New-VmNetworkCacheEntry') -or
    $networkCacheSource -notmatch [regex]::Escape('ConvertFrom-VmNetworkCacheEntry') -or
    $candidateText -notmatch [regex]::Escape('ipv4_addresses = [string[]]') -or
    $candidateText -notmatch [regex]::Escape('mac_addresses  = [string[]]') -or
    $candidateText -notmatch [regex]::Escape('$value -isnot [string]') -or
    $candidateText -notmatch [regex]::Escape('[System.Net.IPAddress]::TryParse') -or
    $candidateText -notmatch [regex]::Escape('[void]$ipv4.Add') -or
    $candidateText -notmatch [regex]::Escape('[void]$macs.Add') -or
    $candidateText -notmatch [regex]::Escape('VM network cache hit for VM')) {
    throw 'Candidate provider does not contain the vNext21.4 typed VM network-cache contract.'
}
if ($candidateText -notmatch [regex]::Escape('VM network cache round-trip changed IPv4/MAC values or collection types') -or
    $candidateText -notmatch [regex]::Escape('corrupt VM network cache entry was accepted') -or
    $candidateText -notmatch [regex]::Escape('expired VM network cache entry was accepted')) {
    throw 'Candidate provider lacks the vNext21.4 network-cache regression self-test.'
}
$templateConfig = Read-JsonHashtable -Path $candidateConfig
$existingConfig = if (Test-Path -LiteralPath $targetConfig) { Read-JsonHashtable -Path $targetConfig } else { $null }
$mergedConfig = Merge-ProviderConfiguration -Existing $existingConfig -Template $templateConfig -Replace:$ReplaceConfiguration
if ($EnableNetworkCache) {
    $mergedConfig.network_cache_seconds = $NetworkCacheSeconds
    $mergedConfig.network_negative_cache_seconds = $NetworkNegativeCacheSeconds
    Write-Host ("VM network cache enabled: positive={0}s; negative={1}s." -f `
        $NetworkCacheSeconds, $NetworkNegativeCacheSeconds) -ForegroundColor Yellow
}
elseif ($DisableNetworkCache) {
    $mergedConfig.network_cache_seconds = 0
    $mergedConfig.network_negative_cache_seconds = 0
    Write-Host 'VM network cache disabled: positive=0s; negative=0s.' -ForegroundColor Yellow
}
$null = ($mergedConfig | ConvertTo-Json -Depth 50) | ConvertFrom-Json -ErrorAction Stop
foreach ($cacheKey in @('network_cache_seconds','network_negative_cache_seconds')) {
    if (-not $mergedConfig.ContainsKey($cacheKey)) { throw "Merged provider configuration is missing [$cacheKey]." }
    [int]$cacheValue = 0
    if (-not [int]::TryParse([string]$mergedConfig[$cacheKey], [ref]$cacheValue) -or $cacheValue -lt 0 -or $cacheValue -gt 300) {
        throw "Merged provider configuration has invalid [$cacheKey]=[$($mergedConfig[$cacheKey])]."
    }
}
if (-not $mergedConfig.ContainsKey('gold_vmid') -or [string]::IsNullOrWhiteSpace([string]$mergedConfig.gold_vmid)) {
    throw 'Merged provider configuration has no gold_vmid; maintenance-state repair cannot be targeted safely.'
}
$goldVmId = [string]$mergedConfig.gold_vmid
$versionStatePath = Join-Path $TargetDirectory 'Proxmox-RAS-VersionState.json'

New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
$service = Get-Service -Name $ServiceName -ErrorAction Stop
$serviceWasRunning = ($service.Status -eq 'Running')
if ($SkipServiceRestart -and $serviceWasRunning) {
    throw "-SkipServiceRestart is unsafe while [$ServiceName] is running. Stop the service first or omit the switch."
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDirectory = Join-Path $TargetDirectory "Backup-vNext21.4-$timestamp"
$installSucceeded = $false
$backupCreated = $false

try {
    if (-not $SkipServiceRestart -and $serviceWasRunning) {
        Write-Host "Stopping service '$ServiceName'..."
        Stop-Service -Name $ServiceName -Force
        Wait-ServiceState -Name $ServiceName -State Stopped
    }
    Stop-StaleProviderProcesses -TargetScript $targetScript

    # Copy a consistent snapshot only after the service/provider process stopped.
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $backupFiles = @(Get-ProviderBackupCandidates -Directory $TargetDirectory)
    foreach ($item in $backupFiles) {
        Copy-Item -LiteralPath $item.FullName -Destination $backupDirectory -Force
    }
    $manifest = @{
        created_utc                = [DateTime]::UtcNow.ToString('o')
        service_was_running        = $serviceWasRunning
        repair_stuck_maintenance   = [bool]$RepairStuckMaintenance
        repair_gold_vmid           = $goldVmId
        enable_network_cache       = [bool]$EnableNetworkCache
        disable_network_cache      = [bool]$DisableNetworkCache
        network_cache_seconds      = [int]$mergedConfig.network_cache_seconds
        network_negative_seconds   = [int]$mergedConfig.network_negative_cache_seconds
        files                      = @($backupFiles | ForEach-Object { $_.Name })
    }
    Write-JsonAtomic -Path (Join-Path $backupDirectory 'BackupManifest.json') -Value $manifest
    $backupCreated = $true

    Write-Host 'Installing provider and merging configuration...'
    Copy-FileAtomic -Source $candidateScript -Destination $targetScript
    Unblock-File -LiteralPath $targetScript -ErrorAction SilentlyContinue
    Write-JsonAtomic -Path $targetConfig -Value $mergedConfig

    if ($RepairStuckMaintenance) {
        Repair-StuckMaintenanceState -VersionStatePath $versionStatePath -VmId $goldVmId
    }

    Test-PowerShellScript -Path $targetScript
    $installedHash = (Get-FileHash -LiteralPath $targetScript -Algorithm SHA256).Hash
    $candidateHash = (Get-FileHash -LiteralPath $candidateScript -Algorithm SHA256).Hash
    if ($installedHash -ne $candidateHash) { throw 'Installed provider hash differs from the validated candidate.' }

    $engines = @(Get-PowerShellEnginePaths)
    if ($engines.Count -eq 0) { throw 'No PowerShell engine was found for the provider smoke test.' }
    foreach ($engine in $engines) {
        Invoke-ProviderInitializeSmokeTest -EnginePath $engine -ProviderScript $targetScript
    }

    if (-not $SkipServiceRestart -and $serviceWasRunning) {
        $serviceStartUtc = [DateTime]::UtcNow
        Write-Host "Starting service '$ServiceName'..."
        Start-Service -Name $ServiceName
        Wait-ServiceState -Name $ServiceName -State Running
        Start-Sleep -Seconds 15
        Wait-ServiceState -Name $ServiceName -State Running -TimeoutSeconds 15

        $newLogLines = @(Get-NewProviderLogLines -Path $logPath -SinceUtc $serviceStartUtc)
        $startupErrors = @($newLogLines | Where-Object {
            $_ -match 'Provider initialize failed|Provider configuration/initialization failed|Internal self-test failed|Failed to retrieve guest info|property ''Count'' cannot be found|System\.Collections\.Hashtable'
        })
        if ($startupErrors.Count -gt 0) {
            throw "Provider service reported configuration/runtime errors:`n$($startupErrors -join [Environment]::NewLine)"
        }
        $implementationLines = @($newLogLines | Where-Object { $_ -match 'Provider process started\. implementation=\[vNext21\.4\]' })
        if ($implementationLines.Count -eq 0) {
            throw 'Provider service did not log the expected vNext21.4 implementation marker after restart.'
        }
        if ($EnableNetworkCache) {
            $expectedCacheMarker = ("network:{0}s]" -f $NetworkCacheSeconds)
            $effectiveConfigLines = @($newLogLines | Where-Object { $_ -match 'EFFECTIVE CONFIG:' -and $_ -like "*$expectedCacheMarker*" })
            if ($effectiveConfigLines.Count -eq 0) {
                throw "Provider service did not log the requested enabled network cache value [$NetworkCacheSeconds] seconds."
            }
        }
        elseif ($DisableNetworkCache) {
            $effectiveConfigLines = @($newLogLines | Where-Object { $_ -match 'EFFECTIVE CONFIG:' -and $_ -match 'network:0s\]' })
            if ($effectiveConfigLines.Count -eq 0) {
                throw 'Provider service did not log network cache disabled (0 seconds).'
            }
        }
        $connectionWarnings = @($newLogLines | Where-Object { $_ -match 'Failed to connect to Proxmox' })
        if ($connectionWarnings.Count -gt 0) {
            Write-Warning "Provider started, but Proxmox connection errors were logged. The installation remains active because credentials/network are external to this update.`n$($connectionWarnings -join [Environment]::NewLine)"
        }
    }

    $installSucceeded = $true
    Write-Host ''
    Write-Host 'vNext21.4 installation completed successfully.' -ForegroundColor Green
    Write-Host "Provider SHA256 : $installedHash"
    Write-Host "Backup          : $backupDirectory"
    Write-Host "Configuration   : $targetConfig"
    Write-Host ("Network cache   : positive={0}s; negative={1}s" -f `
        $mergedConfig.network_cache_seconds, $mergedConfig.network_negative_cache_seconds)
    if (-not $serviceWasRunning) {
        Write-Host "Service state    : left stopped (it was stopped before installation)"
    }
    if (Test-Path -LiteralPath $logPath) {
        Write-Host ''
        Write-Host 'Latest provider log entries:'
        Get-Content -LiteralPath $logPath -Tail 30
    }
}
catch {
    $failure = $_
    Write-Warning "Installation failed; restoring the previous provider/state snapshot. Error: $($failure.Exception.Message)"
    try {
        if (-not $SkipServiceRestart) {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
        Stop-StaleProviderProcesses -TargetScript $targetScript

        if ($backupCreated) {
            if (Test-Path -LiteralPath $logPath) {
                Copy-Item -LiteralPath $logPath -Destination (Join-Path $backupDirectory 'FailedInstall-Proxmox-RAS-Provider.log') -Force -ErrorAction SilentlyContinue
            }
            Restore-ProviderFilesFromBackup -BackupDirectory $backupDirectory -TargetDirectory $TargetDirectory
        }

        if (-not $SkipServiceRestart -and $serviceWasRunning) {
            Start-Service -Name $ServiceName
            Wait-ServiceState -Name $ServiceName -State Running
        }
    }
    catch {
        Write-Warning "Automatic rollback encountered an additional error: $($_.Exception.Message). Backup is in [$backupDirectory]."
    }
    throw $failure
}
finally {
    if (-not $installSucceeded -and $backupCreated) {
        Write-Host "Installation backup retained at: $backupDirectory"
    }
}
