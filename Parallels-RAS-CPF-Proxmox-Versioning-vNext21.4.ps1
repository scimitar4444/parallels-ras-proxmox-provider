# vNext21.4 Network-Cache Hotfix: prevents cached IP/MAC data from degrading into System.Collections.Hashtable, rejects corrupt cache entries, and keeps Parallels RAS client validation supplied with stable primitive address arrays; protocol version remains 1.0.0.
<#  
.SYNOPSIS  
    Parallels RAS Custom Provider Sample Script for Proxmox VE
.DESCRIPTION  
    This script implements a custom provider for Parallels RAS to integrate with Proxmox VE
    hypervisor. It listens for JSON-RPC requests on standard input, processes them according
    to the defined methods, and returns responses on standard output. The provider supports
    connecting to Proxmox using API tokens, listing VMs, retrieving VM information,
    controlling VM power state, converting VMs to templates, tracking clone operations, and cloning VMs. This vNext variant adds RAS template versioning using a normal gold VM,
    immutable per-version Proxmox RASIMG templates for local ZFS linked clones and version restore,
    plus deterministic multi-node placement driven by a JSON configuration file (least-loaded or round-robin).
    vNext10+ no longer creates native rasv-* snapshots on the gold VM; RASIMG is the version source of truth.
    vNext11 preserves the mutable gold VM net* configuration (including MAC address) across RASIMG restores.
    vNext12 makes hosts/list and guests/list resilient to transient Proxmox cluster resource entries that temporarily lack vmid/name properties during clone/delete operations.
    vNext13 also suppresses the expected VM-not-found polling gap while RAS deletes and recreates a host with the same VMID.
    vNext14 reduces production log noise and avoids QEMU Guest Agent network queries for powered-off VMs; optional debug_logging=true in the provider JSON restores verbose trace logging.
    vNext15 hardens cluster/QEMU-agent property handling, suppresses the remaining high-frequency guest-get trace, and restores the gold VM to the exact captured net* interface set.
    vNext16 serializes the short VMID/clone-submit critical section across session-host and RASIMG provisioning, retries explicit VMID conflicts, and commits placement only after Proxmox accepts the session-host clone.
    vNext17 adds an optional farm-owned VMID pool plus least-loaded placement with pending-clone accounting; round-robin remains available as an alternative.
    vNext18 splits farm-owned VMIDs into a dedicated RASIMG pool and a dedicated Session Host pool, keeps the gold VM outside both pools, and validates RASIMG capacity for the supported five retained RAS template versions.
    vNext19 makes guests/control delete authoritative: if RAS asks to delete a VM that is running (including a VM RAS itself restarted during recreate), the provider performs a bounded hard stop, waits for stopped state, then destroys it; normal stop remains graceful shutdown.
    vNext20 prevents deletion of a RASIMG version image while Proxmox storage still reports linked-clone child volumes that depend on that image. The guard preflights every node before the first delete and rechecks each image immediately before destroy while holding the provisioning mutex.
    vNext21 adds bounded HTTP timeouts and safe GET retries, short-lived API/config/state caches, deterministic preferred-subnet IP selection, health-aware placement, persistent recent-delete and task tombstones, rolling state backups, mandatory fail-fast configuration, version-identifiable RASIMG names, and a persistent delete intent that closes the remaining clone/delete race.
    vNext21.1 fixes PowerShell pipeline enumeration in recursive object copies so empty and single-element arrays remain arrays, normalizes cached network data before Count/index access, and runs a regression self-test during provider/initialize.
    vNext21.2 removes the incorrect powered-off prerequisite from guests/convert(is_template=true). Parallels RAS may start the gold VM for its own client/agent validation before closing maintenance; the conversion is logical only and therefore accepts both running and stopped power states. RASIMG publication still requires a stopped source VM.
    vNext21.3 fixes the remaining maintenance-state ordering defect: completing guests/snapshots/create no longer marks the gold VM as a template. The logical state remains false throughout RASIMG publication and Parallels client validation, and changes to true only when guests/convert(is_template=true) is explicitly processed (or when that explicit request was deferred onto an in-flight publish task).
    vNext21.4 replaces the generic recursive-copy network cache with a typed primitive cache, rejects malformed entries instead of stringifying them as System.Collections.Hashtable, refreshes invalid entries immediately, and adds an initialization regression test for the real cache round-trip.
    This script requires PowerShell 7 or later for best compatibility.
.NOTES  
    File Name  : Parallels-RAS-CFP-Proxmox-package2-v2.ps1
    Author     : www.parallels.com
.EXAMPLE
    .\Parallels-RAS-CFP-Proxmox-package2-v2.ps1
    Sample requests in json

    {"method": "provider/connect", "params" : { "settings": {"host":"proxmox.example.com","username":"root@pam","token_name":"automation","token_secret":"XXX"}}}
    {"method": "guests/list"}
    {"method": "guests/control","params":{"control":"start","id":"101"}}
    {"method": "guests/get","params":{"id":"101"}}
    {"method": "guests/get","params":{"id":["101","102"]}}
    {"method": "hosts/get,"params":{"id":"101"}}
    {"method": "guests/convert_to_template","params":{"id":"101"}}
    {"method": "guests/clone","params":{"source_id":"101","target_id":"102","name":"Clone of 101"}}
#>

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$script:CloneStatePath = 'C:\CFP Scripts\Proxmox-RAS-CloneState.json'
$script:VersionStatePath = 'C:\CFP Scripts\Proxmox-RAS-VersionState.json'
$script:VersionTaskStatePath = 'C:\CFP Scripts\Proxmox-RAS-VersionTasks.json'
$script:ProviderConfigPath = 'C:\CFP Scripts\Proxmox-RAS-Provider.json'
$script:PlacementStatePath = 'C:\CFP Scripts\Proxmox-RAS-PlacementState.json'
$script:DefaultTasksPollingRate = 10
$script:StateMutexName = 'Global\ParallelsRASProxmoxCPF-State-v1'
$script:LogMutexName = 'Global\ParallelsRASProxmoxCPF-Log-v1'
$script:ProvisioningMutexName = 'Global\ParallelsRASProxmoxCPF-Provisioning-v1'
$script:VmIdRetryMaxAttempts = 5
$script:MaxRasTemplateVersions = 5
$script:LogMaxBytes = 20MB
$script:LogRetentionCount = 5
$script:LogWriteCount = 0
$script:LogRotateCheckEvery = 100
$script:TraceLoggingEnabled = $false
$script:ProviderConfigCache = $null
$script:JsonStateCache = @{}
$script:ApiResponseCache = @{}
$script:VmNetworkCache = @{}
$script:TaskTombstonePath = 'C:\CFP Scripts\Proxmox-RAS-TaskTombstones.json'
$script:RecentGuestDeleteStatePath = 'C:\CFP Scripts\Proxmox-RAS-RecentDeletes.json'
$script:StateBackupGenerations = 3
$script:CompletedTaskTtlSeconds = 600
$script:FailedTaskTtlSeconds = 86400
$script:EffectiveConfigLogged = $false
$script:ProviderConfigRequired = $true
$script:InvokeRestMethodParameterNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
try {
    foreach ($parameterName in (Get-Command Invoke-RestMethod -ErrorAction Stop).Parameters.Keys) {
        [void]$script:InvokeRestMethodParameterNames.Add([string]$parameterName)
    }
}
catch {
    # Parameter feature detection remains empty; the provider will fall back to
    # the parameters available in the hosting PowerShell edition.
}

if ($Host.Name -notmatch 'ISE') {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}

$stdout = [Console]::OpenStandardOutput()
$writer = [System.IO.StreamWriter]::new($stdout, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true

$script:ProviderNamePrefix = 'Proxmox:'
$script:ImplementationVersion = 'vNext21.4'
$script:LogPath = 'C:\CFP Scripts\Proxmox-RAS-Provider.log'
$script:ProxmoxSession = $null
$script:ProxmoxWebSession = $null
$script:TaskContext = @{}
$script:RecentGuestDeletes = @{}
$script:RecentGuestDeleteTtlSeconds = 120
$script:DummyOperationTaskId = '__DUMMY_TASK__'

$script:ErrorCodes = @{
    ParseError     = -32700
    MethodNotFound = -32601
    InvalidParams  = -32602
    InternalError  = -32603
}

function Invoke-WithNamedMutex {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$TimeoutMs = 15000
    )

    $mutex = $null
    $acquired = $false

    try {
        try {
            $mutex = [System.Threading.Mutex]::new($false, $Name)
        }
        catch {
            # Global\ can be restricted in unusual service/session setups.
            $fallbackName = $Name -replace '^Global\\', ''
            $mutex = [System.Threading.Mutex]::new($false, $fallbackName)
        }

        try {
            $acquired = $mutex.WaitOne($TimeoutMs)
        }
        catch [System.Threading.AbandonedMutexException] {
            # Previous process died while owning the mutex. Ownership is
            # transferred to us, so it is safe to continue.
            $acquired = $true
        }

        if (-not $acquired) {
            throw "Timed out waiting for mutex [$Name]"
        }

        return & $ScriptBlock
    }
    finally {
        if ($null -ne $mutex) {
            if ($acquired) {
                try { $mutex.ReleaseMutex() } catch {}
            }
            $mutex.Dispose()
        }
    }
}

function Invoke-WithStateMutex {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$TimeoutMs = 15000
    )
    return Invoke-WithNamedMutex -Name $script:StateMutexName -ScriptBlock $ScriptBlock -TimeoutMs $TimeoutMs
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Object,
        [int]$Depth = 20,
        [switch]$Compress
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = if ($Compress) {
        $Object | ConvertTo-Json -Depth $Depth -Compress
    }
    else {
        $Object | ConvertTo-Json -Depth $Depth
    }

    # Validate before touching the current state file.
    $null = $json | ConvertFrom-Json -ErrorAction Stop

    if (Test-Path -LiteralPath $Path) {
        try {
            $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
            if ([string]$existing -eq [string]$json) {
                Set-CachedJsonState -Path $Path -Value $Object
                return
            }
        }
        catch {
            # A damaged current file is not copied into the retained generations.
        }
    }

    $operationId = [Guid]::NewGuid().ToString('N')
    $tempPath = "$Path.$PID.$operationId.tmp"
    $replaceBackupPath = "$Path.$PID.$operationId.replace.bak"
    $hadExistingPrimary = Test-Path -LiteralPath $Path
    $replacementCompleted = $false
    $newPrimaryCreated = $false

    try {
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))

        $generations = [Math]::Max(0, [int]$script:StateBackupGenerations)
        if ($generations -gt 0 -and $hadExistingPrimary) {
            $currentIsValid = $false
            try {
                $currentRaw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
                $null = $currentRaw | ConvertFrom-Json -ErrorAction Stop
                $currentIsValid = $true
            }
            catch {}

            if ($currentIsValid) {
                for ($generation = $generations; $generation -ge 2; $generation--) {
                    $from = "$Path.bak$($generation - 1)"
                    $to = "$Path.bak$generation"
                    if (Test-Path -LiteralPath $from) {
                        [System.IO.File]::Copy($from, $to, $true)
                    }
                }
                [System.IO.File]::Copy($Path, "$Path.bak1", $true)
            }
        }

        if ($hadExistingPrimary) {
            [System.IO.File]::Replace($tempPath, $Path, $replaceBackupPath, $true)
            $replacementCompleted = $true
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
            $newPrimaryCreated = $true
        }

        try {
            # Read-after-write validation catches unexpected filesystem/encoding issues.
            $verify = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
            $null = $verify | ConvertFrom-Json -ErrorAction Stop
            Set-CachedJsonState -Path $Path -Value $Object
        }
        catch {
            $verifyError = $_
            # File.Replace already created a same-volume backup of the previous
            # primary. Restore it if verification of the new state fails. For a
            # newly-created state file, remove the invalid primary so the caller
            # cannot mistake it for a committed operation journal.
            try {
                if ($replacementCompleted -and (Test-Path -LiteralPath $replaceBackupPath)) {
                    [System.IO.File]::Copy($replaceBackupPath, $Path, $true)
                }
                elseif ($newPrimaryCreated -and (Test-Path -LiteralPath $Path)) {
                    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
                }
                if ($script:JsonStateCache.ContainsKey($Path)) {
                    [void]$script:JsonStateCache.Remove($Path)
                }
            }
            catch {
                throw "State verification failed for [$Path] and rollback of the previous primary also failed: verify=[$($verifyError.Exception.Message)]; rollback=[$($_.Exception.Message)]"
            }
            throw $verifyError
        }
    }
    finally {
        foreach ($temporaryPath in @($tempPath, $replaceBackupPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function ConvertTo-SafeLogLine {
    param([string]$InputLine)

    if ([string]::IsNullOrEmpty($InputLine)) {
        return $InputLine
    }

    # Never persist credentials received in provider/connect or future
    # settings. Keep key names visible for troubleshooting.
    $pattern = '(?i)("(?:token_secret|password|secret)"\s*:\s*")[^"]*(")'
    return [regex]::Replace($InputLine, $pattern, '$1***REDACTED***$2')
}

function Rotate-DebugLogIfNeeded {
    if (-not (Test-Path -LiteralPath $script:LogPath)) { return }

    $item = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.Length -lt $script:LogMaxBytes) { return }

    for ($i = $script:LogRetentionCount; $i -ge 1; $i--) {
        $current = if ($i -eq 1) { $script:LogPath } else { "$($script:LogPath).$($i - 1)" }
        $target = "$($script:LogPath).$i"

        if ($i -eq $script:LogRetentionCount -and (Test-Path -LiteralPath $target)) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $current) {
            Move-Item -LiteralPath $current -Destination $target -Force -ErrorAction Stop
        }
    }
}

function Test-IsNoisyProductionLogMessage {
    param([AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }

    # High-frequency polling/trace messages are useful during development but
    # make the production provider log grow quickly without adding operational
    # value. Errors and all mutating operations remain logged normally.
    if ($Message -match '^HTTP GET ') { return $true }
    if ($Message -match '^IN \(PID=\d+\): \{"method":"(?:guests/list|guests/get|hosts/list|hosts/get|tasks/get)"') { return $true }
    if ($Message -match '^OUT: \{"result":') { return $true }
    if ($Message -match '^GUEST VMID=') { return $true }
    if ($Message -match '^Skipping internal RAS version image VM ') { return $true }
    if ($Message -match '^Skipping transient cluster VM ') { return $true }
    if ($Message -match '^TRACKED CLONE (?:FOUND|NOT FOUND)') { return $true }
    if ($Message -match '^CLONE-AWARE FLOW: (?:no tracked clone context|tracked clone context found)') { return $true }
    if ($Message -match '^CLONE-AWARE FLOW RESULT ') { return $true }
    if ($Message -match '^HANDLE-GUESTGET using clone-aware flow ') { return $true }
    if ($Message -match '^TASK CONTEXT FOUND IN MEMORY ') { return $true }

    return $false
}

function Write-DebugLog {
    param([string]$Message)

    if (-not $script:TraceLoggingEnabled -and (Test-IsNoisyProductionLogMessage -Message $Message)) {
        return
    }

    try {
        Invoke-WithNamedMutex -Name $script:LogMutexName -TimeoutMs 3000 -ScriptBlock {
            $script:LogWriteCount++
            if ($script:LogWriteCount -eq 1 -or
                ($script:LogWriteCount % $script:LogRotateCheckEvery) -eq 0) {
                Rotate-DebugLogIfNeeded
            }

            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            Add-Content -LiteralPath $script:LogPath -Value "$timestamp $Message" -Encoding UTF8
        } | Out-Null
    }
    catch {
        # Never emit logging failures to stdout.
    }
}

function Write-TraceLog {
    param([string]$Message)
    if ($script:TraceLoggingEnabled) {
        Write-DebugLog -Message $Message
    }
}

function Get-CloneStateEntryByTaskId {
    param([Parameter(Mandatory = $true)][string]$TaskId)

    $all = Get-CloneStateAll
    foreach ($key in $all.Keys) {
        $entry = $all[$key]
        if ($null -eq $entry -or -not ($entry -is [System.Collections.IDictionary])) { continue }
        if (-not $entry.Contains('task_id') -or [string]$entry['task_id'] -ne [string]$TaskId) { continue }

        $ctx = Copy-ObjectRecursive -InputObject $entry
        if (-not $ctx.ContainsKey('type')) { $ctx.type = 'clone' }
        if (-not $ctx.ContainsKey('clone_id')) { $ctx.clone_id = [string]$key }
        Write-DebugLog "CLONE STATE FOUND BY TASK ID for task [$TaskId], clone VM [$($ctx.clone_id)]"
        return $ctx
    }
    Write-DebugLog "CLONE STATE NOT FOUND BY TASK ID for task [$TaskId]"
    return $null
}

function Get-CloneState {
    try {
        $state = Get-CachedJsonState -Path $script:CloneStatePath -DefaultValue @{}
        if ($null -eq $state) { return @{} }
        return $state
    }
    catch {
        Write-DebugLog "Failed to load clone state: $($_.Exception.Message)"
        throw "Clone state file [$($script:CloneStatePath)] is unreadable: $($_.Exception.Message)"
    }
}

function Save-CloneState {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    try { Write-JsonFileAtomic -Path $script:CloneStatePath -Object $State -Depth 20 -Compress }
    catch { Write-DebugLog "Failed to save clone state: $($_.Exception.Message)"; throw }
}

function Set-CloneStateEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmId,

        [Parameter(Mandatory = $true)]
        [hashtable]$Entry
    )

    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-CloneState
        $state[[string]$VmId] = $Entry
        Save-CloneState -State $state
    } | Out-Null
}

function Get-CloneStateAll {
    return Get-CloneState
}

function Get-CloneStateEntry {
    param([Parameter(Mandatory = $true)][string]$VmId)

    $all = Get-CloneStateAll
    if ($all.ContainsKey($VmId)) { return Copy-ObjectRecursive -InputObject $all[$VmId] }

    foreach ($key in $all.Keys) {
        $entry = $all[$key]
        if ($null -eq $entry -or -not ($entry -is [System.Collections.IDictionary])) { continue }
        if ($entry.Contains('clone_id') -and [string]$entry['clone_id'] -eq [string]$VmId) {
            Write-DebugLog "CLONE STATE MATCHED via clone_id for VM [$VmId] (key [$key])"
            return Copy-ObjectRecursive -InputObject $entry
        }
    }
    return $null
}

function Remove-CloneStateEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmId
    )

    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-CloneState
        if ($state.ContainsKey([string]$VmId)) {
            [void]$state.Remove([string]$VmId)
            Save-CloneState -State $state
        }
    } | Out-Null
}

# -----------------------------------------------------------------------------
# RAS template-version metadata
#
# Design for Proxmox/ZFS:
#   * The RAS gold VM remains a NORMAL Proxmox VM permanently.
#   * guests/convert only changes a logical template flag for RAS.
#   * Each RAS version creates immutable full-clone RASIMG templates on the
#     configured local-ZFS nodes. RASIMG is both the linked-clone deployment
#     base and the version-restore source for the mutable gold VM.
#   * vNext10+ creates no native rasv-* snapshots on the gold VM.
#   * vNext11 captures the current gold net* configuration before replacement and
#     reapplies it to the restored VM before the restore task is completed.
#   * RAS clones are linked clones of that immutable per-version template.
#
# This avoids writing into a Proxmox base-* volume after @__base__ was created.
# -----------------------------------------------------------------------------

function Copy-ObjectRecursive {
    param([object]$InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in $InputObject.Keys) {
            $copy[[string]$key] = Copy-ObjectRecursive -InputObject $InputObject[$key]
        }
        return $copy
    }

    if ($InputObject -is [pscustomobject]) {
        $copy = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $copy[$property.Name] = Copy-ObjectRecursive -InputObject $property.Value
        }
        return $copy
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(Copy-ObjectRecursive -InputObject $item)
        }
        # PowerShell enumerates arrays written to the success stream. Without the
        # unary comma, an empty array becomes $null and a one-element array becomes
        # a scalar when nested in a hashtable/cache entry. Return the array as one
        # pipeline object so its collection shape is preserved exactly.
        return ,$items
    }

    return $InputObject
}

function ConvertTo-NormalizedNetworkData {
    param([AllowNull()][object]$NetworkData)

    $ipv4Source = $null
    $macSource = $null

    if ($NetworkData -is [System.Collections.IDictionary]) {
        if ($NetworkData.Contains('IPv4Addresses')) { $ipv4Source = $NetworkData['IPv4Addresses'] }
        if ($NetworkData.Contains('MacAddresses')) { $macSource = $NetworkData['MacAddresses'] }
    }
    elseif ($null -ne $NetworkData) {
        $ipv4Property = $NetworkData.PSObject.Properties['IPv4Addresses']
        $macProperty = $NetworkData.PSObject.Properties['MacAddresses']
        if ($null -ne $ipv4Property) { $ipv4Source = $ipv4Property.Value }
        if ($null -ne $macProperty) { $macSource = $macProperty.Value }
    }

    $ipv4 = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($ipv4Source)) {
        # Network protocol fields are primitive strings. Never coerce a complex
        # object to text: [string]@{} becomes "System.Collections.Hashtable" and
        # poisons the RAS client/agent validation loop.
        if ($null -eq $value -or $value -isnot [string]) { continue }
        $textValue = $value.Trim()
        if ([string]::IsNullOrWhiteSpace($textValue)) { continue }
        [System.Net.IPAddress]$parsedAddress = $null
        if ([System.Net.IPAddress]::TryParse($textValue, [ref]$parsedAddress) -and
            $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            $normalizedIp = $parsedAddress.ToString()
            if (-not $ipv4.Contains($normalizedIp)) { [void]$ipv4.Add($normalizedIp) }
        }
    }

    $macs = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($macSource)) {
        if ($null -eq $value -or $value -isnot [string]) { continue }
        $textValue = $value.Trim()
        if ($textValue -notmatch '^[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}$') { continue }
        $normalizedMac = $textValue.Replace('-', ':').ToUpperInvariant()
        if (-not $macs.Contains($normalizedMac)) { [void]$macs.Add($normalizedMac) }
    }

    return @{
        IPv4Addresses = [string[]]$ipv4.ToArray()
        MacAddresses  = [string[]]$macs.ToArray()
    }
}

function New-VmNetworkCacheEntry {
    param(
        [Parameter(Mandatory = $true)][object]$NetworkData,
        [Parameter(Mandatory = $true)][ValidateRange(1, 300)][int]$TtlSeconds
    )

    $normalized = ConvertTo-NormalizedNetworkData -NetworkData $NetworkData
    return @{
        expires_utc    = [DateTime]::UtcNow.AddSeconds($TtlSeconds)
        ipv4_addresses = [string[]]@($normalized.IPv4Addresses)
        mac_addresses  = [string[]]@($normalized.MacAddresses)
    }
}

function ConvertFrom-VmNetworkCacheEntry {
    param([AllowNull()][object]$Entry)

    if ($null -eq $Entry) { return $null }

    $hasExpiry = $false
    $hasIpv4 = $false
    $hasMacs = $false
    $expirySource = $null
    $ipv4Source = $null
    $macSource = $null

    if ($Entry -is [System.Collections.IDictionary]) {
        $hasExpiry = $Entry.Contains('expires_utc')
        $hasIpv4 = $Entry.Contains('ipv4_addresses')
        $hasMacs = $Entry.Contains('mac_addresses')
        if ($hasExpiry) { $expirySource = $Entry['expires_utc'] }
        if ($hasIpv4) { $ipv4Source = $Entry['ipv4_addresses'] }
        if ($hasMacs) { $macSource = $Entry['mac_addresses'] }
    }
    else {
        $expiryProperty = $Entry.PSObject.Properties['expires_utc']
        $ipv4Property = $Entry.PSObject.Properties['ipv4_addresses']
        $macProperty = $Entry.PSObject.Properties['mac_addresses']
        $hasExpiry = ($null -ne $expiryProperty)
        $hasIpv4 = ($null -ne $ipv4Property)
        $hasMacs = ($null -ne $macProperty)
        if ($hasExpiry) { $expirySource = $expiryProperty.Value }
        if ($hasIpv4) { $ipv4Source = $ipv4Property.Value }
        if ($hasMacs) { $macSource = $macProperty.Value }
    }

    if (-not $hasExpiry -or -not $hasIpv4 -or -not $hasMacs -or $null -eq $expirySource) { return $null }

    $expiresUtc = [DateTime]::MinValue
    try { $expiresUtc = ([DateTime]$expirySource).ToUniversalTime() }
    catch { return $null }
    if ([DateTime]::UtcNow -ge $expiresUtc) { return $null }

    $rawIpv4 = @($ipv4Source)
    $rawMacs = @($macSource)
    foreach ($value in $rawIpv4) {
        if ($null -eq $value -or $value -isnot [string]) { return $null }
    }
    foreach ($value in $rawMacs) {
        if ($null -eq $value -or $value -isnot [string]) { return $null }
    }

    $normalized = ConvertTo-NormalizedNetworkData -NetworkData @{
        IPv4Addresses = [string[]]$rawIpv4
        MacAddresses  = [string[]]$rawMacs
    }

    # A malformed primitive string is also corruption. Do not return a partially
    # normalized cache hit; evict it and immediately query the guest agent again.
    if (@($normalized.IPv4Addresses).Count -ne $rawIpv4.Count -or
        @($normalized.MacAddresses).Count -ne $rawMacs.Count) {
        return $null
    }

    return $normalized
}

function Invoke-ProviderInternalSelfTest {
    # Regression coverage for the cache/state bug that surfaced after a gold
    # restore: recursive function output enumeration converted [] to $null and
    # [x] to x. Under StrictMode, the next cached guests/get could then fail on
    # .Count. Keep this test local, deterministic and API-free so every provider
    # initialize validates the object-shape invariants before RAS uses it.
    $sample = @{
        empty  = @()
        single = @('one')
        many   = @('one','two')
        nested = @{ values = @('nested') }
    }

    $copied = Copy-ObjectRecursive -InputObject $sample
    if (-not ($copied.empty -is [System.Array]) -or @($copied.empty).Count -ne 0) {
        throw 'Internal self-test failed: Copy-ObjectRecursive did not preserve an empty array'
    }
    if (-not ($copied.single -is [System.Array]) -or @($copied.single).Count -ne 1 -or [string]$copied.single[0] -ne 'one') {
        throw 'Internal self-test failed: Copy-ObjectRecursive did not preserve a single-element array'
    }
    if (-not ($copied.many -is [System.Array]) -or @($copied.many).Count -ne 2) {
        throw 'Internal self-test failed: Copy-ObjectRecursive did not preserve a multi-element array'
    }
    if (-not ($copied.nested.values -is [System.Array]) -or @($copied.nested.values).Count -ne 1) {
        throw 'Internal self-test failed: Copy-ObjectRecursive did not preserve a nested array'
    }

    $jsonObject = [pscustomobject]@{
        empty  = @()
        single = @('one')
        many   = @('one','two')
    }
    $converted = ConvertTo-HashtableRecursive -InputObject $jsonObject
    if (-not ($converted.empty -is [System.Array]) -or @($converted.empty).Count -ne 0) {
        throw 'Internal self-test failed: ConvertTo-HashtableRecursive did not preserve an empty JSON array'
    }
    if (-not ($converted.single -is [System.Array]) -or @($converted.single).Count -ne 1) {
        throw 'Internal self-test failed: ConvertTo-HashtableRecursive did not preserve a single-element JSON array'
    }

    $normalizedEmpty = ConvertTo-NormalizedNetworkData -NetworkData @{ IPv4Addresses = $null; MacAddresses = $null }
    $normalizedSingle = ConvertTo-NormalizedNetworkData -NetworkData @{ IPv4Addresses = '192.0.2.12'; MacAddresses = 'bc:24:11:aa:bb:cc' }
    if (-not ($normalizedEmpty.IPv4Addresses -is [System.Array]) -or @($normalizedEmpty.IPv4Addresses).Count -ne 0) {
        throw 'Internal self-test failed: empty network IP data was not normalized to an array'
    }
    if (-not ($normalizedSingle.IPv4Addresses -is [System.Array]) -or @($normalizedSingle.IPv4Addresses).Count -ne 1) {
        throw 'Internal self-test failed: single network IP data was not normalized to an array'
    }
    if (-not ($normalizedSingle.MacAddresses -is [System.Array]) -or @($normalizedSingle.MacAddresses).Count -ne 1 -or [string]$normalizedSingle.MacAddresses[0] -ne 'BC:24:11:AA:BB:CC') {
        throw 'Internal self-test failed: single network MAC data was not normalized correctly'
    }

    # Exercise the actual vNext21.4 cache write/read representation, not only
    # the generic object copier. This is the round-trip that failed in vNext21.3.
    $cacheProbeKey = '__vNext21.4_network_cache_selftest__'
    $script:VmNetworkCache[$cacheProbeKey] = New-VmNetworkCacheEntry -NetworkData @{
        IPv4Addresses = [string[]]@('192.0.2.10')
        MacAddresses  = [string[]]@('BC:24:11:D1:D4:6D')
    } -TtlSeconds 60
    try {
        $cacheProbeResult = ConvertFrom-VmNetworkCacheEntry -Entry $script:VmNetworkCache[$cacheProbeKey]
        if ($null -eq $cacheProbeResult -or
            -not ($cacheProbeResult.IPv4Addresses -is [System.Array]) -or
            @($cacheProbeResult.IPv4Addresses).Count -ne 1 -or
            [string]$cacheProbeResult.IPv4Addresses[0] -ne '192.0.2.10' -or
            -not ($cacheProbeResult.MacAddresses -is [System.Array]) -or
            @($cacheProbeResult.MacAddresses).Count -ne 1 -or
            [string]$cacheProbeResult.MacAddresses[0] -ne 'BC:24:11:D1:D4:6D') {
            throw 'Internal self-test failed: VM network cache round-trip changed IPv4/MAC values or collection types'
        }
    }
    finally {
        [void]$script:VmNetworkCache.Remove($cacheProbeKey)
    }

    $invalidCacheProbe = @{
        expires_utc    = [DateTime]::UtcNow.AddMinutes(1)
        ipv4_addresses = @(@{ invalid = 'complex-object' })
        mac_addresses  = @(@{ invalid = 'complex-object' })
    }
    $invalidCacheResult = ConvertFrom-VmNetworkCacheEntry -Entry $invalidCacheProbe
    if ($null -ne $invalidCacheResult) {
        throw 'Internal self-test failed: corrupt VM network cache entry was accepted'
    }

    $expiredCacheProbe = New-VmNetworkCacheEntry -NetworkData @{
        IPv4Addresses = [string[]]@('192.0.2.10')
        MacAddresses  = [string[]]@('BC:24:11:D1:D4:6D')
    } -TtlSeconds 60
    $expiredCacheProbe['expires_utc'] = [DateTime]::UtcNow.AddSeconds(-1)
    if ($null -ne (ConvertFrom-VmNetworkCacheEntry -Entry $expiredCacheProbe)) {
        throw 'Internal self-test failed: expired VM network cache entry was accepted'
    }
}

function Get-FileCacheStamp {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return ('{0}:{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length)
}

function Set-CachedJsonState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $script:JsonStateCache[$Path] = @{
        stamp = Get-FileCacheStamp -Path $Path
        value = Copy-ObjectRecursive -InputObject $Value
    }
}

