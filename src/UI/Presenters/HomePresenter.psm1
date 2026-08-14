using namespace System.Windows.Controls
using namespace System.Windows.Shapes
using namespace System.Windows.Threading
using namespace System.Collections.Generic
using namespace Donut.Mvvm
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Models\FleetCardStatus.psm1"
using module "..\..\Models\DcuProgress.psm1"
using module "..\..\Models\LogLine.psm1"
using module "..\..\Models\RecentConnection.psm1"
using module "..\..\Models\PendingIntent.psm1"
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\HostListSource.psm1"
using module "..\..\Core\ViewLoader.psm1"
using module "..\..\Services\RemoteServices.psm1"
using module "..\..\Services\DriverMatchingService.psm1"
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
using module "..\..\Services\RecentConnectionsStore.psm1"
using module "..\..\Models\MachineInventory.psm1"
using module "..\..\Models\DiskUsage.psm1"
using module "..\..\Models\JobEnums.psm1"
using module "..\..\Core\TimeFormat.psm1"
using module "..\..\Core\RunspaceManager.psm1"
using module "..\..\Models\ScanCacheDecision.psm1"
using module "..\..\Models\RemoteError.psm1"
using module "..\..\Models\MachineListShaper.psm1"

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
    MoveRowToTop) via a duck-typed reference.

