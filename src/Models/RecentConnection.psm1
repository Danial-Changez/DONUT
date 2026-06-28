using module ".\AppConfig.psm1"
using module ".\MachineInventory.psm1"
using module ".\DiskUsage.psm1"

# RecentConnection / RecentConnectionsStore
#
# Persisted "recent machines" backing the Home machine list. Entries live in
# AppConfig.Settings['recentHosts'] as plain hashtables so they round-trip
# cleanly through ConfigManager's ConvertTo-Json / ConvertFrom-Json -AsHashtable.
#
# The store keeps the array math pure and testable; persistence is delegated to
# a duck-typed config manager (typed [object] to avoid a Models->Core->Models
# using-module cycle). A $null manager makes Save() a no-op, which keeps unit
# tests free of disk I/O.

# Typed view of one stored entry (built from the raw hashtable for the UI).
class RecentConnection {
    [string] $Hostname
    [string] $LastSeen        # ISO8601 UTC ('o'), or '' when never run
    [string] $LastStatus      # e.g. 'Completed','Failed','RebootRequired',''
    [string] $LastJobType
    [int]    $UpdateCount
    [bool]   $RebootRequired
    [MachineInventory] $Inventory   # cached probe result, or $null when never probed
    [DiskUsageReport]  $DiskUsage   # cached "biggest folders" scan, or $null when never run

    static [RecentConnection] FromHashtable([hashtable]$h) {
        $rc = [RecentConnection]::new()
        $rc.Hostname       = [string]$h['hostname']
        $rc.LastSeen       = [string]$h['lastSeen']
        $rc.LastStatus     = [string]$h['lastStatus']
        $rc.LastJobType    = [string]$h['lastJobType']
        $rc.UpdateCount    = if ($null -ne $h['updateCount']) { [int]$h['updateCount'] } else { 0 }
        $rc.RebootRequired = [bool]$h['rebootRequired']
        if ($null -ne $h['inventory']) {
            $rc.Inventory = [MachineInventory]::FromHashtable([hashtable]$h['inventory'])
        }
        if ($null -ne $h['diskUsage']) {
            $rc.DiskUsage = [DiskUsageReport]::FromHashtable([hashtable]$h['diskUsage'])
        }
        return $rc
    }
}

class RecentConnectionsStore {
    hidden [AppConfig] $Config
    hidden [object]    $ConfigManager   # duck-typed; may be $null in tests
    static [int] $Cap = 50