function Get-CachedJsonState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$DefaultValue
    )

    $stamp = Get-FileCacheStamp -Path $Path
    if ($script:JsonStateCache.ContainsKey($Path)) {
        $entry = $script:JsonStateCache[$Path]
        if ($null -ne $entry -and [string]$entry.stamp -eq [string]$stamp) {
            return Copy-ObjectRecursive -InputObject $entry.value
        }
    }

    $candidates = @($Path)
    for ($generation = 1; $generation -le [Math]::Max(0, [int]$script:StateBackupGenerations); $generation++) {
        $candidates += "$Path.bak$generation"
    }

    $firstError = $null
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $raw = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) { throw 'JSON file is empty' }
            $parsed = ConvertTo-HashtableRecursive -InputObject ($raw | ConvertFrom-Json -ErrorAction Stop)
            if (-not ($parsed -is [System.Collections.IDictionary])) {
                throw 'JSON state root must be an object'
            }
            if ($candidate -ne $Path) {
                Write-DebugLog "STATE RECOVERY: [$Path] is unreadable; using valid backup [$candidate]."
                try {
                    # Repair the primary file immediately so the next process start
                    # does not depend on the backup generation again.
                    Write-JsonFileAtomic -Path $Path -Object $parsed -Depth 30
                    $stamp = Get-FileCacheStamp -Path $Path
                    Write-DebugLog "STATE RECOVERY: primary state file [$Path] repaired from [$candidate]."
                }
                catch {
                    Write-DebugLog "STATE RECOVERY WARNING: failed to repair primary state file [$Path] from [$candidate]: $($_.Exception.Message)"
                }
            }
            $script:JsonStateCache[$Path] = @{
                stamp = $stamp
                value = Copy-ObjectRecursive -InputObject $parsed
            }
            return Copy-ObjectRecursive -InputObject $parsed
        }
        catch {
            if ($null -eq $firstError) { $firstError = $_.Exception.Message }
        }
    }

    if ($stamp -eq 'missing') {
        $value = Copy-ObjectRecursive -InputObject $DefaultValue
        $script:JsonStateCache[$Path] = @{ stamp = 'missing'; value = Copy-ObjectRecursive -InputObject $value }
        return $value
    }

    throw "State file [$Path] and all retained backups are unreadable. First error: $firstError"
}

function Clear-ProxmoxApiCache {
    $script:ApiResponseCache = @{}
    $script:VmNetworkCache = @{}
}

function Get-ProxmoxGetCacheTtlSeconds {
    param([Parameter(Mandatory = $true)][string]$Path)

    $cfg = Get-ProviderConfig
    if ($Path -match '/tasks/.+/status$') { return 0 }
    if ($Path -match '/agent/network-get-interfaces$') { return 0 }
    if ($Path -eq '/api2/json/cluster/resources?type=vm') { return [int]$cfg.inventory_cache_seconds }
    if ($Path -match '/qemu/\d+/config$') { return [int]$cfg.vm_config_cache_seconds }
    if ($Path -match '/qemu/\d+/status/current$') { return [int]$cfg.vm_status_cache_seconds }
    if ($Path -eq '/api2/json/nodes') { return [int]$cfg.node_health_cache_seconds }
    if ($Path -match '/storage/.+/status$') { return [int]$cfg.node_health_cache_seconds }
    if ($Path -match '/storage/.+/content\?content=images$') { return [int]$cfg.storage_content_cache_seconds }
    if ($Path -match '/qemu/\d+/snapshot$') { return 2 }
    if ($Path -eq '/api2/json/version') { return 30 }
    return 0
}

function Get-CachedApiResponse {
    param([Parameter(Mandatory = $true)][string]$Key)

    if (-not $script:ApiResponseCache.ContainsKey($Key)) { return $null }
    $entry = $script:ApiResponseCache[$Key]
    if ($null -eq $entry -or [DateTime]::UtcNow -ge [DateTime]$entry.expires_utc) {
        [void]$script:ApiResponseCache.Remove($Key)
        return $null
    }
    return $entry.value
}

function Set-CachedApiResponse {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][int]$TtlSeconds
    )

    if ($TtlSeconds -le 0) { return }
    $script:ApiResponseCache[$Key] = @{
        expires_utc = [DateTime]::UtcNow.AddSeconds($TtlSeconds)
        value       = $Value
    }
}

function ConvertTo-IPv4UInt32 {
    param([Parameter(Mandatory = $true)][string]$Address)

    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $null }
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $bytes = $ip.GetAddressBytes()
    return (([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3])
}

function Test-IPv4InCidr {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Cidr
    )

    $parts = @($Cidr.Trim() -split '/')
    if ($parts.Count -ne 2) { return $false }
    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) { return $false }
    $addressValue = ConvertTo-IPv4UInt32 -Address $Address
    $networkValue = ConvertTo-IPv4UInt32 -Address $parts[0]
    if ($null -eq $addressValue -or $null -eq $networkValue) { return $false }
    $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $prefix) }
    return (($addressValue -band $mask) -eq ($networkValue -band $mask))
}

function Sort-PreferredIPv4Addresses {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Addresses)

    $cfg = Get-ProviderConfig
    $cidrs = @($cfg.preferred_ipv4_cidrs)
    $ranked = @()
    foreach ($address in @($Addresses | Sort-Object -Unique)) {
        $rank = $cidrs.Count + 1
        for ($index = 0; $index -lt $cidrs.Count; $index++) {
            if (Test-IPv4InCidr -Address $address -Cidr ([string]$cidrs[$index])) {
                $rank = $index
                break
            }
        }
        $numeric = ConvertTo-IPv4UInt32 -Address $address
        if ($null -eq $numeric) { $numeric = [uint32]::MaxValue }
        $ranked += [pscustomobject]@{ address = $address; rank = $rank; numeric = $numeric }
    }
    return @($ranked | Sort-Object rank, numeric | ForEach-Object { [string]$_.address })
}

function Get-VmNetworkCacheKey {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$VmId,
        [object]$Config
    )

    $identity = ''
    if ($null -ne $Config) {
        foreach ($propertyName in @('vmgenid','smbios1')) {
            $property = $Config.PSObject.Properties[$propertyName]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $identity += "|$propertyName=$([string]$property.Value)"
            }
        }
        foreach ($property in @($Config.PSObject.Properties | Where-Object { $_.Name -match '^net\d+$' } | Sort-Object Name)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $identity += "|$($property.Name)=$([string]$property.Value)"
            }
        }
    }
    return "$Node|$VmId$identity"
}

function Get-TaskTombstoneState {
    $state = Get-CachedJsonState -Path $script:TaskTombstonePath -DefaultValue @{}
    if ($null -eq $state) { return @{} }
    return $state
}

function Save-TaskTombstoneState {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Write-JsonFileAtomic -Path $script:TaskTombstonePath -Object $State -Depth 20 -Compress
}

function Remove-ExpiredTaskTombstones {
    param([hashtable]$State = $null)

    $localState = if ($null -ne $State) { $State } else { Get-TaskTombstoneState }
    $changed = $false
    foreach ($taskId in @($localState.Keys)) {
        $entry = $localState[$taskId]
        $expires = [DateTime]::MinValue
        if ($null -eq $entry -or -not $entry.ContainsKey('expires_utc') -or
            -not [DateTime]::TryParse([string]$entry.expires_utc, [ref]$expires) -or
            [DateTime]::UtcNow -ge $expires) {
            [void]$localState.Remove($taskId)
            $changed = $true
        }
    }
    if ($changed) { Save-TaskTombstoneState -State $localState }
    return $localState
}

function Set-TaskTombstone {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][hashtable]$Result,
        [hashtable]$Context = $null
    )

    Invoke-WithStateMutex -ScriptBlock {
        $state = Remove-ExpiredTaskTombstones -State (Get-TaskTombstoneState)
        $terminalState = if ($Result.ContainsKey('state')) { [string]$Result.state } else { '' }
        $ttl = if ($terminalState -eq 'failed') {
            [Math]::Max(300, [int]$script:FailedTaskTtlSeconds)
        }
        else {
            [Math]::Max(60, [int]$script:CompletedTaskTtlSeconds)
        }
        $state[$TaskId] = @{
            result      = Copy-ObjectRecursive -InputObject $Result
            context     = Copy-ObjectRecursive -InputObject $Context
            expires_utc = [DateTime]::UtcNow.AddSeconds($ttl).ToString('o')
        }
        Save-TaskTombstoneState -State $state
    } | Out-Null
}

function Get-TaskTombstone {
    param([Parameter(Mandatory = $true)][string]$TaskId)

    return Invoke-WithStateMutex -ScriptBlock {
        $state = Remove-ExpiredTaskTombstones -State (Get-TaskTombstoneState)
        if (-not $state.ContainsKey($TaskId)) { return $null }
        $entry = $state[$TaskId]
        if ($null -eq $entry -or -not $entry.ContainsKey('result')) { return $null }
        return Copy-ObjectRecursive -InputObject $entry.result
    }
}

function Get-RecentGuestDeleteState {
    $state = Get-CachedJsonState -Path $script:RecentGuestDeleteStatePath -DefaultValue @{}
    if ($null -eq $state) { return @{} }
    return $state
}

function Save-RecentGuestDeleteState {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Write-JsonFileAtomic -Path $script:RecentGuestDeleteStatePath -Object $State -Depth 10 -Compress
}

function ConvertTo-HashtableRecursive {
    param([object]$InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($key in $InputObject.Keys) {
            $ht[[string]$key] = ConvertTo-HashtableRecursive -InputObject $InputObject[$key]
        }
        return $ht
    }

    if ($InputObject -is [pscustomobject]) {
        $ht = @{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $ht[$p.Name] = ConvertTo-HashtableRecursive -InputObject $p.Value
        }
        return $ht
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-HashtableRecursive -InputObject $item)
        }
        # Preserve empty and single-element JSON arrays as arrays under StrictMode.
        return ,$items
    }

    return $InputObject
}

function Get-ProviderConfig {
    param([switch]$ForInitialize)

    $defaults = @{
        storage                          = 'local-zfs'
        placement                        = 'round_robin'
        guests_polling_rate              = 5
        tasks_polling_rate               = [int]$script:DefaultTasksPollingRate
        task_observation_horizon_seconds = 14400
        clone_ready_timeout_seconds      = 900
        debug_logging                    = $false
        api_connection_timeout_seconds   = 5
        api_operation_timeout_seconds    = 20
        api_get_max_retries              = 2
        api_get_retry_interval_seconds   = 1
        inventory_cache_seconds          = 2
        vm_config_cache_seconds          = 60
        vm_status_cache_seconds          = 2
        network_cache_seconds            = 30
        network_negative_cache_seconds   = 1
        node_health_cache_seconds        = 10
        storage_content_cache_seconds    = 2
        minimum_storage_free_gb          = 0
        minimum_storage_free_percent     = 0
        state_backup_generations         = 3
        completed_task_ttl_seconds       = 600
        failed_task_ttl_seconds          = 86400
        preferred_ipv4_cidrs             = @()
        gold_vmid                        = $null
        rasimg_vmid_pool_start           = $null
        rasimg_vmid_pool_end             = $null
        session_vmid_pool_start          = $null
        session_vmid_pool_end            = $null
        # Legacy vNext17 shared pool remains readable for in-place upgrades.
        vmid_pool_start                  = $null
        vmid_pool_end                    = $null
        compute_nodes                    = @()
    }

    try {
        $stamp = Get-FileCacheStamp -Path $script:ProviderConfigPath
        if ($null -ne $script:ProviderConfigCache -and
            [string]$script:ProviderConfigCache.stamp -eq [string]$stamp) {
            $cachedConfig = Copy-ObjectRecursive -InputObject $script:ProviderConfigCache.value
            $script:TraceLoggingEnabled = [bool]$cachedConfig.debug_logging
            $script:StateBackupGenerations = [int]$cachedConfig.state_backup_generations
            $script:CompletedTaskTtlSeconds = [int]$cachedConfig.completed_task_ttl_seconds
            $script:FailedTaskTtlSeconds = [int]$cachedConfig.failed_task_ttl_seconds
            return $cachedConfig
        }

        if (-not (Test-Path -LiteralPath $script:ProviderConfigPath)) {
            if ($script:ProviderConfigRequired) {
                throw "Required provider config file is missing"
            }
            if (-not $ForInitialize) {
                Write-DebugLog "Provider config [$($script:ProviderConfigPath)] not found; falling back to compatibility defaults."
            }
            $cfg = Copy-ObjectRecursive -InputObject $defaults
            $script:ProviderConfigCache = @{ stamp = 'missing'; value = Copy-ObjectRecursive -InputObject $cfg }
            $script:TraceLoggingEnabled = [bool]$cfg.debug_logging
            $script:StateBackupGenerations = [int]$cfg.state_backup_generations
            $script:CompletedTaskTtlSeconds = [int]$cfg.completed_task_ttl_seconds
            $script:FailedTaskTtlSeconds = [int]$cfg.failed_task_ttl_seconds
            return $cfg
        }

        $raw = Get-Content -LiteralPath $script:ProviderConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Provider config file is empty' }
        $parsed = ConvertTo-HashtableRecursive -InputObject ($raw | ConvertFrom-Json -ErrorAction Stop)
        if (-not ($parsed -is [System.Collections.IDictionary])) { throw 'Provider config root must be a JSON object' }
        $cfg = Copy-ObjectRecursive -InputObject $defaults

        $allowedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($allowedKey in @($defaults.Keys) + @('_documentation')) { [void]$allowedKeys.Add([string]$allowedKey) }
        foreach ($key in @($parsed.Keys)) {
            if ([string]$key -like '_*') { continue }
            if (-not $allowedKeys.Contains([string]$key)) {
                throw "Unknown provider config setting [$key]"
            }
        }

        $readBoolean = {
            param([object]$Value, [string]$Name)
            if ($Value -is [bool]) { return [bool]$Value }
            $text = ([string]$Value).Trim()
            if ($text -match '^(?i:true|false)$') { return [System.Convert]::ToBoolean($text) }
            throw "$Name must be true or false"
        }

        $readInteger = {
            param([string]$Key, [int]$Minimum, [int]$Maximum)
            if (-not $parsed.ContainsKey($Key)) { return [int]$cfg[$Key] }
            $value = 0
            if (-not [int]::TryParse([string]$parsed[$Key], [ref]$value) -or $value -lt $Minimum -or $value -gt $Maximum) {
                throw "$Key must be an integer between $Minimum and $Maximum"
            }
            return $value
        }

        if ($parsed.ContainsKey('storage') -and -not [string]::IsNullOrWhiteSpace([string]$parsed.storage)) {
            $cfg.storage = ([string]$parsed.storage).Trim()
        }
        if ([string]::IsNullOrWhiteSpace([string]$cfg.storage)) { throw 'storage must not be empty' }

        if ($parsed.ContainsKey('placement') -and -not [string]::IsNullOrWhiteSpace([string]$parsed.placement)) {
            $cfg.placement = ([string]$parsed.placement).Trim().ToLowerInvariant()
        }
        if (@('round_robin','least_loaded') -notcontains $cfg.placement) {
            throw "Unsupported placement [$($cfg.placement)]; supported values are round_robin and least_loaded"
        }

        $cfg.guests_polling_rate = & $readInteger 'guests_polling_rate' 2 300
        $cfg.tasks_polling_rate = & $readInteger 'tasks_polling_rate' 1 300
        $cfg.task_observation_horizon_seconds = & $readInteger 'task_observation_horizon_seconds' 600 86400
        $cfg.clone_ready_timeout_seconds = & $readInteger 'clone_ready_timeout_seconds' 60 7200
        $cfg.api_connection_timeout_seconds = & $readInteger 'api_connection_timeout_seconds' 1 120
        $cfg.api_operation_timeout_seconds = & $readInteger 'api_operation_timeout_seconds' 2 600
        $cfg.api_get_max_retries = & $readInteger 'api_get_max_retries' 0 5
        $cfg.api_get_retry_interval_seconds = & $readInteger 'api_get_retry_interval_seconds' 1 30
        $cfg.inventory_cache_seconds = & $readInteger 'inventory_cache_seconds' 0 60
        $cfg.vm_config_cache_seconds = & $readInteger 'vm_config_cache_seconds' 0 300
        $cfg.vm_status_cache_seconds = & $readInteger 'vm_status_cache_seconds' 0 30
        $cfg.network_cache_seconds = & $readInteger 'network_cache_seconds' 0 300
        $cfg.network_negative_cache_seconds = & $readInteger 'network_negative_cache_seconds' 0 30
        $cfg.node_health_cache_seconds = & $readInteger 'node_health_cache_seconds' 0 300
        $cfg.storage_content_cache_seconds = & $readInteger 'storage_content_cache_seconds' 0 60
        $cfg.minimum_storage_free_gb = & $readInteger 'minimum_storage_free_gb' 0 1048576
        $cfg.minimum_storage_free_percent = & $readInteger 'minimum_storage_free_percent' 0 50
        $cfg.state_backup_generations = & $readInteger 'state_backup_generations' 0 10
        $cfg.completed_task_ttl_seconds = & $readInteger 'completed_task_ttl_seconds' 60 86400
        $cfg.failed_task_ttl_seconds = & $readInteger 'failed_task_ttl_seconds' 300 604800

        if ($parsed.ContainsKey('debug_logging')) {
            $cfg.debug_logging = & $readBoolean ($parsed.debug_logging) 'debug_logging'
        }

        $cfg.preferred_ipv4_cidrs = @()
        if ($parsed.ContainsKey('preferred_ipv4_cidrs') -and $null -ne $parsed.preferred_ipv4_cidrs) {
            foreach ($cidrValue in @($parsed.preferred_ipv4_cidrs)) {
                $cidr = ([string]$cidrValue).Trim()
                if ([string]::IsNullOrWhiteSpace($cidr)) { continue }
                $parts = @($cidr -split '/')
                $prefix = 0
                if ($parts.Count -ne 2 -or -not [int]::TryParse($parts[1], [ref]$prefix) -or
                    $prefix -lt 0 -or $prefix -gt 32 -or $null -eq (ConvertTo-IPv4UInt32 -Address $parts[0])) {
                    throw "preferred_ipv4_cidrs contains invalid CIDR [$cidr]"
                }
                $cfg.preferred_ipv4_cidrs += $cidr
            }
        }

        # vNext18 split VMID pools. The old vNext17 shared vmid_pool_* fields
        # remain accepted only as a compatibility fallback when no split pool is present.
        if ($parsed.ContainsKey('gold_vmid') -and $null -ne $parsed.gold_vmid -and -not [string]::IsNullOrWhiteSpace([string]$parsed.gold_vmid)) {
            $goldVmId = 0
            if (-not [int]::TryParse([string]$parsed.gold_vmid, [ref]$goldVmId) -or $goldVmId -lt 100 -or $goldVmId -gt 999999999) {
                throw 'gold_vmid must be an integer between 100 and 999999999'
            }
            $cfg.gold_vmid = $goldVmId
        }

        $splitKeys = @('rasimg_vmid_pool_start','rasimg_vmid_pool_end','session_vmid_pool_start','session_vmid_pool_end')
        $splitConfigured = $false
        foreach ($key in $splitKeys) {
            if ($parsed.ContainsKey($key) -and $null -ne $parsed[$key] -and -not [string]::IsNullOrWhiteSpace([string]$parsed[$key])) {
                $splitConfigured = $true
            }
        }

        if ($splitConfigured) {
            foreach ($key in $splitKeys) {
                if (-not $parsed.ContainsKey($key) -or $null -eq $parsed[$key] -or [string]::IsNullOrWhiteSpace([string]$parsed[$key])) {
                    throw 'Split VMID configuration requires all of: rasimg_vmid_pool_start, rasimg_vmid_pool_end, session_vmid_pool_start, session_vmid_pool_end'
                }
            }
            if ($null -eq $cfg.gold_vmid) { throw 'Split VMID configuration requires gold_vmid' }

            $rasimgStart = 0; $rasimgEnd = 0; $sessionStart = 0; $sessionEnd = 0
            if (-not [int]::TryParse([string]$parsed.rasimg_vmid_pool_start, [ref]$rasimgStart) -or
                -not [int]::TryParse([string]$parsed.rasimg_vmid_pool_end, [ref]$rasimgEnd) -or
                -not [int]::TryParse([string]$parsed.session_vmid_pool_start, [ref]$sessionStart) -or
                -not [int]::TryParse([string]$parsed.session_vmid_pool_end, [ref]$sessionEnd)) {
                throw 'Split VMID pool boundaries must be integers'
            }
            if ($rasimgStart -lt 100 -or $rasimgEnd -gt 999999999 -or $rasimgStart -gt $rasimgEnd) {
                throw 'RASIMG VMID pool boundaries are invalid'
            }
            if ($sessionStart -lt 100 -or $sessionEnd -gt 999999999 -or $sessionStart -gt $sessionEnd) {
                throw 'Session VMID pool boundaries are invalid'
            }
            if (-not ($rasimgEnd -lt $sessionStart -or $sessionEnd -lt $rasimgStart)) {
                throw 'RASIMG and Session VMID pools must not overlap'
            }
            if (([int]$cfg.gold_vmid -ge $rasimgStart -and [int]$cfg.gold_vmid -le $rasimgEnd) -or
                ([int]$cfg.gold_vmid -ge $sessionStart -and [int]$cfg.gold_vmid -le $sessionEnd)) {
                throw "gold_vmid [$($cfg.gold_vmid)] must be outside both dynamic VMID pools"
            }
            $cfg.rasimg_vmid_pool_start = $rasimgStart
            $cfg.rasimg_vmid_pool_end = $rasimgEnd
            $cfg.session_vmid_pool_start = $sessionStart
            $cfg.session_vmid_pool_end = $sessionEnd
        }

        $hasLegacyPoolStart = $parsed.ContainsKey('vmid_pool_start') -and $null -ne $parsed.vmid_pool_start -and -not [string]::IsNullOrWhiteSpace([string]$parsed.vmid_pool_start)
        $hasLegacyPoolEnd = $parsed.ContainsKey('vmid_pool_end') -and $null -ne $parsed.vmid_pool_end -and -not [string]::IsNullOrWhiteSpace([string]$parsed.vmid_pool_end)
        if ($hasLegacyPoolStart -xor $hasLegacyPoolEnd) { throw 'Legacy vmid_pool_start and vmid_pool_end must both be set or omitted' }
        if ($splitConfigured -and ($hasLegacyPoolStart -or $hasLegacyPoolEnd)) { throw 'Do not mix split and legacy VMID pools' }
        if (-not $splitConfigured -and $hasLegacyPoolStart -and $hasLegacyPoolEnd) {
            $poolStart = 0; $poolEnd = 0
            if (-not [int]::TryParse([string]$parsed.vmid_pool_start, [ref]$poolStart) -or
                -not [int]::TryParse([string]$parsed.vmid_pool_end, [ref]$poolEnd) -or
                $poolStart -lt 100 -or $poolEnd -gt 999999999 -or $poolStart -gt $poolEnd) {
                throw 'Legacy VMID pool boundaries are invalid'
            }
            if ($null -ne $cfg.gold_vmid -and [int]$cfg.gold_vmid -ge $poolStart -and [int]$cfg.gold_vmid -le $poolEnd) {
                throw "gold_vmid [$($cfg.gold_vmid)] must be outside the legacy VMID pool"
            }
            $cfg.vmid_pool_start = $poolStart
            $cfg.vmid_pool_end = $poolEnd
        }

        $hasSessionPool = ($null -ne $cfg.session_vmid_pool_start -and $null -ne $cfg.session_vmid_pool_end) -or
                          ($null -ne $cfg.vmid_pool_start -and $null -ne $cfg.vmid_pool_end)
        if ($cfg.placement -eq 'least_loaded' -and -not $hasSessionPool) {
            throw 'placement=least_loaded requires a Session VMID pool'
        }

        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($parsed.ContainsKey('compute_nodes') -and $null -ne $parsed.compute_nodes) {
            foreach ($rawNode in @($parsed.compute_nodes)) {
                $name = $null
                $enabled = $true
                if ($rawNode -is [string]) { $name = [string]$rawNode }
                elseif ($rawNode -is [System.Collections.IDictionary]) {
                    if ($rawNode.Contains('name')) { $name = [string]$rawNode['name'] }
                    if ($rawNode.Contains('enabled')) { $enabled = & $readBoolean ($rawNode['enabled']) "compute_nodes[$name].enabled" }
                }
                elseif ($rawNode -is [pscustomobject]) {
                    if ($rawNode.PSObject.Properties.Name -contains 'name') { $name = [string]$rawNode.name }
                    if ($rawNode.PSObject.Properties.Name -contains 'enabled') { $enabled = & $readBoolean ($rawNode.enabled) "compute_nodes[$name].enabled" }
                }
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $name = $name.Trim()
                if ($seen.Add($name)) { $cfg.compute_nodes += ,@{ name = $name; enabled = $enabled } }
            }
        }

        $previousStamp = if ($null -ne $script:ProviderConfigCache) { [string]$script:ProviderConfigCache.stamp } else { $null }
        $script:TraceLoggingEnabled = [bool]$cfg.debug_logging
        $script:StateBackupGenerations = [int]$cfg.state_backup_generations
        $script:CompletedTaskTtlSeconds = [int]$cfg.completed_task_ttl_seconds
        $script:FailedTaskTtlSeconds = [int]$cfg.failed_task_ttl_seconds
        $script:ProviderConfigCache = @{ stamp = $stamp; value = Copy-ObjectRecursive -InputObject $cfg }
        if ($null -ne $previousStamp -and $previousStamp -ne [string]$stamp) { $script:EffectiveConfigLogged = $false }
        return Copy-ObjectRecursive -InputObject $cfg
    }
    catch {
        # An existing but invalid production configuration must not make the
        # provider look healthy with unrelated defaults. Let initialize/connect
        # fail clearly so RAS and monitoring surface the actual root cause.
        throw "Provider config [$($script:ProviderConfigPath)] is invalid: $($_.Exception.Message)"
    }
}

function Get-EnabledComputeNodes {
    param([switch]$AllowEmpty)

    $cfg = Get-ProviderConfig
    $nodes = @()
    foreach ($entry in @($cfg.compute_nodes)) {
        if ($null -eq $entry) { continue }
        $enabled = $true
        $name = $null
        if ($entry -is [System.Collections.IDictionary]) {
            if ($entry.Contains('name')) { $name = [string]$entry['name'] }
            if ($entry.Contains('enabled')) { $enabled = [bool]$entry['enabled'] }
        }
        else {
            if ($entry.PSObject.Properties.Name -contains 'name') { $name = [string]$entry.name }
            if ($entry.PSObject.Properties.Name -contains 'enabled') { $enabled = [bool]$entry.enabled }
        }
        if ($enabled -and -not [string]::IsNullOrWhiteSpace($name)) {
            $nodes += $name.Trim()
        }
    }

    if ($nodes.Count -eq 0 -and -not $AllowEmpty) {
        throw "No enabled compute_nodes are configured in [$($script:ProviderConfigPath)]"
    }
    return @($nodes)
}

function Get-ConfiguredStorage {
    $cfg = Get-ProviderConfig
    $storage = [string]$cfg.storage
    if ([string]::IsNullOrWhiteSpace($storage)) {
        throw "No storage is configured in [$($script:ProviderConfigPath)]"
    }
    return $storage.Trim()
}

function Get-ConfiguredVmIdPool {
    param(
        [ValidateSet('session','rasimg')][string]$Kind = 'session',
        [hashtable]$Config = $null
    )

    $cfg = if ($null -ne $Config) { $Config } else { Get-ProviderConfig }

    if ($Kind -eq 'rasimg' -and $null -ne $cfg.rasimg_vmid_pool_start -and $null -ne $cfg.rasimg_vmid_pool_end) {
        return @{ enabled = $true; split = $true; kind = 'rasimg'; start = [int]$cfg.rasimg_vmid_pool_start; end = [int]$cfg.rasimg_vmid_pool_end }
    }
    if ($Kind -eq 'session' -and $null -ne $cfg.session_vmid_pool_start -and $null -ne $cfg.session_vmid_pool_end) {
        return @{ enabled = $true; split = $true; kind = 'session'; start = [int]$cfg.session_vmid_pool_start; end = [int]$cfg.session_vmid_pool_end }
    }

    # vNext17 compatibility: when only the legacy shared pool exists, both
    # RASIMG and Session Hosts allocate from it exactly as before.
    if ($null -ne $cfg.vmid_pool_start -and $null -ne $cfg.vmid_pool_end) {
        return @{ enabled = $true; split = $false; kind = 'legacy'; start = [int]$cfg.vmid_pool_start; end = [int]$cfg.vmid_pool_end }
    }

    return @{ enabled = $false; split = $false; kind = $Kind; start = $null; end = $null }
}

function Assert-ConfiguredGoldVmId {
    param([Parameter(Mandatory = $true)][string]$VmId)

    $cfg = Get-ProviderConfig
    if ($null -eq $cfg.gold_vmid) { return }
    if ([string]$cfg.gold_vmid -ne [string]$VmId) {
        throw "Configured gold_vmid is [$($cfg.gold_vmid)] but RAS requested source/gold VM [$VmId]"
    }
}

function Assert-RasImgVmIdPoolCapacity {
    param([Parameter(Mandatory = $true)][int]$NodeCount)

    if ($NodeCount -lt 1) { return }
    $cfg = Get-ProviderConfig
    $pool = Get-ConfiguredVmIdPool -Kind 'rasimg' -Config $cfg
    if (-not [bool]$pool.enabled -or -not [bool]$pool.split) { return }

    $capacity = ([int]$pool.end - [int]$pool.start) + 1
    $required = [int]$script:MaxRasTemplateVersions * $NodeCount
    if ($capacity -lt $required) {
        throw "RASIMG VMID pool [$($pool.start)-$($pool.end)] provides [$capacity] IDs, but up to [$required] are required for $($script:MaxRasTemplateVersions) retained versions across [$NodeCount] publish nodes"
    }
}

function Get-PlacementState {
    try {
        $state = Get-CachedJsonState -Path $script:PlacementStatePath -DefaultValue @{ next_index = 0; sequence = 0 }
        if (-not $state.ContainsKey('next_index')) { $state.next_index = 0 }
        if (-not $state.ContainsKey('sequence')) { $state.sequence = 0 }
        return $state
    }
    catch {
        Write-DebugLog "Failed to load placement state: $($_.Exception.Message)"
        throw "Placement state file [$($script:PlacementStatePath)] is unreadable: $($_.Exception.Message)"
    }
}

function Save-PlacementState {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Write-JsonFileAtomic -Path $script:PlacementStatePath -Object $State -Depth 10 -Compress
}

