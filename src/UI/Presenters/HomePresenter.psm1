using namespace System.Windows.Controls
using namespace System.Windows.Shapes
using namespace System.Windows.Threading
using namespace System.Collections.Generic
using namespace Donut.Mvvm
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Models\FleetCardStatus.psm1"
using module "..\..\Models\DcuProgress.psm1"
using module "..\..\Models\RecentConnection.psm1"
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\HostListSource.psm1"
using module "..\..\Services\RemoteServices.psm1"
using module "..\..\Services\DriverMatchingService.psm1"
using module "..\..\Services\SystemInfoService.psm1"
using module ".\DialogPresenter.psm1"
using module ".\ToastService.psm1"
using module "..\ViewModels\HostViewModel.psm1"
using module "..\ViewModels\HomeViewModel.psm1"
using module ".\FinderPresenter.psm1"
using module ".\InventoryPresenter.psm1"
using module ".\ResolutionCoordinator.psm1"
using module ".\AsyncJobPresenter.psm1"
using module "..\..\Services\ResourceService.psm1"
using module "..\..\Services\InventoryService.psm1"
using module "..\..\Services\DiskUsageService.psm1"
using module "..\..\Services\HostResolver.psm1"
using module "..\..\Models\MachineInventory.psm1"
using module "..\..\Models\DiskUsage.psm1"
using module "..\..\Models\JobEnums.psm1"
using module "..\..\Core\TimeFormat.psm1"
using module "..\..\Core\RunspaceManager.psm1"
using module "..\..\Models\ScanCacheDecision.psm1"
using module "..\..\Models\RemoteError.psm1"

<#
.SYNOPSIS
    Presenter for the Home screen: machine list and per-machine detail.

