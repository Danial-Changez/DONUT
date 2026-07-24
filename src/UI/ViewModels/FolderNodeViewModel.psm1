using namespace Donut.Mvvm
using module "..\..\Models\DiskUsage.psm1"
using module "..\..\Models\FolderDeletionPolicy.psm1"

<#
.SYNOPSIS
    Display-ready node for the largest-folders TreeView, with tri-state clear selection.

.DESCRIPTION
    Wraps a FolderTreeNode with the values the HierarchicalDataTemplate binds (Label, SizeText,
    Path, Depth, IsRoot, Children) plus the clear-selection state: IsDeletable gates the checkbox,
    and IsSelected is a tri-state (true / false / null) that rolls up and down the tree like the
    Windows "Turn Windows features on/off" list - checking a parent checks every deletable
    descendant; unchecking one child leaves the parent indeterminate and spares that child.

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
    [object]   $IsSelected = $false    # tri-state: $true / $false / $null (indeterminate)
    [object]   $Parent = $null         # set by FromNodes; drives the tri-state roll-up
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

    # --- Tri-state clear selection ---

    # The user (un)checked this node: cascade the value to every deletable descendant, then roll
    # the tri-state up the ancestors. Idempotent, so the presenter can relay a click blindly.
    [void] SetChecked([bool]$value) {
        $this.CascadeDown($value)
        if ($null -ne $this.Parent) { $this.Parent.RollUp() }
    }

    hidden [void] CascadeDown([bool]$value) {
        if ($this.IsDeletable) { $this.Set('IsSelected', $value) }
        foreach ($c in $this.Children) { $c.CascadeDown($value) }
    }

    # Recompute this node's tri-state from its deletable descendants (all checked -> checked,
    # none -> unchecked, mixed -> indeterminate), then bubble up to the parent.
    hidden [void] RollUp() {
        $desc = @($this.DeletableDescendants())
        if ($this.IsDeletable -and $desc.Count -gt 0) {
            $checked = @($desc | Where-Object { $_.IsSelected -eq $true }).Count
            if ($checked -eq 0) { $this.Set('IsSelected', $false) }
            elseif ($checked -eq $desc.Count) { $this.Set('IsSelected', $true) }
            else { $this.Set('IsSelected', $null) }
        }
        if ($null -ne $this.Parent) { $this.Parent.RollUp() }
    }

    hidden [object[]] DeletableDescendants() {
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $this.Children) {
            if ($c.IsDeletable) { $out.Add($c) }
            $out.AddRange([object[]]@($c.DeletableDescendants()))
        }
        return $out.ToArray()
    }

    # Top-most fully-checked (IsSelected == $true) deletable nodes: a $true node covers its whole
    # subtree, while an indeterminate parent yields only its checked children (unchecked ones spared).
    static [FolderNodeViewModel[]] CollectSelected([object[]]$nodes) {
        $out = [System.Collections.Generic.List[FolderNodeViewModel]]::new()
        foreach ($n in @($nodes)) {
            if ($null -eq $n) { continue }
            if ($n.IsDeletable -and $n.IsSelected -eq $true) { $out.Add($n) }
            elseif ($n.Children) { $out.AddRange([FolderNodeViewModel]::CollectSelected($n.Children)) }
        }
        return $out.ToArray()
    }
}
