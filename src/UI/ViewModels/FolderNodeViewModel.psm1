using module "..\..\Models\DiskUsage.psm1"

<#
.SYNOPSIS
    Display-ready node for the largest-folders TreeView (MVVM replacement for the
    imperative BuildFolderTreeItem/BuildFolderHeader builders).

.DESCRIPTION
    Wraps a FolderTreeNode (the pure containment-tree model) with the exact values the
    HierarchicalDataTemplate binds: the relative Label, a formatted SizeText
    (DiskUsageFormat), the full Path for the tooltip, Depth (the container style expands
    roots and collapses deeper levels), IsRoot (drives the brighter root foreground), and
    Children as nested FolderNodeViewModels. Values are computed once per report, so no
    INotifyPropertyChanged is needed - the HostViewModel swaps the whole collection.

.NOTES
    WPF-free and pure, so the mapping is unit-tested without a dispatcher.
#>
class FolderNodeViewModel {
    [string]   $Label = ''
    [string]   $SizeText = ''
    [string]   $Path = ''
    [int]      $Depth = 0
    [bool]     $IsRoot = $false
    [object[]] $Children = @()

    # Root display nodes for a report (empty for a null/empty report).
    static [FolderNodeViewModel[]] FromReport([DiskUsageReport]$report) {
        if ($null -eq $report -or $report.Folders.Count -eq 0) { return @() }
        return [FolderNodeViewModel]::FromNodes([DiskUsageTree]::BuildNested($report.Folders))
    }

    # Recursively maps model nodes (already nested + size-ranked) to display nodes.
    static [FolderNodeViewModel[]] FromNodes([FolderTreeNode[]]$nodes) {
        $out = [System.Collections.Generic.List[FolderNodeViewModel]]::new()
        foreach ($n in @($nodes)) {
            if ($null -eq $n) { continue }
            $vm = [FolderNodeViewModel]::new()
            $vm.Label    = $n.Label
            $vm.Path     = $n.Path
            $vm.Depth    = $n.Depth
            $vm.IsRoot   = ($n.Depth -eq 0)
            $vm.SizeText = [DiskUsageFormat]::SizeLabel($n.SizeBytes)
            $vm.Children = [FolderNodeViewModel]::FromNodes($n.Children)
            $out.Add($vm)
        }
        return $out.ToArray()
    }
}
