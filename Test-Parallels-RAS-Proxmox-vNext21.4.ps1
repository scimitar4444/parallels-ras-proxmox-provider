# Read-only post-install verification for the Parallels RAS Proxmox CPF provider vNext21.4.
[CmdletBinding()]
param(
    [string]$TargetDirectory = 'C:\CFP Scripts',
    [string]$ServiceName = 'RAS Provider Service',
    [int]$LogTail = 300,
    [switch]$ExpectMaintenance,
    [switch]$ExpectNetworkCacheEnabled,
    [switch]$ExpectNetworkCacheDisabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($ExpectNetworkCacheEnabled -and $ExpectNetworkCacheDisabled) {
    throw '-ExpectNetworkCacheEnabled and -ExpectNetworkCacheDisabled cannot be used together.'
}

function ConvertTo-HashtableRecursive {
    param([object]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) { $result[[string]$key] = ConvertTo-HashtableRecursive -InputObject $InputObject[$key] }
        return $result
    }
    if ($InputObject -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) { $result[$property.Name] = ConvertTo-HashtableRecursive -InputObject $property.Value }
        return $result
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) { $items += ,(ConvertTo-HashtableRecursive -InputObject $item) }
        return ,$items
    }
    return $InputObject
}

function Test-ScriptParser {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($null -ne $errors -and @($errors).Count -gt 0) {
        return @($errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" })
    }
    return @()
}

function Invoke-InitializeProbe {
    param([Parameter(Mandatory = $true)][string]$ProviderScript)
    $raw = '{"method":"provider/initialize"}' |
        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ProviderScript
    $lines = @($raw | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        try { return ConvertTo-HashtableRecursive -InputObject ($lines[$index] | ConvertFrom-Json -ErrorAction Stop) }
        catch {}
    }
    throw 'provider/initialize returned no parseable JSON response'
}

$providerPath = Join-Path $TargetDirectory 'Parallels-RAS-CPF-Proxmox-Advanced.ps1'
$configPath = Join-Path $TargetDirectory 'Proxmox-RAS-Provider.json'
$logPath = Join-Path $TargetDirectory 'Proxmox-RAS-Provider.log'
$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Details)
    $checks.Add([pscustomobject]@{ Check = $Name; OK = $Ok; Details = $Details }) | Out-Null
}

