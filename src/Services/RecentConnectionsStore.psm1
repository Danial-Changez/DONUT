using module "..\Models\AppConfig.psm1"
using module "..\Models\RecentConnection.psm1"
using module "..\Core\DonutPaths.psm1"
using module "..\Core\LogService.psm1"
using module "..\Core\TimeFormat.psm1"

<#
.SYNOPSIS
    Persistence service for the "recent machines" entries backing the Home list.

.DESCRIPTION
    Entries live in config\recents.json as a plain JSON array of hashtables -
    machine-list state stays out of config.json, which holds settings only. The
    store owns the file plus the upsert/seed/cap/sort logic; RecentConnection (a
    pure Model) is the typed view of one entry.

.NOTES
    The array math stays pure and testable; a blank path makes every write a
    no-op, which keeps unit tests free of disk I/O. A corrupt or missing file
    loads as an empty list - recency is a cache, and the WSID seed repopulates
    it - so writes are plain Set-Content, no atomicity ceremony needed.

    Upsert deliberately does not carry a legacy 'inventory' blob across from the
    previous entry: reports\ is the inventory store now, and config-era per-machine
    blobs are dropped on the first write rather than kept alive indefinitely.
#>
class RecentConnectionsStore {
    hidden [string] $Path         # recents.json, blank means in-memory only (tests)
    hidden [LogService] $Logger
    hidden [object[]] $Data       # raw entry hashtables, newest first
    static [int] $Cap = 50

    # With DeferSave on, mutations only mark PendingSave and FlushSave() does the write.
    [bool]   $DeferSave = $false
    hidden [bool] $PendingSave = $false

    # Cached because the UI re-reads on every 200ms tick. Any mutation invalidates it.
    hidden [RecentConnection[]] $Cache
    hidden [hashtable] $Index     # lower(hostname) -> entry, for O(1) lookup
    hidden [bool] $CacheValid = $false