    RecentConnectionsStore([AppConfig]$config, [object]$configManager) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        if (-not $this.Config.Settings.ContainsKey('recentHosts') -or $null -eq $this.Config.Settings['recentHosts']) {
            $this.Config.Settings['recentHosts'] = @()
        }
    }

    # Raw stored entries as a plain array of hashtables.
    hidden [object[]] Entries() {
        return @($this.Config.Settings['recentHosts'])
    }

    hidden [void] SetEntries([object[]]$entries) {
        $this.Config.Settings['recentHosts'] = @($entries)
    }

    # Inserts or replaces (by hostname, case-insensitive) and stamps lastSeen=now.
    [void] Upsert([string]$hostname, [string]$status, [string]$jobType, [int]$updateCount, [bool]$rebootRequired) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        $name = $hostname.Trim()

        $entry = @{
            hostname       = $name
            lastSeen       = [datetime]::UtcNow.ToString('o')
            lastStatus     = $status
            lastJobType    = $jobType
            updateCount    = [int]$updateCount
            rebootRequired = [bool]$rebootRequired
        }

        $kept = @($this.Entries() | Where-Object { [string]$_['hostname'] -ne $name })
        $this.SetEntries(@($entry) + $kept)
        $this.Save()
    }

    # Merges a fresh inventory probe onto the host's entry (creating one if the
    # host isn't tracked yet) WITHOUT touching its scan/apply status fields.
    # Stamps the cache with the controller's probe time for "last probed ...".
    [void] UpsertInventory([string]$hostname, [MachineInventory]$inv) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        if ($null -eq $inv) { return }
        $name = $hostname.Trim()

        $entry = $null
        foreach ($e in $this.Entries()) {
            if ([string]$e['hostname'] -eq $name) { $entry = [hashtable]$e; break }
        }
        if ($null -eq $entry) {
            $entry = @{
                hostname       = $name
                lastSeen       = ''
                lastStatus     = ''
                lastJobType    = ''
                updateCount    = 0
                rebootRequired = $false
            }
        }

        $invHash = $inv.ToHashtable()
        $invHash['probedAt'] = [datetime]::UtcNow.ToString('o')
        $entry['inventory'] = $invHash

        $kept = @($this.Entries() | Where-Object { [string]$_['hostname'] -ne $name })
        $this.SetEntries(@($entry) + $kept)
        $this.Save()
    }

    # Merges a fresh "biggest folders" scan onto the host's entry (creating one if
    # the host isn't tracked yet) WITHOUT touching its scan/apply status fields.
    # Mirrors UpsertInventory.
    [void] UpsertDiskUsage([string]$hostname, [DiskUsageReport]$report) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        if ($null -eq $report) { return }
        $name = $hostname.Trim()

        $entry = $null
        foreach ($e in $this.Entries()) {
            if ([string]$e['hostname'] -eq $name) { $entry = [hashtable]$e; break }
        }
        if ($null -eq $entry) {
            $entry = @{
                hostname       = $name
                lastSeen       = ''
                lastStatus     = ''
                lastJobType    = ''
                updateCount    = 0
                rebootRequired = $false
            }
        }

        $entry['diskUsage'] = $report.ToHashtable()

        $kept = @($this.Entries() | Where-Object { [string]$_['hostname'] -ne $name })
        $this.SetEntries(@($entry) + $kept)
        $this.Save()
    }

    # Removes an entry by hostname.
    [void] Remove([string]$hostname) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        $name = $hostname.Trim()
        $kept = @($this.Entries() | Where-Object { [string]$_['hostname'] -ne $name })
        $this.SetEntries($kept)
        $this.Save()
    }

    # One-time seed (only when empty) from a host-name list, e.g. WSID.txt.
    # Seeded hosts are "never run": blank lastSeen/status.
    [void] SeedFrom([string[]]$hosts) {
        if ($this.Entries().Count -gt 0) { return }
        if ($null -eq $hosts) { return }

        $seen = @{}
        $entries = @()
        foreach ($h in $hosts) {
            if ([string]::IsNullOrWhiteSpace($h)) { continue }
            $name = $h.Trim()
            if ($seen.ContainsKey($name.ToLowerInvariant())) { continue }
            $seen[$name.ToLowerInvariant()] = $true
            $entries += @{
                hostname       = $name
                lastSeen       = ''
                lastStatus     = ''
                lastJobType    = ''
                updateCount    = 0
                rebootRequired = $false
            }
        }
        $this.SetEntries($entries)
        $this.Save()
    }

    # Typed entries, newest first (blank lastSeen sorts oldest), capped.
    [RecentConnection[]] GetAll() {
        $typed = @($this.Entries() | ForEach-Object { [RecentConnection]::FromHashtable([hashtable]$_) })
        $sorted = $typed | Sort-Object -Property @{ Expression = { [RecentConnectionsStore]::ParseSeen($_.LastSeen) }; Descending = $true }
        return @($sorted | Select-Object -First ([RecentConnectionsStore]::Cap))
    }

    [int] Count() {
        return $this.Entries().Count
    }

    # Parses a stored lastSeen into a sortable DateTime (blank -> MinValue).
    hidden static [datetime] ParseSeen([string]$value) {
        if ([string]::IsNullOrWhiteSpace($value)) { return [datetime]::MinValue }
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
        if ([datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $parsed
        }
        return [datetime]::MinValue
    }

    hidden [void] Save() {
        if ($null -ne $this.ConfigManager) {
            $this.ConfigManager.SaveConfig($this.Config)
        }
    }
}
