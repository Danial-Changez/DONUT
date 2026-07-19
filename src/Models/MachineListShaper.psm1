<#
.SYNOPSIS
    Pure sort/filter helpers for the Home machine list.

.DESCRIPTION
    Turns a machine's raw state (running flag, reachability, last idle status) into a
    single status category and a sort rank, and answers whether a row matches the
    selected status chip. HostViewModel exposes StatusCategory/SortStatusRank from
    Categorize/StatusRank so a WPF CollectionView can sort and filter declaratively.

.NOTES
    Deliberately WPF-free so it can be unit-tested off-domain. Running wins over the
    idle/reachability states (an active job is the most salient thing about a row), so
    a running machine shows only under the "All" chip - acceptable since running is
    transient and the default Status sort floats it near the top anyway.
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

    # Status-chip match. 'All' (or blank) matches everything; otherwise the category
    # must equal the selected chip.
    static [bool] MatchesStatus([string]$category, [string]$filter) {
        if ([string]::IsNullOrWhiteSpace($filter) -or $filter -eq 'All') { return $true }
        return $category -eq $filter
    }
}
