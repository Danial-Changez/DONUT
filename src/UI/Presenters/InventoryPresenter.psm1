using namespace System.Windows.Controls
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\AsyncJob.psm1"
using module "..\ViewModels\HomeViewModel.psm1"
using module "..\ViewModels\FolderNodeViewModel.psm1"
using module "..\..\Services\InventoryService.psm1"
using module "..\..\Services\DiskUsageService.psm1"
using module "..\..\Models\DiskUsage.psm1"
using module "..\..\Models\MachineInventory.psm1"
using module "..\..\Models\JobEnums.psm1"
using module "..\..\Models\PendingIntent.psm1"
using module "..\..\Models\RemoteError.psm1"
using module "..\..\Models\LogLine.psm1"
using module "..\..\Core\TimeFormat.psm1"

<#
.SYNOPSIS
    Coordinates the Home screen's per-machine detail panel: CIM inventory probe,
    storage scan, and the overview tiles.

.DESCRIPTION
    Extracted from HomePresenter to shed its detail/inventory responsibility (see
    docs/development/architecture/overview.md, "Design decisions"). It owns the
    detail-panel + overview controls and the inventory / disk-scan rendering, while
    HomePresenter keeps the shared AsyncJob pump and forwards the Inventory /
    DiskScan job kinds here.

.NOTES
    Mirrors the FinderPresenter seam: a duck-typed [object] $Home back-ref reaches
    HomePresenter's machine seams (a typed import would be a using-module cycle).
    HomePresenter still owns the reachability gate and the AsyncJob pump; it runs the
    probe here (RunInventoryProbe) once a host is online and routes the Inventory /
    DiskScan completions to CompleteInventory / CompleteDiskScan.

    The report files in reports\ are the store for per-machine scan and probe data, so
    config stays settings-only.
#>
class InventoryPresenter {
    [AppConfig]        $Config
    [LogService]       $Logger
    [HomeViewModel]    $HomeVm
    [InventoryService] $InventoryService
    [DiskUsageService] $DiskUsageService
    [object]           $Toasts   # ToastService
    [object]           $Home     # duck-typed back-ref to HomePresenter's machine seams

    # Header and overview values are selectable TextBoxes so the operator can copy them.
    [Button] $DetailRefreshButton
    [ListBox] $DetailLog
    # The collection the log ListBox renders, swapped whole on host switch or trim.
    [object] $DetailLogItems
    [ProgressBar] $DetailProgress
    [Button] $FindFoldersButton

    [hashtable] $LogBuffers   # hostname -> List[LogLine] of accumulated job-log lines
    # hostname(lower) -> DiskUsageReport, parsed once per session from the scan's CSV.
    hidden [hashtable] $DiskReports = @{}
    # hostname(lower) -> MachineInventory, parsed once per session from the probe's JSON.
    hidden [hashtable] $Inventories = @{}
    [int] $MaxLogLines = 2000 # ring-buffer cap for the in-memory log + detail ListBox
    hidden [bool] $CascadingChecks = $false   # re-entrancy guard for the folder selection cascade
    # A probe fresher than this is reused instead of re-gathered (non-forced calls).
    [timespan] $InventoryTtl = [timespan]::FromMinutes(3)

    InventoryPresenter(
        [AppConfig] $config,
        [LogService] $logger,
        [HomeViewModel] $homeVm,
        [InventoryService] $inventoryService,
        [DiskUsageService] $diskUsageService,
        [object] $toasts,
        [object] $homePresenter
    ) {
        $this.Config = $config
        $this.Logger = $logger
        $this.HomeVm = $homeVm
        $this.InventoryService = $inventoryService
        $this.DiskUsageService = $diskUsageService
        $this.Toasts = $toasts
        $this.Home = $homePresenter
        $this.LogBuffers = @{}
    }

