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
using module "..\..\Models\RecentConnection.psm1"
using module "..\..\Models\JobEnums.psm1"

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
#>
class InventoryPresenter {
    [AppConfig]        $Config
    [LogService]       $Logger
    [HomeViewModel]    $HomeVm
    [InventoryService] $InventoryService
    [DiskUsageService] $DiskUsageService
    [object]           $Store    # RecentConnectionsStore (shared with HomePresenter)
    [object]           $Toasts   # ToastService
    [object]           $Home     # duck-typed back-ref to HomePresenter's machine seams

    # Detail-panel + overview controls. The header/overview values are selectable TextBoxes
    # (SelectableText) so the operator can copy them; still binding-driven, no method reads them.
    [System.Windows.UIElement] $DetailEmptyHint
    [System.Windows.UIElement] $DetailContent
    [TextBox] $DetailHostText
    [TextBox] $DetailProbed
    [Button] $DetailRefreshButton
    [TextBox] $DetailLog
    [ProgressBar] $DetailProgress
    [Button] $FindFoldersButton

    # Overview tile controls (mirror the selected remote machine)
    [TextBox] $OvModel
    [TextBox] $OvModelSub
    [TextBox] $OvBattery
    [TextBox] $OvBatterySub
    [TextBox] $OvDisk
    [TextBox] $OvDiskSub
    [TextBox] $OvUpdates
    [TextBox] $OvUpdatesSub

    [hashtable] $LogBuffers   # hostname -> List[string] of accumulated job-log lines
    [int] $MaxLogLines = 2000 # ring-buffer cap for the in-memory log + detail TextBox
    # A probe fresher than this is reused instead of re-gathered (non-forced calls).
    [timespan] $InventoryTtl = [timespan]::FromMinutes(3)

    InventoryPresenter(
        [AppConfig] $config,
        [LogService] $logger,
        [HomeViewModel] $homeVm,
        [InventoryService] $inventoryService,
        [DiskUsageService] $diskUsageService,
        [object] $store,
        [object] $toasts,
        [object] $homePresenter
    ) {
        $this.Config = $config
        $this.Logger = $logger
        $this.HomeVm = $homeVm
        $this.InventoryService = $inventoryService
        $this.DiskUsageService = $diskUsageService
        $this.Store = $store
        $this.Toasts = $toasts
        $this.Home = $homePresenter
        $this.LogBuffers = @{}
    }

    # Adopts the detail-header + overview tile controls from the Home view. The detail
    # log, progress bar, and probe buttons migrate with the probe lifecycle (stage 3).
    [void] Initialize([System.Windows.FrameworkElement] $view) {
        $this.DetailEmptyHint = $view.FindName('DetailEmptyHint')
        $this.DetailContent = $view.FindName('DetailContent')
        $this.DetailHostText = $view.FindName('txtDetailHost')
        $this.DetailProbed = $view.FindName('txtDetailProbed')

        $this.OvModel = $view.FindName('txtOvModel')
        $this.OvModelSub = $view.FindName('txtOvModelSub')
        $this.OvBattery = $view.FindName('txtOvBattery')
        $this.OvBatterySub = $view.FindName('txtOvBatterySub')
        $this.OvDisk = $view.FindName('txtOvDisk')
        $this.OvDiskSub = $view.FindName('txtOvDiskSub')
        $this.OvUpdates = $view.FindName('txtOvUpdates')
        $this.OvUpdatesSub = $view.FindName('txtOvUpdatesSub')

        $this.DetailRefreshButton = $view.FindName('btnDetailRefresh')
        $this.DetailLog = $view.FindName('txtDetailLog')
        $this.DetailProgress = $view.FindName('DetailProgress')
        $this.FindFoldersButton = $view.FindName('btnFindFolders')

        $presenter = $this
        if ($this.DetailRefreshButton) {
            $this.DetailRefreshButton.Add_Click({
                    $presenter.RefreshInventory($presenter.Home.SelectedHost) }.GetNewClosure())
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

        # The folders TreeView keeps its own inner ScrollViewer, which marks the wheel handled so
        # the outer scroller never moves; re-raise the wheel to the parent so it bubbles up.
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
        }
    }

