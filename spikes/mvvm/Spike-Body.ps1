# Dot-sourced by Test-Mvvm.ps1 (WPF + ObservableObject already loaded).
# Defines a PowerShell view-model and exercises real WPF bindings headlessly.

# A PowerShell view-model: inherits the C# INotifyPropertyChanged base. PS class fields
# compile to real CLR properties, so WPF can bind to them. PS classes have no property
# setters, so mutation goes through Set(), which writes the field AND raises change
# notification - the one ergonomic tax of MVVM in PowerShell.
class HostViewModel : ObservableObject {
    [string] $HostName
    [string] $Status
    [int]    $UpdateCount

    HostViewModel([string]$name, [string]$status) {
        $this.HostName = $name
        $this.Status = $status
        $this.UpdateCount = 0
    }

    [void] Set([string]$prop, $value) {
        $this.$prop = $value
        $this.Raise($prop)
    }
}

# Flush the WPF dispatcher so queued binding updates (DataBind priority) are applied,
# then return - all without ever showing a window.
function Sync-Wpf {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::SystemIdle,
        [System.Action] { $frame.Continue = $false }) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Bind-TextBlock {
    param($Source, [string]$Path, [System.Windows.Data.BindingMode]$Mode = 'OneWay')
    $tb = [System.Windows.Controls.TextBlock]::new()
    $tb.DataContext = $Source
    $b = [System.Windows.Data.Binding]::new($Path)
    $b.Mode = $Mode
    [void][System.Windows.Data.BindingOperations]::SetBinding($tb, [System.Windows.Controls.TextBlock]::TextProperty, $b)
    return $tb
}

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $results.Add([pscustomobject]@{ Test = $Name; Result = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

Write-Host "`n=== MVVM feasibility spike (headless WPF bindings) ===`n" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. PSCustomObject: does WPF bind to it, and does changing a property update the UI?
# ---------------------------------------------------------------------------
try {
    $pco = [pscustomobject]@{ Status = 'Idle' }
    $tb = Bind-TextBlock -Source $pco -Path 'Status'
    Sync-Wpf
    $initialRead = ($tb.Text -eq 'Idle')

    $pco.Status = 'Running'          # plain property set - no change notification
    Sync-Wpf
    $liveUpdate = ($tb.Text -eq 'Running')

    Add-Result 'PSCustomObject - initial one-way read' $initialRead "TextBlock.Text = '$($tb.Text)'"
    Add-Result 'PSCustomObject - live update on property change' $liveUpdate "after set, TextBlock.Text = '$($tb.Text)' (expected 'Running' only if it notifies)"
}
catch {
    Add-Result 'PSCustomObject binding' $false "threw: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 2. PowerShell view-model (: ObservableObject): does the UI update on change?
# ---------------------------------------------------------------------------
try {
    $vm = [HostViewModel]::new('PC-01', 'Idle')
    $tb = Bind-TextBlock -Source $vm -Path 'Status'
    Sync-Wpf
    $initialRead = ($tb.Text -eq 'Idle')

    $vm.Set('Status', 'Scanning')    # sets field + Raise('Status')
    Sync-Wpf
    $liveUpdate = ($tb.Text -eq 'Scanning')

    $vm.Set('Status', 'Completed')
    Sync-Wpf
    $liveUpdate2 = ($tb.Text -eq 'Completed')

    Add-Result 'PS view-model - initial one-way read' $initialRead "TextBlock.Text = '$($tb.Text)'"
    Add-Result 'PS view-model - live update via PropertyChanged' ($liveUpdate -and $liveUpdate2) "after two changes, TextBlock.Text = '$($tb.Text)' (expected 'Completed')"
}
catch {
    Add-Result 'PS view-model binding' $false "threw: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 2b. Two-way: does editing the bound control push back into the view-model?
# ---------------------------------------------------------------------------
try {
    $vm = [HostViewModel]::new('PC-02', 'Idle')
    $box = [System.Windows.Controls.TextBox]::new()
    $box.DataContext = $vm
    $b = [System.Windows.Data.Binding]::new('Status')
    $b.Mode = [System.Windows.Data.BindingMode]::TwoWay
    $b.UpdateSourceTrigger = [System.Windows.Data.UpdateSourceTrigger]::PropertyChanged
    [void][System.Windows.Data.BindingOperations]::SetBinding($box, [System.Windows.Controls.TextBox]::TextProperty, $b)
    Sync-Wpf

    $box.Text = 'EditedInUI'          # simulate a user edit
    Sync-Wpf
    $pushedBack = ($vm.Status -eq 'EditedInUI')

    Add-Result 'PS view-model - two-way (UI edit -> view-model)' $pushedBack "vm.Status = '$($vm.Status)' (expected 'EditedInUI')"
}
catch {
    Add-Result 'PS view-model two-way' $false "threw: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 3. ObservableCollection bound to an ItemsControl (the list / virtualization angle).
# ---------------------------------------------------------------------------
try {
    $items = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $items.Add([HostViewModel]::new('PC-01', 'Idle'))

    $ic = [System.Windows.Controls.ItemsControl]::new()
    $ic.ItemsSource = $items
    Sync-Wpf
    $count1 = $ic.Items.Count

    $items.Add([HostViewModel]::new('PC-02', 'Idle'))   # add after binding
    $items.Add([HostViewModel]::new('PC-03', 'Idle'))
    Sync-Wpf
    $count2 = $ic.Items.Count

    $items.RemoveAt(0)                                   # remove after binding
    Sync-Wpf
    $count3 = $ic.Items.Count

    $ok = ($count1 -eq 1 -and $count2 -eq 3 -and $count3 -eq 2)
    Add-Result 'ObservableCollection -> ItemsControl auto-updates' $ok "Items.Count after add/add/remove: $count1 -> $count2 -> $count3 (expected 1 -> 3 -> 2)"
}
catch {
    Add-Result 'ObservableCollection binding' $false "threw: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 4. Can the ItemsControl actually virtualize? (needs VirtualizingStackPanel panel)
# ---------------------------------------------------------------------------
try {
    $lb = [System.Windows.Controls.ListBox]::new()   # ListBox virtualizes by default
    $panelType = [System.Windows.Controls.ItemsControl].GetProperty('ItemsPanel')
    $isVirtualizingCapable = ([System.Windows.Controls.VirtualizingStackPanel]::GetIsVirtualizing($lb))
    Add-Result 'Data-bound list can virtualize (ListBox/VirtualizingStackPanel)' $isVirtualizingCapable "VirtualizingStackPanel.IsVirtualizing default = $isVirtualizingCapable"
}
catch {
    Add-Result 'Virtualization capability' $false "threw: $($_.Exception.Message)"
}

Write-Host ""
$results | Format-Table -AutoSize | Out-String | Write-Host
$fail = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
$pass = @($results | Where-Object { $_.Result -eq 'PASS' }).Count
Write-Host "Summary: $pass PASS, $fail FAIL" -ForegroundColor $(if ($fail) { 'Yellow' } else { 'Green' })
Write-Host "(FAILs are not necessarily bad - e.g. PSCustomObject 'live update' is EXPECTED to fail; that's the finding.)`n" -ForegroundColor DarkGray