try {
    if (-not (Test-Path -LiteralPath $providerPath -PathType Leaf)) { throw "Provider script not found: $providerPath" }
    $parserErrors = @(Test-ScriptParser -Path $providerPath)
    Add-Check -Name 'PowerShell parser' -Ok ($parserErrors.Count -eq 0) -Details $(if ($parserErrors.Count -eq 0) { 'OK' } else { $parserErrors -join '; ' })

    $header = Get-Content -LiteralPath $providerPath -TotalCount 2 -Encoding UTF8
    $implementationOk = (($header -join ' ') -match 'vNext21.4')
    Add-Check -Name 'Implementation' -Ok $implementationOk -Details (($header -join ' ').Trim())

    $providerSource = Get-Content -LiteralPath $providerPath -Raw -Encoding UTF8
    $convertStart = $providerSource.IndexOf('function Handle-GuestConvert', [System.StringComparison]::Ordinal)
    $convertEnd = $providerSource.IndexOf('function ConvertTo-ProxmoxSnapshotName', [System.StringComparison]::Ordinal)
    $convertSource = if ($convertStart -ge 0 -and $convertEnd -gt $convertStart) {
        $providerSource.Substring($convertStart, $convertEnd - $convertStart)
    } else {
        ''
    }
    $maintenanceContractOk = (
        -not [string]::IsNullOrWhiteSpace($convertSource) -and
        $providerSource -notmatch [regex]::Escape('must be powered off before leaving RAS maintenance') -and
        $providerSource -match [regex]::Escape('Parallels RAS owns the gold VM power state') -and
        $providerSource -match [regex]::Escape('must be powered off before creating a RAS template version') -and
        $convertSource -notmatch 'Get-ProxmoxVmCurrentStatus' -and
        $convertSource -notmatch '/status/(?:start|stop|shutdown)'
    )
    Add-Check -Name 'Maintenance power ownership' -Ok $maintenanceContractOk -Details $(if ($maintenanceContractOk) {
        'RAS controls gold power; only RASIMG publication requires powered-off source'
    } else {
        'vNext21.4 maintenance power contract is missing or inconsistent'
    })

    $versionRecordStart = $providerSource.IndexOf('function Set-VersionRecord', [System.StringComparison]::Ordinal)
    $versionRecordEnd = $providerSource.IndexOf('function Get-VersionImageIds', [System.StringComparison]::Ordinal)
    $versionRecordSource = if ($versionRecordStart -ge 0 -and $versionRecordEnd -gt $versionRecordStart) {
        $providerSource.Substring($versionRecordStart, $versionRecordEnd - $versionRecordStart)
    } else { '' }
    $stateOrderingOk = (
        -not [string]::IsNullOrWhiteSpace($versionRecordSource) -and
        $versionRecordSource -notmatch [regex]::Escape('$tpl.is_template = $true') -and
        $versionRecordSource -match [regex]::Escape('$tpl.is_template = $false') -and
        $versionRecordSource -match [regex]::Escape('must enter RAS maintenance first') -and
        $versionRecordSource -match [regex]::Escape('logical template state preserved') -and
        $providerSource -match [regex]::Escape('convert_to_template_requested') -and
        $providerSource -match [regex]::Escape('Apply-DeferredTemplateConversionIfRequested')
    )
    Add-Check -Name 'Maintenance state ordering' -Ok $stateOrderingOk -Details $(if ($stateOrderingOk) {
        'snapshot publication preserves is_template=false; only explicit convert(true) closes maintenance'
    } else {
        'version publication and logical template state are still coupled'
    })

    $networkCacheStart = $providerSource.IndexOf('function Get-ProxmoxVmNetworkData', [System.StringComparison]::Ordinal)
    $networkCacheEnd = $providerSource.IndexOf('function Get-ProxmoxVmOsType', [System.StringComparison]::Ordinal)
    $networkCacheSource = if ($networkCacheStart -ge 0 -and $networkCacheEnd -gt $networkCacheStart) {
        $providerSource.Substring($networkCacheStart, $networkCacheEnd - $networkCacheStart)
    } else { '' }
    $networkCacheOk = (
        -not [string]::IsNullOrWhiteSpace($networkCacheSource) -and
        $networkCacheSource -notmatch [regex]::Escape('Copy-ObjectRecursive -InputObject $cached.value') -and
        $networkCacheSource -notmatch [regex]::Escape('value       = Copy-ObjectRecursive -InputObject $result') -and
        $providerSource -match [regex]::Escape('function New-VmNetworkCacheEntry') -and
        $networkCacheSource -match [regex]::Escape('ConvertFrom-VmNetworkCacheEntry') -and
        $networkCacheSource -match [regex]::Escape('New-VmNetworkCacheEntry') -and
        $providerSource -match [regex]::Escape('ipv4_addresses = [string[]]') -and
        $providerSource -match [regex]::Escape('mac_addresses  = [string[]]') -and
        $providerSource -match [regex]::Escape('$value -isnot [string]') -and
        $providerSource -match [regex]::Escape('[System.Net.IPAddress]::TryParse') -and
        $providerSource -match [regex]::Escape('[void]$ipv4.Add') -and
        $providerSource -match [regex]::Escape('[void]$macs.Add') -and
        $providerSource -match [regex]::Escape('VM network cache hit for VM') -and
        $providerSource -match [regex]::Escape('VM network cache round-trip changed IPv4/MAC values or collection types') -and
        $providerSource -match [regex]::Escape('corrupt VM network cache entry was accepted') -and
        $providerSource -match [regex]::Escape('expired VM network cache entry was accepted')
    )
    Add-Check -Name 'Typed VM network cache' -Ok $networkCacheOk -Details $(if ($networkCacheOk) {
        'primitive string arrays; expired/invalid entries are evicted and refreshed'
    } else {
        'vNext21.4 network-cache contract is missing or inconsistent'
    })

    $hash = (Get-FileHash -LiteralPath $providerPath -Algorithm SHA256).Hash
    Add-Check -Name 'Provider SHA256' -Ok $true -Details $hash
}
catch {
    Add-Check -Name 'Provider file' -Ok $false -Details $_.Exception.Message
}

