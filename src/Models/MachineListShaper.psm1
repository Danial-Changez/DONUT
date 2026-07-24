<#
.SYNOPSIS
    Pure sort helpers for the Home machine list.

.DESCRIPTION
    Turns a machine's raw state (running flag, reachability, last idle status) into a
    single status category and a sort rank. HostViewModel exposes SortStatusRank from
    Categorize/StatusRank so a WPF CollectionView can keep the list status-grouped.

.NOTES
    Deliberately WPF-free so it can be unit-tested off-domain. Running wins over the
    idle/reachability states (an active job is the most salient thing about a row), so
    a running machine ranks just after the attention group.
#>
class MachineListShaper {
    # Reduce raw state to one category. Order of checks encodes precedence.
    static [string] Categorize([bool]$running, [string]$reachability, [string]$idleStatus) {
        if ($running) { return 'Running' }
        if ($idleStatus -in @('Failed', 'RebootRequired', 'ConnectionLost')) { return 'NeedsAttention' }
        if ($reachability -eq 'Offline') { return 'Offline' }
        if ($reachability -eq 'Online') { return 'Online' }
        return 'Unknown'
    }

    # Sort rank for the "Status, then name" order: problems first, then running, then
    # reachable, then offline, then not-yet-known.
    static [int] StatusRank([string]$category) {
        switch ($category) {
            'NeedsAttention' { return 0 }
            'Running' { return 1 }
            'Online' { return 2 }
            'Offline' { return 3 }
            default { return 4 }
        }
        return 4
    }
}