function Get-RasSessionHostLoadByNode {
    param(
        [Parameter(Mandatory = $true)][string[]]$CandidateNodes,
        [Parameter(Mandatory = $true)][string]$SourceVmId
    )

    $cfg = Get-ProviderConfig
    $pool = Get-ConfiguredVmIdPool -Kind 'session' -Config $cfg
    if (-not [bool]$pool.enabled) {
        throw 'least_loaded placement requires a configured Session VMID pool'
    }

    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $loads = @{}
    foreach ($node in @($CandidateNodes)) {
        if ([string]::IsNullOrWhiteSpace([string]$node)) { continue }
        $name = ([string]$node).Trim()
        if ($candidateSet.Add($name)) { $loads[$name] = 0 }
    }
    if ($candidateSet.Count -eq 0) { throw 'No candidate compute node is available for least-loaded placement' }

    $presentSessionVmIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($vm in @(Get-ProxmoxClusterVMs)) {
        if ($null -eq $vm) { continue }
        $vmidProp = $vm.PSObject.Properties['vmid']
        $nodeProp = $vm.PSObject.Properties['node']
        if ($null -eq $vmidProp -or $null -eq $nodeProp) { continue }

        $vmId = [string]$vmidProp.Value
        $node = [string]$nodeProp.Value
        if ([string]::IsNullOrWhiteSpace($vmId) -or [string]::IsNullOrWhiteSpace($node)) { continue }
        if (-not $candidateSet.Contains($node)) { continue }
        if ([string]$vmId -eq [string]$SourceVmId) { continue }

        $numericId = 0
        if (-not [int]::TryParse($vmId, [ref]$numericId)) { continue }
        if ($numericId -lt [int]$pool.start -or $numericId -gt [int]$pool.end) { continue }

        $name = ''
        $nameProp = $vm.PSObject.Properties['name']
        if ($null -ne $nameProp) { $name = [string]$nameProp.Value }
        if (-not [string]::IsNullOrWhiteSpace($name) -and $name.StartsWith('RASIMG-', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $loads[$node] = [int]$loads[$node] + 1
        [void]$presentSessionVmIds.Add($vmId)
    }

    # CloneState survives provider restarts. Count accepted session-host clones that
    # are not yet visible in cluster/resources, so parallel rollout requests do not
    # all pick the same currently-empty node.
    $cloneState = Get-CloneStateAll
    foreach ($key in @($cloneState.Keys)) {
        $entry = $cloneState[$key]
        if ($null -eq $entry) { continue }

        $cloneId = [string]$key
        $cloneNode = $null
        if ($entry -is [System.Collections.IDictionary]) {
            if ($entry.Contains('clone_id') -and -not [string]::IsNullOrWhiteSpace([string]$entry['clone_id'])) { $cloneId = [string]$entry['clone_id'] }
            if ($entry.Contains('clone_node')) { $cloneNode = [string]$entry['clone_node'] }
        }
        else {
            if ($entry.PSObject.Properties.Name -contains 'clone_id' -and -not [string]::IsNullOrWhiteSpace([string]$entry.clone_id)) { $cloneId = [string]$entry.clone_id }
            if ($entry.PSObject.Properties.Name -contains 'clone_node') { $cloneNode = [string]$entry.clone_node }
        }

        if ([string]::IsNullOrWhiteSpace($cloneId) -or [string]::IsNullOrWhiteSpace($cloneNode)) { continue }
        if (-not $candidateSet.Contains($cloneNode)) { continue }
        if ($presentSessionVmIds.Contains($cloneId)) { continue }

        $numericCloneId = 0
        if (-not [int]::TryParse($cloneId, [ref]$numericCloneId)) { continue }
        if ($numericCloneId -lt [int]$pool.start -or $numericCloneId -gt [int]$pool.end) { continue }

        $loads[$cloneNode] = [int]$loads[$cloneNode] + 1
    }

    return $loads
}

function Get-NextComputeNodeSelection {
    param(
        [Parameter(Mandatory = $true)][string[]]$CandidateNodes,
        [Parameter(Mandatory = $true)][string]$SourceVmId
    )

    $nodes = @($CandidateNodes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($nodes.Count -eq 0) {
        throw 'No candidate compute node is available for placement'
    }

    $cfg = Get-ProviderConfig
    $placement = [string]$cfg.placement
    $state = Invoke-WithStateMutex -ScriptBlock { Get-PlacementState }
    $seq = 0L
    try { $seq = [long]$state.sequence } catch { $seq = 0L }
    if ($seq -lt 0) { $seq = 0L }

    if ($placement -eq 'least_loaded') {
        $loads = Get-RasSessionHostLoadByNode -CandidateNodes $nodes -SourceVmId $SourceVmId
        $minLoad = $null
        foreach ($node in $nodes) {
            $value = [int]$loads[[string]$node]
            if ($null -eq $minLoad -or $value -lt [int]$minLoad) { $minLoad = $value }
        }
        $tied = @($nodes | Where-Object { [int]$loads[[string]$_] -eq [int]$minLoad })
        if ($tied.Count -eq 0) { throw 'least_loaded placement produced no eligible node' }
        $idx = [int]($seq % $tied.Count)
        $selected = [string]$tied[$idx]

        $loadText = @($nodes | ForEach-Object { "$_=$([int]$loads[[string]$_])" }) -join ', '
        Write-DebugLog "Least-loaded placement selected node [$selected] from minimum load [$minLoad] (loads: $loadText; tie_sequence=$seq)."
        return @{
            node       = $selected
            placement  = 'least_loaded'
            sequence   = $seq
            next_index = $idx
            candidates = @($nodes)
            loads      = $loads
        }
    }

    $idx = [int]($seq % $nodes.Count)
    $selected = [string]$nodes[$idx]
    return @{
        node       = $selected
        placement  = 'round_robin'
        sequence   = $seq
        next_index = $idx
        candidates = @($nodes)
        loads      = @{}
    }
}

function Commit-ComputeNodeSelection {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Selection,
        [Parameter(Mandatory = $true)][string]$CloneVmId
    )

    $selected = [string]$Selection.node
    $placement = if ($Selection.ContainsKey('placement')) { [string]$Selection.placement } else { 'round_robin' }
    $expectedSequence = 0L
    try { $expectedSequence = [long]$Selection.sequence } catch { $expectedSequence = 0L }
    $nodes = @($Selection.candidates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($nodes.Count -eq 0) {
        Write-DebugLog "CRITICAL: Clone VM [$CloneVmId] was accepted on node [$selected], but [$placement] placement could not be committed because the candidate list is empty."
        return $false
    }

    # Once Proxmox has accepted a clone, never turn a placement-state write issue
    # into a failed RAS clone response: RAS could retry and create a duplicate VM.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WithStateMutex -ScriptBlock {
                $state = Get-PlacementState
                $seq = 0L
                try { $seq = [long]$state.sequence } catch { $seq = 0L }
                if ($seq -lt 0) { $seq = 0L }

                if ($seq -ne $expectedSequence) {
                    Write-DebugLog "Placement sequence changed before commit for accepted clone VM [$CloneVmId]: selected_sequence=[$expectedSequence], current_sequence=[$seq]. Advancing current sequence once to preserve successful-clone accounting."
                }

                $state.sequence = $seq + 1L
                $state.next_index = [int]($state.sequence % $nodes.Count)
                $state.last_node = $selected
                $state.last_placement = $placement
                $state.last_committed_utc = [DateTime]::UtcNow.ToString('o')
                $state.last_committed_vm_id = $CloneVmId
                if ($Selection.ContainsKey('loads') -and $null -ne $Selection.loads) {
                    $state.last_load_snapshot = $Selection.loads
                }
                Save-PlacementState -State $state

                Write-DebugLog "Placement [$placement] committed node [$selected] for accepted clone VM [$CloneVmId] (sequence=$($state.sequence), candidates=$($nodes -join ','))."
            } | Out-Null
            return $true
        }
        catch {
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds (50 * $attempt)
                continue
            }
            Write-DebugLog "CRITICAL: Clone VM [$CloneVmId] was accepted on node [$selected], but [$placement] placement state could not be committed after 3 attempts: $($_.Exception.Message)"
            return $false
        }
    }

    return $false
}


function Get-HealthyComputeNodes {
    param(
        [Parameter(Mandatory = $true)][string[]]$CandidateNodes,
        [Parameter(Mandatory = $true)][string]$Storage,
        [switch]$IgnoreCapacityThresholds
    )

    $cfg = Get-ProviderConfig
    $nodeResponse = Invoke-ProxmoxApi -Method GET -Path '/api2/json/nodes'
    $nodeStatus = @{}
    foreach ($entry in @($nodeResponse.data)) {
        if ($null -eq $entry) { continue }
        $nodeProperty = $entry.PSObject.Properties['node']
        if ($null -eq $nodeProperty -or [string]::IsNullOrWhiteSpace([string]$nodeProperty.Value)) { continue }
        $status = 'unknown'
        $statusProperty = $entry.PSObject.Properties['status']
        if ($null -ne $statusProperty -and -not [string]::IsNullOrWhiteSpace([string]$statusProperty.Value)) {
            $status = ([string]$statusProperty.Value).ToLowerInvariant()
        }
        $nodeStatus[[string]$nodeProperty.Value] = $status
    }

    $healthy = @()
    $unhealthy = @{}
    $escapedStorage = [System.Uri]::EscapeDataString($Storage)
    foreach ($node in @($CandidateNodes | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$node)) { continue }
        $name = ([string]$node).Trim()
        if (-not $nodeStatus.ContainsKey($name)) {
            $unhealthy[$name] = 'node is not present in /nodes'
            continue
        }
        if ([string]$nodeStatus[$name] -ne 'online') {
            $unhealthy[$name] = "node status is [$($nodeStatus[$name])]"
            continue
        }

        try {
            $storageResponse = Invoke-ProxmoxApi -Method GET -Path "/api2/json/nodes/$name/storage/$escapedStorage/status"
            $data = $storageResponse.data
            $activeProperty = if ($null -ne $data) { $data.PSObject.Properties['active'] } else { $null }
            if ($null -eq $activeProperty) {
                $unhealthy[$name] = "storage [$Storage] status has no active property"
                continue
            }
            $activeText = ([string]$activeProperty.Value).Trim().ToLowerInvariant()
            $storageActive = ($activeText -in @('1','true','yes','on'))
            if (-not $storageActive) {
                $unhealthy[$name] = "storage [$Storage] is inactive"
                continue
            }

            $availableProperty = if ($null -ne $data) { $data.PSObject.Properties['avail'] } else { $null }
            $totalProperty = if ($null -ne $data) { $data.PSObject.Properties['total'] } else { $null }
            if (-not $IgnoreCapacityThresholds -and
                ([int]$cfg.minimum_storage_free_gb -gt 0 -or [int]$cfg.minimum_storage_free_percent -gt 0) -and
                $null -eq $availableProperty) {
                $unhealthy[$name] = "storage [$Storage] status has no available-capacity value"
                continue
            }
            if (-not $IgnoreCapacityThresholds -and [int]$cfg.minimum_storage_free_gb -gt 0) {
                $minimumBytes = [int64]$cfg.minimum_storage_free_gb * 1GB
                if ([int64]$availableProperty.Value -lt $minimumBytes) {
                    $unhealthy[$name] = "storage [$Storage] has less than $($cfg.minimum_storage_free_gb) GiB available"
                    continue
                }
            }
            if (-not $IgnoreCapacityThresholds -and [int]$cfg.minimum_storage_free_percent -gt 0) {
                if ($null -eq $totalProperty -or [double]$totalProperty.Value -le 0) {
                    $unhealthy[$name] = "storage [$Storage] status has no valid total-capacity value"
                    continue
                }
                $freePercent = ([double]$availableProperty.Value / [double]$totalProperty.Value) * 100.0
                if ($freePercent -lt [double]$cfg.minimum_storage_free_percent) {
                    $unhealthy[$name] = "storage [$Storage] has only $([Math]::Round($freePercent,1))% free; minimum is $($cfg.minimum_storage_free_percent)%"
                    continue
                }
            }
            $healthy += $name
        }
        catch {
            $unhealthy[$name] = $_.Exception.Message
        }
    }

    return @{ healthy = @($healthy); unhealthy = $unhealthy }
}