.NOTES
    Must never block the STA UI thread: all remote work is queued as AsyncJobs on
    the pre-warmed runspace pool and polled on a DispatcherTimer. Event-handler
    scriptblocks capture $self/$presenter, since in a WPF handler $this rebinds to
    the sender.

    Reachability gating: remote work only starts on a fresh 'Online' verdict from
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
    [object] $ConfigManager           # duck-typed, used to persist recents
    [System.Windows.FrameworkElement] $ViewContent
    # Each region root owns its own XAML namescope, so lookups go via FindHomeElement.
    hidden [hashtable] $RegionRoots = @{}
    [TextBox] $SearchBar
    [Button] $ClearButton
    [Button] $RunAllButton
    [ListBox] $MachineList
    [HomeViewModel] $HomeVm        # bound to HomeView.DataContext (Machines + SelectedMachine)
    [TextBlock] $ModePill
    [Button] $ModeButton
    [RemoteUpdateService] $UpdateService
    [DialogPresenter] $DialogPresenter
    # Duck-typed MainPresenter ref, since a typed import would cycle. Null in tests.
    [object] $Elevation
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

    # Search-bar AD finder and user Lens. Holds a duck-typed back-ref to the machine seams.
    [FinderPresenter] $Finder
    # Per-machine detail panel covering inventory and the storage scan.
    [InventoryPresenter] $Detail
    # Owns the Resolve lifecycle over the shared Resolver, though the pump stays here.
    [ResolutionCoordinator] $Resolution
    [System.Windows.Window] $HostWindow    # parent window, hooked so the popup tracks moves/resizes

    # Async state ($ActiveJobs is inherited from AsyncJobPresenter)
    [DispatcherTimer] $Timer
    [DispatcherTimer] $IdleRefreshTimer   # advances idle rows' relative times every 30s
    # Warms start after the DC warm or this fallback timer, never during the startup crunch.
    hidden [bool] $DeferredWarmsStarted = $false
    hidden [DispatcherTimer] $DeferredWarmTimer

    # Host name -> HostViewModel (same instances live in $Vm.Machines)
    [hashtable] $Rows

    # Hosts that still need a manual reboot after an apply
    [System.Collections.Generic.List[string]] $ManualRebootQueue

    # Runs queued behind a reachability re-check. CompleteResolve starts or drops them.
    hidden [hashtable] $PendingRuns = @{}

    # Hosts mid connection-drop, carded as "Reconnecting..." until the tail resumes.
    hidden [hashtable] $Reconnecting = @{}

    # Gathers queued the same way. Value is the strongest $force flag seen while queued.
    hidden [hashtable] $PendingGathers = @{}

    # Highest scan milestone per host, ratcheted so a re-emitted line can't step backwards.
    hidden [hashtable] $ScanSteps = @{}

    # Hosts consented in one "Run all" batch, so each applies without its own dialog.
    hidden [HashSet[string]] $BatchApplyHosts = [HashSet[string]]::new()

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
        $this.DriverMatcher = [DriverMatchingService]::new($this.Logger)
        $this.UpdateService = [RemoteUpdateService]::new(
            $config, $this.NetworkProbe, $this.DriverMatcher, $this.Logger)
        $this.DialogPresenter = [DialogPresenter]::new($resources)
        # Recents live in config\recents.json now, so legacy recentHosts migrate out of config.
        [RecentConnectionsStore]::MigrateFromConfig(
            $config, $configManager, [RecentConnectionsStore]::DefaultPath(), $this.Logger)
        $this.Store = [RecentConnectionsStore]::new(
            [RecentConnectionsStore]::DefaultPath(), $this.Logger)
        # Coalesce recents.json writes: mutations mark pending, flushed once per drained batch.
        $this.Store.DeferSave = $true
        $this.HostListSource = [HostListSource]::new($config.SourceRoot)
        $this.InventoryService = [InventoryService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.DiskUsageService = [DiskUsageService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.Resolver = [HostResolver]::new($config, $this.NetworkProbe, $this.Logger)

        $this.Rows = @{}
        $this.HomeVm = [HomeViewModel]::new()   # bound to the view, owns the machine collection
        $this.ManualRebootQueue = [List[string]]::new()

        $presenter = $this
        $this.Timer = [DispatcherTimer]::new()
        $this.Timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $this.Timer.Add_Tick({ $presenter.OnTimerTick($this, $null) }.GetNewClosure())
        $this.Timer.Start()

        $this.IdleRefreshTimer = [DispatcherTimer]::new()
        $this.IdleRefreshTimer.Interval = [TimeSpan]::FromSeconds(30)
        $this.IdleRefreshTimer.Add_Tick({ $presenter.RefreshIdleTimes() }.GetNewClosure())
        $this.IdleRefreshTimer.Start()

        $this.Finder = [FinderPresenter]::new(
            $config, $this.HomeVm, $this.Logger, $toasts, $this.DialogPresenter, $this)

        # Split stage 1: HomePresenter still owns the detail controls until later stages.
        $this.Detail = [InventoryPresenter]::new(
            $config, $this.Logger, $this.HomeVm, $this.InventoryService,
            $this.DiskUsageService, $this.Toasts, $this)

        # Split scaffold: HomePresenter still owns the resolve methods until later stages.
        $this.Resolution = [ResolutionCoordinator]::new(
            $config, $this.Logger, $this.ConfigManager, $this.Toasts, $this.Resolver, $this)

        $this.Initialize()
        # The detail controls live in the DetailPane region's own namescope.
        $this.Detail.Initialize($this.RegionRoots['detailPane'])
    }

    # Deliberately uncaught: a missing or unparsable region must fail the boot loudly.
    hidden [void] ComposeRegions() {
        foreach ($r in @(
                @{ Key = 'actionBar'; File = 'ActionBar.xaml'; Slot = 'slotActionBar' },
                @{ Key = 'statCards'; File = 'StatCards.xaml'; Slot = 'slotStatCards' },
                @{ Key = 'machinePane'; File = 'MachinePane.xaml'; Slot = 'slotMachinePane' },
                @{ Key = 'detailPane'; File = 'DetailPane.xaml'; Slot = 'slotDetailArea' })) {
            $root = [ViewLoader]::Load($this.Config.SourceRoot, "UI\Views\Home\$($r.File)")
            $this.ViewContent.FindName($r.Slot).Content = $root
            $this.RegionRoots[$r.Key] = $root
        }
        # The Lens nests inside the detail pane's namescope, not the shell's.
        $lens = [ViewLoader]::Load($this.Config.SourceRoot, 'UI\Views\Home\LensPane.xaml')
        $this.RegionRoots['detailPane'].FindName('slotLens').Content = $lens
        $this.RegionRoots['lens'] = $lens
    }

    # Tour seam: region names are invisible to the shell's FindName, so probe each root.
    [object] FindHomeElement([string]$name) {
        $roots = @($this.ViewContent) + @(
            $this.RegionRoots['actionBar'], $this.RegionRoots['statCards'],
            $this.RegionRoots['machinePane'], $this.RegionRoots['detailPane'],
            $this.RegionRoots['lens'])
        foreach ($root in $roots) {
            if ($null -eq $root) { continue }
            if ($root.Name -eq $name) { return $root }
            $hit = $root.FindName($name)
            if ($hit) { return $hit }
        }
        return $null
    }

    [void] Initialize() {
        $this.ComposeRegions()
        $bar = $this.RegionRoots['actionBar']
        $this.SearchBar = $bar.FindName('GoogleSearchBar')
        $this.RunAllButton = $bar.FindName('btnRunAll')
        $this.ModePill = $bar.FindName('txtMode')
        $this.ModeButton = $bar.FindName('btnMode')
        $pane = $this.RegionRoots['machinePane']
        $this.ClearButton = $pane.FindName('btnClearTabs')
        $this.MachineList = $pane.FindName('MachineList')

        # The detail panel is owned by InventoryPresenter and wired in its own Initialize.
        $presenter = $this

        $this.ViewContent.DataContext = $this.HomeVm
        if ($this.MachineList) {
            $this.MachineList.Add_SelectionChanged({
                    $presenter.Detail.OnMachineSelectionChanged() }.GetNewClosure())
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
        $this.Finder.Initialize($this.RegionRoots['actionBar'])

        # A WPF Popup is its own top-level window and does not follow the parent's moves.
        $this.ViewContent.Add_Loaded({ $presenter.HookHostWindow() }.GetNewClosure())

        # Row brushes resolve from UIColors.xaml exactly once, before any row exists.
        $this.SeedRowPalette()

        if ($this.Store.Count() -eq 0) {
            $this.Store.SeedFrom($this.HostListSource.ReadHosts())
        }
        $rowsSw = [System.Diagnostics.Stopwatch]::StartNew()
        $this.BuildRows()
        $this.Logger.LogDebug("Machine list restore took $($rowsSw.ElapsedMilliseconds)ms.")
        $this.Store.FlushSave()   # persist the one-time WSID seed (saves are deferred)
        $this.InitMachineListShaping()

        $this.UpdateModePill()
        $this.RefreshIdleTimes()

        # Seeded from the last run so the first selects resolve now. A stale DC falls back.
        $savedDc = [string]$this.Config.Settings['activeDomainController']
        if (-not [string]::IsNullOrWhiteSpace($savedDc)) { $this.Resolver.SetActiveDc($savedDc) }

        # The one safe time to take the loader-lock hit is before the message loop (.NOTES).
        $warmSw = [System.Diagnostics.Stopwatch]::StartNew()
        $this.Resolution.WarmPool()
        $this.Logger.LogInfo("Warm pool barrier held boot for $($warmSw.ElapsedMilliseconds)ms.")

        # The only startup job beyond the warm shells (architecture/runspaces-and-workers).
        $this.Resolution.StartWarm()
        $presenter = $this
        $this.DeferredWarmTimer = [DispatcherTimer]::new()
        $this.DeferredWarmTimer.Interval = [TimeSpan]::FromSeconds(90)
        $this.DeferredWarmTimer.Add_Tick({
                $presenter.StartDeferredWarms('fallback timer')
            }.GetNewClosure())
        $this.DeferredWarmTimer.Start()
    }

    # Primes the finder and Lens agent once the startup crunch is over. Single-shot.
    [void] StartDeferredWarms([string]$reason) {
        if ($this.DeferredWarmsStarted) { return }
        $this.DeferredWarmsStarted = $true
        if ($this.DeferredWarmTimer) { $this.DeferredWarmTimer.Stop() }
        $this.Logger.LogInfo("Starting deferred finder/Lens warms ($reason).")
        $this.Finder.WarmAdSearch()
        $this.Finder.WarmLens()
    }

    # --- Start-early IP resolution ---

    # Called when a verdict lands: re-issues the gather or run queued behind the re-check.
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
                $this.Detail.AppendLog($hostName, "Machine is offline - queued run skipped.", [LogSeverity]::Warn)
                if ($this.Toasts) { $this.Toasts.ShowWarning($hostName, "Offline, so the run was skipped.") }
            }
        }
    }

    # A queued run can't proceed without a verdict, so drop it with a reason.
    [void] DropPendingRunOnResolveFailure([string]$hostName) {
        if ($this.PendingRuns.ContainsKey($hostName)) {
            $this.PendingRuns.Remove($hostName)
            $this.Detail.AppendLog($hostName, "Run not started: could not verify reachability (resolve failed).")
            if ($this.Toasts) { $this.Toasts.ShowWarning($hostName, "Run not started. Could not verify the machine is reachable.") }
        }
    }

    # No row update while a job runs, since live status owns the dot and subtitle then.
    [void] RenderReachability([string]$hostName) {
        $state = $this.Resolver.IsHostOnline($hostName)
        $row = $this.GetRow($hostName)
        if ($row -and -not $this.IsRunning($hostName)) { $row.SetReachability($state) }
    }

    # Threads the prefetched IP into the worker args so the worker skips DNS.
    hidden [void] AttachResolvedIp([hashtable]$prep, [string]$hostName) {
        $ip = $this.Resolver.GetCachedIp($hostName)
        if ([string]::IsNullOrWhiteSpace($ip)) { return }
        # Not an Options key: those merge into dcu-cli args, and DCU rejects -ResolvedIp with 105.
        if ($prep -and $prep.Arguments) {
            $prep.Arguments.ResolvedIp = $ip
        }
    }

    # Only the mode pill reflects the active command. The Add button is static.
    [void] UpdateModePill() {
        $command = $this.Config.GetActiveCommand()
        $label = if ($command -eq 'applyUpdates') { "Apply" } else { "Scan" }
        if ($this.ModePill) { $this.ModePill.Text = $label }
    }

    [void] CycleMode() {
        $next = if ($this.Config.GetActiveCommand() -eq 'scan') { 'applyUpdates' } else { 'scan' }
        $this.Config.SetActiveCommand($next)
        if ($null -ne $this.ConfigManager) { $this.ConfigManager.SaveConfig($this.Config) }
        $this.UpdateModePill()
    }

    # Builds an idle row for every persisted recent connection (newest first).
    [void] BuildRows() {
        foreach ($rc in $this.Store.GetAll()) {
            $vm = $this.EnsureRow($rc.Hostname)
            $vm.ApplyIdle($rc)
            # Memoized report files keep a probed host's tiles across restarts.
            $inv = $this.Detail.GetInventory($rc.Hostname)
            if ($inv) { $vm.ApplyInventory($inv) }
        }
    }

    # Add never scans or applies. Running the active command is a separate step.
    [void] OnSearch() {
        $rawInput = $this.SearchBar.Text
        if ([string]::IsNullOrWhiteSpace($rawInput)) { return }

        $targetHosts = $rawInput -split "[\s,]+" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }

        if ($targetHosts.Count -eq 0) { return }

        foreach ($hostName in $targetHosts) {
            $this.EnsureRow($hostName)
            $this.Resolution.PrefetchIp($hostName)        # the row then shows reachability on Add
            $this.StartInventory($hostName, $true)
        }
        # Touched in reverse so the first typed host ranks newest on the next launch.
        $ordered = @($targetHosts)
        [array]::Reverse($ordered)
        foreach ($hostName in $ordered) { $this.MoveRowToTop($hostName) }
        $this.Detail.SelectMachine($targetHosts[0])

        $this.SearchBar.Text = ""
    }

    # One confirmation for the whole batch, per-host runs still go through StartProcess.
    [void] RunAll() {
        $idleHosts = @($this.Store.GetAll() | ForEach-Object { $_.Hostname } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $this.IsRunning($_) })
        if ($idleHosts.Count -eq 0) { return }

        # Elevating restarts the app, so confirming a destructive batch first would be lost.
        if (-not $this.RequireElevation([GatedAction]::RunAll, $idleHosts, 'Running updates')) { return }

        $command = $this.Config.GetActiveCommand()
        if ($command -eq 'applyUpdates') {
            # Applies are irreversible (BIOS/firmware), so the modal is destructive-tinted.
            $confirmed = $this.DialogPresenter.ShowConfirmation(
                "Apply Updates",
                "Apply updates to $($idleHosts.Count) machine(s). BIOS and firmware installs cannot be rolled back.",
                $idleHosts, 'Apply', $true
            )
            if (-not $confirmed) { return }
            # Batch consent: each host applies without its own dialog (see ProceedWithApply).
            $this.BatchApplyHosts.Clear()
            foreach ($h in $idleHosts) { [void]$this.BatchApplyHosts.Add($h) }
        }

        $this.ManualRebootQueue.Clear()
        foreach ($hostName in $idleHosts) {
            $this.StartProcess($hostName)
        }
    }

    # False means DONUT is relaunching elevated, so this instance must do nothing more.
    [bool] RequireElevation([GatedAction]$action, [string[]]$hosts, [string]$what) {
        if (-not $this.Elevation) { return $true }
        return $this.Elevation.EnsureElevated($action, $hosts, $what)
    }

    # Re-runs the click that asked for elevation, now that this instance has it.
    [void] ResumeGatedAction([PendingIntent]$intent) {
        if ($null -eq $intent) { return }
        switch ($intent.Action) {
            ([GatedAction]::RunAll) { $this.RunAll() }
            ([GatedAction]::Run) { foreach ($h in $intent.Hosts) { $this.StartProcess($h) } }
            ([GatedAction]::Inventory) { foreach ($h in $intent.Hosts) { $this.StartInventory($h) } }
            ([GatedAction]::DiskScan) { $this.Detail.ResumeDiskScan($intent.Hosts) }
            # The toggle already persisted, only the registration was waiting on a token.
            ([GatedAction]::StartupTask) { $this.Elevation.ApplyStartupTask() }
            default {
                $this.Logger.LogInfo("No resume path for $($intent.Action); the user re-runs it.")
            }
        }
    }

    # Subscribed once so an open search popup stays under the search box on move or resize.
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

    [void] RunHost([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        if ($this.IsRunning($hostName)) {
            # A storage scan also holds the row busy, and a silent return reads as a dead button.
            $this.Detail.AppendLog($hostName, "A job is already running for $hostName - wait for it to finish.")
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "Already running. Wait for the current job to finish.") }
            return
        }

        # Apply no longer pre-confirms, a single confirm gates it after the scan.
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

    # Wires the recents fields and on-disk report to the pure ScanCacheDecision rule.
    [bool] RecentScanIsFresh([string]$hostName) {
        $rc = $this.GetRecord($hostName)
        if ($null -eq $rc) { return $false }
        return [ScanCacheDecision]::IsFresh(
            $rc.LastJobType,
            [TimeFormat]::ParseIso($rc.LastSeen),
            [datetime]::UtcNow,
            $this.ScanCacheTtl,
            ($null -ne $this.UpdateService.ParseUpdateReport($hostName)))
    }

    [void] StartProcess([string]$hostName) {
        $row = $this.EnsureRow($hostName)
        # A new run supersedes any last-found updates list shown in the pane.
        if ($row) { $row.Set('HasUpdates', $false) }
        $command = $this.Config.GetActiveCommand()

        # Never scan/apply an offline or unresolved host (reachability gating, .NOTES).
        $reach = $this.Resolver.IsHostOnline($hostName)
        if ($reach -eq 'Offline') {
            $this.Detail.AppendLog($hostName, "Machine is offline - skipping $command.", [LogSeverity]::Warn)
            if ($this.Toasts) { $this.Toasts.ShowWarning($hostName, "Offline, so the run was skipped.") }
            if ($row) { $row.SetReachability('Offline') }
            return
        }
        if ($reach -ne 'Online' -or $this.Resolver.IsVerdictStale($hostName)) {
            # CompleteResolve starts the queued run once the fresh verdict lands.
            if (-not $this.Resolver.HasActiveDc()) {
                # No DC yet means a resolve can't run, so queuing would sit forever.
                $this.Detail.AppendLog($hostName, "Resolver not ready yet (no domain controller) - try again shortly.")
                return
            }
            $this.PendingRuns[$hostName] = $true
            $this.Resolution.PrefetchIp($hostName)
            $this.Detail.AppendLog($hostName, "Verifying $hostName is reachable - the run starts automatically once confirmed.")
            return
        }

        # A successful apply flips the last job to UpdateApply, so the next run re-scans.
        if (($command -eq 'scan' -or $command -eq 'applyUpdates') -and
            $this.RecentScanIsFresh($hostName)) {
            $rc = $this.GetRecord($hostName)
            $age = [TimeFormat]::Relative([TimeFormat]::ParseIso($rc.LastSeen))
            if ($command -eq 'applyUpdates') {
                $this.Detail.AppendLog($hostName, "Reusing scan from $age (under 24h); skipping re-scan.")
                $this.ProceedWithApply($hostName)
            }
            else {
                $this.Detail.AppendLog($hostName, "Scanned $age - results are current; skipping re-scan.")
                if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "Scanned $age, so the results are current.") }
            }
            return
        }

        $this.Detail.AppendSeparator($hostName)
        $this.Detail.AppendLog($hostName, "Starting $command for $hostName...")
        $this.ScanSteps.Remove($hostName)   # fresh job, fresh step ratchet

        try {
            $jobParams = switch ($command) {
                'scan' {
                    @{ Type = 'Scan'; Prep = $this.UpdateService.PrepareScanForUpdates($hostName) }
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
                $job = $this.StartJob(
                    [AsyncJob]::new($hostName, $jobParams.Type, $this.Logger), $jobParams.Prep)
                $this.RefreshCardStatus($job)
                # Apply is destructive: run the identity check in parallel to gate it.
                if ($command -eq 'applyUpdates') { $this.Resolution.StartVerifyName($hostName) }
            }
        }
        catch {
            $this.Detail.AppendLog($hostName, "Error starting process: $_", [LogSeverity]::Error)
            $row.ApplyStatus([FleetCardStatus]::FromJob('Scan', 'Failed', $false))
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Failed to start: $_") }
        }
    }

    # Handler-shaped signature, so both arguments are unused.
    [void] OnTimerTick($timerSource, $tickArgs) {
        try {
            $this.PumpJobs()
            # A late finisher is a warmed runspace and returns the capacity the lapse raised.
            if ($null -ne $this.Resolution) { $this.Resolution.ReapWarmShells() }
        }
        catch {
            $this.Logger.LogException("Error during job pump", $_)
        }
    }

    # Inventory probes only stream, the rest also drive row status and progress.
    [void] OnJobPolled([AsyncJob]$job) {
        # Resolve jobs are pure background precompute, with no row, progress, or log UI.
        if ($job.JobType -eq [JobKind]::Resolve) { return }

        $lines = [System.Collections.Generic.List[LogLine]]::new()
        $line = $null
        while ($job.Logs.TryDequeue([ref]$line)) { $lines.Add($line) }

        if ($job.JobType -eq [JobKind]::Inventory -or $job.JobType -eq [JobKind]::DiskScan -or
            $job.JobType -eq [JobKind]::DeleteFolders) {
            if ($lines.Count -gt 0) { $this.Detail.AppendLogLines($job.HostName, $lines.ToArray()) }
            return
        }

        $latestPct = -1
        $latestStep = 0
        $installing = $false
        $sawReconnect = $false
        $sawNormalLine = $false
        # Any non-reconnect line means the tail resumed, which clears the reconnect state.
        $display = [System.Collections.Generic.List[LogLine]]::new()
        foreach ($entry in $lines) {
            if ([DcuProgress]::IsReconnectLine($entry.Text)) {
                $sawReconnect = $true
                # Re-author as Warn: a drop is worth noticing but the run is recovering.
                $display.Add([LogLine]::Donut([LogSeverity]::Warn,
                        [DcuProgress]::StripReconnectMarker($entry.Text)))
                continue
            }
            $sawNormalLine = $true
            $display.Add($entry)
            $pct = [DcuProgress]::ParsePercent($entry.Text)
            if ($pct -ge 0) { $latestPct = $pct }
            $step = [DcuProgress]::ParseScanStep($entry.Text)
            if ($step -gt $latestStep) { $latestStep = $step }
            if ([DcuProgress]::IsInstalling($entry.Text)) { $installing = $true }
        }
        if ($display.Count -gt 0) { $this.Detail.AppendLogLines($job.HostName, $display.ToArray()) }

        if ($sawReconnect) { $this.Reconnecting[$job.HostName] = $true }
        elseif ($sawNormalLine) { [void]$this.Reconnecting.Remove($job.HostName) }

        # Install has no dcu sub-percent, so the bar goes indeterminate instead of freezing.
        $row = $this.GetRow($job.HostName)
        if ($row) {
            if ($installing) { $row.SetIndeterminate() }
            elseif ($latestPct -ge 0) { $row.SetPercent($latestPct) }
        }

        # An apply's own percent lines own the bar, so a scan milestone drives it only on scans.
        $prev = [int]$this.ScanSteps[$job.HostName]   # missing key -> $null -> 0
        if ($row -and $latestStep -gt $prev) {
            $this.ScanSteps[$job.HostName] = $latestStep
            if ($job.JobType -ne 'UpdateApply') {
                $row.SetPercent($latestStep * 100.0 / [DcuProgress]::ScanStepCount)
            }
        }

        $this.RefreshCardStatus($job)
    }

    # Terminal per-job step, dispatching background kinds to their Complete* handler.
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
        if ($job.JobType -eq [JobKind]::DeleteFolders) {
            $this.Detail.CompleteDeleteFolders($job)
            return
        }

        # Drop any lingering reconnect flag so the settled card reflects the outcome.
        [void]$this.Reconnecting.Remove($job.HostName)

        # No log dump: the worker already live-tailed, and a dump would replay a stale file.
        $finishSev = if ($job.Status -eq 'Completed') { [LogSeverity]::Success }
        elseif ($job.Status -eq 'Failed') { [LogSeverity]::Error }
        else { [LogSeverity]::Info }
        $this.Detail.AppendLog($job.HostName, "Job $($job.JobType) finished: $($job.Status)", $finishSev)

        $transitioned = $false
        if ($job.Status -eq 'Completed' -and $job.JobType -eq 'UpdateScan') {
            if ($this.ScanFoundNoUpdates($job)) {
                $this.Detail.AppendLog($job.HostName, "No updates found.", [LogSeverity]::Success)
                if ($this.Toasts) { $this.Toasts.ShowInfo($job.HostName, "No updates found.") }
            }
            else {
                $transitioned = $this.ProceedWithApply($job.HostName)
            }
        }

        # A plain scan fills the same card as an apply scan, minus the apply prompt.
        if ($job.Status -eq 'Completed' -and $job.JobType -eq 'Scan') {
            if ($this.ScanFoundNoUpdates($job)) {
                # DCU 500 leaves no report on the target, so the flag is the verdict.
                $row = $this.GetRow($job.HostName)
                if ($null -ne $row) { $row.Set('HasUpdates', $false) }
                $this.Detail.AppendLog($job.HostName, "Scan complete: no updates found.", [LogSeverity]::Success)
            }
            else {
                $scanRows = $this.RenderUpdatesFromReport($job.HostName)
                $summary = if ($null -eq $scanRows) { 'no report generated' }
                elseif ($scanRows.Count -eq 0) { 'no updates found' }
                else { "$($scanRows.Count) update(s) available" }
                $scanSev = if ($null -eq $scanRows) { [LogSeverity]::Warn } else { [LogSeverity]::Success }
                $this.Detail.AppendLog($job.HostName, "Scan complete: $summary.", $scanSev)
            }
        }

        if ($job.JobType -eq 'UpdateApply' -and $job.Status -eq 'Completed') {
            $this.CheckForManualReboot($job)
            if ($this.Toasts) {
                if ($this.ManualRebootQueue.Contains($job.HostName)) {
                    $this.Toasts.ShowWarning($job.HostName, "Updates applied. A manual reboot is required.")
                }
                else {
                    $this.Toasts.ShowSuccess($job.HostName, "Updates applied.")
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

    # End of tick: once the batch drains, persist the coalesced recents in one write.
    [void] AfterPump() {
        if ($this.ActiveJobs.Count -eq 0) {
            $this.Store.FlushSave()
        }
    }

    # The pump must not open a second modal, which would deadlock the UI.
    [bool] IsModalOpen() {
        return ($null -ne $this.DialogPresenter) -and $this.DialogPresenter.IsShowing
    }

    # Records the host's final state into the recent store and renders the row idle.
    [void] SettleHost([AsyncJob]$job) {
        $reboot = $this.ManualRebootQueue.Contains($job.HostName)
        $status = if ($job.Status -eq 'Failed') {
            # The exception type is lost across the runspace boundary, so parse the message.
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

        # applyUpdates leaves the scan report stale, so re-parsing would keep the old count.
        $updateCount = if ($job.JobType -eq 'UpdateApply' -and $job.Status -eq 'Completed') {
            0
        }
        else {
            $this.UpdateService.CountUpdates($this.UpdateService.ParseUpdateReport($job.HostName))
        }

        $this.Store.Upsert($job.HostName, $status, $job.JobType, $updateCount)

        # Consume the queue entry so a later run can't inherit a stale reboot flag.
        if ($reboot) { [void]$this.ManualRebootQueue.Remove($job.HostName) }

        $row = $this.GetRow($job.HostName)
        if ($row) {
            $rc = $this.GetRecord($job.HostName)
            if ($rc) { $row.ApplyIdle($rc) }
        }
        $this.Detail.ShowJobProgress($job.HostName, $false, 0, $false)
    }

    [RecentConnection] GetRecord([string]$hostName) {
        return $this.Store.GetByHost($hostName)
    }

    [void] RefreshCardStatus([AsyncJob]$job) {
        $row = $this.GetRow($job.HostName)
        if (-not $row) { return }
        # A running job whose connection dropped shows Reconnecting until the tail resumes.
        if ($job.Status -eq 'Running' -and $this.Reconnecting.ContainsKey($job.HostName)) {
            $row.ApplyStatus([FleetCardStatus]::Reconnecting())
            return
        }
        $rebootRequired = $this.ManualRebootQueue.Contains($job.HostName)
        $row.ApplyStatus([FleetCardStatus]::FromJob($job.JobType, $job.Status, $rebootRequired))
        # The row's live state drives the terminal bar: shown while running, hidden after.
        $this.Detail.ShowJobProgress($job.HostName, ($job.Status -eq 'Running'),
            $row.Percent, $row.ProgressIndeterminate)
    }

    # Called twice, since the verdict may land mid-dialog. True aborts the pending apply.
    hidden [bool] AbortOnIdentityMismatch([string]$hostName) {
        if ($this.Resolver.IdentityVerdict($hostName) -ne 'Mismatch') { return $false }
        $actual = $this.Resolver.GetVerifiedName($hostName)
        $this.Detail.AppendLog($hostName, "Apply aborted: that address answers as '$actual', not '$hostName' - its IP changed. Re-select to re-resolve.", [LogSeverity]::Warn)
        if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Apply stopped. That address now answers as '$actual'. Re-select and retry.") }
        $this.Resolution.InvalidateResolved($hostName)
        return $true
    }

    # Takes a hostName so a reused sub-24h scan can call it. True means the apply started.
    [bool] ProceedWithApply([string]$hostName) {
        if ($this.AbortOnIdentityMismatch($hostName)) { return $false }

        $updateRows = $this.RenderUpdatesFromReport($hostName)
        if ($null -eq $updateRows) {
            $this.Detail.AppendLog($hostName, "No report generated or scan failed.", [LogSeverity]::Warn)
            return $false
        }
        if ($updateRows.Count -eq 0) {
            $this.Detail.AppendLog($hostName, "No updates found.", [LogSeverity]::Success)
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "No updates found.") }
            return $false
        }

        $this.Detail.AppendLog($hostName, "Found $($updateRows.Count) update(s).")
        $this.CopyUpdatesToClipboard($hostName, @($updateRows | ForEach-Object { "$($_.Name), $($_.VersionText)" }))

        # Run all consented up front: apply straight away, no per-host dialog.
        if ($this.BatchApplyHosts.Contains($hostName)) {
            [void]$this.BatchApplyHosts.Remove($hostName)
            $this.Detail.AppendLog($hostName, "Applying $($updateRows.Count) update(s)...")
            return $this.StartApply($hostName)
        }

        # Single run: one small confirm (the list itself lives in the pane, not the dialog).
        $this.Detail.AppendLog($hostName, "Review the updates in the pane, then confirm.")
        $confirmed = $this.DialogPresenter.ShowConfirmation("Apply Updates",
            "Apply $($updateRows.Count) update(s) to ${hostName}, listed in the detail pane. BIOS and firmware installs cannot be rolled back.",
            @(), 'Apply', $true)
        if (-not $confirmed) {
            $this.Detail.AppendLog($hostName, "Cancelled by user.")
            return $false
        }

        # Re-check after the dialog: a Mismatch may have landed while it was open.
        if ($this.AbortOnIdentityMismatch($hostName)) { return $false }
        return $this.StartApply($hostName)
    }

    # Returns the rows, $null when no report exists, or @() when it holds none (card cleared).
    [array] RenderUpdatesFromReport([string]$hostName) {
        $updateRows = $this.UpdateService.GetUpdateRows($hostName)
        if ($null -eq $updateRows) { return $null }

        $vm = $this.GetRow($hostName)
        if ($updateRows.Count -eq 0) {
            if ($null -ne $vm) { $vm.Set('HasUpdates', $false) }
            return @()
        }

        # The name check runs with the apply, so a plain scan usually reads 'Unknown'.
        $verdict = $this.Resolver.IdentityVerdict($hostName)
        $reported = $this.Resolver.GetVerifiedName($hostName)
        $identityLine = switch ($verdict) {
            'Match' { "Identity verified: the machine at this IP answers as '$reported'." }
            'Mismatch' { "Wrong machine: this IP answers as '$reported', not $hostName - do not apply." }
            default { "Identity not verified yet - the name check runs before an apply." }
        }

        if ($null -ne $vm) {
            $vm.Set('Updates', $updateRows)
            $vm.Set('UpdatesIdentityText', $identityLine)
            $vm.Set('IdentityState', $verdict)
            $vm.Set('HasUpdates', $true)
        }
        return $updateRows
    }

    # Launches the apply (phase 2) job. Shared by the single-confirm and Run-all paths.
    hidden [bool] StartApply([string]$hostName) {
        $this.Detail.AppendLog($hostName, "Confirmed. Phase 2: Applying updates...")
        try {
            # The apply re-emits the scan milestones, so restart the ratchet.
            $this.ScanSteps.Remove($hostName)
            $prep = $this.UpdateService.PrepareApplyUpdates($hostName, @{})
            $this.AttachResolvedIp($prep, $hostName)
            $applyJob = $this.StartJob([AsyncJob]::new($hostName, 'UpdateApply', $this.Logger), $prep)
            $this.RefreshCardStatus($applyJob)
            return $true
        }
        catch {
            $this.Detail.AppendLog($hostName, "Error starting apply phase: $_", [LogSeverity]::Error)
            return $false
        }
    }

    # Returns the host's row view-model, building and inserting a new one if needed.
    [HostViewModel] EnsureRow([string]$hostName) { return $this.EnsureRow($hostName, '') }

    # The 2-arg form seeds an already-known owner (e.g. the open Lens's person) before
    # RequestOwners runs, so that add never re-queries the agent for a name on screen.
    [HostViewModel] EnsureRow([string]$hostName, [string]$ownerDisplayName) {
        if ($this.Rows.ContainsKey($hostName)) {
            $existing = $this.Rows[$hostName]
            if ($ownerDisplayName -and -not $existing.OwnerName) {
                $existing.SetOwner($ownerDisplayName)
                $this.Store.UpsertOwner($hostName, $ownerDisplayName)
            }
            return $existing
        }

        $vm = [HostViewModel]::new($hostName)
        if ($ownerDisplayName) {
            $vm.SetOwner($ownerDisplayName)
            $this.Store.UpsertOwner($hostName, $ownerDisplayName)
        }
        $presenter = $this
        # Run is the active command, double-click gathers.
        $run = { param($p) $presenter.RunHost($hostName) }.GetNewClosure()
        $gather = { param($p) $presenter.OnRowActivated($hostName) }.GetNewClosure()
        $remove = { param($p) $presenter.RemoveMachine($hostName) }.GetNewClosure()
        $vm.RunCommand = [RelayCommand]::new([System.Action[object]]$run)
        $vm.GatherCommand = [RelayCommand]::new([System.Action[object]]$gather)
        $vm.RemoveCommand = [RelayCommand]::new([System.Action[object]]$remove)

        $this.Rows[$hostName] = $vm
        $this.HomeVm.Machines.Add($vm)   # UI thread only (every caller runs on the dispatcher)
        $this.RequestOwners()
        return $vm
    }

    # One batch for the whole list, never one call per row. Cache first, agent for the rest.
    [void] RequestOwners() {
        $wanted = @()
        foreach ($name in @($this.Rows.Keys)) {
            $vm = $this.Rows[$name]
            if ($vm.OwnerName) { continue }
            $cached = $this.Store.GetByHost($name)
            if ($cached -and $cached.Owner) {
                $vm.SetOwner($cached.Owner)
                # A one-token owner is a SAM cached before SCCM naming, so re-ask once to heal it.
                if ($cached.Owner -match '\s') { continue }
            }
            $wanted += $name
        }
        if ($wanted.Count -eq 0 -or -not $this.Finder) { return }

        $presenter = $this
        $onResolved = {
            param($map)
            foreach ($machine in @($map.Keys)) {
                $row = $presenter.GetRow([string]$machine)
                if ($row) { $row.SetOwner([string]$map[$machine]) }
                $presenter.Store.UpsertOwner([string]$machine, [string]$map[$machine])
            }
        }.GetNewClosure()
        $this.Finder.ResolveOwners($wanted, $onResolved)
    }

    [HostViewModel] GetRow([string]$hostName) {
        if ($this.Rows.ContainsKey($hostName)) { return $this.Rows[$hostName] }
        return $null
    }

    # GetDefaultView returns the view the ListBox binds to, so sorting it reorders the list.
    [void] InitMachineListShaping() {
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($this.HomeVm.Machines)
        if ($null -eq $view) { return }
        if ($view -is [System.Windows.Data.ListCollectionView]) {
            $view.IsLiveSorting = $true
            foreach ($p in @('SortStatusRank', 'HostName')) { [void]$view.LiveSortingProperties.Add($p) }
        }
        # Attention first, then alphabetical, a fixed order with no runtime filter.
        $asc = [System.ComponentModel.ListSortDirection]::Ascending
        [void]$view.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('SortStatusRank', $asc))
        [void]$view.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('HostName', $asc))
    }

    # Stamps the row's recency so the next launch seeds it near the top. The live
    # list keeps its status-then-name sort, so nothing visibly reorders now.
    [void] MoveRowToTop([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        if ($null -eq $this.GetRow($hostName)) { return }
        $this.Store.Touch($hostName)
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

    # Reachability gate: offline is skipped, unknown or stale is queued behind a re-check.
    [void] StartInventory([string]$hostName, [bool]$force) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        # Only gather from a known-online host so the worker reuses the cached IP.
        $state = $this.Resolver.IsHostOnline($hostName)
        if ($state -eq 'Offline') {
            $this.Detail.AppendLog($hostName, "Machine is offline - skipping inventory.")
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
        foreach ($hostName in $toRemove) { $this.RemoveRowCore($hostName) }
        $this.FinishRemoval()
    }

    # A running host stays put, since stopping its job is a separate deliberate action.
    [void] RemoveMachine([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName) -or -not $this.Rows.ContainsKey($hostName)) { return }
        if ($this.IsRunning($hostName)) {
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "Still running. Wait for the job to finish before removing it.") }
            return
        }
        $this.RemoveRowCore($hostName)
        $this.FinishRemoval()
    }

    # One machine out of the list, recents, and every queue that could resurrect it.
    hidden [void] RemoveRowCore([string]$hostName) {
        $row = $this.Rows[$hostName]
        if ($row) { [void]$this.HomeVm.Machines.Remove($row) }
        $this.Rows.Remove($hostName)
        $this.Store.Remove($hostName)
        $this.Detail.RemoveHostLog($hostName)
        # Drop queued work so a pending run/gather can't re-create the removed card.
        $this.PendingRuns.Remove($hostName)
        $this.PendingGathers.Remove($hostName)
        $this.ScanSteps.Remove($hostName)
        if ($hostName -eq $this.SelectedHost) { $this.Detail.ClearSelection() }
    }

    hidden [void] FinishRemoval() {
        $this.Store.FlushSave()
    }

    # Re-probes verdicts past the TTL so reachability never rots. PrefetchIp is single-flight.
    [void] RefreshIdleTimes() {
        foreach ($rc in $this.Store.GetAll()) {
            if (-not $this.IsRunning($rc.Hostname)) {
                $row = $this.GetRow($rc.Hostname)
                if ($row) { $row.ApplyIdle($rc) }
                if ($this.Resolver.IsVerdictStale($rc.Hostname)) {
                    $this.Resolution.PrefetchIp($rc.Hostname)
                }
            }
        }
    }

    # One source for row accents: the alpha tints derive here, not from duplicated hexes.
    hidden [void] SeedRowPalette() {
        $palette = @{}
        $missing = @()
        foreach ($key in @('AccentGreen', 'AccentRed', 'AccentYellow', 'AccentOrange',
                'AccentCyan', 'AccentPurple', 'BodyTextTertiary')) {
            $res = $null
            if ([System.Windows.Application]::Current) {
                $res = [System.Windows.Application]::Current.TryFindResource($key)
            }
            if ($res -isnot [System.Windows.Media.SolidColorBrush]) { $missing += $key; continue }

            $base = if ($res.IsFrozen) { $res } else { $f = $res.Clone(); $f.Freeze(); $f }
            $c = $base.Color
            $tint = [System.Windows.Media.SolidColorBrush]::new(
                [System.Windows.Media.Color]::FromArgb(26, $c.R, $c.G, $c.B))
            $border = [System.Windows.Media.SolidColorBrush]::new(
                [System.Windows.Media.Color]::FromArgb(77, $c.R, $c.G, $c.B))
            $tint.Freeze()
            $border.Freeze()
            $palette[$key] = @{ Brush = $base; Tint = $tint; TintBorder = $border }
        }
        if ($missing.Count -gt 0) {
            $this.Logger.LogWarning("Row palette keys missing from UIColors.xaml: $($missing -join ', ')")
        }
        [HostViewModel]::SetPalette($palette)
    }

    # The worker flags dcu-cli 500 as NoUpdatesFound, wrapped in the invoke collection.
    hidden [bool] ScanFoundNoUpdates([AsyncJob]$job) {
        foreach ($item in @($job.Result)) {
            if ($null -ne $item -and $item.NoUpdatesFound) { return $true }
        }
        return $false
    }

    [void] CheckForManualReboot([AsyncJob]$job) {
        $needsReboot = $false

        # The apply worker sets RebootRequired on dcu-cli 1/5, wrapped in the invoke collection.
        foreach ($item in @($job.Result)) {
            if ($null -ne $item -and $item.RebootRequired) { $needsReboot = $true; break }
        }

        if ($needsReboot -and -not $this.ManualRebootQueue.Contains($job.HostName)) {
            $this.ManualRebootQueue.Add($job.HostName)
        }
    }

    [void] CopyUpdatesToClipboard([string]$hostName, [array]$updatesList) {
        try {
            $header = "Scanned in DONUT, found and installed the following $($updatesList.Count) updates on $hostName"
            Set-Clipboard -Value ((@($header) + @($updatesList | ForEach-Object { "- $_" })) -join "`n")
        }
        catch {
            $this.Logger.LogWarning("Failed to copy to clipboard: $($_.Exception.Message)")
        }
    }
}