.DESCRIPTION
    Owns the machine list (a HostViewModel per host in HomeViewModel.Machines, bound to a
    virtualizing ListBox, seeded from recents, and kept newest-action-first: an Add /
    Run / gather / storage scan moves that card to the top), the
    Add / Run / Run-all flow (the mode pill selects Scan vs. Apply), and the
    per-machine job lifecycle (extends AsyncJobPresenter's PumpJobs). On select it
    prefetches the host IP (HostResolver) and inventory (InventoryService) and
    renders the detail cards; Storage scan runs DiskUsageService on demand. A scan
    from the last 24h is reused (ScanCacheDecision) instead of re-scanning. The
    search bar's live AD finder + user Lens are delegated to FinderPresenter, which
    calls back into the machine seams (PrefetchIp, EnsureRow, StartInventory,
    MoveRowToTop, UpdateEmptyHint) via a duck-typed reference.

.NOTES
    Must never block the STA UI thread: all remote work is queued as AsyncJobs on
    the pre-warmed runspace pool and polled on a DispatcherTimer. Event-handler
    scriptblocks capture $self/$presenter, since in a WPF handler $this rebinds to
    the sender.

    Reachability gating: remote work only starts on a FRESH 'Online' verdict from
    HostResolver. An offline host is skipped with a reason; an unknown or stale
    verdict queues the run/gather (PendingRuns / PendingGathers) behind a
    background re-resolve, and CompleteResolve starts or drops the queued work
    when the verdict lands. This keeps the freeze-prone, unbounded CIM/psexec
    connect - and the expensive on-worker AD resolve - away from unreachable hosts.

    Cold-loading the worker module graph takes the process-wide CLR loader lock;
    if that happens while the dispatcher is rendering, the UI freezes. WarmPool
    therefore blocks during startup, before the message loop exists, to take that
    hit at the only safe time.
#>
class HomePresenter : AsyncJobPresenter {
    [AppConfig] $Config
    [object] $ConfigManager           # duck-typed; used to persist recents
    [System.Windows.FrameworkElement] $ViewContent
    [TextBox] $SearchBar
    [Button] $SearchButton
    [Button] $ClearButton
    [Button] $RunAllButton
    [ListBox] $MachineList
    [HomeViewModel] $HomeVm        # bound to HomeView.DataContext (Machines + SelectedMachine)
    [System.Windows.UIElement] $EmptyHint
    [TextBlock] $ModePill
    [Button] $ModeButton
    [ScanService] $ScanService
    [RemoteUpdateService] $UpdateService
    [DialogPresenter] $DialogPresenter
    [ToastService] $Toasts
    [NetworkProbe] $NetworkProbe
    [LogService] $Logger
    [DriverMatchingService] $DriverMatcher
    [RecentConnectionsStore] $Store
    [HostListSource] $HostListSource
    [InventoryService] $InventoryService
    [DiskUsageService] $DiskUsageService
    [HostResolver] $Resolver
    # Reuse a scan/update-scan newer than this instead of re-scanning.
    [timespan] $ScanCacheTtl = [timespan]::FromHours(24)
    [string] $SelectedHost

    # Search-bar AD finder + user Lens; holds a duck-typed back-ref to the machine seams.
    [FinderPresenter] $Finder
    # Per-machine detail panel (inventory + storage scan); split stage 1 (scaffold).
    [InventoryPresenter] $Detail
    # Host resolution: DC/runspace warm, IP pre-resolve, identity check, Resolve-job
    # completion. Owns the Resolve lifecycle over the shared Resolver; pump stays here.
    [ResolutionCoordinator] $Resolution
    [System.Windows.Window] $HostWindow    # parent window; hooked so the popup tracks moves/resizes

    # Async state ($ActiveJobs is inherited from AsyncJobPresenter)
    [DispatcherTimer] $Timer
    [DispatcherTimer] $IdleRefreshTimer   # advances idle rows' relative times every 30s

    # Host name -> HostViewModel (same instances live in $Vm.Machines)
    [hashtable] $Rows

    # Hosts that still need a manual reboot after an apply
    [System.Collections.Generic.List[string]] $ManualRebootQueue
    [int] $TotalJobsInBatch

    # Runs queued behind a reachability re-check (see .NOTES); CompleteResolve starts
    # or drops them - never left queued silently.
    hidden [hashtable] $PendingRuns = @{}

    # Gathers queued the same way; value = strongest $force flag seen while queued.
    hidden [hashtable] $PendingGathers = @{}

    # Highest scan milestone per host (1..5); ratcheted so a re-emitted earlier line
    # can't step backwards. Reset at job start.
    hidden [hashtable] $ScanSteps = @{}

    HomePresenter(
        [AppConfig] $config,
        [System.Windows.FrameworkElement] $view,
        [NetworkProbe] $networkProbe,
        [ResourceService] $resources,
        [ToastService] $toasts,
        [object] $configManager
    ) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.ViewContent = $view
        $this.Toasts = $toasts

        $this.NetworkProbe = $networkProbe
        $this.Logger = $networkProbe.Logger
        $this.ScanService = [ScanService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.DriverMatcher = [DriverMatchingService]::new($this.Logger)
        $this.UpdateService = [RemoteUpdateService]::new(
            $config, $this.NetworkProbe, $this.DriverMatcher, $this.Logger)
        $this.DialogPresenter = [DialogPresenter]::new($resources)
        $this.Store = [RecentConnectionsStore]::new($config, $configManager)
        # Coalesce config.json writes: mutations mark pending, flushed once per drained batch.
        $this.Store.DeferSave = $true
        $this.HostListSource = [HostListSource]::new($config.SourceRoot)
        $this.InventoryService = [InventoryService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.DiskUsageService = [DiskUsageService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.Resolver = [HostResolver]::new($config, $this.NetworkProbe, $this.Logger)

        $this.Rows = @{}
        $this.HomeVm = [HomeViewModel]::new()   # bound to the view; owns the machine collection
        $this.ManualRebootQueue = [List[string]]::new()
        $this.TotalJobsInBatch = 0

        $presenter = $this
        $this.Timer = [DispatcherTimer]::new()
        $this.Timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $this.Timer.Add_Tick({ $presenter.OnTimerTick($this, $null) }.GetNewClosure())
        $this.Timer.Start()

        # Advance idle rows' relative times ("just now" -> "1 min ago").
        $this.IdleRefreshTimer = [DispatcherTimer]::new()
        $this.IdleRefreshTimer.Interval = [TimeSpan]::FromSeconds(30)
        $this.IdleRefreshTimer.Add_Tick({ $presenter.RefreshIdleTimes() }.GetNewClosure())
        $this.IdleRefreshTimer.Start()

        $this.Finder = [FinderPresenter]::new(
            $config, $view, $this.HomeVm, $this.Logger, $toasts, $this.DialogPresenter, $this)

        # Split stage 1: the detail/inventory coordinator is constructed and wired, but
        # still inert - HomePresenter owns the detail controls + methods until later stages.
        $this.Detail = [InventoryPresenter]::new(
            $config, $this.Logger, $this.HomeVm, $this.InventoryService,
            $this.DiskUsageService, $this.Store, $this.Toasts, $this)

        # Split scaffold: the resolution coordinator is constructed and wired, but still
        # inert - HomePresenter owns the resolve methods until the next stages move them.
        $this.Resolution = [ResolutionCoordinator]::new(
            $config, $this.Logger, $this.ConfigManager, $this.Toasts, $this.Resolver, $this)

        $this.Initialize()
        $this.Detail.Initialize($this.ViewContent)
    }

    [void] Initialize() {
        $this.SearchBar = $this.ViewContent.FindName('GoogleSearchBar')
        $this.SearchButton = $this.ViewContent.FindName('btnSearch')
        $this.ClearButton = $this.ViewContent.FindName('btnClearTabs')
        $this.RunAllButton = $this.ViewContent.FindName('btnRunAll')
        $this.MachineList = $this.ViewContent.FindName('MachineList')
        $this.EmptyHint = $this.ViewContent.FindName('FleetEmptyHint')
        $this.ModePill = $this.ViewContent.FindName('txtMode')
        $this.ModeButton = $this.ViewContent.FindName('btnMode')

        # The detail panel (header, log, progress, probe buttons) is owned by
        # InventoryPresenter and wired in its own Initialize.
        $presenter = $this

        $this.ViewContent.DataContext = $this.HomeVm
        if ($this.MachineList) {
            $this.MachineList.Add_SelectionChanged({
                    $presenter.Detail.OnMachineSelectionChanged() }.GetNewClosure())
        }

        if ($this.SearchButton) {
            $this.SearchButton.Add_Click({ $presenter.OnSearch() }.GetNewClosure())
        }
        if ($this.ClearButton) {
            $this.ClearButton.Add_Click({ $presenter.ClearCompleted() }.GetNewClosure())
        }
        if ($this.RunAllButton) {
            $this.RunAllButton.Add_Click({ $presenter.RunAll() }.GetNewClosure())
        }
        if ($this.ModeButton) {
            $this.ModeButton.Add_Click({ $presenter.CycleMode() }.GetNewClosure())
        }
        $this.Finder.Initialize()

        # A WPF Popup is its own top-level window and does not follow the parent; hook
        # the host window so the dropdown stays glued to the search box.
        $this.ViewContent.Add_Loaded({ $presenter.HookHostWindow() }.GetNewClosure())

        # Seed recents from WSID.txt the first time, then build a row per recent.
        if ($this.Store.Count() -eq 0) {
            $this.Store.SeedFrom($this.ReadWsidHosts())
        }
        $this.BuildRows()
        $this.Store.FlushSave()   # persist the one-time WSID seed (saves are deferred)

        $this.UpdateModePill()
        $this.RefreshAll()

        # Seed the DC from the last run so the very first selects resolve immediately;
        # the background warm refreshes it (a stale DC just falls back).
        $savedDc = [string]$this.Config.Settings['activeDomainController']
        if (-not [string]::IsNullOrWhiteSpace($savedDc)) { $this.Resolver.SetActiveDc($savedDc) }

        # Warm the pool synchronously before the message loop starts - the one safe
        # time to take the loader-lock hit (see .NOTES).
        $this.Resolution.WarmPool()

        # Prime the finder + Lens agent in the background (non-blocking, unlike WarmPool).
        $this.Finder.WarmAdSearch()
        $this.Finder.WarmLens()

        $this.Resolution.StartWarm()
    }

    # --- Start-early IP resolution ---

    # A resolve verdict landed for a host (owned by ResolutionCoordinator): re-issue any
    # gather / run queued behind the re-check. The PendingRuns / PendingGathers queue is
    # owned here because the run / gather flows write it.
    [void] ReissueAfterResolve([string]$hostName, [bool]$online) {
        if ($this.PendingGathers.ContainsKey($hostName)) {
            $gatherForce = [bool]$this.PendingGathers[$hostName]
            $this.PendingGathers.Remove($hostName)
            $this.StartInventory($hostName, $gatherForce)
        }
        if ($this.PendingRuns.ContainsKey($hostName)) {
            $this.PendingRuns.Remove($hostName)
            if ($online) {
                $this.StartProcess($hostName)
            }
            else {
                $this.Detail.AppendLog($hostName, "Host is offline - queued run skipped.")
                if ($this.Toasts) { $this.Toasts.ShowWarning($hostName, "$hostName is offline - run skipped.") }
            }
        }
    }

    # A resolve failed for a host: a queued run can't proceed without a verdict, so drop
    # it with a reason (called by ResolutionCoordinator.CompleteResolve).
    [void] DropPendingRunOnResolveFailure([string]$hostName) {
        if ($this.PendingRuns.ContainsKey($hostName)) {
            $this.PendingRuns.Remove($hostName)
            $this.Detail.AppendLog($hostName, "Run not started: could not verify reachability (resolve failed).")
            if ($this.Toasts) { $this.Toasts.ShowWarning($hostName, "Run not started - could not verify $hostName is reachable.") }
        }
    }

    # Reflects a host's cached online/offline verdict on its idle row. No row update
    # while a job is running (live status owns the dot/subtitle then).
    [void] RenderReachability([string]$hostName) {
        $state = $this.Resolver.IsHostOnline($hostName)
        $row = $this.GetRow($hostName)
        if ($row -and -not $this.IsRunning($hostName)) { $row.SetReachability($state) }
    }

    # Threads the prefetched IP into a worker-args bundle so the worker skips DNS.
    # No-op when the IP isn't cached yet.
    hidden [void] AttachResolvedIp([hashtable]$prep, [string]$hostName) {
        $ip = $this.Resolver.GetCachedIp($hostName)
        if ([string]::IsNullOrWhiteSpace($ip)) { return }
        # Dedicated argument, not an Options key - Options merge into dcu-cli args,
        # and DCU rejects a bogus -ResolvedIp=<ip> with 105.
        if ($prep -and $prep.Arguments) {
            $prep.Arguments.ResolvedIp = $ip
        }
    }

    # Only the mode pill reflects the active command; the Add button is static.
    [void] UpdateModePill() {
        $command = $this.Config.GetActiveCommand()
        $label = if ($command -eq 'applyUpdates') { "Apply Updates" } else { "Scan" }
        if ($this.ModePill) { $this.ModePill.Text = $label }
    }

    # Cycles the active command (Scan <-> Apply Updates), persists it, refreshes labels.
    [void] CycleMode() {
        $next = if ($this.Config.GetActiveCommand() -eq 'scan') { 'applyUpdates' } else { 'scan' }
        $this.Config.SetActiveCommand($next)
        if ($null -ne $this.ConfigManager) { $this.ConfigManager.SaveConfig($this.Config) }
        $this.UpdateModePill()
    }

    # Backwards-compatible name used by MainPresenter on navigation.
    [void] UpdateSearchButtonLabel() {
        $this.UpdateModePill()
    }

    [string[]] ReadWsidHosts() {
        return $this.HostListSource.ReadHosts()
    }

    # Builds an idle row for every persisted recent connection (newest first).
    [void] BuildRows() {
        foreach ($rc in $this.Store.GetAll()) {
            $vm = $this.EnsureRow($rc.Hostname)
            $vm.ApplyIdle($rc)
        }
        $this.UpdateEmptyHint()
    }

    # "Add": queue the typed host(s) into the machine list and gather inventory.
    # Never scans/applies - running the active command is a separate, deliberate step.
    [void] OnSearch() {
        $rawInput = $this.SearchBar.Text
        if ([string]::IsNullOrWhiteSpace($rawInput)) { return }

        $targetHosts = $rawInput -split "[\r\n,]+" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }

        if ($targetHosts.Count -eq 0) { return }

        foreach ($hostName in $targetHosts) {
            $this.EnsureRow($hostName)
            $this.Resolution.PrefetchIp($hostName)        # resolve now so the row shows online/offline on Add
            $this.StartInventory($hostName, $true)
        }
        # Newest on top; moved in reverse so the first typed host ends up topmost.
        $ordered = @($targetHosts)
        [array]::Reverse($ordered)
        foreach ($hostName in $ordered) { $this.MoveRowToTop($hostName) }
        $this.Detail.SelectMachine($targetHosts[0])
        $this.UpdateEmptyHint()

        $this.SearchBar.Text = ""
    }

    # "Run all": run the active command on every idle machine. One confirmation for
    # the whole batch; per-host runs still go through StartProcess.
    [void] RunAll() {
        $idleHosts = @($this.Store.GetAll() | ForEach-Object { $_.Hostname } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $this.IsRunning($_) })
        if ($idleHosts.Count -eq 0) { return }

        $command = $this.Config.GetActiveCommand()
        if ($command -eq 'applyUpdates') {
            $confirmed = $this.DialogPresenter.ShowConfirmation(
                "Confirm Apply Updates",
                "You are about to apply updates to $($idleHosts.Count) computer(s).",
                $idleHosts
            )
            if (-not $confirmed) { return }
        }

        $this.ManualRebootQueue.Clear()
        $this.TotalJobsInBatch = $idleHosts.Count
        foreach ($hostName in $idleHosts) {
            $this.StartProcess($hostName)
        }
    }

    # Subscribes once to the parent window's move/resize so an open search popup
    # stays positioned under the search box.
    [void] HookHostWindow() {
        if ($null -ne $this.HostWindow) { return }
        $w = [System.Windows.Window]::GetWindow($this.ViewContent)
        if ($null -eq $w) { return }
        $this.HostWindow = $w
        $presenter = $this
        $w.Add_LocationChanged({ $presenter.Finder.RepositionSearchPopup() }.GetNewClosure())
        $w.Add_SizeChanged({ $presenter.Finder.RepositionSearchPopup() }.GetNewClosure())
        # On close: flush deferred recents, stop the Lens agent, purge its exchange dirs.
        $w.Add_Closing({
                try { $presenter.Store.FlushSave() } catch { }
                try { $presenter.Finder.OnAppClosing() } catch { }
            }.GetNewClosure())
    }

    # Runs a single host from a row click; confirms first when destructive.
    [void] RunHost([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        if ($this.IsRunning($hostName)) {
            # A storage scan also holds the row busy; a silent return reads as a dead button.
            $this.Detail.AppendLog($hostName, "A job is already running for $hostName - wait for it to finish.")
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "Already running - wait for the current job to finish.") }
            return
        }

        if ($this.Config.GetActiveCommand() -eq 'applyUpdates') {
            $confirmed = $this.DialogPresenter.ShowConfirmation(
                "Confirm Apply Updates",
                "Apply updates to $hostName now?",
                @($hostName)
            )
            if (-not $confirmed) { return }
        }
        $this.MoveRowToTop($hostName)
        $this.StartProcess($hostName)
    }

    [bool] IsRunning([string]$hostName) {
        foreach ($job in $this.ActiveJobs) {
            # Inventory probes and IP pre-resolves are background work, not a "run".
            if ($job -and $job.HostName -eq $hostName -and
                $job.JobType -ne [JobKind]::Inventory -and
                $job.JobType -ne [JobKind]::Resolve) { return $true }
        }
        return $false
    }

    # True when the host's last scan can be reused instead of re-scanning; wires the
    # recents fields + on-disk report to the pure ScanCacheDecision rule.
    [bool] RecentScanIsFresh([string]$hostName) {
        $rc = $this.GetRecord($hostName)
        if ($null -eq $rc) { return $false }
        return [ScanCacheDecision]::IsFresh(
            $rc.LastJobType,
            [RecentConnectionsStore]::ParseSeen($rc.LastSeen),
            [datetime]::UtcNow,
            $this.ScanCacheTtl,
            ($null -ne $this.UpdateService.ParseUpdateReport($hostName)))
    }

    [void] StartProcess([string]$hostName) {
        $row = $this.EnsureRow($hostName)
        $command = $this.Config.GetActiveCommand()

        # Never scan/apply an offline or unresolved host (reachability gating, .NOTES).
        $reach = $this.Resolver.IsHostOnline($hostName)
        if ($reach -eq 'Offline') {
            $this.Detail.AppendLog($hostName, "Host is offline - skipping $command.")
            if ($this.Toasts) { $this.Toasts.ShowWarning($hostName, "$hostName is offline - skipped.") }
            if ($row) { $row.SetReachability('Offline') }
            return
        }
        if ($reach -ne 'Online' -or $this.Resolver.IsVerdictStale($hostName)) {
            # Unknown or stale verdict: re-verify off-thread and queue the run;
            # CompleteResolve starts it once the fresh verdict lands.
            if (-not $this.Resolver.HasActiveDc()) {
                # No DC yet means a resolve can't run - don't queue (it would sit forever).
                $this.Detail.AppendLog($hostName, "Resolver not ready yet (no domain controller) - try again shortly.")
                return
            }
            $this.PendingRuns[$hostName] = $true
            $this.Resolution.PrefetchIp($hostName)
            $this.Detail.AppendLog($hostName, "Verifying $hostName is reachable - the run starts automatically once confirmed.")
            return
        }

        # Reuse a scan from the last 24h. A successful apply flips the host's last job
        # to UpdateApply, so the next run re-scans (the intended bypass).
        if (($command -eq 'scan' -or $command -eq 'applyUpdates') -and
            $this.RecentScanIsFresh($hostName)) {
            $rc = $this.GetRecord($hostName)
            $age = [TimeFormat]::Relative([RecentConnectionsStore]::ParseSeen($rc.LastSeen))
            if ($command -eq 'applyUpdates') {
                $this.Detail.AppendLog($hostName, "Reusing scan from $age (under 24h); skipping re-scan.")
                $this.ProceedWithApply($hostName)
            }
            else {
                $this.Detail.AppendLog($hostName, "Scanned $age - results are current; skipping re-scan.")
                if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "Scanned $age - results are current.") }
                $this.Detail.RefreshOverview()
            }
            return
        }

        $this.Detail.AppendLog($hostName, "Starting $command for $hostName...")
        $this.ScanSteps.Remove($hostName)   # fresh job, fresh step ratchet

        try {
            $jobParams = switch ($command) {
                'scan' {
                    @{ Type = 'Scan'; Prep = $this.ScanService.PrepareScan($hostName) }
                }
                'applyUpdates' {
                    $this.Detail.AppendLog($hostName, "Phase 1: Scanning for updates...")
                    @{
                        Type = 'UpdateScan'
                        Prep = $this.UpdateService.PrepareScanForUpdates($hostName)
                    }
                }
                default {
                    $this.Detail.AppendLog($hostName, "Command '$command' not implemented yet.")
                    $null
                }
            }

            if ($jobParams) {
                $this.AttachResolvedIp($jobParams.Prep, $hostName)
                $job = [AsyncJob]::new($hostName, $jobParams.Type)
                $job.Start($jobParams.Prep.ScriptPath, $jobParams.Prep.Arguments,
                    $jobParams.Prep.TempConfigPath)
                $this.ActiveJobs.Add($job)
                $this.RefreshCardStatus($job)
                $this.Detail.RefreshOverview()
                # Apply is destructive: run the identity check in parallel to gate it.
                if ($command -eq 'applyUpdates') { $this.Resolution.StartVerifyName($hostName) }
            }
        }
        catch {
            $this.Detail.AppendLog($hostName, "Error starting process: $_")
            $row.ApplyStatus([FleetCardStatus]::FromJob('Scan', 'Failed', $false))
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Failed to start: $_") }
        }
    }

    # Drives the shared job-polling lifecycle (AsyncJobPresenter) each timer tick.
    # Handler-shaped signature; both arguments are unused.
    [void] OnTimerTick($timerSource, $tickArgs) {
        try {
            $this.PumpJobs()
        }
        catch {
            $this.Logger.LogException("Error during job pump", $_)
        }
    }

    # Per-tick: stream the job's queued output into the detail log and keep the row
    # status/progress live. Inventory probes only stream.
    [void] OnJobPolled([AsyncJob]$job) {
        # Resolve jobs are pure background precompute - no row/progress/log UI.
        if ($job.JobType -eq [JobKind]::Resolve) { return }

        # Drain this tick's output once; append as one batch.
        $lines = [System.Collections.Generic.List[string]]::new()
        $line = $null
        while ($job.Logs.TryDequeue([ref]$line)) { $lines.Add($line) }

        if ($job.JobType -eq [JobKind]::Inventory -or $job.JobType -eq [JobKind]::DiskScan) {
            if ($lines.Count -gt 0) { $this.Detail.AppendLogLines($job.HostName, $lines.ToArray()) }
            return
        }

        $latestPct = -1
        $latestStep = 0
        foreach ($entry in $lines) {
            $pct = [DcuProgress]::ParsePercent($entry)
            if ($pct -ge 0) { $latestPct = $pct }
            $step = [DcuProgress]::ParseScanStep($entry)
            if ($step -gt $latestStep) { $latestStep = $step }
        }
        if ($lines.Count -gt 0) { $this.Detail.AppendLogLines($job.HostName, $lines.ToArray()) }

        $row = $this.GetRow($job.HostName)
        if ($row -and $latestPct -ge 0) { $row.SetPercent($latestPct) }

        # Scan milestones -> "N/5 label", ratcheted per host. Scans drive the bar from
        # the step; an apply's own percent lines own the bar (-1).
        $prev = [int]$this.ScanSteps[$job.HostName]   # missing key -> $null -> 0
        if ($row -and $latestStep -gt $prev) {
            $this.ScanSteps[$job.HostName] = $latestStep
            $label = [DcuProgress]::ScanStepLabel($latestStep)
            $stepPct = if ($job.JobType -eq 'UpdateApply') { -1 }
            else { $latestStep * 100.0 / [DcuProgress]::ScanStepCount }
            $row.SetScanStep("$latestStep/$([DcuProgress]::ScanStepCount) $label", $stepPct)
        }

        $this.RefreshCardStatus($job)
    }

    # Terminal per-job step: dispatch to the Complete* handler for background kinds;
    # scan/apply do driver-match analysis, apply transition, and recents persistence.
    [void] OnJobCompleted([AsyncJob]$job) {
        if ($job.JobType -eq [JobKind]::Resolve) {
            $this.Resolution.CompleteResolve($job)
            return
        }
        if ($job.JobType -eq [JobKind]::Inventory) {
            $this.Detail.CompleteInventory($job)
            return
        }
        if ($job.JobType -eq [JobKind]::DiskScan) {
            $this.Detail.CompleteDiskScan($job)
            return
        }

        # No end-of-job log dump: the worker already live-tailed dcu-cli's output, and
        # a dump would replay a stale previous-run file after a failed job.
        $this.Detail.AppendLog($job.HostName, "Job $($job.JobType) finished: $($job.Status)")

        $transitioned = $false
        if ($job.Status -eq 'Completed' -and $job.JobType -eq 'UpdateScan') {
            $transitioned = $this.ProceedWithApply($job.HostName)
        }

        if ($job.JobType -eq 'UpdateApply' -and $job.Status -eq 'Completed') {
            $this.CheckForManualReboot($job)
            if ($this.Toasts) {
                if ($this.ManualRebootQueue.Contains($job.HostName)) {
                    $this.Toasts.ShowWarning($job.HostName, "Updates applied - manual reboot required.")
                }
                else {
                    $this.Toasts.ShowSuccess($job.HostName, "Updates applied successfully.")
                }
            }
        }

        if ($job.Status -eq 'Failed') {
            $this.Resolution.InvalidateResolved($job.HostName)
            if ($this.Toasts) { $this.Toasts.ShowError($job.HostName, "$($job.JobType) failed. Open the log for details.") }
        }

        # Persist + settle the row unless we just kicked off an apply.
        if (-not $transitioned) {
            $this.SettleHost($job)
        }
    }

    # End of tick: refresh fleet counts and, once the batch drains, persist the
    # coalesced recents in one write.
    [void] AfterPump() {
        $this.Detail.RefreshOverview()
        if ($this.ActiveJobs.Count -eq 0) {
            $this.Store.FlushSave()
        }
    }

    # While a modal dialog is up the pump must not open another (UI deadlock);
    # PumpJobs defers completion work until it closes.
    [bool] IsModalOpen() {
        return ($null -ne $this.DialogPresenter) -and $this.DialogPresenter.IsShowing
    }

    # Records the host's final state into the recent store and renders the row idle.
    [void] SettleHost([AsyncJob]$job) {
        $reboot = $this.ManualRebootQueue.Contains($job.HostName)
        $status = if ($job.Status -eq 'Failed') {
            # The exception type is lost across the runspace boundary; re-derive the
            # reason from the message.
            switch ([RemoteFailure]::ReasonFromMessage($job.FailureMessage)) {
                ([RemoteFailureReason]::Offline) { 'Offline' }
                ([RemoteFailureReason]::ConnectionLost) { 'ConnectionLost' }
                default { 'Failed' }
            }
        }
        elseif ($reboot) {
            'RebootRequired'
        }
        else {
            'Completed'
        }

        # applyUpdates doesn't regenerate the scan report, so re-parsing would keep the
        # old count: treat a successful apply as 0 pending.
        $updateCount = if ($job.JobType -eq 'UpdateApply' -and $job.Status -eq 'Completed') {
            0
        }
        else {
            $this.UpdateService.CountUpdates($this.UpdateService.ParseUpdateReport($job.HostName))
        }

        $this.Store.Upsert($job.HostName, $status, $job.JobType, $updateCount, $reboot)

        # Consume the queue entry so a later run can't inherit a stale reboot flag.
        if ($reboot) { [void]$this.ManualRebootQueue.Remove($job.HostName) }

        $row = $this.GetRow($job.HostName)
        if ($row) {
            $rc = $this.GetRecord($job.HostName)
            if ($rc) { $row.ApplyIdle($rc) }
        }
    }

    [RecentConnection] GetRecord([string]$hostName) {
        return $this.Store.GetByHost($hostName)
    }

    [void] RefreshCardStatus([AsyncJob]$job) {
        $row = $this.GetRow($job.HostName)
        if (-not $row) { return }
        $rebootRequired = $this.ManualRebootQueue.Contains($job.HostName)
        $row.ApplyStatus([FleetCardStatus]::FromJob($job.JobType, $job.Status, $rebootRequired))
    }

    # Aborts a pending apply ($true) when the identity check confirmed the IP answers
    # as a different machine. Called twice - the verdict may land mid-dialog.
    hidden [bool] AbortOnIdentityMismatch([string]$hostName) {
        if ($this.Resolver.IdentityVerdict($hostName) -ne 'Mismatch') { return $false }
        $actual = $this.Resolver.GetVerifiedName($hostName)
        $this.Detail.AppendLog($hostName, "Apply aborted: that address answers as '$actual', not '$hostName' - its IP changed. Re-select to re-resolve.")
        if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Apply aborted: address now answers as '$actual'. Re-select and retry.") }
        $this.Resolution.InvalidateResolved($hostName)
        return $true
    }

    # Analyses the update report, confirms with the operator, and kicks the apply
    # ($true = apply started). Takes a hostName so a reused <24h scan can call it.
    [bool] ProceedWithApply([string]$hostName) {
        if ($this.AbortOnIdentityMismatch($hostName)) { return $false }

        $report = $this.UpdateService.ParseUpdateReport($hostName)

        if (-not $report) {
            $this.Detail.AppendLog($hostName, "No report generated or scan failed.")
            return $false
        }

        $updateNodes = $report.SelectNodes("//update")
        if ($updateNodes.Count -eq 0) {
            $this.Detail.AppendLog($hostName, "No updates found.")
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "No updates found.") }
            return $false
        }

        $this.Detail.AppendLog($hostName, "Found $($updateNodes.Count) updates. Analyzing driver matches...")

        $installedDrivers = $this.GetInstalledDriversFromReport($report)
        $displayList = @()
        $clipboardList = @()

        foreach ($updateNode in $updateNodes) {
            $name = $updateNode.InnerText.Trim()
            $version = $updateNode.GetAttribute("version")
            if ([string]::IsNullOrEmpty($version)) { $version = "N/A" }

            $match = $this.DriverMatcher.FindBestDriverMatch($name, $installedDrivers)

            if ($match) {
                $currentVer = $match.Driver.DriverVersion
                $comparison = $this.DriverMatcher.CompareVersions($currentVer, $version)
                $tag = if ($comparison.IsNewer) { "↑NEW" } else { "=" }
                $displayList += $name
                $displayList += "   [$($match.Category)] $currentVer → $version $tag"
                $clipboardList += "$name, $currentVer -> $version"
            }
            else {
                $displayList += "$name ($version)"
                $displayList += "   [No matching driver found]"
                $clipboardList += "$name, $version (latest)"
            }
        }

        # Show the identity verdict in the dialog (the parallel check may not have landed).
        $identityLine = if ($this.Resolver.IdentityVerdict($hostName) -eq 'Match') {
            "Identity verified: the machine answers as '$($this.Resolver.GetVerifiedName($hostName))'."
        }
        else {
            "Identity not verified yet (name check still pending) - proceed with care."
        }
        $displayList = @($identityLine, '') + $displayList

        $this.Detail.AppendLog($hostName, "Driver analysis complete. Waiting for confirmation...")
        $confirmed = $this.DialogPresenter.ShowConfirmation("Updates Available",
            "Updates found for $hostName", $displayList)

        if (-not $confirmed) {
            $this.Detail.AppendLog($hostName, "Cancelled by user.")
            return $false
        }

        # Re-check after the dialog: a Mismatch may have landed while it was open.
        if ($this.AbortOnIdentityMismatch($hostName)) { return $false }

        $this.Detail.AppendLog($hostName, "Confirmed. Phase 2: Applying updates...")
        $this.CopyUpdatesToClipboard($hostName, $clipboardList)
        $this.Detail.AppendLog($hostName, "Updates list copied to clipboard.")

        try {
            # The apply re-emits the scan milestones; restart the ratchet.
            $this.ScanSteps.Remove($hostName)
            $prep = $this.UpdateService.PrepareApplyUpdates($hostName, @{})
            $this.AttachResolvedIp($prep, $hostName)
            $applyJob = [AsyncJob]::new($hostName, 'UpdateApply')
            $applyJob.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($applyJob)
            $this.RefreshCardStatus($applyJob)
            return $true
        }
        catch {
            $this.Detail.AppendLog($hostName, "Error starting apply phase: $_")
            return $false
        }
    }

    # Returns the host's row view-model, building and inserting a new one if needed.
    [HostViewModel] EnsureRow([string]$hostName) {
        if ($this.Rows.ContainsKey($hostName)) {
            return $this.Rows[$hostName]
        }

        $vm = [HostViewModel]::new($hostName)
        $presenter = $this
        # Row commands close over the host name; Run = active command, double-click = gather.
        $run = { param($p) $presenter.RunHost($hostName) }.GetNewClosure()
        $gather = { param($p) $presenter.OnRowActivated($hostName) }.GetNewClosure()
        $vm.RunCommand = [RelayCommand]::new([System.Action[object]]$run)
        $vm.GatherCommand = [RelayCommand]::new([System.Action[object]]$gather)

        $this.Rows[$hostName] = $vm
        $this.HomeVm.Machines.Add($vm)   # UI thread only (every caller runs on the dispatcher)
        $this.UpdateEmptyHint()
        return $vm
    }

    [HostViewModel] GetRow([string]$hostName) {
        if ($this.Rows.ContainsKey($hostName)) { return $this.Rows[$hostName] }
        return $null
    }

    # Moves a host's card to the top on operator actions only - background completions
    # never reorder. Part of the FinderPresenter seam.
    [void] MoveRowToTop([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $vm = $this.GetRow($hostName)
        if ($null -eq $vm) { return }
        $this.Store.Touch($hostName)
        $idx = $this.HomeVm.Machines.IndexOf($vm)
        if ($idx -gt 0) { $this.HomeVm.Machines.Move($idx, 0) }
    }

    # --- Detail panel + inventory probe ---

    # Double-click: select the row (cheap, cached) and gather fresh inventory.
    [void] OnRowActivated([string]$hostName) {
        $this.MoveRowToTop($hostName)
        $this.Detail.SelectMachine($hostName)
        $this.StartInventory($hostName)
    }

    # Explicit gather (double-click / Refresh): forces a fresh probe regardless of TTL.
    [void] StartInventory([string]$hostName) {
        $this.StartInventory($hostName, $true)
    }

    # Reachability gate for a background inventory probe: skip offline hosts, queue
    # unknown/stale ones behind a re-check (strongest force wins; CompleteResolve
    # re-issues when the verdict lands), and hand an online host to InventoryPresenter.
    [void] StartInventory([string]$hostName, [bool]$force) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        # Only gather from a known-online host so the worker reuses the cached IP.
        $state = $this.Resolver.IsHostOnline($hostName)
        if ($state -eq 'Offline') {
            $this.Detail.AppendLog($hostName, "Host is offline - skipping inventory.")
            return
        }
        if ($state -ne 'Online' -or $this.Resolver.IsVerdictStale($hostName)) {
            $prevForce = $this.PendingGathers.ContainsKey($hostName) -and
            [bool]$this.PendingGathers[$hostName]
            $this.PendingGathers[$hostName] = ($force -or $prevForce)
            $this.Resolution.PrefetchIp($hostName)
            return
        }
        $this.Detail.RunInventoryProbe($hostName, $force)
    }

    # Removes idle (not currently running) machines from the list and recents.
    [void] ClearCompleted() {
        $toRemove = @($this.Rows.Keys | Where-Object { -not $this.IsRunning($_) })

        foreach ($hostName in $toRemove) {
            $row = $this.Rows[$hostName]
            if ($row) { [void]$this.HomeVm.Machines.Remove($row) }
            $this.Rows.Remove($hostName)
            $this.Store.Remove($hostName)
            $this.Detail.RemoveHostLog($hostName)
            # Drop queued work so a pending run/gather can't re-create the cleared card.
            $this.PendingRuns.Remove($hostName)
            $this.PendingGathers.Remove($hostName)
            $this.ScanSteps.Remove($hostName)
            if ($hostName -eq $this.SelectedHost) { $this.Detail.ClearSelection() }
        }
        $this.UpdateEmptyHint()
        $this.Detail.RefreshOverview()
        $this.Store.FlushSave()
    }

    [void] UpdateEmptyHint() {
        if (-not $this.EmptyHint) { return }
        $this.EmptyHint.Visibility = if ($this.Rows.Count -eq 0) {
            [System.Windows.Visibility]::Visible
        }
        else {
            [System.Windows.Visibility]::Collapsed
        }
    }

    # Re-renders the overview strip + idle row timestamps; re-probes the selected
    # machine if one is open. Called once on Initialize.
    [void] RefreshAll() {
        if ($this.SelectedHost) { $this.Detail.RefreshInventory($this.SelectedHost) }
        $this.RefreshIdleTimes()
    }

    # Re-renders idle rows from their stored record so relative-time subtitles advance.
    [void] RefreshIdleTimes() {
        foreach ($rc in $this.Store.GetAll()) {
            if (-not $this.IsRunning($rc.Hostname)) {
                $row = $this.GetRow($rc.Hostname)
                if ($row) { $row.ApplyIdle($rc) }
            }
        }
    }

    [System.Windows.Media.Brush] ResBrush([string]$key) {
        $res = $null
        if ($this.MachineList) { $res = $this.MachineList.TryFindResource($key) }
        if ($res -is [System.Windows.Media.Brush]) { return $res }
        return [System.Windows.Media.Brushes]::Gray
    }

    [void] CheckForManualReboot([AsyncJob]$job) {
        $needsReboot = $false

        # The apply worker sets RebootRequired on dcu-cli 1/5; $job.Result is its
        # hashtable wrapped in the invoke collection - unwrap it.
        foreach ($item in @($job.Result)) {
            if ($null -ne $item -and $item.RebootRequired) { $needsReboot = $true; break }
        }

        # Fallback: a reboot-required marker file, in case a future remote step writes one.
        $appDataDir = Join-Path $env:LOCALAPPDATA "DONUT"
        $rebootFlagPath = Join-Path $appDataDir "reports\$($job.HostName)-reboot-required.flag"
        if (Test-Path $rebootFlagPath) {
            $needsReboot = $true
            Remove-Item -Path $rebootFlagPath -Force -ErrorAction SilentlyContinue
        }

        if ($needsReboot -and -not $this.ManualRebootQueue.Contains($job.HostName)) {
            $this.ManualRebootQueue.Add($job.HostName)
        }
    }

    [array] GetInstalledDriversFromReport([xml]$report) {
        $driverNodes = $report.SelectNodes("//drivers/driver")
        if (-not $driverNodes) { return @() }
        return $driverNodes | ForEach-Object {
            @{
                DriverName    = $_.GetAttribute("name")
                ProviderName  = $_.GetAttribute("provider")
                DriverVersion = $_.GetAttribute("version")
                DriverDate    = $_.GetAttribute("date")
            }
        }
    }

    [void] CopyUpdatesToClipboard([string]$hostName, [array]$updatesList) {
        try {
            $clipboardText = "Scanned in DONUT, found and installed the following $($updatesList.Count) updates on $hostName`n"
            foreach ($item in $updatesList) {
                $clipboardText += "- $item`n"
            }
            Set-Clipboard -Value $clipboardText
        }
        catch {
            $this.Logger.LogWarning("Failed to copy to clipboard: $($_.Exception.Message)")
        }
    }
}