    # Selection changed: open the detail panel for the new host, or clear on deselect.
    [void] OnMachineSelectionChanged() {
        $item = if ($this.Home.MachineList) { $this.Home.MachineList.SelectedItem } else { $null }
        $this.HomeVm.SetSelected($item)
        if ($item) { $this.SelectHost([string]$item.HostName) }
        else { $this.ClearSelection() }
    }

    # Programmatic selection; the ListBox's SelectionChanged then opens the detail.
    [void] SelectMachine([string]$hostName) {
        $rowVm = $this.Home.GetRow($hostName)
        if ($rowVm -and $this.Home.MachineList) { $this.Home.MachineList.SelectedItem = $rowVm }
    }

    # Opens the detail panel (single click): renders cached inventory/folders instantly,
    # never touches the network - a fresh probe needs double-click or Refresh.
    [void] SelectHost([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $this.Home.SelectedHost = $hostName

        # Resolve now so the IP is cached before the operator gathers or hits Run.
        $this.Home.Resolution.PrefetchIp($hostName)

        $this.RenderHostLog($hostName)

        $rc = $this.Home.GetRecord($hostName)
        $cachedInv = if ($null -ne $rc) { $rc.Inventory } else { $null }
        $this.PopulateDetailCards($hostName, $cachedInv, $rc)
        # Fill the Available Updates card from the last scan's report on disk (if any), so a
        # completed/cached scan shows without re-running. Read-only: selecting never re-scans.
        [void]$this.Home.RenderUpdatesFromReport($hostName)
        # Same-instance re-applies are skipped, so re-selecting keeps the folder tree's
        # expansion state.
        $cachedDisk = if ($null -ne $rc) { $rc.DiskUsage } else { $null }
        $rowVm = $this.Home.GetRow($hostName)
        if ($rowVm) { $rowVm.ApplyFolders($cachedDisk) }

        # Reflect any known verdict now; the PrefetchIp above updates it when it lands.
        $this.Home.RenderReachability($hostName)

        # Gather, or queue behind the reachability verdict - selecting an unreachable
        # machine must never open the freeze-prone connect.
        $this.Home.StartInventory($hostName, $false)
    }

    # Clears the current selection and returns the detail pane to its empty state.
    [void] ClearSelection() {
        $this.Home.SelectedHost = $null
        $this.UpdateOverviewTiles()
    }

    # Sets the detail-header subtitle (IP + probe freshness) on the host's view-model.
    hidden [void] RenderDetailSubtitle([string]$hostName, [string]$probedIso) {
        $vm = $this.Home.GetRow($hostName)
        if ($vm) { $vm.SetProbed($this.Home.Resolver.GetCachedIp($hostName), $probedIso) }
    }

    # Syncs the host view-model's detail/overview bindables from its inventory.
    [void] PopulateDetailCards([string]$hostName, [MachineInventory]$inv, [RecentConnection]$rc) {
        $vm = $this.Home.GetRow($hostName)
        if ($null -eq $vm) { return }
        $useInv = if ($null -ne $inv) { $inv }
        elseif ($null -ne $rc) { $rc.Inventory }
        else { $null }
        if ($null -ne $useInv) { $vm.ApplyInventory($useInv) }
        $probedIso = if ($null -ne $useInv -and $useInv.ProbedAt) { $useInv.ProbedAt } else { '' }
        $vm.SetProbed($this.Home.Resolver.GetCachedIp($hostName), $probedIso)
        $vm.SetPendingUpdates($(if ($null -ne $rc) { $rc.UpdateCount } else { 0 }))
    }

    # Re-renders the overview strip (e.g. after a job changes pending-update counts).
    [void] RefreshOverview() {
        $this.UpdateOverviewTiles()
    }

    # No-op: the overview strip is fully binding-driven; kept for existing callers.
    [void] UpdateOverviewTiles() { }

    # Appends a job-output line to the host's buffer and, when selected, the detail log.
    [void] AppendLog([string]$hostName, [string]$text) {
        $this.AppendLogLines($hostName, @($text))
    }

    # A blank line between operations (e.g. a disk scan then an update scan); skipped while the
    # host's log is still empty so a run never opens with a leading blank line.
    [void] AppendSeparator([string]$hostName) {
        if ($this.LogBuffers.ContainsKey($hostName) -and $this.LogBuffers[$hostName].Count -gt 0) {
            $this.AppendLogLines($hostName, @(''))
        }
    }

    # Batched append: one AppendText + one ScrollToEnd per batch instead of per line.
    [void] AppendLogLines([string]$hostName, [string[]]$lines) {
        if ($null -eq $lines -or $lines.Count -eq 0) { return }
        if (-not $this.LogBuffers.ContainsKey($hostName)) {
            $this.LogBuffers[$hostName] = [System.Collections.Generic.List[string]]::new()
        }
        $buf = $this.LogBuffers[$hostName]
        $buf.AddRange($lines)

        # Ring-buffer cap keeps memory (and the TextBox) bounded over a long session.
        $trimmed = $false
        if ($buf.Count -gt $this.MaxLogLines) {
            $buf.RemoveRange(0, $buf.Count - $this.MaxLogLines)
            $trimmed = $true
        }

        if ($hostName -eq $this.Home.SelectedHost -and $this.DetailLog) {
            if ($trimmed) {
                # Old lines were dropped - re-render the capped buffer once.
                $this.DetailLog.Text = (($buf -join "`n") + "`n")
            }
            else {
                $this.DetailLog.AppendText((($lines -join "`n") + "`n"))
            }
            $this.DetailLog.ScrollToEnd()
        }
    }

    # Renders a host's buffered job-log into the detail log (on selection).
    [void] RenderHostLog([string]$hostName) {
        if (-not $this.DetailLog) { return }
        $this.DetailLog.Clear()
        if ($this.LogBuffers.ContainsKey($hostName)) {
            $this.DetailLog.Text = (($this.LogBuffers[$hostName]) -join "`n") + "`n"
        }
        $this.DetailLog.ScrollToEnd()
    }

    # Drops a host's buffered log (called when its card is cleared).
    [void] RemoveHostLog([string]$hostName) {
        $this.LogBuffers.Remove($hostName)
    }

    # The one driver of the terminal's progress bar for the selected host - ANY job
    # (inventory, disk scan, scan, apply): a percentage when known, else indeterminate.
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
        }
        else {
            $this.DetailProgress.IsIndeterminate = $true
        }
        $this.DetailProgress.Visibility = [System.Windows.Visibility]::Visible
    }

    # Runs the inventory probe for an online host (single-flight; non-forced calls skip
    # hosts with fresh cached inventory). HomePresenter's gate confirms reachability.
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
            $job = [AsyncJob]::new($hostName, [JobKind]::Inventory, $this.Logger)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.Home.ActiveJobs.Add($job)
        }
        catch {
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
        $rc = $this.Home.GetRecord($hostName)
        if ($null -eq $rc -or $null -eq $rc.Inventory) { return $true }
        $probed = [RecentConnectionsStore]::ParseSeen($rc.Inventory.ProbedAt)
        if ($probed -eq [datetime]::MinValue) { return $true }
        return (([datetime]::UtcNow - $probed) -gt $this.InventoryTtl)
    }

    # Inventory job finished: parse + cache + repopulate the detail cards.
    [void] CompleteInventory([AsyncJob]$job) {
        $hostName = $job.HostName
        # The card may have been cleared mid-probe; persisting now would re-create a
        # ghost recents entry - drop the result instead.
        if (-not $this.Home.Rows.ContainsKey($hostName)) { return }
        $this.ShowJobProgress($hostName, $false, 0, $false)

        if ($job.Status -eq 'Failed') {
            $this.AppendLog($hostName, "Inventory probe failed.")
            $this.Home.Resolution.InvalidateResolved($hostName)
            return
        }

        $inv = $this.InventoryService.ParseInventory($hostName)
        if ($null -eq $inv) {
            $this.AppendLog($hostName, "Inventory probe returned no data.")
            return
        }

        $this.Store.UpsertInventory($hostName, $inv)
        $this.AppendLog($hostName, "Inventory updated.")

        # Push onto the view-model: updates the detail now if selected, ready if later.
        $rc = $this.Home.GetRecord($hostName)
        $cached = if ($null -ne $rc -and $null -ne $rc.Inventory) { $rc.Inventory } else { $inv }
        $this.PopulateDetailCards($hostName, $cached, $rc)
    }

    # Queues the on-demand "biggest folders on C:" scan (single-flight). Heavy - it
    # deploys and runs WizTree - so it only runs from the button.
    [void] FindBigFolders([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        foreach ($j in $this.Home.ActiveJobs) {
            if ($j -and $j.HostName -eq $hostName -and $j.JobType -eq [JobKind]::DiskScan) {
                # A silently ignored click reads as a dead button - say so instead.
                $this.AppendLog($hostName, "A storage scan is already running for $hostName - wait for it to finish (or time out).")
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
            $job = [AsyncJob]::new($hostName, [JobKind]::DiskScan, $this.Logger)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.Home.ActiveJobs.Add($job)
        }
        catch {
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
            $this.Home.Resolution.InvalidateResolved($hostName)
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Disk scan failed. Open the log for details.") }
            return
        }

        $report = $this.DiskUsageService.ParseDiskUsage($hostName)
        if ($null -eq $report -or $report.Folders.Count -eq 0) {
            $this.AppendLog($hostName, "Disk scan returned no folders.")
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Disk scan returned no data.") }
            return
        }

        $this.Store.UpsertDiskUsage($hostName, $report)
        $this.AppendLog($hostName, "Found $($report.Folders.Count) largest folders.")
        if ($this.Toasts) { $this.Toasts.ShowSuccess($hostName, "Found $($report.Folders.Count) largest folders on C:.") }

        # Apply regardless of selection: shows now if selected, ready if selected later.
        $row = $this.Home.GetRow($hostName)
        if ($row) { $row.ApplyFolders($report) }
    }

    # Deletes the folders the operator checked in the tree (destructive - confirmed first). Only
    # deletable rows carry a checkbox and the worker re-checks each path; re-scans on completion.
    [void] DeleteSelectedFolders([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $row = $this.Home.GetRow($hostName)
        if ($null -eq $row) { return }
        $selected = @([FolderNodeViewModel]::CollectSelected($row.Folders))
        if ($selected.Count -eq 0) {
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "Check one or more folders to clear first.") }
            return
        }

        $totalBytes = [long](($selected | Measure-Object -Property SizeBytes -Sum).Sum)
        $list = @($selected | ForEach-Object { "$($_.Path)  ($($_.SizeText))" })
        $confirmed = $this.Home.DialogPresenter.ShowConfirmation(
            "Clear folder contents on $hostName",
            "Permanently clear the contents of $($selected.Count) folder(s) (~$([DiskUsageFormat]::SizeLabel($totalBytes))) on ${hostName}? The folders are kept. This runs as SYSTEM and cannot be undone.",
            $list, 'Clear', $true)
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
            $job = [AsyncJob]::new($hostName, [JobKind]::DeleteFolders, $this.Logger)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.Home.ActiveJobs.Add($job)
        }
        catch {
            $this.AppendLog($hostName, "Clear could not start: $_")
            $this.Logger.LogException("Folder clear failed to start for $hostName", $_)
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Could not start clearing folders.") }
            $this.ShowJobProgress($hostName, $false, 0, $false)
        }
    }

    # Clear job finished: report the count and re-scan so the tree reflects the freed space.
    [void] CompleteDeleteFolders([AsyncJob]$job) {
        $hostName = $job.HostName
        $this.ShowJobProgress($hostName, $false, 0, $false)
        if ($job.Status -eq 'Failed') {
            $this.AppendLog($hostName, "Clear failed.")
            $this.Home.Resolution.InvalidateResolved($hostName)
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Clearing folders failed. Open the log for details.") }
            return
        }
        $count = 0
        if ($job.Result -and $job.Result.Deleted) { $count = [int]$job.Result.Deleted }
        $this.AppendLog($hostName, "Cleared $count folder(s). Re-scanning...")
        if ($this.Toasts) { $this.Toasts.ShowSuccess($hostName, "Cleared $count folder(s) on $hostName.") }
        $this.FindBigFolders($hostName)
    }
}
