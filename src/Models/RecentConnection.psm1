<#
.SYNOPSIS
    Typed view of one persisted "recent machine" entry backing the Home list.

.DESCRIPTION
    Entries are plain hashtables so they round-trip cleanly through
    ConvertTo-Json / ConvertFrom-Json -AsHashtable. This pure Model is the typed
    view of one entry (status, counts, owner); the upsert/seed/cap/sort +
    persistence logic lives in Services\RecentConnectionsStore (Models do no
    I/O). Per-machine probe data is deliberately absent: the scan's CSV and the
    inventory JSON in reports\ are its stores.
#>
class RecentConnection {
    [string] $Hostname
    [string] $LastSeen        # ISO8601 UTC ('o'), or '' when never run
    [string] $LastTouched     # last operator action (add/run/gather/storage scan), or ''
    [string] $LastStatus      # e.g. 'Completed','Failed','RebootRequired',''
    [string] $LastJobType
    [int]    $UpdateCount
    [string] $Owner           # SCCM primary user's display name, cached and looked up once

    static [RecentConnection] FromHashtable([hashtable]$h) {
        $rc = [RecentConnection]::new()
        $rc.Hostname    = [string]$h['hostname']
        $rc.LastSeen    = [string]$h['lastSeen']
        $rc.LastTouched = [string]$h['lastTouched']
        $rc.LastStatus  = [string]$h['lastStatus']
        $rc.LastJobType = [string]$h['lastJobType']
        $rc.UpdateCount = if ($null -ne $h['updateCount']) { [int]$h['updateCount'] } else { 0 }
        $rc.Owner       = [string]$h['owner']
        return $rc
    }
}
