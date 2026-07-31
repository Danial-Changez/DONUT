using module ".\MachineInventory.psm1"
using module ".\DiskUsage.psm1"

<#
.SYNOPSIS
    Typed view of one persisted "recent machine" entry backing the Home list.

.DESCRIPTION
    Entries live in AppConfig.Settings['recentHosts'] as plain hashtables so they
    round-trip cleanly through ConfigManager's JSON. This pure Model is the typed
    view of one entry (status, counts, cached inventory + disk usage); the
    upsert/seed/cap/sort + persistence logic lives in
    Services\RecentConnectionsStore (Models do no I/O).
#>
class RecentConnection {
    [string] $Hostname
    [string] $LastSeen        # ISO8601 UTC ('o'), or '' when never run
    [string] $LastTouched     # last operator action (add/run/gather/storage scan), or ''
    [string] $LastStatus      # e.g. 'Completed','Failed','RebootRequired',''
    [string] $LastJobType
    [int]    $UpdateCount
    [bool]   $RebootRequired
    [string] $Owner           # SCCM primary user's display name; cached, looked up once
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
        $rc.Owner          = [string]$h['owner']
        if ($null -ne $h['inventory']) {
            $rc.Inventory = [MachineInventory]::FromHashtable([hashtable]$h['inventory'])
        }
        if ($null -ne $h['diskUsage']) {
            $rc.DiskUsage = [DiskUsageReport]::FromHashtable([hashtable]$h['diskUsage'])
        }
        return $rc
    }
}
