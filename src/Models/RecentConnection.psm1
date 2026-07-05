using module ".\AppConfig.psm1"
using module ".\MachineInventory.psm1"
using module ".\DiskUsage.psm1"

<#
.SYNOPSIS
    Persisted "recent machines" model backing the Home machine list.

.DESCRIPTION
    Entries live in AppConfig.Settings['recentHosts'] as plain hashtables so they
    round-trip cleanly through ConfigManager's ConvertTo-Json /
    ConvertFrom-Json -AsHashtable. RecentConnection is the typed view of one
    entry (status, counts, cached inventory + disk usage); RecentConnectionsStore
    owns the upsert/seed/cap/sort logic.

.NOTES
    The store keeps the array math pure and testable; persistence is delegated to
    a duck-typed config manager (typed [object] to avoid a Models -> Core ->
    Models using-module cycle). A $null manager makes Save() a no-op, which keeps
    unit tests free of disk I/O.
#>

# Typed view of one stored entry (built from the raw hashtable for the UI).
class RecentConnection {
    [string] $Hostname
    [string] $LastSeen        # ISO8601 UTC ('o'), or '' when never run
    [string] $LastTouched     # last operator action (add/run/gather/storage scan), or ''
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
        $rc.LastTouched    = [string]$h['lastTouched']
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

    # Save coalescing: with DeferSave on, mutations mark PendingSave and FlushSave()
    # performs the single deferred write (the UI flushes once per drained batch).
    [bool]   $DeferSave = $false
    hidden [bool] $PendingSave = $false

    # Cached typed view, rebuilt lazily, invalidated by any mutation (all funnel through
    # SetEntries) - the UI reads every ~200ms tick. $Index = lower(hostname) -> entry, O(1).
    hidden [RecentConnection[]] $Cache
    hidden [hashtable] $Index
    hidden [bool] $CacheValid = $false