    # Adopts the detail-header and overview controls from the Home view.
    [void] Initialize([System.Windows.FrameworkElement] $view) {

        $this.DetailRefreshButton = $view.FindName('btnDetailRefresh')
        $this.DetailLog = $view.FindName('lstDetailLog')
        $this.DetailProgress = $view.FindName('DetailProgress')
        $this.FindFoldersButton = $view.FindName('btnFindFolders')

        $presenter = $this
        if ($this.DetailRefreshButton) {
            $this.DetailRefreshButton.Add_Click({
                    $presenter.RefreshInventory($presenter.Home.SelectedHost) }.GetNewClosure())
        }
        # Per-line rendering costs cross-line drag-selection, so Copy replaces it.
        $copyLog = $view.FindName('btnCopyLog')
        if ($copyLog) {
            $copyLog.Add_Click({
                    $presenter.CopyHostLog($presenter.Home.SelectedHost) }.GetNewClosure())
        }
        if ($this.FindFoldersButton) {
            $this.FindFoldersButton.Add_Click({
                    $presenter.FindBigFolders($presenter.Home.SelectedHost) }.GetNewClosure())
        }
        $deleteFolders = $view.FindName('btnDeleteFolders')
        if ($deleteFolders) {
            $deleteFolders.Add_Click({
                    $presenter.DeleteSelectedFolders($presenter.Home.SelectedHost) }.GetNewClosure())
        }

        # The TreeView's inner ScrollViewer eats the wheel, so re-raise it to the parent.
        $folders = $view.FindName('DiskFoldersList')
        if ($folders) {
            $folders.Add_PreviewMouseWheel({
                    param($s, $e)
                    if ($e.Handled) { return }
                    $e.Handled = $true
                    $ev = [System.Windows.Input.MouseWheelEventArgs]::new($e.MouseDevice, $e.Timestamp, $e.Delta)
                    $ev.RoutedEvent = [System.Windows.UIElement]::MouseWheelEvent
                    $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($s)
                    if ($parent) { $parent.RaiseEvent($ev) }
                })
            # Tri-state cascade: a folder checkbox toggling propagates to descendants + ancestors.
            $checkHandler = [System.Windows.RoutedEventHandler] {
                param($s, $e) $presenter.OnFolderCheckToggled($e)
            }.GetNewClosure()
            $folders.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent, $checkHandler)
            $folders.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, $checkHandler)
        }
    }

    # Relays a folder checkbox toggle into the node's selection cascade (guarded against the
    # PropertyChanged echo the cascade itself raises). Pure tree logic lives on the node.
    [void] OnFolderCheckToggled([System.Windows.RoutedEventArgs]$e) {
        if ($this.CascadingChecks) { return }
        $cb = $e.OriginalSource -as [System.Windows.Controls.CheckBox]
        if ($null -eq $cb) { return }
        $node = $cb.DataContext -as [FolderNodeViewModel]
        if ($null -eq $node -or -not $node.IsDeletable) { return }
        $this.CascadingChecks = $true
        try { $node.SetChecked([bool]$cb.IsChecked) }
        finally { $this.CascadingChecks = $false }
    }

    # Selection changed: open the detail panel for the new host, or clear on deselect.
    [void] OnMachineSelectionChanged() {
        $item = if ($this.Home.MachineList) { $this.Home.MachineList.SelectedItem } else { $null }
        $this.HomeVm.SetSelected($item)
        if ($item) { $this.SelectHost([string]$item.HostName) }
        else { $this.ClearSelection() }
    }

    # Programmatic selection, so the ListBox's SelectionChanged opens the detail.
    [void] SelectMachine([string]$hostName) {
        $rowVm = $this.Home.GetRow($hostName)
        if ($rowVm -and $this.Home.MachineList) { $this.Home.MachineList.SelectedItem = $rowVm }
    }

    # Opens the detail panel (single click): renders cached inventory and folders instantly
    # and never touches the network. A fresh probe needs double-click or Refresh.
    [void] SelectHost([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $this.Home.SelectedHost = $hostName

        # Resolve now so the IP is cached before the operator gathers or hits Run.
        $this.Home.Resolution.PrefetchIp($hostName)

        $this.RenderHostLog($hostName)

        $this.PopulateDetailCards($hostName, $this.GetInventory($hostName))
        # Read-only: a cached scan report paints the Updates card without re-running it.
        [void]$this.Home.RenderUpdatesFromReport($hostName)
        # Memoized so a re-select re-applies the same instance, keeping the tree's expansion.
        $diskKey = $hostName.ToLowerInvariant()
        if (-not $this.DiskReports.ContainsKey($diskKey)) {
            $parsed = $this.DiskUsageService.ParseDiskUsage($hostName)
            if ($null -ne $parsed) { $this.DiskReports[$diskKey] = $parsed }
        }
        $rowVm = $this.Home.GetRow($hostName)
        if ($rowVm) { $rowVm.ApplyFolders($this.DiskReports[$diskKey]) }

        # Reflect any known verdict now, since the PrefetchIp above updates it when it lands.
        $this.Home.RenderReachability($hostName)

        # Queued behind the reachability verdict: an unreachable host must never be connected.
        $this.Home.StartInventory($hostName, $false)
    }

    # Clears the current selection and returns the detail pane to its empty state.
    [void] ClearSelection() {
        $this.Home.SelectedHost = $null
    }

    # The exception type dies at the runspace boundary, so re-derive the reason from the
    # message and flip offline-class rows. The next re-probe self-corrects.
    hidden [void] ReflectFailure([string]$hostName, [string]$failureMessage) {
        $reason = [RemoteFailure]::ReasonFromMessage($failureMessage)
        if ($reason -in @([RemoteFailureReason]::Offline, [RemoteFailureReason]::Unresolvable,
                [RemoteFailureReason]::ConnectionLost, [RemoteFailureReason]::TimedOut)) {
            $ip = $this.Home.Resolver.GetCachedIp($hostName)
            $this.Home.Resolver.CacheVerdict($hostName, $ip, $false)
            $this.Home.RenderReachability($hostName)
        }
        $this.Home.Resolution.InvalidateResolved($hostName)
    }

    # Syncs the host view-model's detail/overview bindables from its inventory.
    [void] PopulateDetailCards([string]$hostName, [MachineInventory]$inv) {
        $vm = $this.Home.GetRow($hostName)
        if ($null -eq $vm) { return }
        if ($null -ne $inv) { $vm.ApplyInventory($inv) }
        $vm.SetResolvedIp($this.Home.Resolver.GetCachedIp($hostName))
    }

    # The session-memoized inventory for a host: the probe's JSON in reports\
    # parsed once, refreshed in place by CompleteInventory. $null = never probed.
    [MachineInventory] GetInventory([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return $null }
        $key = $hostName.Trim().ToLowerInvariant()
        if (-not $this.Inventories.ContainsKey($key)) {
            $parsed = $this.InventoryService.ParseInventory($hostName)
            if ($null -eq $parsed) { return $null }
            $this.Inventories[$key] = $parsed
        }
        return $this.Inventories[$key]
    }

    # Appends a job-output line to the host's buffer and, when selected, the detail log.
    [void] AppendLog([string]$hostName, [string]$text) {
        $this.AppendLog($hostName, $text, [LogSeverity]::Info)
    }

    [void] AppendLog([string]$hostName, [string]$text, [LogSeverity]$severity) {
        $this.AppendLogLines($hostName, @([LogLine]::Donut($severity, $text)))
    }

    # A blank line between operations, skipped while the host's log is still empty so a
    # run never opens with a leading blank line.
    [void] AppendSeparator([string]$hostName) {
        if ($this.LogBuffers.ContainsKey($hostName) -and $this.LogBuffers[$hostName].Count -gt 0) {
            $this.AppendLogLines($hostName, @([LogLine]::Donut([LogSeverity]::Info, '')))
        }
    }

    # Batched append: buffer once, then either add the new items or re-render on trim.
    [void] AppendLogLines([string]$hostName, [LogLine[]]$lines) {
        if ($null -eq $lines -or $lines.Count -eq 0) { return }
        if (-not $this.LogBuffers.ContainsKey($hostName)) {
            $this.LogBuffers[$hostName] = [System.Collections.Generic.List[LogLine]]::new()
        }
        $buf = $this.LogBuffers[$hostName]
        $buf.AddRange($lines)

        # Ring-buffer cap keeps memory (and the ListBox) bounded over a long session.
        $trimmed = $false
        if ($buf.Count -gt $this.MaxLogLines) {
            $buf.RemoveRange(0, $buf.Count - $this.MaxLogLines)
            $trimmed = $true
        }

        if ($hostName -eq $this.Home.SelectedHost -and $this.DetailLog) {
            if ($trimmed -or $null -eq $this.DetailLogItems) {
                # Old lines were dropped, so re-render the capped buffer once.
                $this.RenderHostLog($hostName)
            } else {
                foreach ($l in $lines) { $this.DetailLogItems.Add($l) }
                $this.ScrollLogToEnd()
            }
        }
    }

    # Renders a host's buffered job-log into the detail log (on selection). A fresh
    # collection swap is one change notification instead of N per-line ones.
    [void] RenderHostLog([string]$hostName) {
        if (-not $this.DetailLog) { return }
        $items = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
        if ($this.LogBuffers.ContainsKey($hostName)) {
            foreach ($l in $this.LogBuffers[$hostName]) { $items.Add($l) }
        }
        $this.DetailLogItems = $items
        $this.DetailLog.ItemsSource = $items
        $this.ScrollLogToEnd()
    }

    hidden [void] ScrollLogToEnd() {
        if ($this.DetailLogItems -and $this.DetailLogItems.Count -gt 0) {
            $this.DetailLog.ScrollIntoView($this.DetailLogItems[$this.DetailLogItems.Count - 1])
        }
    }

    # Clipboard copy of the selected host's whole log ("[HH:mm:ss] [Tag] text" lines).
    [void] CopyHostLog([string]$hostName) {
        if (-not $hostName -or -not $this.LogBuffers.ContainsKey($hostName)) { return }
        $text = (@($this.LogBuffers[$hostName] | ForEach-Object {
                    if ($_.Stamp) { "[$($_.Stamp)] $($_.DisplayText)" } else { $_.DisplayText }
                }) -join "`n")
        try { Set-Clipboard -Value $text }
        catch { $this.Logger.LogWarning("Copy log failed: $($_.Exception.Message)") }
    }

    # Drops a host's buffered log (called when its card is cleared).
    [void] RemoveHostLog([string]$hostName) {
        $this.LogBuffers.Remove($hostName)
    }

    # The one driver of the selected host's progress bar for every job kind: a percentage
    # when known, else indeterminate.
    [void] ShowJobProgress([string]$hostName, [bool]$running, [double]$percent, [bool]$indeterminate) {
        if ($hostName -ne $this.Home.SelectedHost -or -not $this.DetailProgress) { return }
        if (-not $running) {
            $this.DetailProgress.IsIndeterminate = $false
            $this.DetailProgress.Visibility = [System.Windows.Visibility]::Collapsed
            return
        }
        if ($percent -gt 0 -and -not $indeterminate) {
            $this.DetailProgress.IsIndeterminate = $false
            $this.DetailProgress.Value = $percent
        } else {
            $this.DetailProgress.IsIndeterminate = $true
        }
        $this.DetailProgress.Visibility = [System.Windows.Visibility]::Visible
    }

    # Runs the inventory probe for an online host (single-flight, and non-forced calls skip
    # a fresh cached inventory). HomePresenter's gate confirms reachability.
    [void] RunInventoryProbe([string]$hostName, [bool]$force) {
        foreach ($j in $this.Home.ActiveJobs) {
            if ($j -and $j.HostName -eq $hostName -and
                $j.JobType -eq [JobKind]::Inventory) { return }
        }
        if (-not $force -and -not $this.InventoryIsStale($hostName)) { return }
        try {
            $this.AppendSeparator($hostName)
            $this.AppendLog($hostName, "Gathering inventory...")
            $this.ShowJobProgress($hostName, $true, 0, $true)
            $prep = $this.InventoryService.PrepareInventory($hostName)
            $this.Home.AttachResolvedIp($prep, $hostName)
            $this.Home.StartJob([AsyncJob]::new($hostName, [JobKind]::Inventory, $this.Logger), $prep)
        } catch {
            $this.AppendLog($hostName, "Inventory probe could not start: $_")
            $this.ShowJobProgress($hostName, $false, 0, $false)
        }
    }

    # Forces a re-probe of the selected host (detail-panel Refresh).
    [void] RefreshInventory([string]$hostName) {
        $this.Home.MoveRowToTop($hostName)
        $this.Home.StartInventory($hostName)
    }

    # True when a host has no cached inventory or its last probe is older than the TTL.
    [bool] InventoryIsStale([string]$hostName) {
        $inv = $this.GetInventory($hostName)
        if ($null -eq $inv) { return $true }
        $probed = [TimeFormat]::ParseIso($inv.ProbedAt)
        if ($probed -eq [datetime]::MinValue) { return $true }
        return (([datetime]::UtcNow - $probed) -gt $this.InventoryTtl)
    }

    # Inventory job finished: parse + memoize + repopulate the detail cards.
    [void] CompleteInventory([AsyncJob]$job) {
        $hostName = $job.HostName
        # The card may have been cleared mid-probe, leaving nothing to paint.
        if (-not $this.Home.Rows.ContainsKey($hostName)) { return }
        $this.ShowJobProgress($hostName, $false, 0, $false)

        if ($job.Status -eq 'Failed') {
            $this.AppendLog($hostName, "Inventory probe failed.")
            $this.ReflectFailure($hostName, $job.FailureMessage)
            return
        }

        $inv = $this.InventoryService.ParseInventory($hostName)
        if ($null -eq $inv) {
            $this.AppendLog($hostName, "Inventory probe returned no data.")
            return
        }

        $this.Inventories[$hostName.Trim().ToLowerInvariant()] = $inv
        $this.AppendLog($hostName, "Inventory updated.")

        # Push onto the view-model: updates the detail now if selected, ready if later.
        $this.PopulateDetailCards($hostName, $inv)
    }

    # Re-runs a storage scan that asked for elevation, once the restart has provided it.
    [void] ResumeDiskScan([string[]]$hosts) {
        foreach ($h in $hosts) { $this.FindBigFolders($h) }
    }

    # Queues the on-demand "biggest folders on C:" scan (single-flight). It deploys and
    # runs WizTree, so it is button-only rather than automatic.
    [void] FindBigFolders([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        if (-not $this.Home.RequireElevation([GatedAction]::DiskScan, @($hostName), 'A storage scan')) { return }
        foreach ($j in $this.Home.ActiveJobs) {
            if ($j -and $j.HostName -eq $hostName -and $j.JobType -eq [JobKind]::DiskScan) {
                # A silently ignored click reads as a dead button, so say so instead.
                $this.AppendLog($hostName,
                    "A storage scan is already running for $hostName - wait for it to finish (or time out).")
                return
            }
        }
        $this.Home.MoveRowToTop($hostName)
        try {
            $this.AppendSeparator($hostName)
            $this.AppendLog($hostName, "Scanning C: for largest folders...")
            $this.ShowJobProgress($hostName, $true, 0, $true)
            $prep = $this.DiskUsageService.PrepareDiskScan($hostName)
            $this.Home.AttachResolvedIp($prep, $hostName)
            $this.Home.StartJob([AsyncJob]::new($hostName, [JobKind]::DiskScan, $this.Logger), $prep)
        } catch {
            $this.AppendLog($hostName, "Disk scan could not start: $_")
            $this.Logger.LogException("Disk scan failed to start for $hostName", $_)
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Could not start disk scan.") }
            $this.ShowJobProgress($hostName, $false, 0, $false)
        }
    }

    # Disk-scan job finished: parse the WizTree CSV + cache + render the folder list.
    [void] CompleteDiskScan([AsyncJob]$job) {
        $hostName = $job.HostName
        $this.ShowJobProgress($hostName, $false, 0, $false)

        if ($job.Status -eq 'Failed') {
            $this.AppendLog($hostName, "Disk scan failed.")
            $this.ReflectFailure($hostName, $job.FailureMessage)
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Disk scan failed. Open the log for details.") }
            return
        }

        $report = $this.DiskUsageService.ParseDiskUsage($hostName)
        if ($null -eq $report -or $report.Folders.Count -eq 0) {
            $this.AppendLog($hostName, "Disk scan returned no folders.")
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Disk scan returned no data.") }
            return
        }

        $this.DiskReports[$hostName.ToLowerInvariant()] = $report
        $this.AppendLog($hostName, "Found $($report.Folders.Count) largest folders.")
        if ($this.Toasts) {
            $this.Toasts.ShowSuccess($hostName, "Found the $($report.Folders.Count) largest folders on C:.")
        }

        # Apply regardless of selection: shows now if selected, ready if selected later.
        $row = $this.Home.GetRow($hostName)
        if ($row) { $row.ApplyFolders($report) }
    }

    # Deletes the folders the operator checked in the tree. Destructive, so it confirms first,
    # only deletable rows carry a checkbox, and the worker re-checks every path.
    [void] DeleteSelectedFolders([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        # Not resumed after elevating: the folder selection lives here, so the user re-picks.
        if (-not $this.Home.RequireElevation([GatedAction]::DeleteFolders, @($hostName), 'Clearing folders')) { return }
        $row = $this.Home.GetRow($hostName)
        if ($null -eq $row) { return }
        $selected = @([FolderNodeViewModel]::CollectSelected($row.Folders))
        if ($selected.Count -eq 0) {
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "Check at least one folder to clear.") }
            return
        }

        $totalBytes = [long](($selected | Measure-Object -Property SizeBytes -Sum).Sum)
        $list = @($selected | ForEach-Object { [pscustomobject]@{ Left = $_.Path; Right = "($($_.SizeText))" } })
        $sizeLabel = [DiskUsageFormat]::SizeLabel($totalBytes)
        $confirmed = $this.Home.DialogPresenter.ShowConfirmation(
            "Clear Folder Contents on $hostName",
            "Permanently clear the contents of $($selected.Count) folder(s) (~$sizeLabel) on ${hostName}. " +
            "The folders are kept. Runs as SYSTEM and cannot be undone.",
            $list,
            'Clear',
            $true)
        if (-not $confirmed) {
            $this.AppendLog($hostName, "Clear cancelled.")
            return
        }

        try {
            $this.AppendSeparator($hostName)
            $this.AppendLog($hostName, "Clearing $($selected.Count) folder(s)...")
            $this.ShowJobProgress($hostName, $true, 0, $true)
            $paths = @($selected | ForEach-Object { $_.Path })
            $prep = $this.DiskUsageService.PrepareDeleteFolders($hostName, $paths)
            $this.Home.AttachResolvedIp($prep, $hostName)
            $this.Home.StartJob([AsyncJob]::new($hostName, [JobKind]::DeleteFolders, $this.Logger), $prep)
        } catch {
            $this.AppendLog($hostName, "Clear could not start: $_")
            $this.Logger.LogException("Folder clear failed to start for $hostName", $_)
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Could not start the clear.") }
            $this.ShowJobProgress($hostName, $false, 0, $false)
        }
    }

    # Clear job finished: report the count and re-scan so the tree reflects the freed space.
    [void] CompleteDeleteFolders([AsyncJob]$job) {
        $hostName = $job.HostName
        $this.ShowJobProgress($hostName, $false, 0, $false)
        if ($job.Status -eq 'Failed') {
            $this.AppendLog($hostName, "Clear failed.")
            $this.ReflectFailure($hostName, $job.FailureMessage)
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Clear failed. Open the log for details.") }
            return
        }
        $count = 0
        if ($job.Result -and $job.Result.Deleted) { $count = [int]$job.Result.Deleted }
        $this.AppendLog($hostName, "Cleared $count folder(s). Re-scanning...")
        if ($this.Toasts) { $this.Toasts.ShowSuccess($hostName, "Cleared $count folder(s).") }
        $this.FindBigFolders($hostName)
    }
}