try {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Required config not found: $configPath" }
    $rawConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $config = ConvertTo-HashtableRecursive -InputObject ($rawConfig | ConvertFrom-Json -ErrorAction Stop)
    if (-not ($config -is [System.Collections.IDictionary])) { throw 'Config root is not a JSON object' }
    $summary = 'storage={0}; placement={1}; gold={2}; pools={3}-{4}/{5}-{6}; nodes={7}' -f `
        $config.storage, $config.placement, $config.gold_vmid,
        $config.rasimg_vmid_pool_start, $config.rasimg_vmid_pool_end,
        $config.session_vmid_pool_start, $config.session_vmid_pool_end,
        (@($config.compute_nodes | ForEach-Object { "{0}:{1}" -f $_.name,$_.enabled }) -join ',')
    Add-Check -Name 'Configuration JSON' -Ok $true -Details $summary

    $positiveCache = [int]$config.network_cache_seconds
    $negativeCache = [int]$config.network_negative_cache_seconds
    $cacheDisabled = ($positiveCache -eq 0 -and $negativeCache -eq 0)
    $cacheEnabled = ($positiveCache -gt 0 -and $negativeCache -ge 0)
    $cacheConfigurationOk = (
        (-not $ExpectNetworkCacheDisabled -or $cacheDisabled) -and
        (-not $ExpectNetworkCacheEnabled -or $cacheEnabled)
    )
    Add-Check -Name 'Network cache configuration' -Ok $cacheConfigurationOk -Details ("network_cache_seconds={0}; network_negative_cache_seconds={1}; expected_enabled={2}; expected_disabled={3}" -f `
        $positiveCache, $negativeCache, [bool]$ExpectNetworkCacheEnabled, [bool]$ExpectNetworkCacheDisabled)
}
catch {
    Add-Check -Name 'Configuration JSON' -Ok $false -Details $_.Exception.Message
}

try {
    $versionStatePath = Join-Path $TargetDirectory 'Proxmox-RAS-VersionState.json'
    if (-not (Test-Path -LiteralPath $versionStatePath -PathType Leaf)) {
        Add-Check -Name 'Gold logical template state' -Ok $true -Details 'version state not created yet'
    }
    else {
        $state = ConvertTo-HashtableRecursive -InputObject ((Get-Content -LiteralPath $versionStatePath -Raw -Encoding UTF8) | ConvertFrom-Json -ErrorAction Stop)
        $goldId = [string]$config.gold_vmid
        if (-not $state.ContainsKey('templates') -or -not $state.templates.ContainsKey($goldId)) {
            Add-Check -Name 'Gold logical template state' -Ok $true -Details "VM $goldId has no logical state entry yet"
        }
        else {
            $entry = $state.templates[$goldId]
            $logical = if ($entry.ContainsKey('is_template')) { [System.Convert]::ToBoolean($entry.is_template) } else { $false }
            $current = if ($entry.ContainsKey('current_version')) { [string]$entry.current_version } else { '' }
            $versions = if ($entry.ContainsKey('versions') -and $null -ne $entry.versions) { $entry.versions.Count } else { 0 }
            $stateOk = (-not $ExpectMaintenance -or -not $logical)
            $stateDetails = "VM=$goldId; is_template=$logical; current_version=$current; versions=$versions"
            if ($ExpectMaintenance) { $stateDetails += '; expected maintenance/is_template=false' }
            Add-Check -Name 'Gold logical template state' -Ok $stateOk -Details $stateDetails
        }
    }
}
catch {
    Add-Check -Name 'Gold logical template state' -Ok $false -Details $_.Exception.Message
}