function Write-EffectiveProviderConfigLog {
    if ($script:EffectiveConfigLogged) { return }
    $cfg = Get-ProviderConfig
    $enabledNodes = @()
    foreach ($entry in @($cfg.compute_nodes)) {
        if ($entry -is [System.Collections.IDictionary] -and [bool]$entry['enabled']) { $enabledNodes += [string]$entry['name'] }
    }
    $hash = 'missing'
    if (Test-Path -LiteralPath $script:ProviderConfigPath) {
        try { $hash = (Get-FileHash -LiteralPath $script:ProviderConfigPath -Algorithm SHA256 -ErrorAction Stop).Hash }
        catch { $hash = 'unavailable' }
    }
    Write-DebugLog ("EFFECTIVE CONFIG: path=[{0}] sha256=[{1}] storage=[{2}] placement=[{3}] gold=[{4}] rasimg_pool=[{5}-{6}] session_pool=[{7}-{8}] nodes=[{9}] guest_poll=[{10}s] task_poll=[{11}s] task_horizon=[{12}s] api_timeout=[{13}/{14}s] caches=[inventory:{15}s,config:{16}s,status:{17}s,network:{18}s] preferred_cidrs=[{19}] debug=[{20}]" -f `
        $script:ProviderConfigPath, $hash, $cfg.storage, $cfg.placement, $cfg.gold_vmid,
        $cfg.rasimg_vmid_pool_start, $cfg.rasimg_vmid_pool_end, $cfg.session_vmid_pool_start,
        $cfg.session_vmid_pool_end, ($enabledNodes -join ','), $cfg.guests_polling_rate,
        $cfg.tasks_polling_rate, $cfg.task_observation_horizon_seconds,
        $cfg.api_connection_timeout_seconds, $cfg.api_operation_timeout_seconds,
        $cfg.inventory_cache_seconds, $cfg.vm_config_cache_seconds, $cfg.vm_status_cache_seconds,
        $cfg.network_cache_seconds, (@($cfg.preferred_ipv4_cidrs) -join ','), $cfg.debug_logging)
    $script:EffectiveConfigLogged = $true
}

function Get-ProxmoxClusterNodeNames {
    $resp = Invoke-ProxmoxApi -Method GET -Path '/api2/json/nodes'
    $nodes = @()
    foreach ($entry in @($resp.data)) {
        if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains 'node' -and -not [string]::IsNullOrWhiteSpace([string]$entry.node)) {
            $nodes += [string]$entry.node
        }
    }
    return @($nodes)
}

function Assert-ComputeNodesReady {
    param(
        [Parameter(Mandatory = $true)][string[]]$Nodes,
        [Parameter(Mandatory = $true)][string]$Storage,
        [switch]$IgnoreCapacityThresholds
    )

    $health = Get-HealthyComputeNodes -CandidateNodes $Nodes -Storage $Storage -IgnoreCapacityThresholds:$IgnoreCapacityThresholds
    if (@($health.healthy).Count -ne @($Nodes | Select-Object -Unique).Count) {
        $details = @()
        foreach ($node in $health.unhealthy.Keys) { $details += "$node=$([string]$health.unhealthy[$node])" }
        throw "One or more configured compute nodes are not ready for storage [$Storage]: $($details -join '; ')"
    }
}

function Get-VersionState {
    try {
        $state = Get-CachedJsonState -Path $script:VersionStatePath -DefaultValue @{ templates = @{} }
        if (-not $state.ContainsKey('templates') -or $null -eq $state.templates) { $state.templates = @{} }
        return $state
    }
    catch {
        Write-DebugLog "Failed to load version state: $($_.Exception.Message)"
        throw "Version state file [$($script:VersionStatePath)] is unreadable: $($_.Exception.Message)"
    }
}

function Save-VersionState {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Write-JsonFileAtomic -Path $script:VersionStatePath -Object $State -Depth 30
}

function Get-VersionTemplateState {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [switch]$Create
    )

    $existing = Get-VersionState
    if ($existing.templates.ContainsKey([string]$VmId) -or -not $Create) {
        if ($existing.templates.ContainsKey([string]$VmId)) {
            return $existing.templates[[string]$VmId]
        }
        return $null
    }

    return Invoke-WithStateMutex -ScriptBlock {
        $state = Get-VersionState
        if (-not $state.templates.ContainsKey([string]$VmId)) {
            $state.templates[[string]$VmId] = @{
                is_template     = $false
                current_version = $null
                versions        = @{}
            }
            Save-VersionState -State $state
        }
        return $state.templates[[string]$VmId]
    }
}

function Set-LogicalTemplateState {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][bool]$IsTemplate
    )

    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-VersionState
        if (-not $state.templates.ContainsKey([string]$VmId)) {
            $state.templates[[string]$VmId] = @{
                is_template     = $IsTemplate
                current_version = $null
                versions        = @{}
            }
        }
        else {
            $state.templates[[string]$VmId].is_template = $IsTemplate
            if (-not $state.templates[[string]$VmId].ContainsKey('versions')) {
                $state.templates[[string]$VmId].versions = @{}
            }
        }
        Save-VersionState -State $state
    } | Out-Null
}

function Get-LogicalTemplateState {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [bool]$DefaultValue = $false
    )

    $state = Get-VersionState
    if ($state.templates.ContainsKey([string]$VmId)) {
        $t = $state.templates[[string]$VmId]
        if ($t.ContainsKey('is_template')) {
            return [bool]$t.is_template
        }
    }
    return $DefaultValue
}

function Set-VersionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][string]$SnapshotName,
        [AllowEmptyString()][string]$NativeSnapshot = '',
        [Parameter(Mandatory = $true)][hashtable]$Images
    )

    if ($Images.Count -eq 0) {
        throw "Cannot store RAS version [$SnapshotName] for VM [$VmId] without any version images"
    }

    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-VersionState
        if (-not $state.templates.ContainsKey([string]$VmId)) {
            # A version record can be published only while the gold VM is in
            # maintenance. Publishing immutable RASIMG backing must therefore
            # start with and preserve the logical non-template state.
            $state.templates[[string]$VmId] = @{
                is_template     = $false
                current_version = $SnapshotName
                versions        = @{}
            }
        }

        $tpl = $state.templates[[string]$VmId]
        $logicalTemplateState = $false
        if ($tpl.ContainsKey('is_template')) {
            try { $logicalTemplateState = [System.Convert]::ToBoolean($tpl.is_template) }
            catch { $logicalTemplateState = $false }
        }
        if ($logicalTemplateState) {
            throw "Cannot store RAS version [$SnapshotName] for VM [$VmId] while logical template state is True; guests/convert(is_template=false) must enter RAS maintenance first"
        }
        $tpl.is_template = $false
        if (-not $tpl.ContainsKey('versions') -or $null -eq $tpl.versions) {
            $tpl.versions = @{}
        }

        $normalizedImages = @{}
        foreach ($node in $Images.Keys) {
            $img = $Images[$node]
            if ($null -eq $img) { continue }
            $imageId = if ($img.ContainsKey('image_id')) { [string]$img.image_id } else { '' }
            if ([string]::IsNullOrWhiteSpace($imageId)) { continue }
            $imageName = if ($img.ContainsKey('image_name')) { [string]$img.image_name } else { '' }
            $normalizedImages[[string]$node] = @{
                node       = [string]$node
                image_id   = $imageId
                image_name = $imageName
            }
        }
        if ($normalizedImages.Count -eq 0) {
            throw "Cannot store RAS version [$SnapshotName] for VM [$VmId]: image map is empty"
        }

        if ($tpl.versions.ContainsKey($SnapshotName)) {
            $oldRecord = $tpl.versions[$SnapshotName]
            $oldNative = if ($oldRecord.ContainsKey('native_snapshot')) { [string]$oldRecord.native_snapshot } else { '' }
            $oldIds = @((Get-VersionImageIds -Record $oldRecord) | Sort-Object -Unique)
            $newIds = @($normalizedImages.Values | ForEach-Object { [string]$_.image_id } | Sort-Object -Unique)
            $sameIds = (($oldIds -join ',') -eq ($newIds -join ','))

            if ($oldNative -ne [string]$NativeSnapshot -or -not $sameIds) {
                throw "RAS version [$SnapshotName] already exists for VM [$VmId] with different backing objects"
            }
            Write-DebugLog "RAS version [$SnapshotName] for VM [$VmId] completed idempotently with existing multi-node backing."
        }
        else {
            $firstNode = @($normalizedImages.Keys | Sort-Object | Select-Object -First 1)[0]
            $firstImage = $normalizedImages[$firstNode]
            $tpl.versions[$SnapshotName] = @{
                native_snapshot = $NativeSnapshot
                version_source   = 'rasimg'
                images           = $normalizedImages
                # Legacy aliases retained so older state readers do not break.
                image_id        = [string]$firstImage.image_id
                image_name      = [string]$firstImage.image_name
                created_utc     = [DateTime]::UtcNow.ToString('o')
            }
        }

        $tpl.current_version = $SnapshotName
        # Do not set is_template=true here. Parallels RAS must still be able to
        # boot and inspect the mutable gold VM before it explicitly closes
        # maintenance through guests/convert(is_template=true).
        $state.templates[[string]$VmId] = $tpl
        Save-VersionState -State $state
        Write-DebugLog "RAS version record [$SnapshotName] stored for VM [$VmId]; logical template state preserved as [$logicalTemplateState] until guests/convert(is_template=true)."
    } | Out-Null
}


function Get-VersionImageIds {
    param([Parameter(Mandatory = $true)][object]$Record)

    $ids = @()
    if ($null -eq $Record) { return @() }

    if ($Record.ContainsKey('images') -and $null -ne $Record.images) {
        foreach ($node in $Record.images.Keys) {
            $img = $Record.images[$node]
            if ($null -ne $img -and $img.ContainsKey('image_id') -and -not [string]::IsNullOrWhiteSpace([string]$img.image_id)) {
                $ids += [string]$img.image_id
            }
        }
    }

    if ($ids.Count -eq 0 -and $Record.ContainsKey('image_id') -and -not [string]::IsNullOrWhiteSpace([string]$Record.image_id)) {
        $ids += [string]$Record.image_id
    }
    return @($ids | Select-Object -Unique)
}

function Get-VersionImageMap {
    param([Parameter(Mandatory = $true)][object]$Record)

    $map = @{}
    if ($null -eq $Record) { return $map }

    if ($Record.ContainsKey('images') -and $null -ne $Record.images) {
        foreach ($node in $Record.images.Keys) {
            $img = $Record.images[$node]
            if ($null -eq $img) { continue }
            $imageId = if ($img.ContainsKey('image_id')) { [string]$img.image_id } else { '' }
            if ([string]::IsNullOrWhiteSpace($imageId)) { continue }
            $imageName = if ($img.ContainsKey('image_name')) { [string]$img.image_name } else { '' }
            $map[[string]$node] = @{ node = [string]$node; image_id = $imageId; image_name = $imageName }
        }
        if ($map.Count -gt 0) { return $map }
    }

    # vNext8 and older records contained one image_id without a node map.
    if ($Record.ContainsKey('image_id') -and -not [string]::IsNullOrWhiteSpace([string]$Record.image_id)) {
        $legacyId = [string]$Record.image_id
        if (Test-ProxmoxVmExists -VmId $legacyId) {
            $vm = Get-ProxmoxVmNode -VmId $legacyId
            $legacyNode = [string]$vm.node
            $legacyName = if ($Record.ContainsKey('image_name')) { [string]$Record.image_name } else { '' }
            $map[$legacyNode] = @{ node = $legacyNode; image_id = $legacyId; image_name = $legacyName }
        }
    }
    return $map
}


function Test-VersionRecordBackingComplete {
    param(
        [Parameter(Mandatory = $true)][string]$SourceVmId,
        [Parameter(Mandatory = $true)][object]$Record
    )

    # vNext10: RASIMG is the authoritative version backing. Native rasv-*
    # snapshots from vNext9/older are legacy metadata only and may disappear
    # when the gold VM is restored from an older RASIMG.
    $images = Get-VersionImageMap -Record $Record
    if ($images.Count -eq 0) { return $false }

    foreach ($node in $images.Keys) {
        $img = $images[$node]
        $imageId = [string]$img.image_id
        if (-not (Test-ProxmoxVmExists -VmId $imageId)) { return $false }
        $actual = Get-ProxmoxVmNode -VmId $imageId
        if ([string]$actual.node -ne [string]$node) { return $false }
    }

    return $true
}

function Get-VersionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][string]$SnapshotName
    )

    $state = Get-VersionState
    if (-not $state.templates.ContainsKey([string]$VmId)) { return $null }
    $tpl = $state.templates[[string]$VmId]
    if (-not $tpl.ContainsKey('versions') -or $null -eq $tpl.versions) { return $null }
    if (-not $tpl.versions.ContainsKey($SnapshotName)) { return $null }
    return $tpl.versions[$SnapshotName]
}

function Get-CurrentVersionName {
    param([Parameter(Mandatory = $true)][string]$VmId)

    $state = Get-VersionState
    if (-not $state.templates.ContainsKey([string]$VmId)) { return $null }
    $tpl = $state.templates[[string]$VmId]
    if ($tpl.ContainsKey('current_version') -and -not [string]::IsNullOrWhiteSpace([string]$tpl.current_version)) {
        return [string]$tpl.current_version
    }
    return $null
}

function Set-CurrentVersionName {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][string]$SnapshotName
    )

    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-VersionState
        if (-not $state.templates.ContainsKey([string]$VmId)) { return }
        $state.templates[[string]$VmId].current_version = $SnapshotName
        Save-VersionState -State $state
    } | Out-Null
}

function Remove-VersionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][string]$SnapshotName
    )

    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-VersionState
        if (-not $state.templates.ContainsKey([string]$VmId)) { return }

        $tpl = $state.templates[[string]$VmId]
        if ($tpl.ContainsKey('versions') -and $null -ne $tpl.versions -and $tpl.versions.ContainsKey($SnapshotName)) {
            [void]$tpl.versions.Remove($SnapshotName)
        }

        if ($tpl.ContainsKey('current_version') -and [string]$tpl.current_version -eq $SnapshotName) {
            $remaining = @()

            if ($tpl.ContainsKey('versions') -and $null -ne $tpl.versions) {
                foreach ($key in $tpl.versions.Keys) {
                    # Ignore legacy vNext archive records if an older state
                    # file still contains them.
                    if ([string]$key -like '__archive__*') { continue }

                    $record = $tpl.versions[$key]
                    $created = [DateTime]::MinValue
                    if ($null -ne $record -and $record.ContainsKey('created_utc')) {
                        [DateTime]::TryParse([string]$record.created_utc, [ref]$created) | Out-Null
                    }

                    $remaining += [pscustomobject]@{
                        name    = [string]$key
                        created = $created
                    }
                }
            }

            $fallback = $remaining | Sort-Object created -Descending | Select-Object -First 1
            if ($null -ne $fallback) {
                $tpl.current_version = [string]$fallback.name
                Write-DebugLog "Deleted current RAS version [$SnapshotName] for VM [$VmId]; current version moved to [$($tpl.current_version)]."
            }
            else {
                $tpl.current_version = $null
                Write-DebugLog "Deleted last RAS version [$SnapshotName] for VM [$VmId]; no current version remains."
            }
        }

        $state.templates[[string]$VmId] = $tpl
        Save-VersionState -State $state
    } | Out-Null
}

function Get-HiddenImageVmIds {
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'

    $state = Get-VersionState
    foreach ($templateId in $state.templates.Keys) {
        $tpl = $state.templates[$templateId]
        if ($null -eq $tpl -or -not $tpl.ContainsKey('versions') -or $null -eq $tpl.versions) { continue }
        foreach ($versionName in $tpl.versions.Keys) {
            $record = $tpl.versions[$versionName]
            if ($null -eq $record) { continue }
            foreach ($imageId in @(Get-VersionImageIds -Record $record)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$imageId)) { [void]$ids.Add([string]$imageId) }
            }
        }
    }

    # Hide all in-progress multi-node image VMs as well.
    $taskState = Get-VersionTaskState
    foreach ($taskId in $taskState.Keys) {
        $entry = $taskState[$taskId]
        if ($null -eq $entry) { continue }
        foreach ($field in @('image_id','current_image_id')) {
            if ($entry.ContainsKey($field) -and -not [string]::IsNullOrWhiteSpace([string]$entry[$field])) {
                [void]$ids.Add([string]$entry[$field])
            }
        }
        if ($entry.ContainsKey('images') -and $null -ne $entry.images) {
            foreach ($node in $entry.images.Keys) {
                $img = $entry.images[$node]
                if ($null -ne $img -and $img.ContainsKey('image_id') -and -not [string]::IsNullOrWhiteSpace([string]$img.image_id)) {
                    [void]$ids.Add([string]$img.image_id)
                }
            }
        }
    }

    return @($ids)
}

function Get-VersionTaskState {
    try {
        $state = Get-CachedJsonState -Path $script:VersionTaskStatePath -DefaultValue @{}
        if ($null -eq $state) { return @{} }
        return $state
    }
    catch {
        Write-DebugLog "Failed to load version task state: $($_.Exception.Message)"
        throw "Version task state file [$($script:VersionTaskStatePath)] is unreadable: $($_.Exception.Message)"
    }
}

function Save-VersionTaskState {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Write-JsonFileAtomic -Path $script:VersionTaskStatePath -Object $State -Depth 30
}

function Set-VersionTaskEntry {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][hashtable]$Entry
    )

    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-VersionTaskState
        $state[$TaskId] = $Entry
        Save-VersionTaskState -State $state
    } | Out-Null
}

function Get-VersionTaskEntry {
    param([Parameter(Mandatory = $true)][string]$TaskId)
    $state = Get-VersionTaskState
    if ($state.ContainsKey($TaskId)) { return $state[$TaskId] }
    return $null
}

function Remove-VersionTaskEntry {
    param([Parameter(Mandatory = $true)][string]$TaskId)

    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-VersionTaskState
        if ($state.ContainsKey($TaskId)) {
            [void]$state.Remove($TaskId)
            Save-VersionTaskState -State $state
        }
    } | Out-Null
}

function Get-ActiveVersionRevertForVm {
    param([Parameter(Mandatory = $true)][string]$VmId)

    $state = Get-VersionTaskState
    $candidates = @()
    foreach ($taskId in $state.Keys) {
        $entry = $state[$taskId]
        if ($null -eq $entry) { continue }
        if (-not $entry.ContainsKey('type') -or [string]$entry.type -ne 'version_revert') { continue }
        if (-not $entry.ContainsKey('source_id') -or [string]$entry.source_id -ne [string]$VmId) { continue }
        $stage = if ($entry.ContainsKey('stage')) { [string]$entry.stage } else { '' }
        if ($stage -notin @('restore-intent','gold-delete','gold-restore-submit','gold-restore-clone')) { continue }
        $started = [DateTime]::MinValue
        if ($entry.ContainsKey('started_utc')) {
            [DateTime]::TryParse([string]$entry.started_utc, [ref]$started) | Out-Null
        }
        $candidates += [pscustomobject]@{ task_id = [string]$taskId; entry = $entry; started = $started }
    }
    return ($candidates | Sort-Object started -Descending | Select-Object -First 1)
}

function Get-ActiveVersionRevertVmIds {
    $state = Get-VersionTaskState
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($taskId in $state.Keys) {
        $entry = $state[$taskId]
        if ($null -eq $entry) { continue }
        if (-not $entry.ContainsKey('type') -or [string]$entry.type -ne 'version_revert') { continue }
        $stage = if ($entry.ContainsKey('stage')) { [string]$entry.stage } else { '' }
        if ($stage -notin @('restore-intent','gold-delete','gold-restore-submit','gold-restore-clone')) { continue }
        if ($entry.ContainsKey('source_id') -and -not [string]::IsNullOrWhiteSpace([string]$entry.source_id)) {
            [void]$ids.Add([string]$entry.source_id)
        }
    }
    return @($ids)
}

function New-RasSyntheticRestoringGoldGuest {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][object]$RevertInfo
    )
    $entry = $RevertInfo.entry
    $name = if ($entry.ContainsKey('gold_name') -and -not [string]::IsNullOrWhiteSpace([string]$entry.gold_name)) { [string]$entry.gold_name } else { "VM $VmId" }
    $node = if ($entry.ContainsKey('source_node')) { [string]$entry.source_node } else { $null }
    return @{
        id            = $VmId
        name          = $name
        provider      = 'Proxmox'
        state         = 'powered_off'
        power_state   = 'stopped'
        host_os       = 'win11'
        ip            = $null
        ip_addresses  = @()
        mac_addresses = @()
        node          = $node
        is_template   = $false
        type          = 'Virtual Machine'
    }
}

function Get-ActiveVersionCreateTaskForVm {
    param([Parameter(Mandatory = $true)][string]$VmId)

    $state = Get-VersionTaskState
    $candidates = @()
    foreach ($taskId in $state.Keys) {
        $entry = $state[$taskId]
        if ($null -eq $entry) { continue }
        if (-not $entry.ContainsKey('type') -or [string]$entry.type -ne 'version_create') { continue }
        if (-not $entry.ContainsKey('source_id') -or [string]$entry.source_id -ne [string]$VmId) { continue }
        $stage = if ($entry.ContainsKey('stage')) { [string]$entry.stage } else { '' }
        if ($stage -notin @('prepare-images','snapshot','image-clone','image-migrate','image-template','clone','template')) { continue }
        $started = [DateTime]::MinValue
        if ($entry.ContainsKey('started_utc')) {
            [DateTime]::TryParse([string]$entry.started_utc, [ref]$started) | Out-Null
        }
        $candidates += [pscustomobject]@{ task_id = [string]$taskId; entry = $entry; started = $started }
    }

    if ($candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object started -Descending | Select-Object -First 1)
}

function Get-ActiveVersionDeleteTaskForVersion {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][string]$SnapshotName
    )

    $state = Get-VersionTaskState
    foreach ($taskId in $state.Keys) {
        $entry = $state[$taskId]
        if ($null -eq $entry) { continue }
        if (-not $entry.ContainsKey('type') -or [string]$entry.type -ne 'version_delete') { continue }
        if (-not $entry.ContainsKey('source_id') -or [string]$entry.source_id -ne [string]$VmId) { continue }
        if (-not $entry.ContainsKey('snapshot_name') -or [string]$entry.snapshot_name -ne [string]$SnapshotName) { continue }
        return @{ task_id = [string]$taskId; entry = $entry }
    }
    return $null
}

function Send-Response {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResponseObject
    )

    try {
        $json = $ResponseObject | ConvertTo-Json -Compress -Depth 20
        $writer.WriteLine($json)
        Write-DebugLog "OUT: $json"
    }
    catch {
        $fallback = @{
            error = @{
                code    = $script:ErrorCodes.InternalError
                message = "$($script:ProviderNamePrefix) Failed to serialize response: $($_.Exception.Message)"
            }
        } | ConvertTo-Json -Compress -Depth 10

        $writer.WriteLine($fallback)
        Write-DebugLog "OUT-FALLBACK: $fallback"
    }
}

function New-ErrorResponse {
    param(
        [int]$Code,
        [string]$Message
    )

    return @{
        error = @{
            code    = $Code
            message = $Message
        }
    }
}

function ConvertFrom-JsonSafe {
    param([string]$InputLine)

    try {
        return $InputLine | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-DebugLog "JSON parse failed: $($_.Exception.Message)"
        return $null
    }
}

function Test-RequiredFields {
    param(
        [object]$Data,
        [string[]]$RequiredFields
    )

    foreach ($field in $RequiredFields) {
        $keys = $field -split '\.'
        $value = $Data

        foreach ($key in $keys) {
            if ($null -ne $value -and $value.PSObject.Properties.Name -contains $key) {
                $value = $value.$key
            }
            else {
                return "$($script:ProviderNamePrefix) Missing field: $field"
            }
        }
    }

    return $null
}

function Initialize-CertificateBypass {
    param([bool]$AllowInsecureTls = $false)

    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            return
        }

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        if ($AllowInsecureTls) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
        else {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
        }
    }
    catch {
        Write-DebugLog "TLS initialization failed: $($_.Exception.Message)"
        throw
    }
}

function Get-Session {
    if ($null -eq $script:ProxmoxSession) {
        throw 'Session not initialized'
    }

    if ([string]::IsNullOrWhiteSpace($script:ProxmoxSession.host)) {
        throw 'Session host missing'
    }

    if ($null -eq $script:ProxmoxSession.header) {
        throw 'Session header missing'
    }

    return $script:ProxmoxSession
}

function Get-ProxmoxBaseUrl {
    param([hashtable]$Session)
    return ("https://{0}" -f $Session.host).TrimEnd('/')
}

function Get-HttpStatusCodeFromErrorRecord {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    if ($null -eq $exception) { return $null }

    try {
        $responseProperty = $exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $response = $responseProperty.Value
            $statusProperty = $response.PSObject.Properties['StatusCode']
            if ($null -ne $statusProperty -and $null -ne $statusProperty.Value) {
                try { return [int]$statusProperty.Value }
                catch {
                    $valueProperty = $statusProperty.Value.PSObject.Properties['value__']
                    if ($null -ne $valueProperty) { return [int]$valueProperty.Value }
                }
            }
        }
    }
    catch {}

    return $null
}

function Test-IsRetryableGetFailure {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $statusCode = Get-HttpStatusCodeFromErrorRecord -ErrorRecord $ErrorRecord
    if ($null -ne $statusCode) {
        return (@(408, 429, 502, 503, 504) -contains [int]$statusCode)
    }

    # Transport failures do not always carry an HTTP response. Retry only errors
    # that are plausibly transient; certificate and authentication failures are
    # deliberately excluded so configuration problems surface immediately.
    $message = [string]$ErrorRecord.Exception.Message
    return ($message -match '(?i)(timed?\s*out|timeout|temporar(?:y|ily) unavailable|connection (?:refused|reset|closed|aborted)|network is unreachable|host is down|no such host|name or service not known|remote name could not be resolved|response ended prematurely|unexpected end of.*response)')
}

function Invoke-ProxmoxRestMethod {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST','PUT','DELETE')][string]$Method,
        [object]$Body = $null,
        [bool]$AllowInsecureTls = $false
    )

    $cfg = Get-ProviderConfig
    $irmParams = @{
        Uri         = $Uri
        Headers     = $Headers
        Method      = $Method
        ErrorAction = 'Stop'
    }

    if ($null -ne $script:ProxmoxWebSession -and $script:InvokeRestMethodParameterNames.Contains('WebSession')) {
        $irmParams.WebSession = $script:ProxmoxWebSession
    }
    if ($script:InvokeRestMethodParameterNames.Contains('ConnectionTimeoutSeconds')) {
        $irmParams.ConnectionTimeoutSeconds = [int]$cfg.api_connection_timeout_seconds
    }
    elseif ($script:InvokeRestMethodParameterNames.Contains('TimeoutSec')) {
        $irmParams.TimeoutSec = [int]$cfg.api_operation_timeout_seconds
    }
    if ($script:InvokeRestMethodParameterNames.Contains('OperationTimeoutSeconds')) {
        $irmParams.OperationTimeoutSeconds = [int]$cfg.api_operation_timeout_seconds
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        if ($AllowInsecureTls -and $script:InvokeRestMethodParameterNames.Contains('SkipCertificateCheck')) {
            $irmParams.SkipCertificateCheck = $true
        }
        if ($script:InvokeRestMethodParameterNames.Contains('SkipHeaderValidation')) {
            $irmParams.SkipHeaderValidation = $true
        }
    }

    if ($null -ne $Body) { $irmParams.Body = $Body }
    Write-DebugLog "HTTP $Method $Uri"

    # PowerShell's built-in MaximumRetryCount retries every HTTP 400-599 response,
    # including expected Proxmox 500 responses while QGA/VM state is not ready.
    # Use a narrow provider-side policy instead: only idempotent GET requests and
    # only transport failures or 408/429/502/503/504 are retried.
    $maximumRetries = if ($Method -eq 'GET') { [int]$cfg.api_get_max_retries } else { 0 }
    $attempt = 0
    while ($true) {
        try {
            return Invoke-RestMethod @irmParams
        }
        catch {
            $errorRecord = $_
            $httpError = [string]$errorRecord.Exception.Message
            $retryable = ($Method -eq 'GET' -and $attempt -lt $maximumRetries -and (Test-IsRetryableGetFailure -ErrorRecord $errorRecord))
            if ($retryable) {
                $attempt++
                $baseDelayMs = [Math]::Max(1, [int]$cfg.api_get_retry_interval_seconds) * 1000
                $jitterMs = Get-Random -Minimum 0 -Maximum 251
                Write-DebugLog "HTTP GET transient failure; retry [$attempt/$maximumRetries] after $($baseDelayMs + $jitterMs)ms: $httpError"
                Start-Sleep -Milliseconds ($baseDelayMs + $jitterMs)
                continue
            }

            if ($Method -eq 'GET' -and ($httpError -match 'VM .* is not running' -or $httpError -match 'QEMU guest agent is not running')) {
                Write-TraceLog "HTTP expected transient failure: $httpError"
            }
            else {
                Write-DebugLog "HTTP failure: $httpError"
            }
            throw
        }
    }
}

function Invoke-ProxmoxApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST','DELETE','PUT')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Body
    )

    $session = Get-Session
    $base = Get-ProxmoxBaseUrl -Session $session
    $uri = ($base.TrimEnd('/') + '/' + $Path.TrimStart('/'))
    $allowInsecureTls = if ($session.ContainsKey('allow_insecure_tls')) { [bool]$session.allow_insecure_tls } else { $false }

    if ($Method -eq 'GET') {
        $ttl = Get-ProxmoxGetCacheTtlSeconds -Path $Path
        $cacheKey = "$($session.host)|$Path"
        if ($ttl -gt 0) {
            $cached = Get-CachedApiResponse -Key $cacheKey
            if ($null -ne $cached) { return $cached }
        }

        $response = Invoke-ProxmoxRestMethod -Uri $uri -Headers $session.header -Method GET -AllowInsecureTls $allowInsecureTls
        if ($ttl -gt 0 -and $Path -match '/qemu/\d+/config$' -and $null -ne $response -and
            $response.PSObject.Properties.Name -contains 'data' -and $null -ne $response.data) {
            $lockProperty = $response.data.PSObject.Properties['lock']
            $nameProperty = $response.data.PSObject.Properties['name']
            $hasTransientLock = ($null -ne $lockProperty -and -not [string]::IsNullOrWhiteSpace([string]$lockProperty.Value))
            $hasTransientName = ($null -eq $nameProperty -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value) -or [string]$nameProperty.Value -match '^\s*VM\s+\d+\s*$')
            if ($hasTransientLock -or $hasTransientName) { $ttl = [Math]::Min($ttl, 1) }
        }
        if ($ttl -gt 0) { Set-CachedApiResponse -Key $cacheKey -Value $response -TtlSeconds $ttl }
        return $response
    }

    if ($Method -eq 'DELETE') {
        $response = Invoke-ProxmoxRestMethod -Uri $uri -Headers $session.header -Method DELETE -AllowInsecureTls $allowInsecureTls
        Clear-ProxmoxApiCache
        return $response
    }

    if ($null -eq $Body) { $Body = @{} }
    $response = Invoke-ProxmoxRestMethod -Uri $uri -Headers $session.header -Method $Method -Body $Body -AllowInsecureTls $allowInsecureTls
    Clear-ProxmoxApiCache
    return $response
}

function Get-ProxmoxClusterVMs {
    $resp = Invoke-ProxmoxApi -Method GET -Path '/api2/json/cluster/resources?type=vm'

    $data = @()
    if ($null -ne $resp -and $resp.PSObject.Properties.Name -contains 'data' -and $null -ne $resp.data) {
        $data = @($resp.data)
    }

    # Proxmox can expose short-lived/incomplete cluster-resource rows while a VM
    # is cloned or destroyed. Never let StrictMode turn a missing property into a
    # provider-wide failure. Only complete QEMU rows with a VMID are returned.
    $result = @()
    foreach ($entry in $data) {
        if ($null -eq $entry) { continue }

        $typeProp = $entry.PSObject.Properties['type']
        if ($null -eq $typeProp -or [string]$typeProp.Value -ne 'qemu') { continue }

        $vmidProp = $entry.PSObject.Properties['vmid']
        if ($null -eq $vmidProp -or [string]::IsNullOrWhiteSpace([string]$vmidProp.Value)) {
            Write-TraceLog 'Skipping transient QEMU cluster resource without vmid.'
            continue
        }

        $result += $entry
    }

    return @($result)
}

function Get-ProxmoxVmNode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmId
    )

    $vm = $null
    foreach ($candidate in (Get-ProxmoxClusterVMs)) {
        if ($null -eq $candidate) { continue }
        $vmidProp = $candidate.PSObject.Properties['vmid']
        if ($null -eq $vmidProp) { continue }
        if ([string]$vmidProp.Value -eq [string]$VmId) {
            $vm = $candidate
            break
        }
    }

    if ($null -eq $vm) {
        throw "VM [$VmId] not found in cluster"
    }

    $nodeProp = $vm.PSObject.Properties['node']
    if ($null -eq $nodeProp -or [string]::IsNullOrWhiteSpace([string]$nodeProp.Value)) {
        throw "VM [$VmId] has no node information"
    }

    return $vm
}

function Map-ProxmoxStateToRasState {
    param([string]$State)

    $normalized = if ($null -ne $State) { $State.ToString().Trim().ToLowerInvariant() } else { 'unknown' }

    switch ($normalized) {
        'running' { return 'powered_on' }
        'stopped' { return 'powered_off' }
        'paused' { return 'suspended' }
        'suspended' { return 'suspended' }
        'shutdown' { return 'powering_off' }
        'halting' { return 'powering_off' }
        'prelaunch' { return 'powering_on' }
        default { return 'powered_off' }
    }
}

function Get-ProxmoxVmCurrentStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Node,

        [Parameter(Mandatory = $true)]
        [string]$VmId
    )

    $resp = Invoke-ProxmoxApi -Method GET -Path "/api2/json/nodes/$Node/qemu/$VmId/status/current"
    return $resp.data
}

function Get-ProxmoxVmConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Node,

        [Parameter(Mandatory = $true)]
        [string]$VmId
    )

    $resp = Invoke-ProxmoxApi -Method GET -Path "/api2/json/nodes/$Node/qemu/$VmId/config"
    return $resp.data
}

function Get-ProxmoxStorageImageContent {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$Storage
    )

    $escapedStorage = [System.Uri]::EscapeDataString($Storage)
    $resp = Invoke-ProxmoxApi -Method GET -Path "/api2/json/nodes/$Node/storage/$escapedStorage/content?content=images"

    if ($null -eq $resp -or -not ($resp.PSObject.Properties.Name -contains 'data') -or $null -eq $resp.data) {
        return @()
    }

    return @($resp.data)
}

function Get-VersionImageLinkedCloneDependencies {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$Storage,
        [Parameter(Mandatory = $true)][string]$ImageVmId
    )

    # Proxmox ZFSPoolPlugin exposes linked-clone parentage in storage content
    # volume IDs as:
    #   <storage>:base-<PARENT-VMID>-disk-*/vm-<CHILD-VMID>-disk-*
    # Match every child volume whose immutable base belongs to this RASIMG.
    $basePrefix = "${Storage}:base-${ImageVmId}-"
    $pattern = '^' + [Regex]::Escape($basePrefix) + '[^/]+/'
    $dependencies = @{}

    foreach ($item in (Get-ProxmoxStorageImageContent -Node $Node -Storage $Storage)) {
        if ($null -eq $item) { continue }

        $volidProp = $item.PSObject.Properties['volid']
        if ($null -eq $volidProp -or [string]::IsNullOrWhiteSpace([string]$volidProp.Value)) { continue }

        $volid = [string]$volidProp.Value
        if ($volid -notmatch $pattern) { continue }

        $childVmId = $null
        $vmidProp = $item.PSObject.Properties['vmid']
        if ($null -ne $vmidProp -and -not [string]::IsNullOrWhiteSpace([string]$vmidProp.Value)) {
            $childVmId = [string]$vmidProp.Value
        }
        elseif ($volid -match '/vm-(\d+)-') {
            $childVmId = [string]$Matches[1]
        }

        # Even an orphaned child volume without an owner VMID is a real storage
        # dependency and must block deletion of the base image.
        $key = if (-not [string]::IsNullOrWhiteSpace($childVmId)) { "vm:$childVmId" } else { "vol:$volid" }
        if (-not $dependencies.ContainsKey($key)) {
            $dependencies[$key] = [pscustomobject]@{
                vmid  = $childVmId
                volid = $volid
                node  = $Node
            }
        }
    }

    return @($dependencies.Values | Sort-Object @{ Expression = { if ([string]::IsNullOrWhiteSpace([string]$_.vmid)) { '999999999' } else { [string]$_.vmid } } }, volid)
}

function Get-VersionImageDeleteBlockers {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$DeleteQueue,
        [Parameter(Mandatory = $true)][string]$Storage
    )

    $blockers = @()
    $imageIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in $DeleteQueue) {
        $imageId = if ($item -is [System.Collections.IDictionary]) { [string]$item['image_id'] } else { [string]$item.image_id }
        if ([string]::IsNullOrWhiteSpace($imageId)) { continue }
        [void]$imageIds.Add($imageId)

        $actualVm = Get-ProxmoxVmNodeIfPresentStrict -VmId $imageId
        if ($null -eq $actualVm) { continue }
        $node = [string]$actualVm.node
        foreach ($dep in @(Get-VersionImageLinkedCloneDependencies -Node $node -Storage $Storage -ImageVmId $imageId)) {
            $blockers += [pscustomobject]@{
                image_id = $imageId
                node     = $node
                vmid     = [string]$dep.vmid
                volid    = [string]$dep.volid
                source   = 'storage'
            }
        }
    }

    # A clone POST can be accepted slightly before its ZFS child volume becomes
    # visible in storage/content. Persistent CloneState closes that visibility gap.
    $cloneState = Get-CloneStateAll
    foreach ($cloneVmId in $cloneState.Keys) {
        $entry = $cloneState[$cloneVmId]
        if ($null -eq $entry -or -not ($entry -is [System.Collections.IDictionary])) { continue }
        if (-not $entry.Contains('image_source_id')) { continue }
        $imageId = [string]$entry['image_source_id']
        if (-not $imageIds.Contains($imageId)) { continue }
        $node = if ($entry.Contains('clone_node')) { [string]$entry['clone_node'] } else { '' }
        $blockers += [pscustomobject]@{
            image_id = $imageId
            node     = $node
            vmid     = [string]$cloneVmId
            volid    = 'pending-clone-state'
            source   = 'clone-state'
        }
    }

    return @($blockers | Sort-Object image_id, vmid, volid -Unique)
}

function Format-VersionImageDeleteBlockers {
    param([Parameter(Mandatory = $true)][object[]]$Blockers)

    $parts = @()
    $groups = @($Blockers | Group-Object image_id)
    foreach ($group in $groups) {
        $imageId = [string]$group.Name
        $childIds = @(
            $group.Group |
                ForEach-Object {
                    if (-not [string]::IsNullOrWhiteSpace([string]$_.vmid)) { [string]$_.vmid }
                    else { "orphan-volume:$([string]$_.volid)" }
                } |
                Sort-Object -Unique
        )
        $nodes = @($group.Group | ForEach-Object { [string]$_.node } | Sort-Object -Unique)
        $parts += "RASIMG $imageId on $($nodes -join ',') -> $($childIds -join ',')"
    }

    return ($parts -join '; ')
}

function Get-ProxmoxVmSnapshots {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$VmId
    )
    $resp = Invoke-ProxmoxApi -Method GET -Path "/api2/json/nodes/$Node/qemu/$VmId/snapshot"
    return @($resp.data)
}

function Find-ProxmoxVmSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][string]$SnapshotName
    )
    foreach ($snapshot in (Get-ProxmoxVmSnapshots -Node $Node -VmId $VmId)) {
        if ($snapshot.PSObject.Properties.Name -contains 'name' -and [string]$snapshot.name -eq $SnapshotName) {
            return $snapshot
        }
    }
    return $null
}

function Test-ProxmoxVmExists {
    param([Parameter(Mandatory = $true)][string]$VmId)

    # A transport, authentication or API failure is not proof that a VM is
    # absent. Only the provider's definitive not-found result maps to false;
    # all other failures propagate so destructive/recovery workflows fail closed.
    $vm = Get-ProxmoxVmNodeIfPresentStrict -VmId $VmId
    return ($null -ne $vm)
}

function Get-ProxmoxVmNodeIfPresentStrict {
    param([Parameter(Mandatory = $true)][string]$VmId)

    try {
        return Get-ProxmoxVmNode -VmId $VmId
    }
    catch {
        # Only a definitive provider-generated "not found" result is treated as
        # absence. API/transport/permission failures must propagate so destructive
        # safety checks fail closed instead of silently skipping an image.
        if ([string]$_.Exception.Message -eq "VM [$VmId] not found in cluster") {
            return $null
        }
        throw
    }
}

function Delete-ProxmoxVmSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][string]$SnapshotName
    )
    $encoded = [System.Uri]::EscapeDataString($SnapshotName)
    $resp = Invoke-ProxmoxApi -Method DELETE -Path "/api2/json/nodes/$Node/qemu/$VmId/snapshot/$encoded"
    $taskId = [string]$resp.data
    if ([string]::IsNullOrWhiteSpace($taskId)) { throw 'Proxmox returned no task id for snapshot deletion' }
    return $taskId
}


function Get-ProxmoxVmGuestAgentInterfaces {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Node,

        [Parameter(Mandatory = $true)]
        [string]$VmId
    )

    try {
        $resp = Invoke-ProxmoxApi -Method GET -Path "/api2/json/nodes/$Node/qemu/$VmId/agent/network-get-interfaces"
        if ($null -eq $resp) { return @() }

        $dataProp = $resp.PSObject.Properties['data']
        if ($null -eq $dataProp -or $null -eq $dataProp.Value) { return @() }
        $data = $dataProp.Value

        $resultProp = $data.PSObject.Properties['result']
        if ($null -ne $resultProp -and $null -ne $resultProp.Value) {
            return @($resultProp.Value)
        }

        return @($data)
    }
    catch {
        $agentError = [string]$_.Exception.Message
        if ($agentError -match 'VM .* is not running' -or $agentError -match 'QEMU guest agent is not running') {
            Write-TraceLog "Guest agent interface query not ready for VM [$VmId]: $agentError"
        }
        else {
            Write-DebugLog "Guest agent interface query failed for VM [$VmId]: $agentError"
        }
        return @()
    }
}

function Get-ProxmoxVmNetworkData {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$VmId,
        [bool]$QueryGuestAgent = $true,
        [object]$Config = $null
    )

    $cfgObject = $Config
    if ($null -eq $cfgObject) {
        try { $cfgObject = Get-ProxmoxVmConfig -Node $Node -VmId $VmId }
        catch { $cfgObject = $null }
    }

    $cacheKey = Get-VmNetworkCacheKey -Node $Node -VmId $VmId -Config $cfgObject
    if ($QueryGuestAgent -and $script:VmNetworkCache.ContainsKey($cacheKey)) {
        $cachedNetworkData = ConvertFrom-VmNetworkCacheEntry -Entry $script:VmNetworkCache[$cacheKey]
        if ($null -ne $cachedNetworkData) {
            Write-TraceLog ("VM network cache hit for VM [{0}]: IPs=[{1}], MACs=[{2}]" -f `
                $VmId, (@($cachedNetworkData.IPv4Addresses) -join ','), (@($cachedNetworkData.MacAddresses) -join ','))
            return $cachedNetworkData
        }

        Write-DebugLog "Discarding expired or invalid VM network cache entry for VM [$VmId]; querying guest agent immediately."
        [void]$script:VmNetworkCache.Remove($cacheKey)
    }

    $ipv4Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $macSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $interfaces = if ($QueryGuestAgent) { @(Get-ProxmoxVmGuestAgentInterfaces -Node $Node -VmId $VmId) } else { @() }
    foreach ($iface in $interfaces) {
        if ($null -eq $iface) { continue }
        $mac = $null
        $macProperty = $iface.PSObject.Properties['hardware-address']
        if ($null -ne $macProperty -and -not [string]::IsNullOrWhiteSpace([string]$macProperty.Value)) {
            $mac = ([string]$macProperty.Value).ToUpperInvariant()
        }

        $ipListProperty = $iface.PSObject.Properties['ip-addresses']
        $ipAddresses = if ($null -ne $ipListProperty -and $null -ne $ipListProperty.Value) { @($ipListProperty.Value) } else { @() }
        foreach ($ip in $ipAddresses) {
            if ($null -eq $ip) { continue }
            $typeProperty = $ip.PSObject.Properties['ip-address-type']
            $addressProperty = $ip.PSObject.Properties['ip-address']
            if ($null -eq $typeProperty -or $null -eq $addressProperty) { continue }
            $address = [string]$addressProperty.Value
            if ([string]$typeProperty.Value -eq 'ipv4' -and
                -not [string]::IsNullOrWhiteSpace($address) -and
                $address -ne '127.0.0.1' -and $address -notmatch '^169\.254\.') {
                [void]$ipv4Set.Add($address)
                if (-not [string]::IsNullOrWhiteSpace($mac)) { [void]$macSet.Add($mac) }
            }
        }
    }

    if ($null -ne $cfgObject) {
        try {
            foreach ($property in $cfgObject.PSObject.Properties) {
                if ($property.Name -match '^net\d+$' -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $match = [regex]::Match([string]$property.Value, '([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5})')
                    if ($match.Success) { [void]$macSet.Add($match.Groups[1].Value.ToUpperInvariant()) }
                }
            }
        }
        catch { Write-DebugLog "Config MAC lookup failed for VM [$VmId]: $($_.Exception.Message)" }
    }

    $orderedIps = @(Sort-PreferredIPv4Addresses -Addresses @($ipv4Set))
    $orderedMacs = @($macSet | Sort-Object)
    $result = ConvertTo-NormalizedNetworkData -NetworkData @{
        IPv4Addresses = @($orderedIps | Select-Object -First 3)
        MacAddresses  = @($orderedMacs | Select-Object -First 3)
    }

    if ($QueryGuestAgent) {
        $config = Get-ProviderConfig
        $ttl = if (@($result.IPv4Addresses).Count -gt 0) { [int]$config.network_cache_seconds } else { [int]$config.network_negative_cache_seconds }
        if ($ttl -gt 0) {
            # Store only primitive typed arrays. Do not pass network protocol data
            # through the generic recursive object copier.
            $script:VmNetworkCache[$cacheKey] = New-VmNetworkCacheEntry -NetworkData $result -TtlSeconds $ttl
            Write-TraceLog ("VM network cache stored for VM [{0}]: ttl=[{1}s], IPs=[{2}], MACs=[{3}]" -f `
                $VmId, $ttl, (@($result.IPv4Addresses) -join ','), (@($result.MacAddresses) -join ','))
        }
    }

    return $result
}

function Get-ProxmoxVmOsType {
    param(
        [object]$CurrentStatus,
        [object]$Config
    )

    if ($null -ne $CurrentStatus -and $CurrentStatus.PSObject.Properties.Name -contains 'ostype') {
        if (-not [string]::IsNullOrWhiteSpace([string]$CurrentStatus.ostype)) {
            return [string]$CurrentStatus.ostype
        }
    }

    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains 'ostype') {
        if (-not [string]::IsNullOrWhiteSpace([string]$Config.ostype)) {
            return [string]$Config.ostype
        }
    }

    return 'unknown'
}

function Get-ProxmoxVmIsTemplate {
    param([object]$Config)

    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains 'template') {
        try {
            return ([int]$Config.template -eq 1)
        }
        catch {
            return $false
        }
    }

    return $false
}

function ConvertTo-RasGuestObject {
    param([Parameter(Mandatory = $true)][string]$VmId)

    $clusterVm = Get-ProxmoxVmNode -VmId $VmId
    $nodeProperty = $clusterVm.PSObject.Properties['node']
    $node = [string]$nodeProperty.Value

    # cluster/resources already carries the steady-state running/stopped value.
    # Reuse it instead of issuing one status/current request per VM every poll.
    $rawState = 'unknown'
    foreach ($statePropertyName in @('qmpstatus','status')) {
        $stateProperty = $clusterVm.PSObject.Properties[$statePropertyName]
        if ($null -ne $stateProperty -and -not [string]::IsNullOrWhiteSpace([string]$stateProperty.Value)) {
            $rawState = [string]$stateProperty.Value
            break
        }
    }

    $current = $clusterVm
    if ($rawState -eq 'unknown') {
        try {
            $current = Get-ProxmoxVmCurrentStatus -Node $node -VmId $VmId
            foreach ($statePropertyName in @('qmpstatus','status')) {
                $stateProperty = $current.PSObject.Properties[$statePropertyName]
                if ($null -ne $stateProperty -and -not [string]::IsNullOrWhiteSpace([string]$stateProperty.Value)) {
                    $rawState = [string]$stateProperty.Value
                    break
                }
            }
        }
        catch { Write-DebugLog "Current status fallback failed for VM [$VmId]: $($_.Exception.Message)" }
    }

    $config = $null
    try { $config = Get-ProxmoxVmConfig -Node $node -VmId $VmId }
    catch { Write-DebugLog "Config lookup failed for VM [$VmId]: $($_.Exception.Message)" }

    $queryGuestAgent = ($rawState.Trim().ToLowerInvariant() -eq 'running')
    try {
        $network = Get-ProxmoxVmNetworkData -Node $node -VmId $VmId -QueryGuestAgent $queryGuestAgent -Config $config
    }
    catch {
        Write-DebugLog "Network lookup failed for VM [$VmId]: $($_.Exception.Message)"
        $network = @{ IPv4Addresses = @(); MacAddresses = @() }
    }

    $name = $null
    foreach ($source in @($clusterVm, $current, $config)) {
        if ($null -eq $source) { continue }
        $nameProperty = $source.PSObject.Properties['name']
        if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            $name = [string]$nameProperty.Value
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "VM-$VmId" }

    $osType = Get-ProxmoxVmOsType -CurrentStatus $current -Config $config
    $physicalTemplate = Get-ProxmoxVmIsTemplate -Config $config
    $isTemplate = Get-LogicalTemplateState -VmId $VmId -DefaultValue $physicalTemplate
    $rasState = Map-ProxmoxStateToRasState -State $rawState

    $network = ConvertTo-NormalizedNetworkData -NetworkData $network
    $ipv4Addresses = @($network.IPv4Addresses)
    $macAddresses = @($network.MacAddresses)

    $guestObject = @{
        id            = [string]$VmId
        name          = $name
        provider      = 'Proxmox'
        node          = $node
        state         = $rasState
        power_state   = $rawState
        host_os       = $osType
        ip            = $(if ($ipv4Addresses.Count -gt 0) { $ipv4Addresses[0] } else { $null })
        ip_addresses  = $ipv4Addresses
        mac_addresses = $macAddresses
        is_template   = $isTemplate
        type          = 'Virtual Machine'
    }

    Write-DebugLog ("GUEST VMID={0}; Name={1}; Node={2}; State={3}; Template={4}; IPs={5}" -f `
        $guestObject.id, $guestObject.name, $guestObject.node, $guestObject.state,
        $guestObject.is_template, ($guestObject.ip_addresses -join ','))
    return $guestObject
}

function Get-TrackedCloneContextByVmId {
    param([Parameter(Mandatory = $true)][string]$VmId)

    foreach ($key in @($script:TaskContext.Keys)) {
        $ctx = $script:TaskContext[$key]
        if ($null -ne $ctx -and $ctx.ContainsKey('type') -and [string]$ctx.type -eq 'clone' -and
            $ctx.ContainsKey('clone_id') -and [string]$ctx.clone_id -eq [string]$VmId) {
            Write-DebugLog "TRACKED CLONE FOUND IN MEMORY for VM [$VmId]"
            return @{ task_id = $key; context = $ctx }
        }
    }

    $persisted = Get-CloneStateEntry -VmId $VmId
    if ($null -ne $persisted) {
        $ctx = Copy-ObjectRecursive -InputObject $persisted
        if (-not $ctx.ContainsKey('type')) { $ctx.type = 'clone' }
        if (-not $ctx.ContainsKey('clone_id')) { $ctx.clone_id = [string]$VmId }
        Write-DebugLog "TRACKED CLONE FOUND IN FILE for VM [$VmId]"
        return @{ task_id = $null; context = $ctx }
    }

    Write-DebugLog "TRACKED CLONE NOT FOUND for VM [$VmId]"
    return $null
}

function Start-ProxmoxVmIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmId
    )

    $clusterVm = Get-ProxmoxVmNode -VmId $VmId
    $node = [string]$clusterVm.node
    $current = Get-ProxmoxVmCurrentStatus -Node $node -VmId $VmId

    $rawState = ''
    if ($current.PSObject.Properties.Name -contains 'qmpstatus' -and -not [string]::IsNullOrWhiteSpace([string]$current.qmpstatus)) {
        $rawState = [string]$current.qmpstatus
    }
    elseif ($current.PSObject.Properties.Name -contains 'status' -and -not [string]::IsNullOrWhiteSpace([string]$current.status)) {
        $rawState = [string]$current.status
    }

    $rasState = Map-ProxmoxStateToRasState -State $rawState

    if ($rasState -eq 'powered_on' -or $rasState -eq 'powering_on') {
        return @{
            started       = $false
            pending       = $false
            node          = $node
            raw_state     = $rawState
            ras_state     = $rasState
            task_id       = $null
            error_message = $null
        }
    }

    try {
        $resp = Invoke-ProxmoxApi -Method POST -Path "/api2/json/nodes/$node/qemu/$VmId/status/start" -Body @{}
        $startTaskId = $null
        if ($null -ne $resp -and $resp.PSObject.Properties.Name -contains 'data') {
            $startTaskId = [string]$resp.data
        }

        Write-DebugLog "Issued start for VM [$VmId], start task id=[$startTaskId]"

        return @{
            started       = $true
            pending       = $false
            node          = $node
            raw_state     = $rawState
            ras_state     = $rasState
            task_id       = $startTaskId
            error_message = $null
        }
    }
    catch {
        $msg = $_.Exception.Message
        Write-DebugLog "Start attempt for VM [$VmId] failed: $msg"

        if ($msg -match "can't lock file" -or $msg -match 'got timeout' -or $msg -match 'VM is locked') {
            return @{
                started       = $false
                pending       = $true
                node          = $node
                raw_state     = $rawState
                ras_state     = $rasState
                task_id       = $null
                error_message = $msg
            }
        }

        throw
    }
}