    RecentConnectionsStore([AppConfig]$config, [object]$configManager) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        if (-not $this.Config.Settings.ContainsKey('recentHosts') -or
            $null -eq $this.Config.Settings['recentHosts']) {
            $this.Config.Settings['recentHosts'] = @()
        }
    }

    # Raw stored entries as a plain array of hashtables.
    hidden [object[]] Entries() {
        return @($this.Config.Settings['recentHosts'])
    }

    hidden [void] SetEntries([object[]]$entries) {
        $this.Config.Settings['recentHosts'] = @($entries)
        $this.CacheValid = $false
    }

    # The six-key "never run" entry shape shared by Touch/UpsertInventory/UpsertDiskUsage/SeedFrom.
    hidden static [hashtable] NewBlankEntry([string]$name) {
        return @{
            hostname       = $name
            lastSeen       = ''
            lastStatus     = ''
            lastJobType    = ''
            updateCount    = 0
            rebootRequired = $false
        }
    }

    # Finds the raw stored entry by hostname (case-insensitive), or $null when untracked.
    hidden [hashtable] FindEntry([string]$name) {
        foreach ($e in $this.Entries()) {
            if ([string]$e['hostname'] -eq $name) { return [hashtable]$e }
        }
        return $null
    }

    # The shared mutation tail: drop any same-host entry, put $entry at the head, persist.
    hidden [void] CommitFront([hashtable]$entry, [string]$name) {
        $kept = @($this.Entries() | Where-Object { [string]$_['hostname'] -ne $name })
        $this.SetEntries(@($entry) + $kept)
        $this.Save()
    }

    # Inserts or replaces (by hostname, case-insensitive) and stamps lastSeen=now.
    [void] Upsert([string]$hostname, [string]$status, [string]$jobType,
        [int]$updateCount, [bool]$rebootRequired) {
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

        # Carry over what a run does not change (cached inventory/disk-usage,
        # lastTouched); replacing the entry without these silently loses the caches.
        $prev = $this.FindEntry($name)
        if ($null -ne $prev) {
            foreach ($k in @('inventory', 'diskUsage', 'lastTouched')) {
                if ($prev.ContainsKey($k)) { $entry[$k] = $prev[$k] }
            }
        }

        $this.CommitFront($entry, $name)
    }

    # Stamps the host's last operator action so the next launch orders cards newest-
    # first. Deliberately leaves lastSeen alone: that means "last run" (24h scan reuse).
    [void] Touch([string]$hostname) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        $name = $hostname.Trim()

        $entry = $this.FindEntry($name)
        if ($null -eq $entry) { $entry = [RecentConnectionsStore]::NewBlankEntry($name) }
        $entry['lastTouched'] = [datetime]::UtcNow.ToString('o')

        $this.CommitFront($entry, $name)
    }

    # Merges a fresh inventory probe onto the host's entry without touching its
    # scan/apply status fields; stamps the probe time for "last probed ...".
    [void] UpsertInventory([string]$hostname, [MachineInventory]$inv) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        if ($null -eq $inv) { return }
        $name = $hostname.Trim()

        $entry = $this.FindEntry($name)
        if ($null -eq $entry) { $entry = [RecentConnectionsStore]::NewBlankEntry($name) }

        $invHash = $inv.ToHashtable()
        $invHash['probedAt'] = [datetime]::UtcNow.ToString('o')
        $entry['inventory'] = $invHash

        $this.CommitFront($entry, $name)
    }

    # Merges a fresh "biggest folders" scan onto the host's entry without touching
    # its scan/apply status fields. Mirrors UpsertInventory.
    [void] UpsertDiskUsage([string]$hostname, [DiskUsageReport]$report) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        if ($null -eq $report) { return }
        $name = $hostname.Trim()

        $entry = $this.FindEntry($name)
        if ($null -eq $entry) { $entry = [RecentConnectionsStore]::NewBlankEntry($name) }

        $entry['diskUsage'] = $report.ToHashtable()

        $this.CommitFront($entry, $name)
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
            $entries += [RecentConnectionsStore]::NewBlankEntry($name)
        }
        $this.SetEntries($entries)
        $this.Save()
    }

    # Typed entries, most-recent-activity first (RecencyKey; blank stamps sort oldest),
    # capped, and cached until the next mutation so per-tick reads don't rebuild.
    [RecentConnection[]] GetAll() {
        $this.EnsureCache()
        return $this.Cache
    }

    # O(1) single-host lookup from the cached index (case-insensitive), or $null.
    [RecentConnection] GetByHost([string]$hostname) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return $null }
        $this.EnsureCache()
        $key = $hostname.Trim().ToLowerInvariant()
        if ($this.Index.ContainsKey($key)) { return $this.Index[$key] }
        return $null
    }

    # A card's ordering key: the most recent of lastTouched (operator action) and
    # lastSeen (last run), so either floats the card toward the top of the next launch.
    hidden static [datetime] RecencyKey([RecentConnection]$rc) {
        $touched = [RecentConnectionsStore]::ParseSeen($rc.LastTouched)
        $seen = [RecentConnectionsStore]::ParseSeen($rc.LastSeen)
        return $(if ($touched -gt $seen) { $touched } else { $seen })
    }

    # Rebuilds the typed cache + index from the raw entries when stale.
    hidden [void] EnsureCache() {
        if ($this.CacheValid) { return }
        $typed = @($this.Entries() |
                ForEach-Object { [RecentConnection]::FromHashtable([hashtable]$_) })
        $sorted = $typed | Sort-Object -Property @{
            Expression = { [RecentConnectionsStore]::RecencyKey($_) }; Descending = $true
        }
        $this.Cache = @($sorted | Select-Object -First ([RecentConnectionsStore]::Cap))
        $this.Index = @{}
        foreach ($rc in $this.Cache) {
            if ($null -ne $rc -and -not [string]::IsNullOrWhiteSpace($rc.Hostname)) {
                $this.Index[$rc.Hostname.ToLowerInvariant()] = $rc
            }
        }
        $this.CacheValid = $true
    }

    [int] Count() {
        return $this.Entries().Count
    }

    # Parses a stored lastSeen into a sortable DateTime (blank -> MinValue).
    hidden static [datetime] ParseSeen([string]$value) {
        if ([string]::IsNullOrWhiteSpace($value)) { return [datetime]::MinValue }
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
        if ([datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture,
                $styles, [ref]$parsed)) {
            return $parsed
        }
        return [datetime]::MinValue
    }

    hidden [void] Save() {
        if ($this.DeferSave) { $this.PendingSave = $true; return }
        $this.WriteConfig()
    }

    # Writes any pending deferred save (no-op when nothing is pending). Called by the
    # UI once per drained batch / on close, so many upserts collapse to one disk write.
    [void] FlushSave() {
        if ($this.PendingSave) { $this.WriteConfig() }
    }

    hidden [void] WriteConfig() {
        $this.PendingSave = $false
        if ($null -ne $this.ConfigManager) {
            $this.ConfigManager.SaveConfig($this.Config)
        }
    }
}