try {
    $response = Invoke-InitializeProbe -ProviderScript $providerPath
    if ($response.ContainsKey('error')) { throw [string]$response.error.message }
    if (-not $response.ContainsKey('result') -or [string]$response.result.version -ne '1.0.0') { throw 'Unexpected CPF protocol response' }
    $cap = $response.result.capabilities
    $details = 'protocol={0}; template_method={1}; linked_clones={2}; guest_poll={3}s; task_poll={4}s; retries={5}' -f `
        $response.result.version, $cap.template_method, $cap.can_link_clones,
        $cap.guests_polling_rate, $cap.tasks_polling_rate, $cap.tasks_polling_retries
    Add-Check -Name 'provider/initialize' -Ok $true -Details $details
}
catch {
    Add-Check -Name 'provider/initialize' -Ok $false -Details $_.Exception.Message
}

try {
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    Add-Check -Name 'RAS Provider Service' -Ok ($service.Status -eq 'Running') -Details ([string]$service.Status)
}
catch {
    Add-Check -Name 'RAS Provider Service' -Ok $false -Details $_.Exception.Message
}

$stateFiles = @(
    'Proxmox-RAS-CloneState.json',
    'Proxmox-RAS-VersionState.json',
    'Proxmox-RAS-VersionTasks.json',
    'Proxmox-RAS-PlacementState.json',
    'Proxmox-RAS-RecentDeletes.json',
    'Proxmox-RAS-TaskTombstones.json'
)
foreach ($name in $stateFiles) {
    $path = Join-Path $TargetDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Check -Name "State $name" -Ok $true -Details 'not created yet'
        continue
    }
    try {
        $parsed = ConvertTo-HashtableRecursive -InputObject ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json -ErrorAction Stop)
        if (-not ($parsed -is [System.Collections.IDictionary])) { throw 'JSON root is not an object' }
        $backups = @(Get-ChildItem -Path "$path.bak*" -File -ErrorAction SilentlyContinue).Count
        Add-Check -Name "State $name" -Ok $true -Details "valid; entries=$($parsed.Count); backups=$backups"
    }
    catch {
        Add-Check -Name "State $name" -Ok $false -Details $_.Exception.Message
    }
}

if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    $tail = @(Get-Content -LiteralPath $logPath -Tail $LogTail -ErrorAction SilentlyContinue)
    $activeTail = @($tail)
    $latestStartIndex = -1
    for ($index = 0; $index -lt $tail.Count; $index++) {
        if ([string]$tail[$index] -match 'Provider process started\. implementation=\[vNext21\.4\]') { $latestStartIndex = $index }
    }
    if ($latestStartIndex -ge 0 -and $tail.Count -gt 0) {
        $activeTail = @($tail[$latestStartIndex..($tail.Count - 1)])
    }

    $bad = @($activeTail | Where-Object {
        $_ -match '(?i)(Provider initialize failed|Provider configuration/initialization failed|Internal self-test failed|Failed to retrieve guest info|property ''Count'' cannot be found|STATE RECOVERY WARNING|CRITICAL:|"code"\s*:\s*-32603|System\.Collections\.Hashtable)'
    })
    Add-Check -Name 'Recent provider log' -Ok ($bad.Count -eq 0) -Details $(if ($bad.Count -eq 0) { "no critical/type-corruption pattern in $($activeTail.Count) vNext21.4 log lines" } else { ($bad | Select-Object -Last 5) -join ' | ' })
}
else {
    Add-Check -Name 'Recent provider log' -Ok $true -Details 'log not created yet'
}

$checks | Format-Table -AutoSize
$failed = @($checks | Where-Object { -not $_.OK })
if ($failed.Count -gt 0) {
    Write-Error "$($failed.Count) verification check(s) failed."
    exit 1
}
Write-Host 'vNext21.4 verification completed successfully.' -ForegroundColor Green