function Get-RasGuestObjectForCloneAwareFlow {
    param([Parameter(Mandatory = $true)][string]$VmId)

    $guest = ConvertTo-RasGuestObject -VmId $VmId
    $tracked = Get-TrackedCloneContextByVmId -VmId $VmId
    if ($null -eq $tracked) {
        Write-DebugLog "CLONE-AWARE FLOW: no tracked clone context for VM [$VmId]"
        return $guest
    }

    Write-DebugLog "CLONE-AWARE FLOW: tracked clone context found for VM [$VmId]"
    $ctx = $tracked.context
    foreach ($field in @('start_issued','start_pending','creation_completed')) {
        if (-not $ctx.ContainsKey($field)) { $ctx[$field] = $false }
        try { $ctx[$field] = [System.Convert]::ToBoolean($ctx[$field]) } catch { $ctx[$field] = $false }
    }
    if (-not $ctx.ContainsKey('start_retry_count')) { $ctx.start_retry_count = 0 }
    try { $ctx.start_retry_count = [int]$ctx.start_retry_count } catch { $ctx.start_retry_count = 0 }

    if ($guest.state -eq 'powered_off' -or $guest.state -eq 'powering_off') {
        $startInfo = Start-ProxmoxVmIfNeeded -VmId $VmId
        $ctx.start_retry_count = [int]$ctx.start_retry_count + 1
        $ctx.clone_node = $startInfo.node
        if ($startInfo.started) {
            $ctx.start_issued = $true
            $ctx.start_pending = $false
            $ctx.start_task_id = $startInfo.task_id
            Write-DebugLog "Clone-aware get: VM [$VmId] was off, start issued."
        }
        elseif ($startInfo.pending) {
            $ctx.start_pending = $true
            Write-DebugLog "Clone-aware get: VM [$VmId] still locked, start deferred."
        }
        $guest.state = 'powering_on'
        $guest.power_state = 'starting'
    }
    elseif ($guest.state -eq 'powered_on') {
        $hasIp = ($null -ne $guest.ip_addresses -and @($guest.ip_addresses).Count -gt 0)
        if ($hasIp) {
            $ctx.creation_completed = $true
            if (-not $ctx.ContainsKey('ready_utc') -or [string]::IsNullOrWhiteSpace([string]$ctx.ready_utc)) {
                $ctx.ready_utc = [DateTime]::UtcNow.ToString('o')
            }
            Write-DebugLog "Clone-aware get: VM [$VmId] is powered on and has IP(s) [$($guest.ip_addresses -join ',')]."
        }
        else {
            $guest.state = 'powering_on'
            $guest.power_state = 'starting'
            Write-DebugLog "Clone-aware get: VM [$VmId] is powered on but has no IP yet. Reporting powering_on."
        }
    }

    # guests/get may observe readiness before tasks/get. Keep tracking intact so
    # tasks/get remains the single terminal authority and can always return clone_id.
    if ($null -ne $tracked.task_id) { $script:TaskContext[$tracked.task_id] = $ctx }
    Set-CloneStateEntry -VmId $VmId -Entry $ctx

    Write-DebugLog "CLONE-AWARE FLOW RESULT for VM [$VmId]: state=[$($guest.state)] power_state=[$($guest.power_state)]"
    return $guest
}

function Get-ControlAction {
    param([Parameter(Mandatory = $true)][string]$Control)

    switch ($Control.Trim().ToLowerInvariant()) {
        'start' { return 'start' }
        'stop' { return 'shutdown' }
        'reset' { return 'reset' }
        'restart' { return 'reboot' }
        'reboot' { return 'reboot' }
        'delete' { return 'delete' }
        'suspend' { return 'suspend' }
        default { return $null }
    }
}

function Get-ProxmoxNextVmId {
    # Compatibility fallback only when no farm-owned VMID pool is configured.
    $resp = Invoke-ProxmoxApi -Method GET -Path '/api2/json/cluster/nextid'
    $nextId = if ($null -ne $resp -and $resp.PSObject.Properties.Name -contains 'data') { [string]$resp.data } else { '' }
    if ([string]::IsNullOrWhiteSpace($nextId)) {
        throw 'Proxmox cluster/nextid returned an empty VMID'
    }
    return $nextId
}

function Get-ProxmoxClusterUsedVmIds {
    $resp = Invoke-ProxmoxApi -Method GET -Path '/api2/json/cluster/resources?type=vm'
    $used = [System.Collections.Generic.HashSet[int]]::new()
    if ($null -eq $resp -or -not ($resp.PSObject.Properties.Name -contains 'data')) { return $used }

    foreach ($entry in @($resp.data)) {
        if ($null -eq $entry) { continue }
        $vmidProp = $entry.PSObject.Properties['vmid']
        if ($null -eq $vmidProp) { continue }
        $id = 0
        if ([int]::TryParse([string]$vmidProp.Value, [ref]$id)) { [void]$used.Add($id) }
    }
    return $used
}

function Get-NextManagedVmId {
    param(
        [ValidateSet('session','rasimg')][string]$PoolKind = 'session',
        [System.Collections.Generic.HashSet[int]]$ExcludeVmIds = $null
    )

    $cfg = Get-ProviderConfig
    $pool = Get-ConfiguredVmIdPool -Kind $PoolKind -Config $cfg
    if (-not [bool]$pool.enabled) {
        return Get-ProxmoxNextVmId
    }

    $used = Get-ProxmoxClusterUsedVmIds
    for ($candidate = [int]$pool.start; $candidate -le [int]$pool.end; $candidate++) {
        if ($null -ne $ExcludeVmIds -and $ExcludeVmIds.Contains($candidate)) { continue }
        if (-not $used.Contains($candidate)) { return [string]$candidate }
    }

    throw "Configured RAS $PoolKind VMID pool [$($pool.start)-$($pool.end)] is exhausted"
}

function Test-IsProxmoxVmIdConflictError {
    param([AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }

    # Proxmox wording differs slightly between versions/endpoints. Retry only
    # explicit allocation collisions; storage, permission, network and all other
    # failures must surface immediately instead of being hidden by generic retries.
    if ($Message -match '(?i)\b(?:VM|VMID)\b[^\r\n]*\balready exists\b') { return $true }
    if ($Message -match '(?i)\balready exists\b[^\r\n]*\b(?:VM|VMID)\b') { return $true }
    if ($Message -match '(?i)\bconfiguration file\b[^\r\n]*\bqemu-server\b[^\r\n]*\balready exists\b') { return $true }
    if ($Message -match '(?i)\bqemu-server\b[^\r\n]*\.conf\b[^\r\n]*\balready exists\b') { return $true }

    return $false
}

function Invoke-ProxmoxCloneWithVmIdRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$SourceVmId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet(0,1)][int]$Full,
        [string]$Storage,
        [ValidateSet('session','rasimg')][string]$PoolKind = 'session',
        [string]$Purpose = 'clone',
        [int]$MaxAttempts = $script:VmIdRetryMaxAttempts
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    $rejectedVmIds = [System.Collections.Generic.HashSet[int]]::new()

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $newVmId = Get-NextManagedVmId -PoolKind $PoolKind -ExcludeVmIds $rejectedVmIds
        $body = @{
            newid = [string]$newVmId
            name  = $Name
            full  = $Full
        }
        if (-not [string]::IsNullOrWhiteSpace($Storage)) {
            $body.storage = $Storage
        }

        try {
            $resp = Invoke-ProxmoxApi -Method POST -Path "/api2/json/nodes/$Node/qemu/$SourceVmId/clone" -Body $body
            $taskId = if ($null -ne $resp -and $resp.PSObject.Properties.Name -contains 'data') { [string]$resp.data } else { '' }
            if ([string]::IsNullOrWhiteSpace($taskId)) {
                throw "Proxmox accepted no task id for $Purpose candidate VM [$newVmId]"
            }

            return @{
                vmid    = [string]$newVmId
                task_id = $taskId
                attempt = $attempt
            }
        }
        catch {
            $message = [string]$_.Exception.Message
            if (Test-IsProxmoxVmIdConflictError -Message $message) {
                $numericRejected = 0
                if ([int]::TryParse([string]$newVmId, [ref]$numericRejected)) { [void]$rejectedVmIds.Add($numericRejected) }
                if ($attempt -lt $MaxAttempts) {
                    Write-DebugLog "VMID allocation conflict for $Purpose candidate [$newVmId] on node [$Node] (attempt $attempt/$MaxAttempts); rescanning the configured $PoolKind VMID pool. Error=[$message]"
                    Start-Sleep -Milliseconds (100 * $attempt)
                    continue
                }
                throw "VMID allocation conflict persisted for $Purpose after $MaxAttempts attempts. Last candidate=[$newVmId]. Last error: $message"
            }
            throw
        }
    }

    throw "Unable to allocate a VMID for $Purpose after $MaxAttempts attempts"
}

function Get-ProxmoxTaskNodeFromUpid {
    param([string]$Upid)

    if ([string]::IsNullOrWhiteSpace($Upid)) {
        throw 'Task id is empty'
    }

    $parts = @($Upid -split ':')
    if ($parts.Count -lt 3 -or $parts[0] -ne 'UPID') {
        throw "Invalid Proxmox task id format: $Upid"
    }

    return $parts[1]
}

function Get-ProxmoxTaskStatus {
    param([string]$TaskId)

    $node = Get-ProxmoxTaskNodeFromUpid -Upid $TaskId
    $escapedTaskId = [System.Uri]::EscapeDataString($TaskId)
    $resp = Invoke-ProxmoxApi -Method GET -Path "/api2/json/nodes/$node/tasks/$escapedTaskId/status"
    return $resp.data
}

function New-TaskResultState {
    param([object]$TaskStatus)

    if ($null -eq $TaskStatus) {
        return @{
            state = 'failed'
            error = @{
                code    = 1
                message = 'Task status unavailable'
            }
        }
    }

    $status = ''
    if ($TaskStatus.PSObject.Properties.Name -contains 'status' -and $TaskStatus.status) {
        $status = [string]$TaskStatus.status
    }

    $exitStatus = $null
    if ($TaskStatus.PSObject.Properties.Name -contains 'exitstatus') {
        $exitStatus = [string]$TaskStatus.exitstatus
    }

    if ($status -eq 'running') {
        return @{ state = 'running' }
    }

    if ($status -eq 'stopped' -and $exitStatus -eq 'OK') {
        return @{ state = 'completed' }
    }

    $msg = if (-not [string]::IsNullOrWhiteSpace($exitStatus)) { $exitStatus } else { 'Unknown task failure' }
    return @{
        state = 'failed'
        error = @{
            code    = 1
            message = $msg
        }
    }
}

function Handle-Initialize {
    try {
        Invoke-ProviderInternalSelfTest
        $cfg = Get-ProviderConfig -ForInitialize
        Write-EffectiveProviderConfigLog
        $rate = [int]$cfg.tasks_polling_rate
        $horizon = [int]$cfg.task_observation_horizon_seconds
        $retries = [Math]::Max(1, [int][Math]::Ceiling([double]$horizon / [double]$rate))

        # Validate every persistent state family during initialize. Missing files
        # resolve to safe empty defaults; damaged primaries are repaired from a
        # valid rolling backup, while unrecoverable corruption fails fast before
        # the RAS Provider Service starts using the new implementation.
        Invoke-WithStateMutex -ScriptBlock {
            $null = Get-CloneState
            $null = Get-VersionState
            $null = Get-VersionTaskState
            $null = Get-PlacementState
            $null = Get-RecentGuestDeleteState
            $null = Remove-ExpiredTaskTombstones -State (Get-TaskTombstoneState)
        } | Out-Null

        return @{
            result = @{
                version      = '1.0.0'
                capabilities = @{
                    can_suspend_guests    = $true
                    guests_polling_rate   = [int]$cfg.guests_polling_rate
                    tasks_polling_rate    = $rate
                    tasks_polling_retries = $retries
                    template_method       = 'versioning'
                    can_link_clones       = $true
                }
            }
        }
    }
    catch {
        Write-DebugLog "Provider initialize failed: $($_.Exception.Message)"
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Provider configuration/initialization failed: $($_.Exception.Message)"
    }
}

function Handle-Connect {
    param([object]$Params)

    $settings = $Params.settings
    if ($null -eq $settings) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Missing settings"
    }

    $proxmoxHost = [string]$settings.host
    $username = [string]$settings.username
    $tokenName = [string]$settings.token_name
    $tokenSecret = [string]$settings.token_secret
    if ([string]::IsNullOrWhiteSpace($proxmoxHost) -or [string]::IsNullOrWhiteSpace($username) -or
        [string]::IsNullOrWhiteSpace($tokenName) -or [string]::IsNullOrWhiteSpace($tokenSecret)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid connection parameters"
    }

    $allowInsecureTls = $true
    if ($settings.PSObject.Properties.Name -contains 'allow_insecure_tls') {
        try { $allowInsecureTls = [System.Convert]::ToBoolean($settings.allow_insecure_tls) }
        catch { return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) allow_insecure_tls must be true or false" }
    }

    try {
        $cfg = Get-ProviderConfig
        Write-EffectiveProviderConfigLog
        Initialize-CertificateBypass -AllowInsecureTls $allowInsecureTls
        Clear-ProxmoxApiCache

        $header = @{ Authorization = "PVEAPIToken=$username!$tokenName=$tokenSecret" }
        $script:ProxmoxSession = @{
            host               = $proxmoxHost
            user               = $username
            token_name         = $tokenName
            header             = $header
            allow_insecure_tls = $allowInsecureTls
        }
        try {
            $script:ProxmoxWebSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        }
        catch {
            $script:ProxmoxWebSession = $null
            Write-DebugLog "Persistent HTTP session is unavailable in this PowerShell host; continuing without WebSession reuse: $($_.Exception.Message)"
        }

        $resp = Invoke-ProxmoxApi -Method GET -Path '/api2/json/version'
        $version = [string]$resp.data.version

        $enabledNodes = @(Get-EnabledComputeNodes -AllowEmpty)
        if ($enabledNodes.Count -gt 0) {
            # Provider connectivity must not disappear merely because one future
            # compute node is temporarily offline. Require at least one online
            # node with active storage; provisioning later filters candidates and
            # version publish still requires every selected target to be ready.
            $health = Get-HealthyComputeNodes -CandidateNodes $enabledNodes -Storage ([string]$cfg.storage) -IgnoreCapacityThresholds
            if (@($health.healthy).Count -eq 0) {
                $details = @($health.unhealthy.Keys | Sort-Object | ForEach-Object { "$_=$($health.unhealthy[$_])" })
                throw "No enabled compute node is currently online with active storage [$($cfg.storage)]: $($details -join '; ')"
            }
            if ($health.unhealthy.Count -gt 0) {
                $details = @($health.unhealthy.Keys | Sort-Object | ForEach-Object { "$_=$($health.unhealthy[$_])" })
                Write-DebugLog "CONNECT WARNING: some enabled compute nodes are currently unavailable and will be excluded from new provisioning: $($details -join '; ')"
            }
        }

        # Restore unexpired delete-gap tombstones after service/provider restarts.
        $script:RecentGuestDeletes = @{}
        foreach ($vmId in (Get-RecentGuestDeleteState).Keys) {
            $entry = Get-RecentGuestDelete -VmId ([string]$vmId)
            if ($null -ne $entry) { $script:RecentGuestDeletes[[string]$vmId] = $entry }
        }
        Invoke-WithStateMutex -ScriptBlock { $null = Remove-ExpiredTaskTombstones -State (Get-TaskTombstoneState) } | Out-Null

        if ($allowInsecureTls) {
            Write-DebugLog "SECURITY WARNING: TLS certificate validation is disabled for Proxmox [$proxmoxHost]. Configure allow_insecure_tls=false after installing a trusted certificate."
        }
        Write-DebugLog "Connected successfully to $proxmoxHost as $username, version=$version"
        return @{ result = @{ message = "$($script:ProviderNamePrefix) Connected successfully to Proxmox $proxmoxHost (version: $version)" } }
    }
    catch {
        $script:ProxmoxSession = $null
        $script:ProxmoxWebSession = $null
        Clear-ProxmoxApiCache
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to connect to Proxmox: $($_.Exception.Message)"
    }
}

function Handle-Disconnect {
    try {
        $hostName = if ($null -ne $script:ProxmoxSession) { $script:ProxmoxSession.host } else { $null }
        $script:ProxmoxSession = $null
        $script:ProxmoxWebSession = $null
        $script:TaskContext = @{}
        $script:RecentGuestDeletes = @{}
        Clear-ProxmoxApiCache

        # Persistent clone/version/recent-delete/task-tombstone state deliberately
        # survives disconnects and provider restarts.
        Write-DebugLog "Provider session cleared for Proxmox [$hostName]; persistent operation state retained."
        return @{ result = @{ message = "Session cleared on Proxmox $hostName" } }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to clear session: $($_.Exception.Message)"
    }
}

function Handle-HostList {
    try {
        $clusterVMs = Get-ProxmoxClusterVMs
        $hosts = @()

        $hiddenImages = @(Get-HiddenImageVmIds)
        foreach ($vm in $clusterVMs) {
            if ($null -eq $vm) {
                Write-DebugLog "Skipping null cluster resource entry in hosts/list."
                continue
            }

            $vmId = $null
            if ($vm.PSObject.Properties.Name -contains 'vmid') {
                $vmId = [string]$vm.vmid
            }
            if ([string]::IsNullOrWhiteSpace($vmId)) {
                Write-DebugLog "Skipping transient cluster resource without vmid in hosts/list."
                continue
            }

            $vmName = $null
            if ($vm.PSObject.Properties.Name -contains 'name') {
                $vmName = [string]$vm.name
            }
            if ([string]::IsNullOrWhiteSpace($vmName)) {
                # Proxmox can briefly expose an incomplete cluster/resources entry
                # while a VM is being cloned or deleted. Do not let StrictMode turn
                # that transient state into a complete hosts/list failure.
                Write-DebugLog "Skipping transient cluster VM [$vmId] without name in hosts/list."
                continue
            }

            if (($hiddenImages -contains $vmId) -or $vmName -like 'RASIMG-*') {
                Write-DebugLog "Skipping internal RAS version image VM [$vmId] name=[$vmName] from hosts/list."
                continue
            }
            $hosts += $vmId
        }

        return @{ result = @{ guests = @($hosts) } }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to retrieve host list: $($_.Exception.Message)"
    }
}

function Handle-HostGet {
    param([object]$Params)

    if ($null -eq $Params -or $null -eq $Params.id) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid or missing host ID"
    }

    try {
        $ids = @($Params.id)

        if ($ids.Count -eq 1) {
            $hostObj = Get-RasGuestObjectForCloneAwareFlow -VmId ([string]$ids[0])
            return @{ result = $hostObj }
        }

        $resultMap = @{}
        foreach ($id in $ids) {
            $vmId = [string]$id
            try {
                $resultMap[$vmId] = Get-RasGuestObjectForCloneAwareFlow -VmId $vmId
            }
            catch {
                $resultMap[$vmId] = @{
                    id            = $vmId
                    name          = $null
                    provider      = 'Proxmox'
                    state         = 'powered_off'
                    power_state   = 'unknown'
                    host_os       = 'unknown'
                    ip            = $null
                    ip_addresses  = @()
                    mac_addresses = @()
                    is_template   = $false
                    type          = 'Virtual Machine'
                }
                Write-DebugLog "Host get failed for VM [$vmId]: $($_.Exception.Message)"
            }
        }

        return @{ result = $resultMap }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to retrieve host info: $($_.Exception.Message)"
    }
}

function Handle-HostControl {
    param([object]$Params)
    return Handle-GuestControl -Params $Params
}

function Handle-GuestList {
    try {
        $clusterVMs = Get-ProxmoxClusterVMs
        $guests = @()

        $hiddenImages = @(Get-HiddenImageVmIds)
        foreach ($vm in $clusterVMs) {
            if ($null -eq $vm) {
                Write-DebugLog "Skipping null cluster resource entry in guests/list."
                continue
            }

            $vmId = $null
            if ($vm.PSObject.Properties.Name -contains 'vmid') {
                $vmId = [string]$vm.vmid
            }
            if ([string]::IsNullOrWhiteSpace($vmId)) {
                Write-DebugLog "Skipping transient cluster resource without vmid in guests/list."
                continue
            }

            $vmName = $null
            if ($vm.PSObject.Properties.Name -contains 'name') {
                $vmName = [string]$vm.name
            }
            if ([string]::IsNullOrWhiteSpace($vmName)) {
                # During clone/delete, /cluster/resources may briefly contain a VM
                # entry before its name property is populated (or while it is being
                # removed). Under StrictMode, direct access to a missing .name
                # property used to abort the whole guests/list request with -32603.
                Write-DebugLog "Skipping transient cluster VM [$vmId] without name in guests/list."
                continue
            }

            if (($hiddenImages -contains $vmId) -or $vmName -like 'RASIMG-*') {
                Write-DebugLog "Skipping internal RAS version image VM [$vmId] name=[$vmName] from guests/list."
                continue
            }
            # Skip placeholder names like "VM 101" which indicates VM cloning is still in progress.
            $isAutoName = $vmId -match '^\d+$' -and
                $vmName -match ("^\s*VM\s+{0}\s*$" -f [regex]::Escape($vmId))

            if ($isAutoName) {
                # During a vNext10+ gold restore, VM 300 can temporarily be a
                # clone placeholder. It is re-added below from persisted task
                # state so RAS never observes the template guest disappearing.
                Write-DebugLog "Skipping guest [$vmId] because name [$vmName] matches the placeholder VM <id> pattern."
                continue
            }

            $guests += $vmId
        }

        foreach ($restoringVmId in @(Get-ActiveVersionRevertVmIds)) {
            if ($guests -notcontains [string]$restoringVmId) {
                $guests += [string]$restoringVmId
                Write-DebugLog "Keeping restoring gold VM [$restoringVmId] visible in guests/list from persisted version-revert state."
            }
        }

        return @{ result = @{ guests = @($guests | Select-Object -Unique) } }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to retrieve guest list: $($_.Exception.Message)"
    }
}

function Register-RecentGuestDelete {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [string]$Name,
        [string]$Node
    )

    $entry = @{
        vmid        = $VmId
        name        = $Name
        node        = $Node
        expires_utc = [DateTime]::UtcNow.AddSeconds([int]$script:RecentGuestDeleteTtlSeconds).ToString('o')
    }
    $script:RecentGuestDeletes[$VmId] = $entry
    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-RecentGuestDeleteState
        $state[$VmId] = $entry
        Save-RecentGuestDeleteState -State $state
    } | Out-Null
    Write-DebugLog "Tracking transient delete gap for VM [$VmId] for $($script:RecentGuestDeleteTtlSeconds)s (persistent)."
}

function Get-RecentGuestDelete {
    param([Parameter(Mandatory = $true)][string]$VmId)

    $entry = $null
    if ($script:RecentGuestDeletes.ContainsKey($VmId)) { $entry = $script:RecentGuestDeletes[$VmId] }
    if ($null -eq $entry) {
        $state = Get-RecentGuestDeleteState
        if ($state.ContainsKey($VmId)) {
            $entry = $state[$VmId]
            $script:RecentGuestDeletes[$VmId] = $entry
        }
    }
    if ($null -eq $entry) { return $null }

    $expires = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$entry.expires_utc, [ref]$expires) -or [DateTime]::UtcNow -gt $expires) {
        Remove-RecentGuestDelete -VmId $VmId
        return $null
    }
    return $entry
}


function Remove-RecentGuestDelete {
    param([Parameter(Mandatory = $true)][string]$VmId)

    if ($script:RecentGuestDeletes.ContainsKey($VmId)) { [void]$script:RecentGuestDeletes.Remove($VmId) }
    Invoke-WithStateMutex -ScriptBlock {
        $state = Get-RecentGuestDeleteState
        if ($state.ContainsKey($VmId)) {
            [void]$state.Remove($VmId)
            Save-RecentGuestDeleteState -State $state
        }
    } | Out-Null
}

function New-RasTransientGuestObject {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [string]$Name,
        [string]$Node,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$PowerState
    )

    return @{
        id            = $VmId
        name          = $(if ([string]::IsNullOrWhiteSpace($Name)) { "VM-$VmId" } else { $Name })
        provider      = 'Proxmox'
        node          = $Node
        state         = $State
        power_state   = $PowerState
        host_os       = 'unknown'
        ip            = $null
        ip_addresses  = @()
        mac_addresses = @()
        is_template   = $false
        type          = 'Virtual Machine'
    }
}

function Handle-GuestGet {
    param([object]$Params)

    if ($null -eq $Params -or $null -eq $Params.id) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid or missing guest ID"
    }

    try {
        $ids = @($Params.id)

        if ($ids.Count -eq 1) {
            $singleId = [string]$ids[0]
            $activeRestore = Get-ActiveVersionRevertForVm -VmId $singleId
            if ($null -ne $activeRestore) {
                Write-DebugLog "HANDLE-GUESTGET returning synthetic restoring-gold state for VM [$singleId]."
                return @{ result = (New-RasSyntheticRestoringGoldGuest -VmId $singleId -RevertInfo $activeRestore) }
            }
            Write-DebugLog "HANDLE-GUESTGET using clone-aware flow for VM [$singleId]"
            try {
                $guest = Get-RasGuestObjectForCloneAwareFlow -VmId $singleId
                return @{ result = $guest }
            }
            catch {
                $lookupMessage = $_.Exception.Message
                if ($lookupMessage -match '^VM \[[^\]]+\] not found in cluster$') {
                    # Recreate has two legitimate gaps where the same VMID is briefly
                    # absent from Proxmox: after RAS deletes the old host and while the
                    # replacement linked clone is being registered in cluster/resources.
                    $trackedClone = Get-TrackedCloneContextByVmId -VmId $singleId
                    if ($null -ne $trackedClone) {
                        $cloneCtx = $trackedClone.context
                        $cloneName = if ($cloneCtx.ContainsKey('name')) { [string]$cloneCtx.name } else { $null }
                        $cloneNode = if ($cloneCtx.ContainsKey('clone_node')) { [string]$cloneCtx.clone_node } else { $null }
                        Write-DebugLog "HANDLE-GUESTGET returning transient cloning state for temporarily absent VM [$singleId]."
                        return @{ result = (New-RasTransientGuestObject -VmId $singleId -Name $cloneName -Node $cloneNode -State 'powering_on' -PowerState 'starting') }
                    }

                    $recentDelete = Get-RecentGuestDelete -VmId $singleId
                    if ($null -ne $recentDelete) {
                        Write-DebugLog "HANDLE-GUESTGET returning transient delete state for temporarily absent VM [$singleId]."
                        return @{ result = (New-RasTransientGuestObject -VmId $singleId -Name ([string]$recentDelete.name) -Node ([string]$recentDelete.node) -State 'powering_off' -PowerState 'stopped') }
                    }
                }
                throw
            }
        }

        $resultMap = @{}
        foreach ($id in $ids) {
            $vmId = [string]$id
            try {
                $activeRestore = Get-ActiveVersionRevertForVm -VmId $vmId
                if ($null -ne $activeRestore) {
                    $resultMap[$vmId] = New-RasSyntheticRestoringGoldGuest -VmId $vmId -RevertInfo $activeRestore
                    continue
                }
                $resultMap[$vmId] = Get-RasGuestObjectForCloneAwareFlow -VmId $vmId
            }
            catch {
                $resultMap[$vmId] = @{
                    id            = $vmId
                    name          = $null
                    provider      = 'Proxmox'
                    state         = 'powered_off'
                    power_state   = 'unknown'
                    host_os       = 'unknown'
                    ip            = $null
                    ip_addresses  = @()
                    mac_addresses = @()
                    is_template   = $false
                    type          = 'Virtual Machine'
                }
                Write-DebugLog "Guest get failed for VM [$vmId]: $($_.Exception.Message)"
            }
        }

        return @{ result = $resultMap }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to retrieve guest info: $($_.Exception.Message)"
    }
}

function Get-ProxmoxRawVmPowerState {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$VmId
    )

    $current = Get-ProxmoxVmCurrentStatus -Node $Node -VmId $VmId
    if ($null -eq $current) { return '' }

    $qmp = $current.PSObject.Properties['qmpstatus']
    if ($null -ne $qmp -and -not [string]::IsNullOrWhiteSpace([string]$qmp.Value)) {
        return ([string]$qmp.Value).Trim().ToLowerInvariant()
    }

    $status = $current.PSObject.Properties['status']
    if ($null -ne $status -and -not [string]::IsNullOrWhiteSpace([string]$status.Value)) {
        return ([string]$status.Value).Trim().ToLowerInvariant()
    }

    return ''
}

