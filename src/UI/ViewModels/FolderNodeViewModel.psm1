using namespace Donut.Mvvm
using module "..\..\Models\DiskUsage.psm1"
using module "..\..\Models\FolderDeletionPolicy.psm1"

<#
.SYNOPSIS
    Display-ready node for the largest-folders TreeView, with explicit clear selection.

.DESCRIPTION
    Wraps a FolderTreeNode with the values the HierarchicalDataTemplate binds (Label, SizeText,
    Path, Depth, IsRoot, Children) plus the clear-selection state: IsDeletable gates the checkbox,
    and a checked folder means "clear THIS folder's contents" - checking one also checks every
    deletable descendant shown under it. Selection never travels upward: the tree shows only the
    largest folders, so a parent's visible children are not its whole contents, and a roll-up
    that promoted "all visible children checked" to a checked parent once escalated a single
    child's clear into clearing the parent's entire on-disk contents. Unchecking a child instead
    releases any checked ancestor (it no longer covers the spared child); the ancestor's other
    checked descendants stay selected individually.

.NOTES
    An ObservableObject so cascaded selection changes notify the bound checkboxes. The cascade
    itself is here (pure tree logic); the presenter only relays the user's click into SetChecked.
#>
class FolderNodeViewModel : ObservableObject {
    [string]   $Label = ''
    [string]   $SizeText = ''
    [string]   $Path = ''
    [long]     $SizeBytes = 0
    [int]      $Depth = 0
    [bool]     $IsRoot = $false
    [bool]     $IsDeletable = $false   # gates the checkbox (FolderDeletionPolicy)
    [bool]     $IsSelected = $false
    [object]   $Parent = $null         # set by FromNodes; walked when a child is spared
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
            $vm.Label       = $n.Label
            $vm.Path        = $n.Path
            $vm.Depth       = $n.Depth
            $vm.IsRoot      = ($n.Depth -eq 0)
            $vm.SizeBytes   = $n.SizeBytes
            $vm.SizeText    = [DiskUsageFormat]::SizeLabel($n.SizeBytes)
            $vm.IsDeletable = [FolderDeletionPolicy]::IsDeletable($n.Path)
            $vm.Children    = [FolderNodeViewModel]::FromNodes($n.Children)
            foreach ($c in $vm.Children) { $c.Parent = $vm }
            $out.Add($vm)
        }
        return $out.ToArray()
    }

    # --- Clear selection ---

    # The user (un)checked this node: cascade the value to every deletable descendant.
    # Unchecking also releases any checked ancestor - see .DESCRIPTION. Idempotent,
    # so the presenter can relay a click blindly.
    [void] SetChecked([bool]$value) {
        $this.CascadeDown($value)
        if (-not $value) {
            $p = $this.Parent
            while ($null -ne $p) {
                if ($p.IsSelected) { $p.Set('IsSelected', $false) }
                $p = $p.Parent
            }
        }
    }

    hidden [void] CascadeDown([bool]$value) {
        if ($this.IsDeletable) { $this.Set('IsSelected', $value) }
        foreach ($c in $this.Children) { $c.CascadeDown($value) }
    }

    # Top-most checked deletable nodes: a checked node clears its whole subtree, so its
    # descendants are not listed separately.
    static [FolderNodeViewModel[]] CollectSelected([object[]]$nodes) {
        $out = [System.Collections.Generic.List[FolderNodeViewModel]]::new()
        foreach ($n in @($nodes)) {
            if ($null -eq $n) { continue }
            if ($n.IsDeletable -and $n.IsSelected) { $out.Add($n) }
            elseif ($n.Children) { $out.AddRange([FolderNodeViewModel]::CollectSelected($n.Children)) }
        }
        return $out.ToArray()
    }
}