    RecentConnectionsStore([string]$path, [LogService]$logger) {
        $this.Path = $path
        $this.Logger = [LogService]::Coalesce($logger)
        $this.Data = @()
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return }
        try {
            $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            $this.Data = @($raw | Where-Object { $_ -is [hashtable] })
        }
        catch {
            $this.Logger.LogWarning(
                "Could not read recents file '$path' - starting empty: $($_.Exception.Message)")
        }
    }

    static [string] DefaultPath() {
        return (Join-Path ([DonutPaths]::ConfigDir()) 'recents.json')
    }

    # One-time config.json to recents.json move. Safe to re-run: an existing recents file
    # wins, key removal is idempotent, and a failed import leaves config for the retry.
    static [void] MigrateFromConfig([AppConfig]$config, [object]$configManager,
        [string]$path, [LogService]$logger) {
        if ($null -eq $config) { return }
        $log = [LogService]::Coalesce($logger)

        $legacy = @($config.Settings['recentHosts'] | Where-Object { $_ -is [hashtable] })
        if ($legacy.Count -gt 0 -and -not (Test-Path -LiteralPath $path)) {
            $imported = @()
            foreach ($e in $legacy) {
                $copy = ([hashtable]$e).Clone()
                $copy.Remove('inventory')
                $copy.Remove('rebootRequired')
                $imported += $copy
            }
            try {
                ConvertTo-Json -InputObject $imported -Depth 5 |
                    Set-Content -LiteralPath $path -Encoding UTF8
                $log.LogInfo("Moved $($imported.Count) recent host(s) from config.json to '$path'.")
            }
            catch {
                $log.LogException("Recents migration could not write '$path'", $_)
                return
            }
        }

        $removed = $false
        foreach ($k in @('recentHosts', 'domainControllers')) {
            if ($config.Settings.ContainsKey($k)) { $config.Settings.Remove($k); $removed = $true }
        }
        if ($removed -and $null -ne $configManager) { $configManager.SaveConfig($config) }
    }

    # Raw stored entries as a plain array of hashtables.
    hidden [object[]] Entries() {
        return @($this.Data)
    }

    # Cap on write, not just read: the persisted file must not grow unbounded.
    # CommitFront prepends, so the acted-on entry always survives the trim.
    hidden [void] SetEntries([object[]]$entries) {
        $this.Data = @($entries | Select-Object -First ([RecentConnectionsStore]::Cap))
        $this.CacheValid = $false
    }

    # The five-key "never run" entry shape shared by Touch/UpsertOwner/SeedFrom.
    hidden static [hashtable] NewBlankEntry([string]$name) {
        return @{
            hostname    = $name
            lastSeen    = ''
            lastStatus  = ''
            lastJobType = ''
            updateCount = 0
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
    [void] Upsert([string]$hostname, [string]$status, [string]$jobType, [int]$updateCount) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        $name = $hostname.Trim()

        $entry = @{
            hostname    = $name
            lastSeen    = [datetime]::UtcNow.ToString('o')
            lastStatus  = $status
            lastJobType = $jobType
            updateCount = [int]$updateCount
        }

        # Replacing the entry outright silently loses these caches. See .NOTES.
        $prev = $this.FindEntry($name)
        if ($null -ne $prev) {
            foreach ($k in @('lastTouched', 'owner')) {
                if ($prev.ContainsKey($k)) { $entry[$k] = $prev[$k] }
            }
        }

        $this.CommitFront($entry, $name)
    }

    # Stamps the host's last operator action so the next launch orders cards newest
    # first. Deliberately leaves lastSeen alone: that means "last run" (24h scan reuse).
    [void] Touch([string]$hostname) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        $name = $hostname.Trim()

        $entry = $this.FindEntry($name)
        if ($null -eq $entry) { $entry = [RecentConnectionsStore]::NewBlankEntry($name) }
        $entry['lastTouched'] = [datetime]::UtcNow.ToString('o')

        $this.CommitFront($entry, $name)
    }

    # Caches the machine's SCCM primary user. Written once and kept: affinity changes
    # rarely, and re-asking on every render would be a round trip per card per paint.
    [void] UpsertOwner([string]$hostname, [string]$owner) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { return }
        if ([string]::IsNullOrWhiteSpace($owner)) { return }
        $name = $hostname.Trim()

        $entry = $this.FindEntry($name)
        if ($null -eq $entry) { $entry = [RecentConnectionsStore]::NewBlankEntry($name) }
        $entry['owner'] = $owner
        $this.CommitFront($entry, $name)
    }

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

    # Typed entries, most-recent-activity first by RecencyKey, with blank stamps sorting
    # oldest. Cached until the next mutation so per-tick reads do not rebuild.
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
        $touched = [TimeFormat]::ParseIso($rc.LastTouched)
        $seen = [TimeFormat]::ParseIso($rc.LastSeen)
        return $(if ($touched -gt $seen) { $touched } else { $seen })
    }

    # Rebuilds the typed cache and index from the raw entries when stale. The Cap here
    # guards a hand-edited oversized file, and SetEntries enforces it on every write.
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

    hidden [void] Save() {
        if ($this.DeferSave) { $this.PendingSave = $true; return }
        $this.WriteRecents()
    }

    # Writes any pending deferred save. The UI calls it once per drained batch and on
    # close, so many upserts collapse to one disk write.
    [void] FlushSave() {
        if ($this.PendingSave) { $this.WriteRecents() }
    }

    hidden [void] WriteRecents() {
        $this.PendingSave = $false
        if ([string]::IsNullOrWhiteSpace($this.Path)) { return }
        try {
            # -InputObject keeps an empty/one-entry list serialized as a JSON array.
            ConvertTo-Json -InputObject $this.Data -Depth 5 |
                Set-Content -LiteralPath $this.Path -Encoding UTF8
        }
        catch {
            $this.Logger.LogException("Could not write recents file '$($this.Path)'", $_)
        }
    }
}