function Stop-ProxmoxVmImmediatelyForDelete {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$VmId,
        [int]$TimeoutSeconds = 15
    )

    $state = Get-ProxmoxRawVmPowerState -Node $Node -VmId $VmId
    if ($state -eq 'stopped') {
        return $null
    }

    Write-DebugLog "RAS delete requested for VM [$VmId] while state=[$state]; forcing immediate Proxmox stop before destroy."

    $stopTaskId = $null
    $stopSubmitted = $false
    $lastSubmitError = $null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $stopResp = Invoke-ProxmoxApi -Method POST -Path "/api2/json/nodes/$Node/qemu/$VmId/status/stop" -Body @{}
            if ($null -ne $stopResp -and $stopResp.PSObject.Properties.Name -contains 'data') {
                $stopTaskId = [string]$stopResp.data
            }
            $stopSubmitted = $true
            break
        }
        catch {
            $lastSubmitError = $_.Exception.Message
            # A start/shutdown task can hold a short-lived lock. Re-check state and
            # retry briefly instead of failing an otherwise authoritative RAS delete.
            try {
                $state = Get-ProxmoxRawVmPowerState -Node $Node -VmId $VmId
                if ($state -eq 'stopped') { return $null }
            }
            catch {}

            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds (300 * $attempt)
                continue
            }
        }
    }

    if (-not $stopSubmitted) {
        throw "Unable to force-stop VM [$VmId] before delete after 3 attempts: $lastSubmitError"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $state = Get-ProxmoxRawVmPowerState -Node $Node -VmId $VmId
        if ($state -eq 'stopped') {
            Write-DebugLog "VM [$VmId] reached stopped state for RAS delete; continuing with destroy."
            return $stopTaskId
        }
    }

    throw "VM [$VmId] did not reach stopped state within [$TimeoutSeconds] seconds after forced stop for RAS delete"
}

function Remove-ProxmoxVmForRasDelete {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$VmId
    )

    # RAS recreate can issue a start shortly before its delete request. Treat delete
    # as authoritative and make the operation self-contained instead of relying on
    # the VM still being stopped from an earlier guests/control stop call.
    $state = Get-ProxmoxRawVmPowerState -Node $Node -VmId $VmId
    if ($state -ne 'stopped') {
        $null = Stop-ProxmoxVmImmediatelyForDelete -Node $Node -VmId $VmId -TimeoutSeconds 15
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Invoke-ProxmoxApi -Method DELETE -Path "/api2/json/nodes/$Node/qemu/$VmId"
        }
        catch {
            $message = [string]$_.Exception.Message
            $retryable = ($message -match 'is running\s*-\s*destroy failed' -or
                          $message -match '(?i)locked|lock')

            if (-not $retryable -or $attempt -ge 3) {
                throw
            }

            Write-DebugLog "RAS delete retry [$attempt] for VM [$VmId] after transient Proxmox destroy failure: $message"
            try {
                $state = Get-ProxmoxRawVmPowerState -Node $Node -VmId $VmId
                if ($state -ne 'stopped') {
                    $null = Stop-ProxmoxVmImmediatelyForDelete -Node $Node -VmId $VmId -TimeoutSeconds 15
                }
            }
            catch {
                if ($attempt -ge 3) { throw }
            }
            Start-Sleep -Milliseconds (300 * $attempt)
        }
    }

    throw "Failed to delete VM [$VmId] after 3 attempts"
}

function Handle-GuestControl {
    param([object]$Params)

    if ($null -eq $Params -or [string]::IsNullOrWhiteSpace([string]$Params.id)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid guest id"
    }

    if ($null -eq $Params.control -or [string]::IsNullOrWhiteSpace([string]$Params.control)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid guest control"
    }

    try {
        $vmId = [string]$Params.id
        $requestedControl = [string]$Params.control
        $action = Get-ControlAction -Control $requestedControl

        if ([string]::IsNullOrWhiteSpace($action)) {
            return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Unsupported guest control: $requestedControl"
        }

        $clusterVm = Get-ProxmoxVmNode -VmId $vmId
        $node = [string]$clusterVm.node
        $existingName = if ($clusterVm.PSObject.Properties.Name -contains 'name') { [string]$clusterVm.name } else { $null }

        if ($action -eq 'start') {
            try {
                $current = Get-ProxmoxVmCurrentStatus -Node $node -VmId $vmId
                $rawState = ''

                if ($current.PSObject.Properties.Name -contains 'qmpstatus' -and -not [string]::IsNullOrWhiteSpace([string]$current.qmpstatus)) {
                    $rawState = [string]$current.qmpstatus
                }
                elseif ($current.PSObject.Properties.Name -contains 'status' -and -not [string]::IsNullOrWhiteSpace([string]$current.status)) {
                    $rawState = [string]$current.status
                }

                if ($rawState.Trim().ToLowerInvariant() -eq 'paused') {
                    $action = 'resume'
                    Write-DebugLog "Guest control start remapped to resume for paused VM [$vmId]."
                }
            }
            catch {
                Write-DebugLog "Failed to get current status for VM [$vmId] before start control. Falling back to start: $($_.Exception.Message)"
            }
        }

        if ($action -eq 'delete') {
            $resp = Remove-ProxmoxVmForRasDelete -Node $node -VmId $vmId
            Register-RecentGuestDelete -VmId $vmId -Name $existingName -Node $node
        }
        else {
            $resp = Invoke-ProxmoxApi -Method POST -Path "/api2/json/nodes/$node/qemu/$vmId/status/$action" -Body @{}
        }

        $upid = $null
        if ($null -ne $resp -and $resp.PSObject.Properties.Name -contains 'data') {
            $upid = $resp.data
        }

        return @{
            result = @{
                id      = $vmId
                node    = $node
                action  = $action
                upid    = $upid
                message = "$($script:ProviderNamePrefix) Guest control [$requestedControl] submitted successfully"
            }
        }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to control guest [$($Params.control)]: $($_.Exception.Message)"
    }
}

function Test-IsProxmoxTaskId {
    param([AllowEmptyString()][string]$TaskId)
    return (-not [string]::IsNullOrWhiteSpace($TaskId) -and $TaskId.StartsWith('UPID:', [System.StringComparison]::Ordinal))
}

function Complete-TrackedVersionTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [hashtable]$Output = @{}
    )

    $terminalResult = @{ state = 'completed'; output = $Output }
    Set-TaskTombstone -TaskId $TaskId -Result $terminalResult -Context $Context
    Remove-VersionTaskEntry -TaskId $TaskId
    if ($script:TaskContext.ContainsKey($TaskId)) { [void]$script:TaskContext.Remove($TaskId) }
    return @{ result = $terminalResult }
}

function Apply-DeferredTemplateConversionIfRequested {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    # A real RAS broker normally waits for guests/snapshots/create to complete
    # before sending guests/convert(true). Keep this path for brokers that issue
    # the explicit convert request while the version task is still in flight.
    # Re-read the persistent task entry so the flag also works across provider
    # process restarts or concurrent CPF process instances.
    $persistent = Get-VersionTaskEntry -TaskId $TaskId
    if ($null -ne $persistent -and $persistent.ContainsKey('convert_to_template_requested')) {
        $Context.convert_to_template_requested = $persistent.convert_to_template_requested
    }

    $requested = $false
    if ($Context.ContainsKey('convert_to_template_requested')) {
        try { $requested = [System.Convert]::ToBoolean($Context.convert_to_template_requested) }
        catch { $requested = $false }
    }
    if (-not $requested) { return $false }

    $vmId = [string]$Context.source_id
    Set-LogicalTemplateState -VmId $vmId -IsTemplate $true
    Write-DebugLog "Deferred RAS guests/convert(is_template=true) applied for VM [$vmId] after version task [$TaskId] completed."
    return $true
}

function Handle-VersionCreateTaskInfo {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $stage = if ($Context.ContainsKey('stage')) { [string]$Context.stage } else { '' }

    # vNext8 compatibility for an in-flight single-node task during upgrade.
    if ($stage -eq 'clone') {
        $cloneStatus = Get-ProxmoxTaskStatus -TaskId ([string]$Context.clone_task_id)
        $cloneResult = New-TaskResultState -TaskStatus $cloneStatus
        if ($cloneResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
        if ($cloneResult.state -eq 'failed') {
            $msg = if ($cloneResult.error.ContainsKey('message')) { [string]$cloneResult.error.message } else { 'Version image clone failed' }
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
            return @{ result = @{ state = 'failed'; error = $cloneResult.error } }
        }
        $imageId = [string]$Context.image_id
        $imageVm = Get-ProxmoxVmNode -VmId $imageId
        $imageNode = [string]$imageVm.node
        $resp = Invoke-ProxmoxApi -Method POST -Path "/api2/json/nodes/$imageNode/qemu/$imageId/template" -Body @{}
        $Context.stage = 'template'
        $Context.template_task_id = [string]$resp.data
        $script:TaskContext[$TaskId] = $Context
        Set-VersionTaskEntry -TaskId $TaskId -Entry $Context
        return @{ result = @{ state = 'running' } }
    }

    if ($stage -eq 'template') {
        $templateStatus = Get-ProxmoxTaskStatus -TaskId ([string]$Context.template_task_id)
        $templateResult = New-TaskResultState -TaskStatus $templateStatus
        if ($templateResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
        if ($templateResult.state -eq 'failed') {
            $msg = if ($templateResult.error.ContainsKey('message')) { [string]$templateResult.error.message } else { 'Version image template conversion failed' }
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
            return @{ result = @{ state = 'failed'; error = $templateResult.error } }
        }
        $legacyVm = Get-ProxmoxVmNode -VmId ([string]$Context.image_id)
        $legacyImages = @{}
        $legacyNode = [string]$legacyVm.node
        $legacyImages[$legacyNode] = @{ node = $legacyNode; image_id = [string]$Context.image_id; image_name = [string]$Context.image_name }
        Set-VersionRecord -VmId ([string]$Context.source_id) -SnapshotName ([string]$Context.snapshot_name) -NativeSnapshot ([string]$Context.native_snapshot) -Images $legacyImages
        $null = Apply-DeferredTemplateConversionIfRequested -TaskId $TaskId -Context $Context
        return Complete-TrackedVersionTask -TaskId $TaskId -Context $Context -Output @{ snapshot_id = [string]$Context.snapshot_name; image_id = [string]$Context.image_id }
    }

    if ($stage -in @('prepare-images','snapshot')) {
        $started = Start-NextVersionImageClone -OuterTaskId $TaskId -Context $Context
        if (-not $started) { throw 'Version publish has no target compute nodes' }
        return @{ result = @{ state = 'running' } }
    }

    if ($stage -eq 'image-clone') {
        $cloneStatus = Get-ProxmoxTaskStatus -TaskId ([string]$Context.clone_task_id)
        $cloneResult = New-TaskResultState -TaskStatus $cloneStatus
        if ($cloneResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
        if ($cloneResult.state -eq 'failed') {
            $msg = if ($cloneResult.error.ContainsKey('message')) { [string]$cloneResult.error.message } else { 'Multi-node version image clone failed' }
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
            return @{ result = @{ state = 'failed'; error = $cloneResult.error } }
        }

        if ([string]$Context.current_target_node -ne [string]$Context.source_node) {
            Start-VersionImageMigration -OuterTaskId $TaskId -Context $Context
        }
        else {
            Start-VersionImageTemplateConversion -OuterTaskId $TaskId -Context $Context
        }
        return @{ result = @{ state = 'running' } }
    }

    if ($stage -eq 'image-migrate') {
        $migrationStatus = Get-ProxmoxTaskStatus -TaskId ([string]$Context.migration_task_id)
        $migrationResult = New-TaskResultState -TaskStatus $migrationStatus
        if ($migrationResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
        if ($migrationResult.state -eq 'failed') {
            $msg = if ($migrationResult.error.ContainsKey('message')) { [string]$migrationResult.error.message } else { 'Version image migration failed' }
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
            return @{ result = @{ state = 'failed'; error = $migrationResult.error } }
        }
        Start-VersionImageTemplateConversion -OuterTaskId $TaskId -Context $Context
        return @{ result = @{ state = 'running' } }
    }

    if ($stage -eq 'image-template') {
        $templateStatus = Get-ProxmoxTaskStatus -TaskId ([string]$Context.template_task_id)
        $templateResult = New-TaskResultState -TaskStatus $templateStatus
        if ($templateResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
        if ($templateResult.state -eq 'failed') {
            $msg = if ($templateResult.error.ContainsKey('message')) { [string]$templateResult.error.message } else { 'Version image template conversion failed' }
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
            return @{ result = @{ state = 'failed'; error = $templateResult.error } }
        }

        $done = Complete-CurrentVersionImageAndContinue -OuterTaskId $TaskId -Context $Context
        if ($done) {
            $firstId = @($Context.images.Values | ForEach-Object { [string]$_.image_id } | Select-Object -First 1)[0]
            return Complete-TrackedVersionTask -TaskId $TaskId -Context $Context -Output @{ snapshot_id = [string]$Context.snapshot_name; image_id = $firstId }
        }
        return @{ result = @{ state = 'running' } }
    }

    if ($stage -eq 'completed') {
        $firstId = @($Context.images.Values | ForEach-Object { [string]$_.image_id } | Select-Object -First 1)[0]
        return Complete-TrackedVersionTask -TaskId $TaskId -Context $Context -Output @{ snapshot_id = [string]$Context.snapshot_name; image_id = $firstId }
    }

    throw "Unknown RAS version create stage [$stage] for task [$TaskId]"
}

function Start-GoldDeleteForRestore {
    param(
        [Parameter(Mandatory = $true)][string]$OuterTaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $goldId = [string]$Context.source_id
    $node = [string]$Context.source_node
    if (-not (Test-ProxmoxVmExists -VmId $goldId)) {
        $Context.stage = 'gold-delete'
        $Context.gold_delete_task_id = $null
        $script:TaskContext[$OuterTaskId] = $Context
        Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
        return @{ submitted = $false; already_absent = $true }
    }

    $current = Get-ProxmoxVmCurrentStatus -Node $node -VmId $goldId
    $rawState = if ($current.PSObject.Properties.Name -contains 'status') { [string]$current.status } else { '' }
    if ($rawState -eq 'running') {
        throw "Gold VM [$goldId] started while a RAS version restore intent was active"
    }

    try {
        $resp = Invoke-ProxmoxApi -Method DELETE -Path "/api2/json/nodes/$node/qemu/${goldId}?destroy-unreferenced-disks=1"
        $deleteTaskId = [string]$resp.data
        if ([string]::IsNullOrWhiteSpace($deleteTaskId)) {
            throw "No task id returned while removing mutable gold VM [$goldId] for version restore"
        }

        $Context.gold_delete_task_id = $deleteTaskId
        $Context.stage = 'gold-delete'
        $Context.delete_submit_attempts = [int]$Context.delete_submit_attempts + 1
        $Context.last_submit_error = $null
        $script:TaskContext[$OuterTaskId] = $Context
        Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
        Write-DebugLog "RAS version restore [$OuterTaskId]: gold delete submitted as task [$deleteTaskId]."
        return @{ submitted = $true; already_absent = $false; task_id = $deleteTaskId }
    }
    catch {
        $Context.delete_submit_attempts = [int]$Context.delete_submit_attempts + 1
        $Context.last_submit_error = [string]$_.Exception.Message
        $Context.stage = 'restore-intent'
        $script:TaskContext[$OuterTaskId] = $Context
        Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
        if ([int]$Context.delete_submit_attempts -ge 3) { throw }
        Write-DebugLog "RAS version restore [$OuterTaskId]: gold delete submit not confirmed (attempt $($Context.delete_submit_attempts)/3); state retained for reconciliation. Error=[$($_.Exception.Message)]"
        return @{ submitted = $false; already_absent = $false; pending_reconcile = $true }
    }
}

function Complete-GoldRestoreTask {
    param(
        [Parameter(Mandatory = $true)][string]$OuterTaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $goldId = [string]$Context.source_id
    if (-not (Test-ProxmoxVmExists -VmId $goldId)) {
        throw "Gold VM [$goldId] is missing while completing RAS version restore"
    }

    $restoredVm = Get-ProxmoxVmNode -VmId $goldId
    if ([string]$restoredVm.node -ne [string]$Context.source_node) {
        throw "Restored gold VM [$goldId] is on node [$([string]$restoredVm.node)], expected [$([string]$Context.source_node)]"
    }
    $restoredConfig = Get-ProxmoxVmConfig -Node ([string]$Context.source_node) -VmId $goldId
    if ($restoredConfig.PSObject.Properties.Name -contains 'lock' -and -not [string]::IsNullOrWhiteSpace([string]$restoredConfig.lock)) {
        return @{ result = @{ state = 'running' } }
    }
    if ($restoredConfig.PSObject.Properties.Name -contains 'template' -and [int]$restoredConfig.template -eq 1) {
        throw "Restored gold VM [$goldId] unexpectedly has template=1; refusing to complete maintenance restore"
    }

    if ($Context.ContainsKey('gold_network') -and $null -ne $Context.gold_network) {
        Restore-GoldNetworkIdentity -Node ([string]$Context.source_node) -VmId $goldId -Network $Context.gold_network
    }
    else {
        Write-DebugLog "RAS version restore [$OuterTaskId] has no captured gold_network (legacy in-flight task); clone-generated network identity is left unchanged."
    }

    Set-CurrentVersionName -VmId $goldId -SnapshotName ([string]$Context.snapshot_name)
    Write-DebugLog "RAS version [$($Context.snapshot_name)] restored successfully to gold VM [$goldId] from RASIMG [$($Context.restore_image_id)]."
    return Complete-TrackedVersionTask -TaskId $OuterTaskId -Context $Context -Output @{}
}

function Handle-VersionRevertTaskInfo {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $stage = if ($Context.ContainsKey('stage')) { [string]$Context.stage } else { '' }

    # Compatibility for an old in-flight native snapshot rollback.
    if ([string]::IsNullOrWhiteSpace($stage)) {
        $status = Get-ProxmoxTaskStatus -TaskId $TaskId
        $result = New-TaskResultState -TaskStatus $status
        if ($result.state -eq 'running') { return @{ result = @{ state = 'running' } } }
        if ($result.state -eq 'failed') {
            $msg = if ($result.error.ContainsKey('message')) { [string]$result.error.message } else { 'Legacy version restore failed' }
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
            return @{ result = @{ state = 'failed'; error = $result.error } }
        }
        Set-CurrentVersionName -VmId ([string]$Context.source_id) -SnapshotName ([string]$Context.snapshot_name)
        return Complete-TrackedVersionTask -TaskId $TaskId -Context $Context -Output @{}
    }

    if ($stage -eq 'restore-intent') {
        if (-not (Test-ProxmoxVmExists -VmId ([string]$Context.source_id))) {
            $null = Start-GoldRestoreClone -OuterTaskId $TaskId -Context $Context
            return @{ result = @{ state = 'running' } }
        }

        $config = Get-ProxmoxVmConfig -Node ([string]$Context.source_node) -VmId ([string]$Context.source_id)
        if ($config.PSObject.Properties.Name -contains 'lock' -and -not [string]::IsNullOrWhiteSpace([string]$config.lock)) {
            Write-DebugLog "RAS version restore [$TaskId]: waiting for gold VM lock [$([string]$config.lock)] during delete-intent reconciliation."
            return @{ result = @{ state = 'running' } }
        }

        try {
            $submit = Start-GoldDeleteForRestore -OuterTaskId $TaskId -Context $Context
            if ([bool]$submit.already_absent) { $null = Start-GoldRestoreClone -OuterTaskId $TaskId -Context $Context }
            return @{ result = @{ state = 'running' } }
        }
        catch {
            $message = "Gold delete submission failed after bounded retries: $($_.Exception.Message)"
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $message
            return @{ result = @{ state = 'failed'; error = @{ code = 1; message = $message } } }
        }
    }

    if ($stage -eq 'gold-delete') {
        $secondary = if ($Context.ContainsKey('gold_delete_task_id')) { [string]$Context.gold_delete_task_id } else { '' }
        if ([string]::IsNullOrWhiteSpace($secondary) -and (Test-IsProxmoxTaskId -TaskId $TaskId)) { $secondary = $TaskId }

        if ([string]::IsNullOrWhiteSpace($secondary)) {
            if (Test-ProxmoxVmExists -VmId ([string]$Context.source_id)) {
                $Context.stage = 'restore-intent'
                $script:TaskContext[$TaskId] = $Context
                Set-VersionTaskEntry -TaskId $TaskId -Entry $Context
                return @{ result = @{ state = 'running' } }
            }
            $null = Start-GoldRestoreClone -OuterTaskId $TaskId -Context $Context
            return @{ result = @{ state = 'running' } }
        }

        $deleteStatus = Get-ProxmoxTaskStatus -TaskId $secondary
        $deleteResult = New-TaskResultState -TaskStatus $deleteStatus
        if ($deleteResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
        if ($deleteResult.state -eq 'failed') {
            $msg = if ($deleteResult.error.ContainsKey('message')) { [string]$deleteResult.error.message } else { 'Gold delete failed' }
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
            return @{ result = @{ state = 'failed'; error = $deleteResult.error } }
        }
        $null = Start-GoldRestoreClone -OuterTaskId $TaskId -Context $Context
        return @{ result = @{ state = 'running' } }
    }

    if ($stage -eq 'gold-restore-submit') {
        if (-not (Test-ProxmoxVmExists -VmId ([string]$Context.source_id))) {
            try {
                $null = Start-GoldRestoreClone -OuterTaskId $TaskId -Context $Context
                return @{ result = @{ state = 'running' } }
            }
            catch {
                $message = "Gold restore clone submission failed after bounded retries: $($_.Exception.Message)"
                Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $message
                return @{ result = @{ state = 'failed'; error = @{ code = 1; message = $message } } }
            }
        }
        return Complete-GoldRestoreTask -OuterTaskId $TaskId -Context $Context
    }

    if ($stage -eq 'gold-restore-clone') {
        $restoreTaskId = if ($Context.ContainsKey('restore_clone_task_id')) { [string]$Context.restore_clone_task_id } else { '' }
        if ([string]::IsNullOrWhiteSpace($restoreTaskId)) {
            $Context.stage = 'gold-restore-submit'
            $script:TaskContext[$TaskId] = $Context
            Set-VersionTaskEntry -TaskId $TaskId -Entry $Context
            return @{ result = @{ state = 'running' } }
        }
        $restoreStatus = Get-ProxmoxTaskStatus -TaskId $restoreTaskId
        $restoreResult = New-TaskResultState -TaskStatus $restoreStatus
        if ($restoreResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
        if ($restoreResult.state -eq 'failed') {
            $msg = if ($restoreResult.error.ContainsKey('message')) { [string]$restoreResult.error.message } else { 'Gold restore clone failed' }
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
            return @{ result = @{ state = 'failed'; error = $restoreResult.error } }
        }
        return Complete-GoldRestoreTask -OuterTaskId $TaskId -Context $Context
    }

    throw "Unknown RAS version restore stage [$stage] for task [$TaskId]"
}

function Handle-VersionDeleteTaskInfo {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $stage = if ($Context.ContainsKey('stage')) { [string]$Context.stage } else { '' }

    if ($stage -eq 'delete-intent') {
        $blockers = @(Get-VersionImageDeleteBlockers -DeleteQueue @($Context.delete_queue) -Storage ([string]$Context.storage))
        if ($blockers.Count -gt 0) {
            $details = Format-VersionImageDeleteBlockers -Blockers $blockers
            $message = "RAS version [$($Context.snapshot_name)] cannot be deleted because linked clones still depend on its RASIMG(s): $details"
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $message
            return @{ result = @{ state = 'failed'; error = @{ code = 1; message = $message } } }
        }
        $Context.stage = 'images-delete'
        $stage = 'images-delete'
        $script:TaskContext[$TaskId] = $Context
        Set-VersionTaskEntry -TaskId $TaskId -Entry $Context
        $started = Start-NextVersionImageDelete -OuterTaskId $TaskId -Context $Context
        if ($started) { return @{ result = @{ state = 'running' } } }
    }

    if ($stage -eq 'image-delete') {
        $secondary = if ($Context.ContainsKey('current_delete_task_id') -and -not [string]::IsNullOrWhiteSpace([string]$Context.current_delete_task_id)) { [string]$Context.current_delete_task_id } else { $TaskId }
        $deleteStatus = Get-ProxmoxTaskStatus -TaskId $secondary
        $deleteResult = New-TaskResultState -TaskStatus $deleteStatus
        if ($deleteResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
        if ($deleteResult.state -eq 'failed') {
            $msg = if ($deleteResult.error.ContainsKey('message')) { [string]$deleteResult.error.message } else { 'Version image deletion failed' }
            Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
            return @{ result = @{ state = 'failed'; error = $deleteResult.error } }
        }
        $Context.stage = 'images-delete'
        $Context.current_delete_task_id = $null
        $script:TaskContext[$TaskId] = $Context
        Set-VersionTaskEntry -TaskId $TaskId -Entry $Context
        $stage = 'images-delete'
    }

    if ($stage -eq 'images-delete') {
        $secondary = if ($Context.ContainsKey('current_delete_task_id')) { [string]$Context.current_delete_task_id } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($secondary)) {
            $deleteStatus = Get-ProxmoxTaskStatus -TaskId $secondary
            $deleteResult = New-TaskResultState -TaskStatus $deleteStatus
            if ($deleteResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
            if ($deleteResult.state -eq 'failed') {
                $msg = if ($deleteResult.error.ContainsKey('message')) { [string]$deleteResult.error.message } else { 'Version image deletion failed' }
                Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
                return @{ result = @{ state = 'failed'; error = $deleteResult.error } }
            }
            $Context.current_delete_task_id = $null
            $Context.current_delete_image_id = $null
            $script:TaskContext[$TaskId] = $Context
            Set-VersionTaskEntry -TaskId $TaskId -Entry $Context
        }

        $started = Start-NextVersionImageDelete -OuterTaskId $TaskId -Context $Context
        if ($started) { return @{ result = @{ state = 'running' } } }

        $sourceId = [string]$Context.source_id
        $sourceNode = [string]$Context.source_node
        $nativeName = [string]$Context.native_snapshot
        $native = if (-not [string]::IsNullOrWhiteSpace($nativeName)) { Find-ProxmoxVmSnapshot -Node $sourceNode -VmId $sourceId -SnapshotName $nativeName } else { $null }
        if ($null -ne $native) {
            $nativeTaskId = Delete-ProxmoxVmSnapshot -Node $sourceNode -VmId $sourceId -SnapshotName $nativeName
            $Context.stage = 'native-delete'
            $Context.native_delete_task_id = $nativeTaskId
            $script:TaskContext[$TaskId] = $Context
            Set-VersionTaskEntry -TaskId $TaskId -Entry $Context
            return @{ result = @{ state = 'running' } }
        }

        Remove-VersionRecord -VmId $sourceId -SnapshotName ([string]$Context.snapshot_name)
        return Complete-TrackedVersionTask -TaskId $TaskId -Context $Context -Output @{}
    }

    if ($stage -eq 'native-delete') {
        $secondary = if ($Context.ContainsKey('native_delete_task_id')) { [string]$Context.native_delete_task_id } else { '' }
        if ([string]::IsNullOrWhiteSpace($secondary) -and (Test-IsProxmoxTaskId -TaskId $TaskId)) { $secondary = $TaskId }
        if (-not [string]::IsNullOrWhiteSpace($secondary)) {
            $nativeStatus = Get-ProxmoxTaskStatus -TaskId $secondary
            $nativeResult = New-TaskResultState -TaskStatus $nativeStatus
            if ($nativeResult.state -eq 'running') { return @{ result = @{ state = 'running' } } }
            if ($nativeResult.state -eq 'failed') {
                $msg = if ($nativeResult.error.ContainsKey('message')) { [string]$nativeResult.error.message } else { 'Native snapshot deletion failed' }
                Clear-TrackedTaskAfterFailure -TaskId $TaskId -Context $Context -Message $msg
                return @{ result = @{ state = 'failed'; error = $nativeResult.error } }
            }
        }
        Remove-VersionRecord -VmId ([string]$Context.source_id) -SnapshotName ([string]$Context.snapshot_name)
        return Complete-TrackedVersionTask -TaskId $TaskId -Context $Context -Output @{}
    }

    throw "Unknown RAS version delete stage [$stage] for task [$TaskId]"
}

function Clear-TrackedTaskAfterFailure {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [object]$Context,
        [string]$Message
    )

    if ($null -eq $Context) {
        Set-TaskTombstone -TaskId $TaskId -Result @{ state = 'failed'; error = @{ code = 1; message = $Message } }
        return
    }

    $type = if ($Context.ContainsKey('type')) { [string]$Context.type } else { '' }
    Set-TaskTombstone -TaskId $TaskId -Result @{ state = 'failed'; error = @{ code = 1; message = $Message } } -Context $Context

    if ($type -eq 'clone') {
        $cloneId = if ($Context.ContainsKey('clone_id')) { [string]$Context.clone_id } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($cloneId)) {
            Remove-CloneStateEntry -VmId $cloneId
        }
    }
    elseif ($type -in @('version_create', 'version_delete', 'version_revert')) {
        Remove-VersionTaskEntry -TaskId $TaskId
    }

    if ($script:TaskContext.ContainsKey($TaskId)) {
        [void]$script:TaskContext.Remove($TaskId)
    }

    if ($type -eq 'version_create') {
        $sourceId = if ($Context.ContainsKey('source_id')) { [string]$Context.source_id } else { '?' }
        $snapshotName = if ($Context.ContainsKey('native_snapshot')) { [string]$Context.native_snapshot } else { '?' }
        $imageId = if ($Context.ContainsKey('current_image_id')) { [string]$Context.current_image_id } elseif ($Context.ContainsKey('image_id')) { [string]$Context.image_id } else { '?' }
        $completedImages = @()
        if ($Context.ContainsKey('images') -and $null -ne $Context.images) {
            foreach ($node in $Context.images.Keys) { $completedImages += "$node=$([string]$Context.images[$node].image_id)" }
        }
        Write-DebugLog "RAS version create task [$TaskId] failed for source [$sourceId]. Tracking cleared so a retry is possible. Orphan check may be required: legacy native snapshot=[$snapshotName], current image VM=[$imageId], completed images=[$($completedImages -join ',')]. Error=[$Message]"
    }
    elseif ($type -eq 'version_revert') {
        # If the initial gold delete itself failed, the old gold VM still exists
        # and we can safely return RAS to logical template mode. Once deletion
        # completed and restore cloning started, keep maintenance active on
        # failure because the gold VM may be absent/incomplete and needs repair.
        $stage = if ($Context.ContainsKey('stage')) { [string]$Context.stage } else { '' }
        $goldExists = $false
        try { $goldExists = Test-ProxmoxVmExists -VmId ([string]$Context.source_id) } catch {}
        if ($stage -in @('restore-intent','gold-delete') -and $goldExists) {
            try {
                Set-LogicalTemplateState -VmId ([string]$Context.source_id) -IsTemplate $true
                Write-DebugLog "RAS version restore [$TaskId] failed before gold replacement; logical template state restored to True. Error=[$Message]"
            }
            catch {
                Write-DebugLog "RAS version restore [$TaskId] failed and logical template state could not be restored: $($_.Exception.Message)"
            }
        }
        else {
            Write-DebugLog "RAS version restore [$TaskId] failed during stage [$stage]. Maintenance remains active because gold replacement may be incomplete. Error=[$Message]"
        }
    }
    else {
        Write-DebugLog "Tracked task [$TaskId] type=[$type] failed. Persistent tracking cleared. Error=[$Message]"
    }
}

function Start-NextVersionImageClone {
    param(
        [Parameter(Mandatory = $true)][string]$OuterTaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $targets = @($Context.target_nodes)
    $index = [int]$Context.node_index
    if ($index -ge $targets.Count) { return $false }

    $sourceId = [string]$Context.source_id
    $sourceNode = [string]$Context.source_node
    $current = Get-ProxmoxVmCurrentStatus -Node $sourceNode -VmId $sourceId
    $rawState = if ($current.PSObject.Properties.Name -contains 'status') { [string]$current.status } else { '' }
    if ($rawState -eq 'running') {
        throw "Gold VM [$sourceId] started while publishing RAS version; refusing full clone"
    }

    $targetNode = [string]$targets[$index]
    $stamp = [string]$Context.publish_stamp
    $imageName = New-RasVersionImageName -SourceVmId $sourceId -SnapshotName ([string]$Context.snapshot_name) -Stamp $stamp -Node $targetNode

    # vNext18: allocate RASIMG IDs only from the dedicated RASIMG VMID pool
    # when split pools are configured; legacy vNext17 shared pools remain compatible.
    # Serialize only the short allocation + clone-submit section with session-host
    # provisioning; the long clone task remains parallel.
    $allocation = Invoke-WithNamedMutex -Name $script:ProvisioningMutexName -TimeoutMs 60000 -ScriptBlock {
        return Invoke-ProxmoxCloneWithVmIdRetry `
            -Node $sourceNode `
            -SourceVmId $sourceId `
            -Name $imageName `
            -Full 1 `
            -Storage ([string]$Context.storage) `
            -PoolKind 'rasimg' `
            -Purpose "RASIMG version image"
    }
    $imageId = [string]$allocation.vmid
    $cloneTaskId = [string]$allocation.task_id

    $Context.current_target_node = $targetNode
    $Context.current_image_id = [string]$imageId
    $Context.current_image_name = $imageName
    $Context.clone_task_id = $cloneTaskId
    $Context.migration_task_id = $null
    $Context.template_task_id = $null
    $Context.stage = 'image-clone'
    $script:TaskContext[$OuterTaskId] = $Context
    Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
    Write-DebugLog "RAS version task [$OuterTaskId]: full image clone VM [$imageId] for target node [$targetNode] started on source node [$sourceNode] as task [$cloneTaskId]."
    return $true
}

function Start-VersionImageMigration {
    param(
        [Parameter(Mandatory = $true)][string]$OuterTaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $imageId = [string]$Context.current_image_id
    $sourceNode = [string]$Context.source_node
    $targetNode = [string]$Context.current_target_node
    $storage = [string]$Context.storage

    $body = @{
        target             = $targetNode
        online             = 0
        'with-local-disks' = 1
        targetstorage      = $storage
    }
    $resp = Invoke-ProxmoxApi -Method POST -Path "/api2/json/nodes/$sourceNode/qemu/$imageId/migrate" -Body $body
    $migrationTaskId = [string]$resp.data
    if ([string]::IsNullOrWhiteSpace($migrationTaskId)) { throw 'No task id returned while migrating version image to target node' }

    $Context.migration_task_id = $migrationTaskId
    $Context.stage = 'image-migrate'
    $script:TaskContext[$OuterTaskId] = $Context
    Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
    Write-DebugLog "RAS version task [$OuterTaskId]: image VM [$imageId] migration [$sourceNode -> $targetNode] on storage [$storage] started as task [$migrationTaskId]."
}

function Start-VersionImageTemplateConversion {
    param(
        [Parameter(Mandatory = $true)][string]$OuterTaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $imageId = [string]$Context.current_image_id
    $imageVm = Get-ProxmoxVmNode -VmId $imageId
    $imageNode = [string]$imageVm.node
    $expectedNode = [string]$Context.current_target_node
    if ($imageNode -ne $expectedNode) {
        throw "Version image VM [$imageId] is on node [$imageNode], expected [$expectedNode]"
    }

    $resp = Invoke-ProxmoxApi -Method POST -Path "/api2/json/nodes/$imageNode/qemu/$imageId/template" -Body @{}
    $templateTaskId = [string]$resp.data
    if ([string]::IsNullOrWhiteSpace($templateTaskId)) { throw 'No task id returned while converting version image to template' }

    $Context.template_task_id = $templateTaskId
    $Context.stage = 'image-template'
    $script:TaskContext[$OuterTaskId] = $Context
    Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
    Write-DebugLog "RAS version task [$OuterTaskId]: image VM [$imageId] on node [$imageNode] template conversion started as task [$templateTaskId]."
}

function Complete-CurrentVersionImageAndContinue {
    param(
        [Parameter(Mandatory = $true)][string]$OuterTaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    if (-not $Context.ContainsKey('images') -or $null -eq $Context.images) { $Context.images = @{} }
    $node = [string]$Context.current_target_node
    $Context.images[$node] = @{
        node       = $node
        image_id   = [string]$Context.current_image_id
        image_name = [string]$Context.current_image_name
    }
    $Context.node_index = [int]$Context.node_index + 1
    $Context.current_target_node = $null
    $Context.current_image_id = $null
    $Context.current_image_name = $null
    $Context.clone_task_id = $null
    $Context.migration_task_id = $null
    $Context.template_task_id = $null

    if ([int]$Context.node_index -lt @($Context.target_nodes).Count) {
        $script:TaskContext[$OuterTaskId] = $Context
        Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
        $null = Start-NextVersionImageClone -OuterTaskId $OuterTaskId -Context $Context
        return $false
    }

    Set-VersionRecord -VmId ([string]$Context.source_id) -SnapshotName ([string]$Context.snapshot_name) -NativeSnapshot ([string]$Context.native_snapshot) -Images $Context.images
    $null = Apply-DeferredTemplateConversionIfRequested -TaskId $OuterTaskId -Context $Context
    $Context.stage = 'completed'
    $script:TaskContext[$OuterTaskId] = $Context
    Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
    Write-DebugLog "RAS version [$($Context.snapshot_name)] completed on nodes [$(@($Context.target_nodes) -join ',')]."
    return $true
}

function Get-GoldNetworkIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Config
    )

    $network = @{}
    foreach ($prop in $Config.PSObject.Properties) {
        if ([string]$prop.Name -match '^net\d+$' -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            $network[[string]$prop.Name] = [string]$prop.Value
        }
    }

    if ($network.Count -eq 0) {
        throw 'Gold VM network identity could not be captured because no net* interface is configured'
    }

    return $network
}

function Get-MacAddressFromProxmoxNetConfig {
    param([string]$NetConfig)

    if ([string]::IsNullOrWhiteSpace($NetConfig)) { return $null }
    $match = [regex]::Match($NetConfig, '^[^=,]+=([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})(?:,|$)')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.ToUpperInvariant()
}

function Restore-GoldNetworkIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][object]$Network
    )

    $networkMap = ConvertTo-HashtableRecursive -InputObject $Network
    if ($null -eq $networkMap -or $networkMap.Count -eq 0) {
        throw "Captured network identity for gold VM [$VmId] is empty"
    }

    $expectedNetwork = @{}
    foreach ($key in @($networkMap.Keys | Sort-Object)) {
        if ([string]$key -notmatch '^net\d+$') { continue }
        $value = [string]$networkMap[$key]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $expectedNetwork[[string]$key] = $value
    }

    if ($expectedNetwork.Count -eq 0) {
        throw "Captured network identity for gold VM [$VmId] contains no usable net* interfaces"
    }

    # A historical RASIMG can contain a different number of NICs than the current
    # persistent gold identity. Restore both the values and the exact net* key set:
    # write captured NICs and delete any clone-inherited interfaces that did not
    # exist on the gold VM immediately before maintenance restore.
    $currentConfig = Get-ProxmoxVmConfig -Node $Node -VmId $VmId
    $currentNetKeys = @($currentConfig.PSObject.Properties |
        Where-Object { [string]$_.Name -match '^net\d+$' } |
        ForEach-Object { [string]$_.Name } |
        Sort-Object -Unique)
    $expectedNetKeys = @($expectedNetwork.Keys | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $extraNetKeys = @($currentNetKeys | Where-Object { $expectedNetKeys -notcontains [string]$_ })

    $body = @{}
    foreach ($key in $expectedNetKeys) {
        $body[$key] = [string]$expectedNetwork[$key]
    }
    if ($extraNetKeys.Count -gt 0) {
        # Proxmox VM config update accepts a comma-separated 'delete' list.
        $body['delete'] = ($extraNetKeys -join ',')
    }

    # Proxmox clone operations generate fresh NIC MAC addresses by design. The
    # gold VM, however, is a persistent RAS identity and must keep its previous
    # network identity so DHCP reservations and RAS agent addressing stay valid.
    $null = Invoke-ProxmoxApi -Method PUT -Path "/api2/json/nodes/$Node/qemu/$VmId/config" -Body $body

    $verify = Get-ProxmoxVmConfig -Node $Node -VmId $VmId
    $actualNetKeys = @($verify.PSObject.Properties |
        Where-Object { [string]$_.Name -match '^net\d+$' } |
        ForEach-Object { [string]$_.Name } |
        Sort-Object -Unique)

    $missingNetKeys = @($expectedNetKeys | Where-Object { $actualNetKeys -notcontains [string]$_ })
    $unexpectedNetKeys = @($actualNetKeys | Where-Object { $expectedNetKeys -notcontains [string]$_ })
    if ($missingNetKeys.Count -gt 0 -or $unexpectedNetKeys.Count -gt 0) {
        throw "Gold VM [$VmId] network identity restore failed: expected interfaces [$($expectedNetKeys -join ',')], actual [$($actualNetKeys -join ',')]"
    }

    foreach ($key in $expectedNetKeys) {
        $verifyProp = $verify.PSObject.Properties[$key]
        if ($null -eq $verifyProp) {
            throw "Gold VM [$VmId] network identity restore failed: interface [$key] is missing after update"
        }

        $expectedValue = [string]$expectedNetwork[$key]
        $actualValue = [string]$verifyProp.Value
        $expectedMac = Get-MacAddressFromProxmoxNetConfig -NetConfig $expectedValue
        $actualMac = Get-MacAddressFromProxmoxNetConfig -NetConfig $actualValue

        if (-not [string]::IsNullOrWhiteSpace($expectedMac)) {
            if ([string]::IsNullOrWhiteSpace($actualMac) -or $actualMac -ne $expectedMac) {
                throw "Gold VM [$VmId] MAC restore failed for [$key]: expected [$expectedMac], actual [$actualMac]"
            }
        }
    }

    $summary = @()
    foreach ($key in $expectedNetKeys) {
        $mac = Get-MacAddressFromProxmoxNetConfig -NetConfig ([string]$expectedNetwork[$key])
        $summary += if ([string]::IsNullOrWhiteSpace($mac)) { "${key}=preserved" } else { "${key}=$mac" }
    }
    if ($extraNetKeys.Count -gt 0) {
        $summary += "removed=$($extraNetKeys -join ',')"
    }
    Write-DebugLog "Gold VM [$VmId] network identity restored on node [$Node]: $($summary -join ', ')."
}

function Start-GoldRestoreClone {
    param(
        [Parameter(Mandatory = $true)][string]$OuterTaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $goldId = [string]$Context.source_id
    $sourceNode = [string]$Context.source_node
    $imageId = [string]$Context.restore_image_id
    $imageNode = [string]$Context.restore_image_node
    $storage = [string]$Context.storage
    $goldName = [string]$Context.gold_name

    if (Test-ProxmoxVmExists -VmId $goldId) {
        $Context.stage = 'gold-restore-submit'
        $script:TaskContext[$OuterTaskId] = $Context
        Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
        return $null
    }
    if (-not (Test-ProxmoxVmExists -VmId $imageId)) {
        throw "RASIMG [$imageId] for restore no longer exists"
    }
    $imageVm = Get-ProxmoxVmNode -VmId $imageId
    if ([string]$imageVm.node -ne $imageNode -or $imageNode -ne $sourceNode) {
        throw "RASIMG [$imageId] is on node [$([string]$imageVm.node)], but gold restore requires node-local image on [$sourceNode]"
    }

    # Persist the pre-submit stage first. If the connection fails after Proxmox
    # accepted the full clone, a later tasks/get can reconcile from the presence
    # and lock state of VM 300 instead of losing the restore operation.
    $Context.stage = 'gold-restore-submit'
    if (-not $Context.ContainsKey('restore_submit_attempts')) { $Context.restore_submit_attempts = 0 }
    $script:TaskContext[$OuterTaskId] = $Context
    Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context

    try {
        $body = @{
            newid   = $goldId
            name    = $goldName
            full    = 1
            storage = $storage
        }
        $resp = Invoke-ProxmoxApi -Method POST -Path "/api2/json/nodes/$sourceNode/qemu/$imageId/clone" -Body $body
        $cloneTaskId = [string]$resp.data
        if ([string]::IsNullOrWhiteSpace($cloneTaskId)) {
            throw "No task id returned while restoring gold VM [$goldId] from RASIMG [$imageId]"
        }

        $Context.restore_submit_attempts = [int]$Context.restore_submit_attempts + 1
        $Context.restore_clone_task_id = $cloneTaskId
        $Context.last_submit_error = $null
        $Context.stage = 'gold-restore-clone'
        $script:TaskContext[$OuterTaskId] = $Context
        Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
        Write-DebugLog "RAS version restore [$OuterTaskId]: restoring gold VM [$goldId] from RASIMG [$imageId] on node [$sourceNode] as task [$cloneTaskId]."
        return $cloneTaskId
    }
    catch {
        $Context.restore_submit_attempts = [int]$Context.restore_submit_attempts + 1
        $Context.last_submit_error = [string]$_.Exception.Message
        $Context.stage = 'gold-restore-submit'
        $script:TaskContext[$OuterTaskId] = $Context
        Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
        if ([int]$Context.restore_submit_attempts -ge 3) { throw }
        Write-DebugLog "RAS version restore [$OuterTaskId]: restore clone submit not confirmed (attempt $($Context.restore_submit_attempts)/3); state retained for reconciliation. Error=[$($_.Exception.Message)]"
        return $null
    }
}

function Start-NextVersionImageDelete {
    param(
        [Parameter(Mandatory = $true)][string]$OuterTaskId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $queue = @($Context.delete_queue)
    $idx = [int]$Context.delete_index
    $storage = if ($Context.ContainsKey('storage') -and -not [string]::IsNullOrWhiteSpace([string]$Context.storage)) {
        [string]$Context.storage
    }
    else {
        Get-ConfiguredStorage
    }

    while ($idx -lt $queue.Count) {
        $item = $queue[$idx]
        $imageId = if ($item -is [System.Collections.IDictionary]) { [string]$item['image_id'] } else { [string]$item.image_id }
        if ([string]::IsNullOrWhiteSpace($imageId)) {
            $idx++
            $Context.delete_index = $idx
            continue
        }

        $initialVm = Get-ProxmoxVmNodeIfPresentStrict -VmId $imageId
        if ($null -eq $initialVm) {
            $idx++
            $Context.delete_index = $idx
            continue
        }

        # Do not advance delete_index until Proxmox accepted the destroy. If the
        # safety recheck or API submit fails, retrying must revisit the same image
        # instead of silently skipping a still-present RASIMG.
        $deleteSubmission = Invoke-WithNamedMutex -Name $script:ProvisioningMutexName -TimeoutMs 60000 -ScriptBlock {
            $vm = Get-ProxmoxVmNodeIfPresentStrict -VmId $imageId
            if ($null -eq $vm) { return @{ skipped = $true } }

            $node = [string]$vm.node
            # The initial preflight may have populated the short storage-content
            # cache. Bypass it for the final destructive check.
            Clear-ProxmoxApiCache
            $blockers = @(Get-VersionImageDeleteBlockers -DeleteQueue @(@{ node = $node; image_id = $imageId }) -Storage $storage)
            if ($blockers.Count -gt 0) {
                $depText = Format-VersionImageDeleteBlockers -Blockers $blockers
                throw "SAFETY: refusing to delete RASIMG [$imageId] on node [$node] because linked-clone dependencies still exist [$depText]"
            }

            $resp = Invoke-ProxmoxApi -Method DELETE -Path "/api2/json/nodes/$node/qemu/${imageId}?purge=1&destroy-unreferenced-disks=1"
            $deleteTaskId = [string]$resp.data
            if ([string]::IsNullOrWhiteSpace($deleteTaskId)) {
                throw "No task id returned while deleting version image [$imageId]"
            }
            return @{ skipped = $false; node = $node; task_id = $deleteTaskId }
        }

        if ($null -eq $deleteSubmission -or [bool]$deleteSubmission.skipped) {
            $idx++
            $Context.delete_index = $idx
            continue
        }

        $Context.delete_index = $idx + 1
        $deleteTaskId = [string]$deleteSubmission.task_id
        $node = [string]$deleteSubmission.node
        $Context.current_delete_task_id = $deleteTaskId
        $Context.current_delete_image_id = $imageId
        $Context.stage = 'images-delete'
        $script:TaskContext[$OuterTaskId] = $Context
        Set-VersionTaskEntry -TaskId $OuterTaskId -Entry $Context
        Write-DebugLog "RAS version delete [$OuterTaskId]: dependency guard passed; deleting image VM [$imageId] on node [$node] as task [$deleteTaskId]."
        return $true
    }

    $Context.delete_index = $idx
    $Context.current_delete_task_id = $null
    $Context.current_delete_image_id = $null
    return $false
}

function Handle-TaskInfo {
    param([object]$Params)

    if ($null -eq $Params -or [string]::IsNullOrWhiteSpace([string]$Params.id)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid task id"
    }

    try {
        $taskId = [string]$Params.id

        if (-not [string]::IsNullOrWhiteSpace([string]$script:DummyOperationTaskId) -and
            $taskId.StartsWith([string]$script:DummyOperationTaskId, [System.StringComparison]::Ordinal)) {
            Write-DebugLog "Dummy task [$taskId] requested. Returning completed state."
            return @{
                result = @{
                    state  = 'completed'
                    output = @{}
                }
            }
        }

        $tombstone = Get-TaskTombstone -TaskId $taskId
        if ($null -ne $tombstone) {
            Write-DebugLog "Task [$taskId] resolved from persistent terminal tombstone."
            return @{ result = $tombstone }
        }

        # Resolve persisted context before evaluating failure. Otherwise failed
        # clone/version tasks remain in state forever and can block retries.
        $ctx = $null
        if ($script:TaskContext.ContainsKey($taskId)) {
            $ctx = $script:TaskContext[$taskId]
            Write-DebugLog "TASK CONTEXT FOUND IN MEMORY for task [$taskId]"
        }
        else {
            $ctx = Get-CloneStateEntryByTaskId -TaskId $taskId
            if ($null -eq $ctx) {
                $ctx = Get-VersionTaskEntry -TaskId $taskId
            }
            if ($null -ne $ctx) {
                $script:TaskContext[$taskId] = $ctx
            }
        }

        if ($null -ne $ctx -and $ctx.ContainsKey('type') -and [string]$ctx.type -eq 'version_revert') {
            return Handle-VersionRevertTaskInfo -TaskId $taskId -Context $ctx
        }
        if ($null -ne $ctx -and $ctx.ContainsKey('type') -and [string]$ctx.type -eq 'version_delete') {
            return Handle-VersionDeleteTaskInfo -TaskId $taskId -Context $ctx
        }
        if ($null -ne $ctx -and $ctx.ContainsKey('type') -and [string]$ctx.type -eq 'version_create') {
            return Handle-VersionCreateTaskInfo -TaskId $taskId -Context $ctx
        }

        $taskStatus = $null
        $taskResult = $null
        try {
            $taskStatus = Get-ProxmoxTaskStatus -TaskId $taskId
            $taskResult = New-TaskResultState -TaskStatus $taskStatus
        }
        catch {
            if ($null -ne $ctx -and $ctx.ContainsKey('type') -and [string]$ctx.type -eq 'clone') {
                # Proxmox can age a completed task out of its task history while
                # RAS still polls it after a provider/service restart. The clone
                # context and target VM are authoritative enough to continue the
                # readiness check; a missing target will still fail/timeout below.
                Write-DebugLog "Clone task [$taskId] status is unavailable; reconciling from persisted clone VM [$([string]$ctx.clone_id)]. Error=[$($_.Exception.Message)]"
                $taskResult = @{ state = 'completed' }
            }
            else {
                throw
            }
        }

        if ($taskResult.state -eq 'failed') {
            $failureMessage = if ($null -ne $taskResult.error -and $taskResult.error.ContainsKey('message')) {
                [string]$taskResult.error.message
            }
            else {
                'Unknown task failure'
            }

            Clear-TrackedTaskAfterFailure -TaskId $taskId -Context $ctx -Message $failureMessage

            return @{
                result = @{
                    state = 'failed'
                    error = $taskResult.error
                }
            }
        }

        if ($taskResult.state -eq 'running') {
            return @{ result = @{ state = 'running' } }
        }



        if ($null -ne $ctx -and $ctx.ContainsKey('type') -and [string]$ctx.type -eq 'clone') {
            $cloneId = [string]$ctx.clone_id

            $cloneTimeout = [int](Get-ProviderConfig).clone_ready_timeout_seconds
            $cloneStarted = [DateTime]::MinValue
            if ($ctx.ContainsKey('started_utc')) { [DateTime]::TryParse([string]$ctx.started_utc, [ref]$cloneStarted) | Out-Null }
            if ($cloneStarted -ne [DateTime]::MinValue -and [DateTime]::UtcNow -gt $cloneStarted.AddSeconds($cloneTimeout)) {
                $timeoutMessage = "Clone VM [$cloneId] did not become powered on with an IPv4 address within [$cloneTimeout] seconds"
                Clear-TrackedTaskAfterFailure -TaskId $taskId -Context $ctx -Message $timeoutMessage
                return @{ result = @{ state = 'failed'; error = @{ code = 1; message = $timeoutMessage } } }
            }

            if ([string]::IsNullOrWhiteSpace($cloneId)) {
                Write-DebugLog "Clone task [$taskId] has no clone_id. Completing without output."
                $terminalResult = @{ state = 'completed'; output = @{} }
                Set-TaskTombstone -TaskId $taskId -Result $terminalResult -Context $ctx
                if ($script:TaskContext.ContainsKey($taskId)) { [void]$script:TaskContext.Remove($taskId) }
                return @{ result = $terminalResult }
            }

            $guest = ConvertTo-RasGuestObject -VmId $cloneId

            if ($guest.state -eq 'powered_off' -or $guest.state -eq 'powering_off') {
                $startInfo = Start-ProxmoxVmIfNeeded -VmId $cloneId

                if (-not $ctx.ContainsKey('start_retry_count')) {
                    $ctx.start_retry_count = 0
                }

                $ctx.start_retry_count = [int]$ctx.start_retry_count + 1
                $ctx.clone_node = $startInfo.node

                if ($startInfo.started) {
                    $ctx.start_issued = $true
                    $ctx.start_pending = $false
                    $ctx.start_task_id = $startInfo.task_id
                    Write-DebugLog "Clone task [$taskId]: start issued successfully for clone VM [$cloneId]."
                }
                elseif ($startInfo.pending) {
                    $ctx.start_pending = $true
                    Write-DebugLog "Clone task [$taskId]: start deferred for clone VM [$cloneId] because lock is still held."
                }

                $script:TaskContext[$taskId] = $ctx
                Set-CloneStateEntry -VmId $cloneId -Entry $ctx
                return @{ result = @{ state = 'running' } }
            }

            if ($guest.state -eq 'powering_on') {
                Write-DebugLog "Clone task [$taskId]: VM [$cloneId] is powering on. Waiting."
                return @{ result = @{ state = 'running' } }
            }

            if ($guest.state -ne 'powered_on') {
                Write-DebugLog "Clone task [$taskId]: VM [$cloneId] state is [$($guest.state)]. Waiting."
                return @{ result = @{ state = 'running' } }
            }

            if ($null -eq $guest.ip_addresses -or @($guest.ip_addresses).Count -eq 0) {
                Write-DebugLog "Clone task [$taskId]: VM [$cloneId] is powered on but has no IP yet. Waiting."
                return @{ result = @{ state = 'running' } }
            }

            $ctx.creation_completed = $true
            $terminalResult = @{ state = 'completed'; output = @{ clone_id = $cloneId } }
            Set-TaskTombstone -TaskId $taskId -Result $terminalResult -Context $ctx
            if ($script:TaskContext.ContainsKey($taskId)) { [void]$script:TaskContext.Remove($taskId) }
            Remove-CloneStateEntry -VmId $cloneId

            Write-DebugLog "Clone task [$taskId]: VM [$cloneId] is powered on and has IP [$($guest.ip_addresses -join ',')]. Completing task."
            Write-DebugLog "Clone task [$taskId]: terminal result persisted and tracking removed for clone VM [$cloneId]."
            return @{ result = $terminalResult }
        }

        return @{
            result = @{
                state  = 'completed'
                output = @{}
            }
        }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to retrieve task info: $($_.Exception.Message)"
    }
}

function Handle-GuestConvert {
    param([object]$Params)

    if ($null -eq $Params -or [string]::IsNullOrWhiteSpace([string]$Params.id)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid guest id"
    }
    if ($null -eq $Params.is_template) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Missing is_template flag"
    }

    try {
        $vmId = [string]$Params.id
        $isTemplate = [bool]$Params.is_template

        # RAS maintenance is logical only: the gold VM itself must always remain
        # a normal Proxmox VM with vm-<id>-disk-* volumes. Validate that the
        # provider object still exists, but do not take ownership of its power state.
        $null = Get-ProxmoxVmNode -VmId $vmId

        if (-not $isTemplate) {
            Set-LogicalTemplateState -VmId $vmId -IsTemplate $false
            $taskId = "{0}:convert:{1}:{2}" -f $script:DummyOperationTaskId, $vmId, ([Guid]::NewGuid().ToString('N'))
            Write-DebugLog "RAS maintenance entered for VM [$vmId]. Logical template state=False; physical Proxmox VM remains normal."
            return @{ result = @{ task_id = $taskId } }
        }

        # With CPF template_method=versioning, RAS creates the actual template
        # version explicitly through guests/snapshots/create (for example
        # RAS_TEMPLATE_VERSION_1, _2, ...).  guests/convert(is_template=true)
        # only closes maintenance / marks the gold VM as a logical RAS template.
        # It MUST NOT publish an additional generic "RAS Template Snapshot"
        # image, otherwise every version creation produces a duplicate RASIMG.
        #
        # Parallels RAS owns the gold VM power state. During "leave maintenance"
        # it may start the VM again to validate the RAS Guest Agent/client before
        # it sends this convert-to-template request. Because this operation only
        # changes provider metadata and does not capture or modify disks, both a
        # running and a stopped gold VM are valid here. The powered-off boundary
        # remains exclusively in guests/snapshots/create, where immutable RASIMG
        # backing is actually created.

        # If RAS explicitly calls convert=true while a version publish is still
        # running, attach that request to the persistent task. Snapshot creation
        # alone never changes the logical template state; only this explicit
        # request may do so after the publish has completed.
        $activePublish = Get-ActiveVersionCreateTaskForVm -VmId $vmId
        if ($null -ne $activePublish) {
            $existingTaskId = [string]$activePublish.task_id
            $existingEntry = $activePublish.entry
            $existingEntry.convert_to_template_requested = $true
            $script:TaskContext[$existingTaskId] = $existingEntry
            Set-VersionTaskEntry -TaskId $existingTaskId -Entry $existingEntry
            Write-DebugLog "RAS convert-to-template for VM [$vmId] explicitly requested while version publish is active; deferred on task [$existingTaskId], logical=[$([string]$existingEntry.snapshot_name)], stage=[$([string]$existingEntry.stage)]."
            return @{ result = @{ task_id = $existingTaskId } }
        }

        # A versioned RAS template must already have a completed RAS version at
        # this point. Do not invent a second provider-side version here.
        $currentVersion = Get-CurrentVersionName -VmId $vmId
        if ([string]::IsNullOrWhiteSpace([string]$currentVersion)) {
            return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) No completed RAS template version exists for VM [$vmId] while leaving maintenance"
        }

        $currentRecord = Get-VersionRecord -VmId $vmId -SnapshotName ([string]$currentVersion)
        if ($null -eq $currentRecord) {
            return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Current RAS template version [$currentVersion] for VM [$vmId] has no version record"
        }

        Set-LogicalTemplateState -VmId $vmId -IsTemplate $true
        $taskId = "{0}:convert:{1}:{2}" -f $script:DummyOperationTaskId, $vmId, ([Guid]::NewGuid().ToString('N'))
        Write-DebugLog "RAS maintenance/template conversion completed for VM [$vmId]. Current version=[$currentVersion]; RAS retains power control; no additional Proxmox snapshot/image created."
        return @{ result = @{ task_id = $taskId } }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to convert/publish guest [$($Params.id)]: $($_.Exception.Message)"
    }
}

function ConvertTo-ProxmoxSnapshotName {
    param([string]$Name)

    $value = if ([string]::IsNullOrWhiteSpace($Name)) {
        'ras-template-snapshot'
    }
    else {
        $Name.Trim().ToLowerInvariant()
    }

    # Proxmox-kompatibler Name ohne Leer- und Sonderzeichen
    $value = [regex]::Replace(
        $value,
        '[^a-z0-9_-]+',
        '-'
    )

    $value = $value.Trim([char[]]'_-')

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = 'ras-template-snapshot'
    }

    if ($value.Length -gt 40) {
        $value = $value.Substring(0, 40).TrimEnd([char[]]'_-')
    }

    return $value
}

function New-RasVersionImageName {
    param(
        [Parameter(Mandatory = $true)][string]$SourceVmId,
        [Parameter(Mandatory = $true)][string]$SnapshotName,
        [Parameter(Mandatory = $true)][string]$Stamp,
        [Parameter(Mandatory = $true)][string]$Node
    )

    $versionToken = $null
    if ($SnapshotName -match '(?i)RAS[_ -]*TEMPLATE[_ -]*VERSION[_ -]*(\d+)$') {
        $versionToken = "V$($Matches[1])"
    }
    else {
        $versionToken = ConvertTo-ProxmoxSnapshotName -Name $SnapshotName
        if ($versionToken.Length -gt 18) { $versionToken = $versionToken.Substring(0,18).TrimEnd('-') }
    }
    $safeNode = [regex]::Replace($Node.ToLowerInvariant(), '[^a-z0-9_-]+', '-')
    $name = "RASIMG-$SourceVmId-$versionToken-$Stamp-$safeNode"
    if ($name.Length -gt 60) { $name = $name.Substring(0,60).TrimEnd('-') }
    return $name
}

function Handle-GuestSnapshotCreate {
    param([object]$Params)

    if ($null -eq $Params -or [string]::IsNullOrWhiteSpace([string]$Params.id)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid guest id"
    }
    if (-not ($Params.PSObject.Properties.Name -contains 'name') -or [string]::IsNullOrWhiteSpace([string]$Params.name)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid snapshot/version name"
    }

    $vmId = [string]$Params.id
    $requestedName = [string]$Params.name
    try { Assert-ConfiguredGoldVmId -VmId $vmId }
    catch { return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) $($_.Exception.Message)" }
    $publishMutexName = "Global\ParallelsRASProxmoxCPF-Version-$vmId"

    try {
        return Invoke-WithNamedMutex -Name $publishMutexName -TimeoutMs 30000 -ScriptBlock {
            $existing = Get-VersionRecord -VmId $vmId -SnapshotName $requestedName
            if ($null -ne $existing) {
                $complete = Test-VersionRecordBackingComplete -SourceVmId $vmId -Record $existing
                if (-not $complete) {
                    return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) RAS version [$requestedName] exists in provider state but its Proxmox backing is incomplete"
                }
                $dummy = "{0}:version-exists:{1}:{2}" -f $script:DummyOperationTaskId, $vmId, ([Guid]::NewGuid().ToString('N'))
                Write-DebugLog "RAS version [$requestedName] for VM [$vmId] already exists with complete backing; returning completed dummy task."
                return @{ result = @{ task_id = $dummy } }
            }

            $activePublish = Get-ActiveVersionCreateTaskForVm -VmId $vmId
            if ($null -ne $activePublish) {
                $existingTaskId = [string]$activePublish.task_id
                $existingEntry = $activePublish.entry
                $activeName = if ($existingEntry.ContainsKey('snapshot_name')) { [string]$existingEntry.snapshot_name } else { '' }
                if ([string]$activeName -eq [string]$requestedName) {
                    Write-DebugLog "RAS version create retry for VM [$vmId], version [$requestedName]; reusing active task [$existingTaskId], stage=[$([string]$existingEntry.stage)]."
                    return @{ result = @{ task_id = $existingTaskId } }
                }
                return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Another RAS template version [$activeName] is still being published for VM [$vmId]"
            }

            $clusterVm = Get-ProxmoxVmNode -VmId $vmId
            $sourceNode = [string]$clusterVm.node
            $current = Get-ProxmoxVmCurrentStatus -Node $sourceNode -VmId $vmId
            $rawState = if ($current.PSObject.Properties.Name -contains 'status') { [string]$current.status } else { '' }
            if ($rawState -eq 'running') {
                return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Gold VM [$vmId] must be powered off before creating a RAS template version"
            }

            $targetNodes = @(Get-EnabledComputeNodes -AllowEmpty)
            if ($targetNodes.Count -eq 0) {
                if (Test-Path -LiteralPath $script:ProviderConfigPath) {
                    return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) No enabled compute_nodes are configured in [$($script:ProviderConfigPath)]"
                }
                # Compatibility mode if no CFG exists yet: behave exactly like vNext8.
                $targetNodes = @($sourceNode)
            }
            $storage = Get-ConfiguredStorage
            $nodesToCheck = @($targetNodes) + @($sourceNode)
            $nodesToCheck = @($nodesToCheck | Select-Object -Unique)
            Assert-ComputeNodesReady -Nodes $nodesToCheck -Storage $storage

            # vNext10: each version is backed exclusively by immutable RASIMG
            # full clones. Always keep one restore image on the gold node, even
            # if that node is temporarily disabled for new session-host placement.
            $publishNodes = @($targetNodes)
            if ($publishNodes -notcontains $sourceNode) {
                $publishNodes = @($sourceNode) + $publishNodes
                Write-DebugLog "Gold node [$sourceNode] is not enabled for placement; adding it as an internal RASIMG restore target for version [$requestedName]."
            }
            $publishNodes = @($publishNodes | Select-Object -Unique)
            Assert-RasImgVmIdPoolCapacity -NodeCount $publishNodes.Count

            $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
            $ctx = @{
                type                  = 'version_create'
                stage                 = 'prepare-images'
                source_id             = $vmId
                source_node           = $sourceNode
                snapshot_name         = $requestedName
                native_snapshot       = ''
                storage               = $storage
                publish_stamp         = $stamp
                target_nodes          = @($publishNodes)
                node_index            = 0
                images                = @{}
                current_target_node   = $null
                current_image_id      = $null
                current_image_name    = $null
                clone_task_id         = $null
                migration_task_id     = $null
                template_task_id      = $null
                convert_to_template_requested = $false
                started_utc           = [DateTime]::UtcNow.ToString('o')
            }

            # The first full-clone UPID becomes the stable outer task returned
            # to RAS. No native gold snapshot is created anymore.
            $placeholder = "PENDING-$([Guid]::NewGuid().ToString('N'))"
            $started = Start-NextVersionImageClone -OuterTaskId $placeholder -Context $ctx
            if (-not $started) { throw 'Version publish has no target compute nodes' }
            $taskId = [string]$ctx.clone_task_id
            Remove-VersionTaskEntry -TaskId $placeholder
            if ($script:TaskContext.ContainsKey($placeholder)) { [void]$script:TaskContext.Remove($placeholder) }
            $script:TaskContext[$taskId] = $ctx
            Set-VersionTaskEntry -TaskId $taskId -Entry $ctx

            Write-DebugLog "Creating RAS version [$requestedName] for VM [$vmId] from RASIMG only: target nodes [$($publishNodes -join ',')], storage [$storage], first task [$taskId]."
            return @{ result = @{ task_id = $taskId } }
        }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to create RAS version [$requestedName] for guest [$vmId]: $($_.Exception.Message)"
    }
}

function Handle-GuestSnapshotsExists {
    param([object]$Params)

    if ($null -eq $Params -or [string]::IsNullOrWhiteSpace([string]$Params.id) -or
        -not ($Params.PSObject.Properties.Name -contains 'name') -or [string]::IsNullOrWhiteSpace([string]$Params.name)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid snapshot/version parameters"
    }

    try {
        $vmId = [string]$Params.id
        $requestedName = [string]$Params.name
        $record = Get-VersionRecord -VmId $vmId -SnapshotName $requestedName
        if ($null -eq $record) { return @{ result = $false } }
        return @{ result = [bool](Test-VersionRecordBackingComplete -SourceVmId $vmId -Record $record) }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to check RAS version [$($Params.name)] for guest [$($Params.id)]: $($_.Exception.Message)"
    }
}

function New-RasVersionRestoreRejectedResponse {
    param(
        [Parameter(Mandatory = $true)][string]$VmId,
        [Parameter(Mandatory = $true)][int]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )
    try {
        Set-LogicalTemplateState -VmId $VmId -IsTemplate $true
        Write-DebugLog "RAS version restore for VM [$VmId] rejected before destructive work; logical template state restored to True. Reason=[$Message]"
    }
    catch {
        Write-DebugLog "Failed to restore logical template state for VM [$VmId] after rejected version restore: $($_.Exception.Message)"
    }
    return New-ErrorResponse -Code $Code -Message $Message
}

function Handle-GuestSnapshotsRevert {
    param([object]$Params)

    if ($null -eq $Params -or [string]::IsNullOrWhiteSpace([string]$Params.id) -or
        -not ($Params.PSObject.Properties.Name -contains 'name') -or [string]::IsNullOrWhiteSpace([string]$Params.name)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid snapshot/version parameters"
    }

    $vmId = [string]$Params.id
    $requestedName = [string]$Params.name
    $restoreMutexName = "Global\ParallelsRASProxmoxCPF-Restore-$vmId"

    try {
        return Invoke-WithNamedMutex -Name $restoreMutexName -TimeoutMs 30000 -ScriptBlock {
            $activeRestore = Get-ActiveVersionRevertForVm -VmId $vmId
            if ($null -ne $activeRestore) {
                $activeName = if ($activeRestore.entry.ContainsKey('snapshot_name')) { [string]$activeRestore.entry.snapshot_name } else { '' }
                if ($activeName -eq $requestedName) {
                    Write-DebugLog "RAS version restore retry for VM [$vmId], version [$requestedName]; reusing persistent task [$($activeRestore.task_id)], stage=[$([string]$activeRestore.entry.stage)]."
                    return @{ result = @{ task_id = [string]$activeRestore.task_id } }
                }
                return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Another RAS version restore [$activeName] is already active for VM [$vmId]"
            }

            $record = Get-VersionRecord -VmId $vmId -SnapshotName $requestedName
            if ($null -eq $record) {
                return New-RasVersionRestoreRejectedResponse -VmId $vmId -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) RAS version [$requestedName] does not exist for VM [$vmId]"
            }
            if (-not (Test-VersionRecordBackingComplete -SourceVmId $vmId -Record $record)) {
                return New-RasVersionRestoreRejectedResponse -VmId $vmId -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) RAS version [$requestedName] has incomplete RASIMG backing"
            }

            $clusterVm = Get-ProxmoxVmNode -VmId $vmId
            $sourceNode = [string]$clusterVm.node
            $current = Get-ProxmoxVmCurrentStatus -Node $sourceNode -VmId $vmId
            $rawState = if ($current.PSObject.Properties.Name -contains 'status') { [string]$current.status } else { '' }
            if ($rawState -eq 'running') {
                return New-RasVersionRestoreRejectedResponse -VmId $vmId -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Gold VM [$vmId] must be powered off before restoring RAS version [$requestedName]"
            }

            $goldConfig = Get-ProxmoxVmConfig -Node $sourceNode -VmId $vmId
            $goldName = if ($goldConfig.PSObject.Properties.Name -contains 'name' -and -not [string]::IsNullOrWhiteSpace([string]$goldConfig.name)) { [string]$goldConfig.name } else { "VM $vmId" }
            $goldNetwork = Get-GoldNetworkIdentity -Config $goldConfig

            $images = Get-VersionImageMap -Record $record
            if (-not $images.ContainsKey($sourceNode)) {
                return New-RasVersionRestoreRejectedResponse -VmId $vmId -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) RAS version [$requestedName] has no node-local restore image on gold node [$sourceNode]"
            }
            $restoreImage = $images[$sourceNode]
            $restoreImageId = [string]$restoreImage.image_id
            if ([string]::IsNullOrWhiteSpace($restoreImageId) -or -not (Test-ProxmoxVmExists -VmId $restoreImageId)) {
                return New-RasVersionRestoreRejectedResponse -VmId $vmId -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Restore RASIMG for version [$requestedName] on node [$sourceNode] is missing"
            }

            $storage = Get-ConfiguredStorage
            Assert-ComputeNodesReady -Nodes @($sourceNode) -Storage $storage

            $outerTaskId = "RESTORE-INTENT:${vmId}:$([Guid]::NewGuid().ToString('N'))"
            $ctx = @{
                type                    = 'version_revert'
                stage                   = 'restore-intent'
                source_id               = $vmId
                source_node             = $sourceNode
                snapshot_name           = $requestedName
                restore_image_id        = $restoreImageId
                restore_image_node      = $sourceNode
                storage                 = $storage
                gold_name               = $goldName
                gold_network            = $goldNetwork
                gold_delete_task_id     = $null
                restore_clone_task_id   = $null
                delete_submit_attempts  = 0
                restore_submit_attempts = 0
                last_submit_error       = $null
                started_utc             = [DateTime]::UtcNow.ToString('o')
            }

            # The stable provider-side task id is persisted before deleting gold.
            # RAS can therefore keep polling the same id across provider restarts.
            $script:TaskContext[$outerTaskId] = $ctx
            Set-VersionTaskEntry -TaskId $outerTaskId -Entry $ctx

            try {
                $submit = Start-GoldDeleteForRestore -OuterTaskId $outerTaskId -Context $ctx
                if ([bool]$submit.already_absent) { $null = Start-GoldRestoreClone -OuterTaskId $outerTaskId -Context $ctx }
            }
            catch {
                $message = [string]$_.Exception.Message
                Clear-TrackedTaskAfterFailure -TaskId $outerTaskId -Context $ctx -Message $message
                try { Set-LogicalTemplateState -VmId $vmId -IsTemplate $true } catch {}
                return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to begin RAS version restore [$requestedName] for guest [$vmId]: $message"
            }

            Write-DebugLog "RAS version restore [$outerTaskId]: persistent workflow created for gold VM [$vmId], version [$requestedName], RASIMG [$restoreImageId]."
            return @{ result = @{ task_id = $outerTaskId } }
        }
    }
    catch {
        try { Set-LogicalTemplateState -VmId $vmId -IsTemplate $true } catch {}
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to restore RAS version [$requestedName] for guest [$vmId]: $($_.Exception.Message)"
    }
}

function Handle-GuestSnapshotsDelete {
    param([object]$Params)

    if ($null -eq $Params -or [string]::IsNullOrWhiteSpace([string]$Params.id) -or
        -not ($Params.PSObject.Properties.Name -contains 'name') -or [string]::IsNullOrWhiteSpace([string]$Params.name)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid snapshot/version parameters"
    }

    $intentTaskId = $null
    $deleteSubmissionAttempted = $false
    try {
        $vmId = [string]$Params.id
        $requestedName = [string]$Params.name

        $activeDelete = Get-ActiveVersionDeleteTaskForVersion -VmId $vmId -SnapshotName $requestedName
        if ($null -ne $activeDelete) {
            $activeStage = if ($activeDelete.entry.ContainsKey('stage')) { [string]$activeDelete.entry.stage } else { '' }
            Write-DebugLog "RAS version delete retry for VM [$vmId], version [$requestedName]; reusing persistent task [$($activeDelete.task_id)], stage=[$activeStage]."
            return @{ result = @{ task_id = [string]$activeDelete.task_id } }
        }

        $record = Get-VersionRecord -VmId $vmId -SnapshotName $requestedName
        if ($null -eq $record) {
            $activePublish = Get-ActiveVersionCreateTaskForVm -VmId $vmId
            if ($null -ne $activePublish -and $activePublish.entry.ContainsKey('snapshot_name') -and [string]$activePublish.entry.snapshot_name -eq $requestedName) {
                return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) RAS version [$requestedName] is still being published and cannot be deleted yet"
            }
            $dummy = "{0}:version-missing:{1}:{2}" -f $script:DummyOperationTaskId, $vmId, ([Guid]::NewGuid().ToString('N'))
            return @{ result = @{ task_id = $dummy } }
        }

        $clusterVm = Get-ProxmoxVmNode -VmId $vmId
        $sourceNode = [string]$clusterVm.node
        $nativeName = [string]$record.native_snapshot
        $images = Get-VersionImageMap -Record $record
        $queue = @()
        foreach ($node in $images.Keys) {
            $img = $images[$node]
            $queue += ,@{ node = [string]$node; image_id = [string]$img.image_id; image_name = [string]$img.image_name }
        }
        $storage = Get-ConfiguredStorage

        # Persist intent before any preflight. Clone submission rechecks this
        # intent while holding the same provisioning mutex used by final delete.
        $intentTaskId = "DELETE-INTENT:${vmId}:$([Guid]::NewGuid().ToString('N'))"
        $ctx = @{
            type                    = 'version_delete'
            stage                   = 'delete-intent'
            source_id               = $vmId
            source_node             = $sourceNode
            snapshot_name           = $requestedName
            native_snapshot         = $nativeName
            storage                 = $storage
            delete_queue            = @($queue)
            delete_index            = 0
            current_delete_task_id  = $null
            current_delete_image_id = $null
            native_delete_task_id   = $null
            started_utc             = [DateTime]::UtcNow.ToString('o')
        }
        $script:TaskContext[$intentTaskId] = $ctx
        Set-VersionTaskEntry -TaskId $intentTaskId -Entry $ctx

        $blockers = @(Get-VersionImageDeleteBlockers -DeleteQueue $queue -Storage $storage)
        if ($blockers.Count -gt 0) {
            $details = Format-VersionImageDeleteBlockers -Blockers $blockers
            Remove-VersionTaskEntry -TaskId $intentTaskId
            [void]$script:TaskContext.Remove($intentTaskId)
            $intentTaskId = $null
            Write-DebugLog "SAFETY BLOCK: RAS version [$requestedName] for VM [$vmId] not deleted because linked clones still depend on its RASIMG(s): $details"
            return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) RAS version [$requestedName] cannot be deleted because linked clones still depend on its RASIMG(s): $details. Recreate or remove those hosts first."
        }

        $ctx.stage = 'images-delete'
        $script:TaskContext[$intentTaskId] = $ctx
        Set-VersionTaskEntry -TaskId $intentTaskId -Entry $ctx
        $deleteSubmissionAttempted = $true
        $started = Start-NextVersionImageDelete -OuterTaskId $intentTaskId -Context $ctx
        if ($started) {
            # Keep the stable synthetic outer task ID for the complete multi-step
            # delete workflow. Re-keying to the first Proxmox UPID created a tiny
            # crash window between removing and re-adding persistent state.
            return @{ result = @{ task_id = $intentTaskId } }
        }

        $native = if (-not [string]::IsNullOrWhiteSpace($nativeName)) { Find-ProxmoxVmSnapshot -Node $sourceNode -VmId $vmId -SnapshotName $nativeName } else { $null }
        if ($null -ne $native) {
            $taskId = Delete-ProxmoxVmSnapshot -Node $sourceNode -VmId $vmId -SnapshotName $nativeName
            $ctx.stage = 'native-delete'
            $ctx.native_delete_task_id = $taskId
            $script:TaskContext[$intentTaskId] = $ctx
            Set-VersionTaskEntry -TaskId $intentTaskId -Entry $ctx
            return @{ result = @{ task_id = $intentTaskId } }
        }

        Remove-VersionRecord -VmId $vmId -SnapshotName $requestedName
        Remove-VersionTaskEntry -TaskId $intentTaskId
        [void]$script:TaskContext.Remove($intentTaskId)
        $dummy = "{0}:version-deleted:{1}:{2}" -f $script:DummyOperationTaskId, $vmId, ([Guid]::NewGuid().ToString('N'))
        return @{ result = @{ task_id = $dummy } }
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($intentTaskId) -and -not $deleteSubmissionAttempted) {
            try { Remove-VersionTaskEntry -TaskId $intentTaskId } catch {}
            if ($script:TaskContext.ContainsKey($intentTaskId)) { [void]$script:TaskContext.Remove($intentTaskId) }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($intentTaskId)) {
            Write-DebugLog "DELETE INTENT RETAINED: version delete [$intentTaskId] may have submitted destructive work and requires retry/reconciliation. Error=[$($_.Exception.Message)]"
        }
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to delete RAS version [$($Params.name)] for guest [$($Params.id)]: $($_.Exception.Message)"
    }
}

function Handle-GuestClone {
    param([object]$Params)

    if ($null -eq $Params -or [string]::IsNullOrWhiteSpace([string]$Params.id)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid source guest id"
    }
    if (-not ($Params.PSObject.Properties.Name -contains 'name') -or [string]::IsNullOrWhiteSpace([string]$Params.name)) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) Invalid clone name"
    }

    try {
        $sourceVmId = [string]$Params.id
        Assert-ConfiguredGoldVmId -VmId $sourceVmId
        $cloneName = [string]$Params.name
        $snapshotName = $null
        if ($Params.PSObject.Properties.Name -contains 'snapshot' -and -not [string]::IsNullOrWhiteSpace([string]$Params.snapshot)) {
            $snapshotName = [string]$Params.snapshot
        }
        if ([string]::IsNullOrWhiteSpace($snapshotName)) { $snapshotName = Get-CurrentVersionName -VmId $sourceVmId }
        if ([string]::IsNullOrWhiteSpace($snapshotName)) {
            return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) No RAS template version is selected for source VM [$sourceVmId]"
        }

        $record = Get-VersionRecord -VmId $sourceVmId -SnapshotName $snapshotName
        if ($null -eq $record -and [string]$snapshotName -eq 'RAS Template Snapshot') {
            $currentVersion = Get-CurrentVersionName -VmId $sourceVmId
            if (-not [string]::IsNullOrWhiteSpace([string]$currentVersion)) {
                $currentRecord = Get-VersionRecord -VmId $sourceVmId -SnapshotName ([string]$currentVersion)
                if ($null -ne $currentRecord) {
                    Write-DebugLog "Clone request used default RAS snapshot name; resolving to current version [$currentVersion] for source VM [$sourceVmId]."
                    $snapshotName = [string]$currentVersion
                    $record = $currentRecord
                }
            }
        }
        if ($null -eq $record) {
            return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) RAS template version [$snapshotName] not found for source VM [$sourceVmId]"
        }

        # Once a version delete has started, never accept a new linked clone from
        # that version. This keeps a multi-node delete from becoming partially
        # complete if RAS races a deployment against version removal.
        $activeVersionDelete = Get-ActiveVersionDeleteTaskForVersion -VmId $sourceVmId -SnapshotName $snapshotName
        if ($null -ne $activeVersionDelete) {
            Write-DebugLog "SAFETY BLOCK: clone [$cloneName] rejected because RAS version [$snapshotName] for VM [$sourceVmId] is being deleted by task [$($activeVersionDelete.task_id)]."
            return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) RAS template version [$snapshotName] is being deleted and cannot be used for a new clone"
        }

        $images = Get-VersionImageMap -Record $record
        if ($images.Count -eq 0) {
            return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) RAS template version [$snapshotName] has no usable version images"
        }

        $configuredNodes = @(Get-EnabledComputeNodes -AllowEmpty)
        $candidates = @()
        if ($configuredNodes.Count -gt 0) {
            foreach ($node in $configuredNodes) {
                if ($images.ContainsKey([string]$node)) { $candidates += [string]$node }
            }
        }
        elseif (Test-Path -LiteralPath $script:ProviderConfigPath) {
            return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message "$($script:ProviderNamePrefix) No enabled compute_nodes are configured in [$($script:ProviderConfigPath)]"
        }
        else {
            # No CFG at all: legacy/single-node compatibility with existing vNext8 state.
            $candidates = @($images.Keys | Sort-Object)
        }
        if ($candidates.Count -eq 0) {
            return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) RAS template version [$snapshotName] has no image on any enabled compute node"
        }

        # vNext18: the provisioning mutex covers placement, Session-Host VMID allocation
        # and clone submission only. The actual clone/boot/agent wait remains parallel.
        $provisioned = Invoke-WithNamedMutex -Name $script:ProvisioningMutexName -TimeoutMs 60000 -ScriptBlock {
            $deleteInsideMutex = Get-ActiveVersionDeleteTaskForVersion -VmId $sourceVmId -SnapshotName $snapshotName
            if ($null -ne $deleteInsideMutex) {
                throw "RAS template version [$snapshotName] entered delete state before clone submission"
            }

            $storageForHealth = Get-ConfiguredStorage
            $health = Get-HealthyComputeNodes -CandidateNodes $candidates -Storage $storageForHealth
            $healthyCandidates = @($health.healthy)
            if ($healthyCandidates.Count -eq 0) {
                $healthDetails = @($health.unhealthy.Keys | ForEach-Object { "$_=$([string]$health.unhealthy[$_])" }) -join '; '
                throw "No healthy compute node with storage [$storageForHealth] is available: $healthDetails"
            }
            $selection = Get-NextComputeNodeSelection -CandidateNodes $healthyCandidates -SourceVmId $sourceVmId
            $selectedNode = [string]$selection.node
            $selectedImage = $images[$selectedNode]
            $selectedImageVmId = [string]$selectedImage.image_id

            if (-not (Test-ProxmoxVmExists -VmId $selectedImageVmId)) {
                throw "$($script:ProviderNamePrefix) Version image VM [$selectedImageVmId] for [$snapshotName] on node [$selectedNode] is missing"
            }
            $actual = Get-ProxmoxVmNode -VmId $selectedImageVmId
            if ([string]$actual.node -ne [string]$selectedNode) {
                throw "$($script:ProviderNamePrefix) Version image VM [$selectedImageVmId] is on node [$($actual.node)] but state expects [$selectedNode]"
            }

            $allocation = Invoke-ProxmoxCloneWithVmIdRetry `
                -Node $selectedNode `
                -SourceVmId $selectedImageVmId `
                -Name $cloneName `
                -Full 0 `
                -PoolKind 'session' `
                -Purpose "RAS session-host linked clone"

            $acceptedVmId = [string]$allocation.vmid
            $acceptedTaskId = [string]$allocation.task_id

            # Commit only after the clone POST has returned a real Proxmox task ID.
            # A failed clone attempt therefore does not consume a placement sequence.
            [void](Commit-ComputeNodeSelection -Selection $selection -CloneVmId $acceptedVmId)

            $acceptedCtx = @{
                type               = 'clone'
                source_id          = $sourceVmId
                image_source_id    = $selectedImageVmId
                snapshot_name      = $snapshotName
                clone_id           = $acceptedVmId
                name               = $cloneName
                full               = $false
                clone_node         = $selectedNode
                start_issued       = $false
                start_task_id      = $null
                start_pending      = $false
                start_retry_count  = 0
                creation_completed = $false
                started_utc        = [DateTime]::UtcNow.ToString('o')
            }

            # Persist the accepted clone while the provisioning mutex is still held.
            # least_loaded therefore sees the reservation before the VM necessarily
            # appears in cluster/resources. A persistence failure must not turn an
            # already-accepted clone into a failed RAS request (duplicate risk).
            $cloneStatePersisted = $false
            for ($persistAttempt = 1; $persistAttempt -le 3; $persistAttempt++) {
                try {
                    Set-CloneStateEntry -VmId $acceptedVmId -Entry ($acceptedCtx + @{ task_id = $acceptedTaskId })
                    $cloneStatePersisted = $true
                    break
                }
                catch {
                    if ($persistAttempt -lt 3) { Start-Sleep -Milliseconds (50 * $persistAttempt); continue }
                    Write-DebugLog "CRITICAL: Accepted clone VM [$acceptedVmId] could not be persisted to CloneState after 3 attempts: $($_.Exception.Message)"
                }
            }

            return @{
                node                  = $selectedNode
                image_vm_id           = $selectedImageVmId
                vmid                  = $acceptedVmId
                task_id               = $acceptedTaskId
                context               = $acceptedCtx
                clone_state_persisted = $cloneStatePersisted
            }
        }

        $node = [string]$provisioned.node
        $imageVmId = [string]$provisioned.image_vm_id
        $newVmId = [string]$provisioned.vmid
        $taskId = [string]$provisioned.task_id
        $ctx = [hashtable]$provisioned.context
        $placementMode = [string](Get-ProviderConfig).placement
        Write-DebugLog "Creating linked clone [$newVmId] for RAS source [$sourceVmId], version [$snapshotName], placement [$placementMode] node [$node], image VM [$imageVmId] accepted as task [$taskId]."
        Remove-RecentGuestDelete -VmId ([string]$newVmId)

        $script:TaskContext[$taskId] = $ctx
        if (-not [bool]$provisioned.clone_state_persisted) {
            # Best-effort second chance outside the provisioning mutex. Failure is
            # still non-fatal because the Proxmox clone is already accepted.
            try { Set-CloneStateEntry -VmId $newVmId -Entry ($ctx + @{ task_id = $taskId }) }
            catch { Write-DebugLog "CRITICAL: Accepted clone VM [$newVmId] still could not be persisted to CloneState: $($_.Exception.Message)" }
        }
        return @{ result = @{ task_id = $taskId; clone_id = $newVmId } }
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to clone guest [$($Params.id)]: $($_.Exception.Message)"
    }
}

$script:MethodRegistry = @{
    'provider/initialize' = @{ Handler = { param($data) Handle-Initialize }; RequiredFields = @() }
    'provider/connect'    = @{ Handler = { param($data) Handle-Connect -Params $data.params }; RequiredFields = @('params.settings.host','params.settings.username','params.settings.token_name','params.settings.token_secret') }
    'provider/disconnect' = @{ Handler = { param($data) Handle-Disconnect }; RequiredFields = @() }

    'hosts/list'          = @{ Handler = { param($data) Handle-HostList }; RequiredFields = @() }
    'hosts/get'           = @{ Handler = { param($data) Handle-HostGet -Params $data.params }; RequiredFields = @('params.id') }
    'hosts/control'       = @{ Handler = { param($data) Handle-HostControl -Params $data.params }; RequiredFields = @('params.id', 'params.control') }

    'guests/list'         = @{ Handler = { param($data) Handle-GuestList }; RequiredFields = @() }
    'guests/get'          = @{ Handler = { param($data) Handle-GuestGet -Params $data.params }; RequiredFields = @('params.id') }
    'guests/control'      = @{ Handler = { param($data) Handle-GuestControl -Params $data.params }; RequiredFields = @('params.id', 'params.control') }

    'guests/convert'      = @{ Handler = { param($data) Handle-GuestConvert -Params $data.params }; RequiredFields = @('params.id', 'params.is_template') }
    'guests/clone'        = @{ Handler = { param($data) Handle-GuestClone -Params $data.params }; RequiredFields = @('params.id', 'params.name') }
    'guests/snapshots/create' = @{ Handler = { param($data) Handle-GuestSnapshotCreate -Params $data.params }; RequiredFields = @('params.id', 'params.name') }
    'guests/snapshots/delete' = @{ Handler = { param($data) Handle-GuestSnapshotsDelete -Params $data.params }; RequiredFields = @('params.id', 'params.name') }
    'guests/snapshots/exists' = @{ Handler = { param($data) Handle-GuestSnapshotsExists -Params $data.params }; RequiredFields = @('params.id', 'params.name') }
    'guests/snapshots/revert' = @{ Handler = { param($data) Handle-GuestSnapshotsRevert -Params $data.params }; RequiredFields = @('params.id', 'params.name') }
    'tasks/get'           = @{ Handler = { param($data) Handle-TaskInfo -Params $data.params }; RequiredFields = @('params.id') }
}

function Process-Method {
    param([string]$InputLine)

    $safeInputLine = ConvertTo-SafeLogLine -InputLine $InputLine
    Write-DebugLog "IN (PID=$PID): $safeInputLine"

    $methodData = ConvertFrom-JsonSafe -InputLine $InputLine
    if ($null -eq $methodData) {
        return New-ErrorResponse -Code $script:ErrorCodes.ParseError -Message "$($script:ProviderNamePrefix) Invalid JSON format"
    }

    $methodName = $null
    if ($methodData.PSObject.Properties.Name -contains 'method') {
        $methodName = [string]$methodData.method
    }

    if ([string]::IsNullOrWhiteSpace($methodName)) {
        return New-ErrorResponse -Code $script:ErrorCodes.MethodNotFound -Message "$($script:ProviderNamePrefix) Missing method name"
    }

    $lookupName = $methodName.Trim().ToLowerInvariant()
    if (-not $script:MethodRegistry.ContainsKey($lookupName)) {
        return New-ErrorResponse -Code $script:ErrorCodes.MethodNotFound -Message "$($script:ProviderNamePrefix) Unknown method: $methodName"
    }

    $methodEntry = $script:MethodRegistry[$lookupName]
    $validationError = Test-RequiredFields -Data $methodData -RequiredFields $methodEntry.RequiredFields
    if ($null -ne $validationError) {
        return New-ErrorResponse -Code $script:ErrorCodes.InvalidParams -Message $validationError
    }

    try {
        return & $methodEntry.Handler $methodData
    }
    catch {
        return New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Method execution failed: $($_.Exception.Message)"
    }
}

Write-DebugLog "Provider process started. implementation=[$($script:ImplementationVersion)] protocol=[1.0.0] PID=$PID"

while ($true) {
    try {
        $inputLine = [Console]::In.ReadLine()

        if ($null -eq $inputLine) {
            Write-DebugLog 'Input stream closed. Exiting.'
            break
        }

        $response = Process-Method -InputLine ($inputLine.Trim())
        Send-Response -ResponseObject $response
    }
    catch {
        $response = New-ErrorResponse -Code $script:ErrorCodes.InternalError -Message "$($script:ProviderNamePrefix) Failed to process input: $($_.Exception.Message)"
        Send-Response -ResponseObject $response
    }
}
