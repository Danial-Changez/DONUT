using namespace System.Windows.Controls
using namespace System.Windows.Shapes
using namespace System.Windows.Threading
using namespace System.Collections.Generic
using namespace Donut.Mvvm
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Models\FleetStatus.psm1"
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
    [bool] $PoolWarmed = $false   # single-shot guard for WarmPool
    [timespan] $InventoryTtl = [timespan]::FromMinutes(3)   # select-prefetch skips inventory fresher than this
    [timespan] $ScanCacheTtl = [timespan]::FromHours(24)    # reuse a scan/update-scan newer than this instead of re-scanning
    [string] $SelectedHost
    [hashtable] $LogBuffers   # hostname -> List[string] of accumulated job-log lines
    [int] $MaxLogLines = 2000 # ring-buffer cap for the in-memory log + detail TextBox

    # Detail-panel controls
    [System.Windows.UIElement] $DetailEmptyHint
    [System.Windows.UIElement] $DetailContent
    [TextBlock] $DetailHostText
    [TextBlock] $DetailProbed
    [Button] $DetailRefreshButton
    [TextBox] $DetailLog
    [ProgressBar] $DetailProgress
    [Button] $FindFoldersButton

    # Overview tile controls (mirror the selected remote machine)
    [TextBlock] $OvModel
    [TextBlock] $OvModelSub
    [TextBlock] $OvBattery
    [TextBlock] $OvBatterySub
    [TextBlock] $OvDisk
    [TextBlock] $OvDiskSub
    [TextBlock] $OvUpdates
    [TextBlock] $OvUpdatesSub

    # The search-bar AD finder + user Lens (extracted sub-presenter; holds a duck-typed
    # back-reference to this presenter for the machine-list seams).
    [FinderPresenter] $Finder
    [System.Windows.Window] $HostWindow    # parent window; hooked so the popup tracks moves/resizes

    # Async state ($ActiveJobs is inherited from AsyncJobPresenter)
    [DispatcherTimer] $Timer
    [DispatcherTimer] $IdleRefreshTimer   # advances idle rows' relative times every 30s

    # Host name -> HostViewModel (same instances live in $Vm.Machines)
    [hashtable] $Rows

    # Manual reboot queue - hosts that require manual reboot after update
    [System.Collections.Generic.List[string]] $ManualRebootQueue
    [int] $TotalJobsInBatch

    # Runs queued behind a reachability re-verification (see .NOTES); CompleteResolve
    # starts them or drops them with a reason - never left queued silently.
    hidden [hashtable] $PendingRuns = @{}

    # Inventory gathers queued the same way; CompleteResolve re-issues them for EVERY
    # verified host. Value = the strongest $force flag seen while queued.
    hidden [hashtable] $PendingGathers = @{}

    # Highest scan milestone seen per host for the CURRENT job (host -> 1..5); ratchets
    # so a re-emitted earlier line can't step backwards. Reset at job start.
    hidden [hashtable] $ScanSteps = @{}

    HomePresenter([AppConfig] $config, [System.Windows.FrameworkElement] $view, [NetworkProbe] $networkProbe, [ResourceService] $resources, [ToastService] $toasts, [object] $configManager) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.ViewContent = $view
        $this.Toasts = $toasts

        $this.NetworkProbe = $networkProbe
        $this.Logger = $networkProbe.Logger
        $this.ScanService = [ScanService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.DriverMatcher = [DriverMatchingService]::new($this.Logger)
        $this.UpdateService = [RemoteUpdateService]::new($config, $this.NetworkProbe, $this.DriverMatcher, $this.Logger)
        $this.DialogPresenter = [DialogPresenter]::new($resources)
        $this.Store = [RecentConnectionsStore]::new($config, $configManager)
        # Coalesce the store's config.json writes: mutations mark pending, flushed once per
        # drained batch / on close - "Run all" no longer serializes config per completion.
        $this.Store.DeferSave = $true
        $this.HostListSource = [HostListSource]::new($config.SourceRoot)
        $this.InventoryService = [InventoryService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.DiskUsageService = [DiskUsageService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.Resolver = [HostResolver]::new($config, $this.NetworkProbe, $this.Logger)

        # $this.ActiveJobs is initialized by the AsyncJobPresenter base constructor.
        $this.Rows = @{}
        $this.HomeVm = [HomeViewModel]::new()   # bound to the view; owns the machine collection
        $this.LogBuffers = @{}
        $this.ManualRebootQueue = [List[string]]::new()
        $this.TotalJobsInBatch = 0

        $presenter = $this
        $this.Timer = [DispatcherTimer]::new()
        $this.Timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $this.Timer.Add_Tick({ $presenter.OnTimerTick($this, $null) }.GetNewClosure())
        $this.Timer.Start()

        # Re-render idle rows so their relative times advance ("just now" -> "1 min ago");
        # cheap, since ApplyIdle only raises PropertyChanged for values that changed.
        $this.IdleRefreshTimer = [DispatcherTimer]::new()
        $this.IdleRefreshTimer.Interval = [TimeSpan]::FromSeconds(30)
        $this.IdleRefreshTimer.Add_Tick({ $presenter.RefreshIdleTimes() }.GetNewClosure())
        $this.IdleRefreshTimer.Start()

        # The search-bar AD finder + user Lens live in their own presenter; it shares the
        # HomeVm and calls back into this presenter's machine seams via $home.
        $this.Finder = [FinderPresenter]::new($config, $view, $this.HomeVm, $this.Logger, $toasts, $this.DialogPresenter, $this)

        $this.Initialize()
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

        $this.OvModel = $this.ViewContent.FindName('txtOvModel')
        $this.OvModelSub = $this.ViewContent.FindName('txtOvModelSub')
        $this.OvBattery = $this.ViewContent.FindName('txtOvBattery')
        $this.OvBatterySub = $this.ViewContent.FindName('txtOvBatterySub')
        $this.OvDisk = $this.ViewContent.FindName('txtOvDisk')
        $this.OvDiskSub = $this.ViewContent.FindName('txtOvDiskSub')
        $this.OvUpdates = $this.ViewContent.FindName('txtOvUpdates')
        $this.OvUpdatesSub = $this.ViewContent.FindName('txtOvUpdatesSub')

        # Detail panel
        $this.DetailEmptyHint = $this.ViewContent.FindName('DetailEmptyHint')
        $this.DetailContent = $this.ViewContent.FindName('DetailContent')
        $this.DetailHostText = $this.ViewContent.FindName('txtDetailHost')
        $this.DetailProbed = $this.ViewContent.FindName('txtDetailProbed')
        $this.DetailRefreshButton = $this.ViewContent.FindName('btnDetailRefresh')
        $this.DetailLog = $this.ViewContent.FindName('txtDetailLog')
        $this.DetailProgress = $this.ViewContent.FindName('DetailProgress')
        $this.FindFoldersButton = $this.ViewContent.FindName('btnFindFolders')
        # (Folders tree + its hint are fully binding-driven: SelectedMachine.Folders /
        # SelectedMachine.HasFolders - no FindName wiring.)

        $presenter = $this

        # MVVM: bind the view to the HomeViewModel so the machine ListBox renders from
        # $Vm.Machines, and react to selection (single click) to drive the detail panel.
        $this.ViewContent.DataContext = $this.HomeVm
        if ($this.MachineList) {
            $this.MachineList.Add_SelectionChanged({ $presenter.OnMachineSelectionChanged() }.GetNewClosure())
        }

        if ($this.SearchButton) { $this.SearchButton.Add_Click({ $presenter.OnSearch() }.GetNewClosure()) }
        if ($this.ClearButton) { $this.ClearButton.Add_Click({ $presenter.ClearCompleted() }.GetNewClosure()) }
        if ($this.RunAllButton) { $this.RunAllButton.Add_Click({ $presenter.RunAll() }.GetNewClosure()) }
        if ($this.ModeButton) { $this.ModeButton.Add_Click({ $presenter.CycleMode() }.GetNewClosure()) }
        if ($this.DetailRefreshButton) { $this.DetailRefreshButton.Add_Click({ $presenter.RefreshInventory($presenter.SelectedHost) }.GetNewClosure()) }
        if ($this.FindFoldersButton) { $this.FindFoldersButton.Add_Click({ $presenter.FindBigFolders($presenter.SelectedHost) }.GetNewClosure()) }
        # The finder wires the search bar's TextChanged/Escape + its popup (the bar itself
        # stays dual-use: OnSearch's Add flow reads and clears it here).
        $this.Finder.Initialize()

        # A WPF Popup is its own top-level window and does NOT follow the parent; hook the
        # host window (once in the visual tree) so the dropdown stays glued to the search box.
        $this.ViewContent.Add_Loaded({ $presenter.HookHostWindow() }.GetNewClosure())

        # Seed recents from WSID.txt the first time, then build a row per recent.
        if ($this.Store.Count() -eq 0) {
            $this.Store.SeedFrom($this.ReadWsidHosts())
        }
        $this.BuildRows()
        # Persist the one-time WSID seed now (store saves are deferred; see DeferSave).
        $this.Store.FlushSave()

        $this.UpdateModePill()
        $this.RefreshAll()

        # Start-early: seed the DC saved from a prior run so the very first selects resolve
        # immediately; the background warm refreshes it (a stale DC just falls back).
        $savedDc = [string]$this.Config.Settings['activeDomainController']
        if (-not [string]::IsNullOrWhiteSpace($savedDc)) { $this.Resolver.SetActiveDc($savedDc) }
        # Warm every pool runspace SYNCHRONOUSLY now, before the message loop starts - the
        # one safe time to take the loader-lock hit (see .NOTES). Brief one-time delay.
        $this.WarmPool()

        # Prime the AD finder + the persistent de-elevated Lens agent in the background
        # (NOT blocking, unlike WarmPool) so both are warm before the first keystroke/pick.
        $this.Finder.WarmAdSearch()
        $this.Finder.WarmLens()

        $this.StartWarm()
    }

    # --- Start-early IP resolution (background, off the UI thread) --------------------

    # One-time: discover + pick a live DC on the pool; cached when it completes.
    [void] StartWarm() {
        try {
            $prep = $this.Resolver.PrepareWarm()
            $job = [AsyncJob]::new('', [JobKind]::Resolve)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($job)
        }
        catch {
            $this.Logger.LogException("Resolver warm-up could not start", $_)
        }
    }

    # Warms every pool runspace's module graph SYNCHRONOUSLY: fires throttleLimit no-op
    # loads at once, then blocks until they finish. One-shot; loader-lock rationale in .NOTES.
    [void] WarmPool() {
        if ($this.PoolWarmed) { return }
        $this.PoolWarmed = $true
        $n = $this.Config.GetThrottleLimit()
        if ($n -lt 1) { $n = 1 }

        $pool = [RunspaceManager]::GetPool()
        $shells = [System.Collections.Generic.List[object]]::new()
        $handles = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $n; $i++) {
            try {
                $prep = $this.Resolver.PrepareWarmRunspace()
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = $pool
                $ps.AddCommand($prep.ScriptPath) | Out-Null
                foreach ($k in $prep.Arguments.Keys) { $ps.AddParameter($k, $prep.Arguments[$k]) | Out-Null }
                $handles.Add($ps.BeginInvoke())
                $shells.Add($ps)
            }
            catch {
                $this.Logger.LogException("Runspace warm-up could not start", $_)
            }
        }

        # Block (bounded) until each runspace has loaded the graph. WaitOne is STA-safe
        # (WaitHandle.WaitAll throws on an STA thread), so wait on the handles one by one.
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        for ($i = 0; $i -lt $shells.Count; $i++) {
            try {
                $remaining = [int][Math]::Max(0, [Math]::Ceiling(($deadline - [datetime]::UtcNow).TotalMilliseconds))
                if ($handles[$i].AsyncWaitHandle.WaitOne($remaining)) {
                    $shells[$i].EndInvoke($handles[$i])
                }
            }
            catch {
                $this.Logger.LogException("Runspace warm-up failed", $_)
            }
            finally {
                try { $shells[$i].Dispose() } catch { }
            }
        }
        $this.Logger.LogInfo("Pre-warmed $($shells.Count) runspace(s).")
    }

    # Resolve a host's IP in the background (single-flight). No-op until a DC is
    # warmed or if the host is already cached / in flight.
    [void] PrefetchIp([string]$hostName) {
        if (-not $this.Resolver.NeedsResolve($hostName)) { return }
        try {
            $this.Resolver.MarkInFlight($hostName)
            $prep = $this.Resolver.PrepareResolve($hostName)
            $job = [AsyncJob]::new($hostName, [JobKind]::Resolve)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($job)
        }
        catch {
            # The latch is set before the job starts; release it if it didn't, or the host
            # wedges (NeedsResolve stays false forever -> never re-resolves).
            $this.Resolver.ClearInFlight($hostName)
            $this.Logger.LogException("[$hostName] IP pre-resolve could not start", $_)
        }
    }

    # A job failed: the cached IP may be dead/stale, so drop it and re-resolve the
    # current IP in the background, ready for a retry.
    [void] InvalidateResolved([string]$hostName) {
        $this.Resolver.Invalidate($hostName)
        $this.PrefetchIp($hostName)
    }

    # Resolve job finished: cache the DC (warm) or the per-host verdict (fresh IP +
    # online), detect an IP change, persist the DC, and refresh the offline indicator.
    [void] CompleteResolve([AsyncJob]$job) {
        if ($job.Status -eq 'Failed') {
            # Even a failed resolve must release the single-flight latch, or NeedsResolve
            # stays false forever and the host wedges; the empty cache forces a fresh resolve.
            $this.Resolver.ClearInFlight($job.HostName)
            # A queued run can't proceed without a verdict - drop it with a reason
            # instead of leaving it queued silently forever.
            if ($this.PendingRuns.ContainsKey($job.HostName)) {
                $this.PendingRuns.Remove($job.HostName)
                $this.AppendLog($job.HostName, "Run not started: could not verify reachability (resolve failed).")
                if ($this.Toasts) { $this.Toasts.ShowWarning($job.HostName, "Run not started - could not verify $($job.HostName) is reachable.") }
            }
            return
        }
        foreach ($item in @($job.Result)) {
            if ($null -eq $item) { continue }
            $mode = [string]$item.Mode
            if ($mode -eq 'Warm') {
                $dc = [string]$item.ActiveDc
                if (-not [string]::IsNullOrWhiteSpace($dc)) {
                    $this.Resolver.SetActiveDc($dc)
                    $this.PersistDomainController($dc, @($item.DomainControllers))
                }
            }
            elseif ($mode -eq 'Host') {
                $hn = [string]$item.HostName
                $newIp = [string]$item.Ip
                $online = [bool]$item.Online
                $oldIp = $this.Resolver.GetCachedIp($hn)
                # Log only a first find or an actual change - never a same-IP TTL refresh.
                if (-not [string]::IsNullOrWhiteSpace($newIp) -and $oldIp -ne $newIp) {
                    if ([string]::IsNullOrWhiteSpace($oldIp)) { $this.Logger.LogInfo("[$hn] resolved IP $newIp") }
                    else { $this.Logger.LogInfo("[$hn] IP changed: $oldIp -> $newIp") }
                }
                $this.Resolver.CacheVerdict($hn, $newIp, $online)
                $this.RenderReachability($hn)
                # If this host's detail panel is open, surface the freshly-resolved IP
                # in the subtitle now that the verdict is known.
                if ($hn -eq $this.SelectedHost) {
                    $rcSel = $this.GetRecord($hn)
                    $iso = if ($null -ne $rcSel -and $null -ne $rcSel.Inventory) { $rcSel.Inventory.ProbedAt } else { '' }
                    $this.RenderDetailSubtitle($hn, $iso)
                }
                # A gather was queued behind this re-verification: re-issue it now.
                # (StartInventory logs the skip itself if the verdict came back Offline.)
                if ($this.PendingGathers.ContainsKey($hn)) {
                    $gatherForce = [bool]$this.PendingGathers[$hn]
                    $this.PendingGathers.Remove($hn)
                    $this.StartInventory($hn, $gatherForce)
                }
                # A Run was queued behind this re-verification (StartProcess found the
                # verdict missing/stale): start it now that a fresh verdict landed.
                if ($this.PendingRuns.ContainsKey($hn)) {
                    $this.PendingRuns.Remove($hn)
                    if ($online) {
                        $this.StartProcess($hn)
                    } else {
                        $this.AppendLog($hn, "Host is offline - queued run skipped.")
                        if ($this.Toasts) { $this.Toasts.ShowWarning($hn, "$hn is offline - run skipped.") }
                    }
                }
            }
            elseif ($mode -eq 'Name') {
                $this.Resolver.CacheName([string]$item.HostName, [string]$item.ActualName)
            }
            elseif ($mode -eq 'WarmRunspace') {
                # No-op: the job's purpose was loading the module graph into its runspace.
            }
        }
    }

    # Fires the identity check (what name does the box at this IP report?) as its own
    # pool job, parallel with the apply-scan; its verdict gates the destructive apply.
    [void] StartVerifyName([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($this.Resolver.GetCachedIp($hostName))) { return }
        $this.Resolver.ClearVerifiedName($hostName)
        try {
            $prep = $this.Resolver.PrepareName($hostName)
            $job = [AsyncJob]::new($hostName, [JobKind]::Resolve)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($job)
        }
        catch {
            $this.Logger.LogException("[$hostName] identity check could not start", $_)
        }
    }

    # Persists the active DC (and list) so the next launch can resolve immediately,
    # without waiting on AD discovery. Only writes when something changed.
    hidden [void] PersistDomainController([string]$dc, [string[]]$list) {
        if ($null -eq $this.ConfigManager) { return }
        $changed = $false
        if ([string]$this.Config.Settings['activeDomainController'] -ne $dc) {
            $this.Config.Settings['activeDomainController'] = $dc
            $changed = $true
        }
        if ($null -ne $list -and $list.Count -gt 0) {
            $existing = @($this.Config.Settings['domainControllers'])
            if (($existing -join '|') -ne ($list -join '|')) {
                $this.Config.Settings['domainControllers'] = @($list)
                $changed = $true
            }
        }
        if ($changed) {
            try { $this.ConfigManager.SaveConfig($this.Config) }
            catch { $this.Logger.LogException("Could not persist domain controller", $_) }
        }
    }

    # Reflects a host's cached online/offline verdict on its idle row. No row update
    # while a job is running on that host (live status owns the dot/subtitle then).
    [void] RenderReachability([string]$hostName) {
        $state = $this.Resolver.IsHostOnline($hostName)
        $row = $this.GetRow($hostName)
        # SetReachability updates the row dot/chip AND the view-model's DetailTitle (the
        # detail header binds to SelectedMachine.DetailTitle), so no control poke needed.
        if ($row -and -not $this.IsRunning($hostName)) { $row.SetReachability($state) }
    }

    # Threads this host's prefetched IP into a worker-args bundle's Options, so the
    # worker skips DNS on the hot path. No-op when the IP isn't cached yet.
    hidden [void] AttachResolvedIp([hashtable]$prep, [string]$hostName) {
        $ip = $this.Resolver.GetCachedIp($hostName)
        if ([string]::IsNullOrWhiteSpace($ip)) { return }
        # Seed the dedicated ResolvedIp argument - NOT an Options key, which /applyUpdates
        # merges into dcu-cli args (DCU rejects a bogus -ResolvedIp=<ip> with 105).
        if ($prep -and $prep.Arguments) {
            $prep.Arguments.ResolvedIp = $ip
        }
    }

    [void] UpdateModePill() {
        # The Add button is static ("Add" = queue + gather inventory); only the mode
        # pill reflects the active command that Run / Run all will execute.
        $command = $this.Config.GetActiveCommand()
        $label = if ($command -eq 'applyUpdates') { "Apply Updates" } else { "Scan" }
        if ($this.ModePill) { $this.ModePill.Text = $label }
    }

    # Quick config pick: cycle the active command (Scan <-> Apply Updates) using
    # each command's configured defaults, persist it, and refresh the labels.
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

    # "Add": queue the typed host(s) into the machine list and gather inventory. Never
    # scans/applies - running the active command is a separate, deliberate step.
    [void] OnSearch() {
        $rawInput = $this.SearchBar.Text
        if ([string]::IsNullOrWhiteSpace($rawInput)) { return }

        $targetHosts = $rawInput -split "[\r\n,]+" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }

        if ($targetHosts.Count -eq 0) { return }

        foreach ($hostName in $targetHosts) {
            $this.EnsureRow($hostName)
            $this.PrefetchIp($hostName)        # resolve now so the row shows online/offline on Add
            $this.StartInventory($hostName, $true)
        }
        # Newest action on top: surface the added cards at the head of the list
        # (moved in reverse so the FIRST typed host ends up topmost).
        $ordered = @($targetHosts)
        [array]::Reverse($ordered)
        foreach ($hostName in $ordered) { $this.MoveRowToTop($hostName) }
        $this.SelectMachine($targetHosts[0])
        $this.UpdateEmptyHint()

        $this.SearchBar.Text = ""
    }

    # "Run all": run the active command on every idle machine. One confirmation for a
    # destructive batch; per-host runs still go through StartProcess.
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

    # Subscribes (once, from ViewContent.Loaded) to the parent window's move/resize so
    # an open search popup stays positioned under the search box.
    [void] HookHostWindow() {
        if ($null -ne $this.HostWindow) { return }
        $w = [System.Windows.Window]::GetWindow($this.ViewContent)
        if ($null -eq $w) { return }
        $this.HostWindow = $w
        $presenter = $this
        $w.Add_LocationChanged({ $presenter.Finder.RepositionSearchPopup() }.GetNewClosure())
        $w.Add_SizeChanged({ $presenter.Finder.RepositionSearchPopup() }.GetNewClosure())
        # On close: persist any deferred recents, then let the finder stop the de-elevated
        # Lens agent and purge its exchange dirs.
        $w.Add_Closing({
                try { $presenter.Store.FlushSave() } catch { }
                try { $presenter.Finder.OnAppClosing() } catch { }
            }.GetNewClosure())
    }

    # Runs a single host from a row click; confirms first when destructive.
    [void] RunHost([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        if ($this.IsRunning($hostName)) {
            # Say why nothing happened - a storage scan also holds the row busy, and
            # a silent return reads as a dead Run button.
            $this.AppendLog($hostName, "A job is already running for $hostName - wait for it to finish.")
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
                $job.JobType -ne [JobKind]::Inventory -and $job.JobType -ne [JobKind]::Resolve) { return $true }
        }
        return $false
    }

    # True when the host's last scan can be reused instead of re-scanning (see
    # ScanCacheDecision). Wires the recents fields + on-disk report to the pure rule.
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

        # Never scan/apply a host that is offline or unresolved (see the reachability
        # gating note in .NOTES). Surface it and bail; for unknown, kick a resolve.
        $reach =$this.Resolver.IsHostOnline($hostName)
        if ($reach -eq 'Offline') {
            $this.AppendLog($hostName, "Host is offline - skipping $command.")
            if ($this.Toasts) { $this.Toasts.ShowWarning($hostName, "$hostName is offline - skipped.") }
            if ($row) { $row.SetReachability('Offline') }
            return
        }
        if ($reach -ne 'Online' -or $this.Resolver.IsVerdictStale($hostName)) {
            # Unknown host or stale 'Online' verdict: re-verify off-thread and QUEUE the
            # run; CompleteResolve starts it automatically once the fresh verdict lands.
            if (-not $this.Resolver.HasActiveDc()) {
                # Startup edge: no DC warmed yet means a resolve can't run, so don't
                # queue (it would sit forever) - surface why instead.
                $this.AppendLog($hostName, "Resolver not ready yet (no domain controller) - try again shortly.")
                return
            }
            $this.PendingRuns[$hostName] = $true
            $this.PrefetchIp($hostName)
            $this.AppendLog($hostName, "Verifying $hostName is reachable - the run starts automatically once confirmed.")
            return
        }

        # Reuse a scan from the last 24h. A successful apply flips the host's last job to
        # UpdateApply, making this false - so the next run re-scans (the intended bypass).
        if (($command -eq 'scan' -or $command -eq 'applyUpdates') -and $this.RecentScanIsFresh($hostName)) {
            $rc = $this.GetRecord($hostName)
            $age = [TimeFormat]::Relative([RecentConnectionsStore]::ParseSeen($rc.LastSeen))
            if ($command -eq 'applyUpdates') {
                $this.AppendLog($hostName, "Reusing scan from $age (under 24h); skipping re-scan.")
                $this.ProceedWithApply($hostName)
            } else {
                $this.AppendLog($hostName, "Scanned $age - results are current; skipping re-scan.")
                if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "Scanned $age - results are current.") }
                $this.RefreshOverview()
            }
            return
        }

        $this.AppendLog($hostName, "Starting $command for $hostName...")
        $this.ScanSteps.Remove($hostName)   # fresh job, fresh step ratchet

        try {
            $jobParams = switch ($command) {
                'scan' {
                    @{ Type = 'Scan'; Prep = $this.ScanService.PrepareScan($hostName) }
                }
                'applyUpdates' {
                    $this.AppendLog($hostName, "Phase 1: Scanning for updates...")
                    @{ Type = 'UpdateScan'; Prep = $this.UpdateService.PrepareScanForUpdates($hostName) }
                }
                default {
                    $this.AppendLog($hostName, "Command '$command' not implemented yet.")
                    $null
                }
            }

            if ($jobParams) {
                $this.AttachResolvedIp($jobParams.Prep, $hostName)
                $job = [AsyncJob]::new($hostName, $jobParams.Type)
                $job.Start($jobParams.Prep.ScriptPath, $jobParams.Prep.Arguments, $jobParams.Prep.TempConfigPath)
                $this.ActiveJobs.Add($job)
                $this.RefreshCardStatus($job)
                $this.RefreshOverview()
                # Inventory is never piggy-backed on a run (gathers are explicit). Apply is
                # destructive: kick the identity check now, in parallel, to gate the apply.
                if ($command -eq 'applyUpdates') { $this.StartVerifyName($hostName) }
            }
        }
        catch {
            $this.AppendLog($hostName, "Error starting process: $_")
            $row.ApplyStatus([FleetStatus]::FromJob('Scan', 'Failed', $false))
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Failed to start: $_") }
        }
    }

    # Timer Tick handler: drive the shared job-polling lifecycle (AsyncJobPresenter).
    [void] OnTimerTick($sender, $e) {
        try {
            $this.PumpJobs()
        }
        catch {
            $this.Logger.LogException("Error during job pump", $_)
        }
    }

    # Per-tick: stream the job's queued output into the (selected host's) detail
    # log and keep the row status/progress live. Inventory probes only stream.
    [void] OnJobPolled([AsyncJob]$job) {
        # Resolve jobs are pure background precompute - no row/progress/log UI.
        if ($job.JobType -eq [JobKind]::Resolve) { return }

        # Drain this tick's queued output once, then append as a single batch.
        $lines = [System.Collections.Generic.List[string]]::new()
        $line = $null
        while ($job.Logs.TryDequeue([ref]$line)) { $lines.Add($line) }

        if ($job.JobType -eq [JobKind]::Inventory -or $job.JobType -eq [JobKind]::DiskScan) {
            if ($lines.Count -gt 0) { $this.AppendLogLines($job.HostName, $lines.ToArray()) }
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
        if ($lines.Count -gt 0) { $this.AppendLogLines($job.HostName, $lines.ToArray()) }

        $row = $this.GetRow($job.HostName)
        if ($row -and $latestPct -ge 0) { $row.SetPercent($latestPct) }

        # Scan milestones -> "N/5 label", ratcheted per host. Scan jobs (no percent output)
        # also drive the bar from the step; an apply's own percent lines own the bar (-1).
        $prev =if ($this.ScanSteps.ContainsKey($job.HostName)) { [int]$this.ScanSteps[$job.HostName] } else { 0 }
        if ($row -and $latestStep -gt $prev) {
            $this.ScanSteps[$job.HostName] = $latestStep
            $label = [DcuProgress]::ScanStepLabel($latestStep)
            $stepPct = if ($job.JobType -eq 'UpdateApply') { -1 } else { $latestStep * 100.0 / [DcuProgress]::ScanStepCount }
            $row.SetScanStep("$latestStep/$([DcuProgress]::ScanStepCount) $label", $stepPct)
        }

        $this.RefreshCardStatus($job)
    }

    # Terminal: inventory probes finish via CompleteInventory; scan/apply do
    # driver-match analysis / apply-phase transition / recents persistence.
    [void] OnJobCompleted([AsyncJob]$job) {
        if ($job.JobType -eq [JobKind]::Resolve) {
            $this.CompleteResolve($job)
            return
        }
        if ($job.JobType -eq [JobKind]::Inventory) {
            $this.CompleteInventory($job)
            return
        }
        if ($job.JobType -eq [JobKind]::DiskScan) {
            $this.CompleteDiskScan($job)
            return
        }

        # No end-of-job log dump: the worker already live-tailed dcu-cli's outputLog (the
        # old dump also replayed a STALE previous-run file after a failed job).
        $this.AppendLog($job.HostName, "Job $($job.JobType) finished: $($job.Status)")

        # Transition to apply phase after a successful update scan.
        $transitioned = $false
        if ($job.Status -eq 'Completed' -and $job.JobType -eq 'UpdateScan') {
            $transitioned = $this.ProceedWithApply($job.HostName)
        }

        if ($job.JobType -eq 'UpdateApply' -and $job.Status -eq 'Completed') {
            $this.CheckForManualReboot($job)
            if ($this.Toasts) {
                if ($this.ManualRebootQueue.Contains($job.HostName)) {
                    $this.Toasts.ShowWarning($job.HostName, "Updates applied - manual reboot required.")
                } else {
                    $this.Toasts.ShowSuccess($job.HostName, "Updates applied successfully.")
                }
            }
        }

        if ($job.Status -eq 'Failed') {
            $this.InvalidateResolved($job.HostName)
            if ($this.Toasts) { $this.Toasts.ShowError($job.HostName, "$($job.JobType) failed. Open the log for details.") }
        }

        # Persist + settle the row unless we just kicked off an apply.
        if (-not $transitioned) {
            $this.SettleHost($job)
        }
    }

    # End of tick: refresh fleet counts and, once the batch fully drains, persist the
    # coalesced recents in one write. (Reboot-required is announced per-host at completion.)
    [void] AfterPump() {
        $this.RefreshOverview()
        if ($this.ActiveJobs.Count -eq 0) {
            $this.Store.FlushSave()
        }
    }

    # A confirm/alert/update dialog is modal; while one is up the pump must not open
    # another (it would deadlock the UI). PumpJobs defers completion work until it closes.
    [bool] IsModalOpen() {
        return ($null -ne $this.DialogPresenter) -and $this.DialogPresenter.IsShowing
    }

    # Records the host's final state into the recent store and renders the row idle.
    [void] SettleHost([AsyncJob]$job) {
        $reboot = $this.ManualRebootQueue.Contains($job.HostName)
        $status = if ($job.Status -eq 'Failed') {
            # The exception type is lost across the runspace boundary; re-derive the reason
            # from the message: Offline -> grey, unconfirmed connection-lost -> amber, else red.
            switch ([RemoteFailure]::ReasonFromMessage($job.FailureMessage)) {
                ([RemoteFailureReason]::Offline)        { 'Offline' }
                ([RemoteFailureReason]::ConnectionLost) { 'ConnectionLost' }
                default                                 { 'Failed' }
            }
        } elseif ($reboot) {
            'RebootRequired'
        } else {
            'Completed'
        }

        # applyUpdates doesn't regenerate the scan report, so re-parsing would keep the old
        # count: treat a successful apply as 0 pending (a needed reboot is flagged separately).
        $updateCount =if ($job.JobType -eq 'UpdateApply' -and $job.Status -eq 'Completed') {
            0
        } else {
            $this.UpdateService.CountUpdates($this.UpdateService.ParseUpdateReport($job.HostName))
        }

        $this.Store.Upsert($job.HostName, $status, $job.JobType, $updateCount, $reboot)

        # The reboot flag is persisted + toasted; consume the queue entry so a later run
        # can't inherit a stale "reboot required" it already satisfied.
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
        $row.ApplyStatus([FleetStatus]::FromJob($job.JobType, $job.Status, $rebootRequired))
    }

    # Aborts a pending apply ($true) when the identity check CONFIRMED the IP answers as a
    # different machine. Called twice - the verdict may land while the confirm dialog is up.
    hidden [bool] AbortOnIdentityMismatch([string]$hostName) {
        if ($this.Resolver.IdentityVerdict($hostName) -ne 'Mismatch') { return $false }
        $actual = $this.Resolver.GetVerifiedName($hostName)
        $this.AppendLog($hostName, "Apply aborted: that address answers as '$actual', not '$hostName' - its IP changed. Re-select to re-resolve.")
        if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Apply aborted: address now answers as '$actual'. Re-select and retry.") }
        $this.InvalidateResolved($hostName)
        return $true
    }

    # Analyses the update report, confirms with the operator, and kicks the apply ($true =
    # apply started). Takes a hostName so a reused <24h scan can call it directly.
    [bool] ProceedWithApply([string]$hostName) {
        # Identity gate: on a confirmed mismatch the IP now answers as a different machine -
        # abort before applying, drop the stale IP, re-resolve.
        if ($this.AbortOnIdentityMismatch($hostName)) { return $false }

        $report = $this.UpdateService.ParseUpdateReport($hostName)

        if (-not $report) {
            $this.AppendLog($hostName, "No report generated or scan failed.")
            return $false
        }

        $updateNodes = $report.SelectNodes("//update")
        if ($updateNodes.Count -eq 0) {
            $this.AppendLog($hostName, "No updates found.")
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "No updates found.") }
            return $false
        }

        $this.AppendLog($hostName, "Found $($updateNodes.Count) updates. Analyzing driver matches...")

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

        # Surface the identity verdict in the dialog: confirmed Match, or still pending
        # (the check runs in parallel with the scan and may not have landed yet).
        $identityLine =if ($this.Resolver.IdentityVerdict($hostName) -eq 'Match') {
            "Identity verified: the machine answers as '$($this.Resolver.GetVerifiedName($hostName))'."
        } else {
            "Identity not verified yet (name check still pending) - proceed with care."
        }
        $displayList = @($identityLine, '') + $displayList

        $this.AppendLog($hostName, "Driver analysis complete. Waiting for confirmation...")
        $confirmed = $this.DialogPresenter.ShowConfirmation("Updates Available", "Updates found for $hostName", $displayList)

        if (-not $confirmed) {
            $this.AppendLog($hostName, "Cancelled by user.")
            return $false
        }

        # Re-check AFTER the dialog: the parallel name-check may have landed a Mismatch
        # while the operator was reading it (the pump keeps draining resolve jobs).
        if ($this.AbortOnIdentityMismatch($hostName)) { return $false }

        $this.AppendLog($hostName, "Confirmed. Phase 2: Applying updates...")
        $this.CopyUpdatesToClipboard($hostName, $clipboardList)
        $this.AppendLog($hostName, "Updates list copied to clipboard.")

        try {
            $this.ScanSteps.Remove($hostName)   # apply re-emits the scan milestones; restart the ratchet
            $prep = $this.UpdateService.PrepareApplyUpdates($hostName, @{})
            $this.AttachResolvedIp($prep, $hostName)
            $applyJob = [AsyncJob]::new($hostName, 'UpdateApply')
            $applyJob.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($applyJob)
            $this.RefreshCardStatus($applyJob)
            return $true
        }
        catch {
            $this.AppendLog($hostName, "Error starting apply phase: $_")
            return $false
        }
    }

    # Returns the existing row view-model for a host, or builds and inserts a new one.
    # Adds to $Vm.Machines (the bound collection); the ListBox renders it via the template.
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

    # Moves a host's card to the top (newest-action-first), on OPERATOR actions only -
    # background completions never reorder. Touch stamps the store so the order persists.
    # (Public: part of the FinderPresenter seam, like EnsureRow/StartInventory.)
    [void] MoveRowToTop([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $vm = $this.GetRow($hostName)
        if ($null -eq $vm) { return }
        $this.Store.Touch($hostName)
        $idx = $this.HomeVm.Machines.IndexOf($vm)
        if ($idx -gt 0) { $this.HomeVm.Machines.Move($idx, 0) }
    }

    # --- Detail panel + inventory probe ----------------------------------------------

    # Appends a job-output line to the host's buffer and, when it's the selected
    # host, to the live detail log.
    [void] AppendLog([string]$hostName, [string]$text) {
        $this.AppendLogLines($hostName, @($text))
    }

    # Batched log append: buffer all lines at once, cap the ring buffer, and touch the
    # detail TextBox a single time (one AppendText + one ScrollToEnd) instead of per line.
    [void] AppendLogLines([string]$hostName, [string[]]$lines) {
        if ($null -eq $lines -or $lines.Count -eq 0) { return }
        if (-not $this.LogBuffers.ContainsKey($hostName)) {
            $this.LogBuffers[$hostName] = [System.Collections.Generic.List[string]]::new()
        }
        $buf = $this.LogBuffers[$hostName]
        $buf.AddRange($lines)

        # Ring-buffer cap: keep memory (and the TextBox) bounded over a long session.
        $trimmed = $false
        if ($buf.Count -gt $this.MaxLogLines) {
            $buf.RemoveRange(0, $buf.Count - $this.MaxLogLines)
            $trimmed = $true
        }

        if ($hostName -eq $this.SelectedHost -and $this.DetailLog) {
            if ($trimmed) {
                # Old lines were dropped - re-render the (now capped) buffer once.
                $this.DetailLog.Text = (($buf -join "`n") + "`n")
            } else {
                $this.DetailLog.AppendText((($lines -join "`n") + "`n"))
            }
            $this.DetailLog.ScrollToEnd()
        }
    }

    # ListBox selection changed (single click, or programmatic via HomeVm.SetSelected):
    # open the detail panel for the newly selected host, or clear it on deselect.
    [void] OnMachineSelectionChanged() {
        $item = if ($this.MachineList) { $this.MachineList.SelectedItem } else { $null }
        # Drive HomeVm.SelectedMachine ourselves so the SelectedMachine.* bindings track
        # the selection; the ListBox's own SelectedItem still owns the row highlight.
        $this.HomeVm.SetSelected($item)
        if ($item) { $this.SelectHost([string]$item.HostName) }
        else { $this.ClearSelection() }
    }

    # Programmatic selection: select the row in the ListBox; its SelectionChanged then
    # sets SelectedMachine and opens the detail. Used by Add and AD-picked computers.
    [void] SelectMachine([string]$hostName) {
        $rowVm = $this.GetRow($hostName)
        if ($rowVm -and $this.MachineList) { $this.MachineList.SelectedItem = $rowVm }
    }

    # Opens the detail panel (single click): renders cached inventory/folders instantly and
    # does NOT touch the network - a fresh probe needs double-click or Refresh.
    [void] SelectHost([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $this.SelectedHost = $hostName

        # Start-early: resolve this host's IP in the background now, so it's cached
        # before the operator double-clicks to gather inventory or hits Run.
        $this.PrefetchIp($hostName)

        # Detail-pane visibility is binding-driven (HomeVm.DetailMode): SetSelected already
        # flipped it to 'Machine', and the header binds to SelectedMachine.* - no pokes.
        if ($this.DetailLog) {
            $this.DetailLog.Clear()
            if ($this.LogBuffers.ContainsKey($hostName)) {
                $this.DetailLog.Text = (($this.LogBuffers[$hostName]) -join "`n") + "`n"
            }
            $this.DetailLog.ScrollToEnd()
        }

        $rc = $this.GetRecord($hostName)
        $cachedInv = if ($null -ne $rc) { $rc.Inventory } else { $null }
        $this.PopulateDetailCards($hostName, $cachedInv, $rc)
        # Folders tree binds to SelectedMachine.Folders; same-instance re-applies are
        # skipped, so re-selecting keeps the tree's expansion state.
        $cachedDisk =if ($null -ne $rc) { $rc.DiskUsage } else { $null }
        $rowVm = $this.GetRow($hostName)
        if ($rowVm) { $rowVm.ApplyFolders($cachedDisk) }

        # Reflect any already-known reachability verdict immediately (a fresh
        # PrefetchIp above will update it when it lands).
        $this.RenderReachability($hostName)

        # Gather inventory, or queue it behind the reachability verdict (see .NOTES) - so
        # selecting an unreachable machine can never open the freeze-prone connect.
        $this.StartInventory($hostName, $false)
    }

    # Double-clicking a row: select it (cheap, cached) and gather fresh inventory
    # in the background. The probe runs on the runspace pool, never the UI thread.
    [void] OnRowActivated([string]$hostName) {
        $this.MoveRowToTop($hostName)
        $this.SelectMachine($hostName)
        $this.StartInventory($hostName)
    }

    # Clears the current selection and returns the detail pane to its empty state.
    # (The ListBox selected visual clears itself when its SelectedItem goes null.)
    [void] ClearSelection() {
        $this.SelectedHost = $null
        # Visibility is binding-driven (HomeVm.DetailMode); SetSelected($null) put it back
        # to 'Empty' before we got here (unless a Lens is showing, which it leaves alone).
        $this.UpdateOverviewTiles()
    }

    # Explicit gather (double-click / Refresh): forces a fresh probe regardless of TTL.
    [void] StartInventory([string]$hostName) {
        $this.StartInventory($hostName, $true)
    }

    # Queues a background inventory probe. Single-flight; when $force is false (select-time
    # prefetch) a host with fresh cached inventory is also skipped.
    [void] StartInventory([string]$hostName, [bool]$force) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        # Only gather from a host we already know is online, so the worker reuses the
        # cached IP (see the reachability gating note in .NOTES).
        $state = $this.Resolver.IsHostOnline($hostName)
        if ($state -eq 'Offline') {
            $this.AppendLog($hostName, "Host is offline - skipping inventory.")
            return
        }
        # Unknown or stale-'Online' verdict: re-validate off-thread and QUEUE the gather
        # (strongest force wins); CompleteResolve re-issues it when the verdict lands.
        if ($state -ne 'Online' -or $this.Resolver.IsVerdictStale($hostName)) {
            $prevForce = $this.PendingGathers.ContainsKey($hostName) -and [bool]$this.PendingGathers[$hostName]
            $this.PendingGathers[$hostName] = ($force -or $prevForce)
            $this.PrefetchIp($hostName)
            return
        }
        foreach ($j in $this.ActiveJobs) {
            if ($j -and $j.HostName -eq $hostName -and $j.JobType -eq [JobKind]::Inventory) { return }
        }
        if (-not $force -and -not $this.InventoryIsStale($hostName)) { return }
        try {
            $this.AppendLog($hostName, "Gathering inventory...")
            if ($hostName -eq $this.SelectedHost -and $this.DetailProgress) {
                $this.DetailProgress.IsIndeterminate = $true
                $this.DetailProgress.Visibility = [System.Windows.Visibility]::Visible
            }
            $prep = $this.InventoryService.PrepareInventory($hostName)
            $this.AttachResolvedIp($prep, $hostName)
            $job = [AsyncJob]::new($hostName, [JobKind]::Inventory)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($job)
        }
        catch {
            $this.AppendLog($hostName, "Inventory probe could not start: $_")
            if ($hostName -eq $this.SelectedHost -and $this.DetailProgress) {
                $this.DetailProgress.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    }

    # Forces a re-probe of the selected host (detail-panel Refresh).
    [void] RefreshInventory([string]$hostName) {
        $this.MoveRowToTop($hostName)
        $this.StartInventory($hostName)
    }

    # True when a host has no cached inventory or its last probe is older than the TTL.
    [bool] InventoryIsStale([string]$hostName) {
        $rc = $this.GetRecord($hostName)
        if ($null -eq $rc -or $null -eq $rc.Inventory) { return $true }
        $probed = [RecentConnectionsStore]::ParseSeen($rc.Inventory.ProbedAt)
        if ($probed -eq [datetime]::MinValue) { return $true }
        return (([datetime]::UtcNow - $probed) -gt $this.InventoryTtl)
    }

    # Inventory job finished: parse + cache + repopulate the detail cards.
    [void] CompleteInventory([AsyncJob]$job) {
        $hostName = $job.HostName
        # The card may have been cleared mid-probe (probes don't count as "running");
        # persisting now would re-create a ghost recents entry - drop the result instead.
        if (-not $this.Rows.ContainsKey($hostName)) { return }
        if ($hostName -eq $this.SelectedHost -and $this.DetailProgress) {
            $this.DetailProgress.IsIndeterminate = $false
            $this.DetailProgress.Visibility = [System.Windows.Visibility]::Collapsed
        }

        if ($job.Status -eq 'Failed') {
            $this.AppendLog($hostName, "Inventory probe failed.")
            $this.InvalidateResolved($hostName)
            return
        }

        $inv = $this.InventoryService.ParseInventory($hostName)
        if ($null -eq $inv) {
            $this.AppendLog($hostName, "Inventory probe returned no data.")
            return
        }

        $this.Store.UpsertInventory($hostName, $inv)
        $this.AppendLog($hostName, "Inventory updated.")

        # Push onto the host's view-model (bound; updates the overview/detail if it's the
        # selected machine, and stays ready if it's selected later).
        $rc = $this.GetRecord($hostName)
        $cached = if ($null -ne $rc -and $null -ne $rc.Inventory) { $rc.Inventory } else { $inv }
        $this.PopulateDetailCards($hostName, $cached, $rc)
    }

    # Queues the on-demand "biggest folders on C:" scan (single-flight). Heavier than the
    # inventory probe (deploys + runs WizTree), so it only runs from the button.
    [void] FindBigFolders([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        foreach ($j in $this.ActiveJobs) {
            if ($j -and $j.HostName -eq $hostName -and $j.JobType -eq [JobKind]::DiskScan) {
                # Say so instead of silently ignoring the click - otherwise a slow scan
                # reads as a dead button (the worker watchdog fails a hung one eventually).
                $this.AppendLog($hostName, "A storage scan is already running for $hostName - wait for it to finish (or time out).")
                return
            }
        }
        $this.MoveRowToTop($hostName)
        try {
            $this.AppendLog($hostName, "Scanning C: for largest folders...")
            if ($hostName -eq $this.SelectedHost -and $this.DetailProgress) {
                $this.DetailProgress.IsIndeterminate = $true
                $this.DetailProgress.Visibility = [System.Windows.Visibility]::Visible
            }
            $prep = $this.DiskUsageService.PrepareDiskScan($hostName)
            $this.AttachResolvedIp($prep, $hostName)
            $job = [AsyncJob]::new($hostName, [JobKind]::DiskScan)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($job)
        }
        catch {
            $this.AppendLog($hostName, "Disk scan could not start: $_")
            $this.Logger.LogException("Disk scan failed to start for $hostName", $_)
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Could not start disk scan.") }
            if ($hostName -eq $this.SelectedHost -and $this.DetailProgress) {
                $this.DetailProgress.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    }

    # Disk-scan job finished: parse the WizTree CSV + cache + render the folder list.
    [void] CompleteDiskScan([AsyncJob]$job) {
        $hostName = $job.HostName
        if ($hostName -eq $this.SelectedHost -and $this.DetailProgress) {
            $this.DetailProgress.IsIndeterminate = $false
            $this.DetailProgress.Visibility = [System.Windows.Visibility]::Collapsed
        }

        if ($job.Status -eq 'Failed') {
            $this.AppendLog($hostName, "Disk scan failed.")
            $this.InvalidateResolved($hostName)
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

        # Apply onto the host's view-model regardless of selection: the tree binds to
        # SelectedMachine.Folders, so it shows now if selected and is ready if selected later.
        $row = $this.GetRow($hostName)
        if ($row) { $row.ApplyFolders($report) }
    }

    # Sets the detail-header subtitle (IP + probe freshness) on the host's view-model;
    # the detail pane binds to SelectedMachine.ProbedText.
    hidden [void] RenderDetailSubtitle([string]$hostName, [string]$probedIso) {
        $vm = $this.GetRow($hostName)
        if ($vm) { $vm.SetProbed($this.Resolver.GetCachedIp($hostName), $probedIso) }
    }

    # Syncs the host view-model's detail/overview bindables from its inventory (cached or
    # fresh); the overview strip + detail header bind to SelectedMachine.*.
    [void] PopulateDetailCards([string]$hostName, [MachineInventory]$inv, [RecentConnection]$rc) {
        $vm = $this.GetRow($hostName)
        if ($null -eq $vm) { return }
        $useInv = if ($null -ne $inv) { $inv } elseif ($null -ne $rc) { $rc.Inventory } else { $null }
        if ($null -ne $useInv) { $vm.ApplyInventory($useInv) }
        $probedIso = if ($null -ne $useInv -and $useInv.ProbedAt) { $useInv.ProbedAt } else { '' }
        $vm.SetProbed($this.Resolver.GetCachedIp($hostName), $probedIso)
        $vm.SetPendingUpdates($(if ($null -ne $rc) { $rc.UpdateCount } else { 0 }))
    }

    # Removes idle (not currently running) machines from the list and recents.
    [void] ClearCompleted() {
        $toRemove = @($this.Rows.Keys | Where-Object { -not $this.IsRunning($_) })

        foreach ($hostName in $toRemove) {
            $row = $this.Rows[$hostName]
            if ($row) { [void]$this.HomeVm.Machines.Remove($row) }
            $this.Rows.Remove($hostName)
            $this.Store.Remove($hostName)
            $this.LogBuffers.Remove($hostName)
            # Drop work queued behind a reachability verdict - a pending run/gather must
            # not fire (and re-create the row) after the operator cleared the card.
            $this.PendingRuns.Remove($hostName)
            $this.PendingGathers.Remove($hostName)
            $this.ScanSteps.Remove($hostName)
            if ($hostName -eq $this.SelectedHost) { $this.ClearSelection() }
        }
        $this.UpdateEmptyHint()
        $this.RefreshOverview()
        $this.Store.FlushSave()
    }

    [void] UpdateEmptyHint() {
        if (-not $this.EmptyHint) { return }
        $this.EmptyHint.Visibility = if ($this.Rows.Count -eq 0) {
            [System.Windows.Visibility]::Visible
        } else {
            [System.Windows.Visibility]::Collapsed
        }
    }

    # Re-renders the overview strip + idle row timestamps; re-probes the selected machine
    # if one is open. Called once on Initialize (per-machine "Refresh info" covers the rest).
    [void] RefreshAll() {
        if ($this.SelectedHost) { $this.RefreshInventory($this.SelectedHost) }
        $this.RefreshIdleTimes()
    }

    # Re-renders idle (not-running) rows from their stored record, so their relative-time
    # subtitles advance over the session. Driven on Initialize and by IdleRefreshTimer (30s).
    [void] RefreshIdleTimes() {
        foreach ($rc in $this.Store.GetAll()) {
            if (-not $this.IsRunning($rc.Hostname)) {
                $row = $this.GetRow($rc.Hostname)
                if ($row) { $row.ApplyIdle($rc) }
            }
        }
    }

    # Re-render the overview strip (e.g. after a job changes pending-update counts).
    [void] RefreshOverview() {
        $this.UpdateOverviewTiles()
    }

    # The overview strip binds to SelectedMachine.* - nothing to poke. Kept as a no-op so
    # existing callers stay valid; empty states come from the bindings' FallbackValues.
    [void] UpdateOverviewTiles() { }

    [System.Windows.Media.Brush] ResBrush([string]$key) {
        $res = $null
        if ($this.MachineList) { $res = $this.MachineList.TryFindResource($key) }
        if ($res -is [System.Windows.Media.Brush]) { return $res }
        return [System.Windows.Media.Brushes]::Gray
    }

    [void] CheckForManualReboot([AsyncJob]$job) {
        $needsReboot = $false

        # Primary signal: the apply worker sets RebootRequired when dcu-cli returns 1/5.
        # $job.Result is the worker's hashtable wrapped in the invoke collection - unwrap it.
        foreach ($item in @($job.Result)) {
            if ($null -ne $item -and $item.RebootRequired) { $needsReboot = $true; break }
        }

        # Fallback: a reboot-required marker file, in case a future remote step writes one.
        $rebootFlagPath = Join-Path (Join-Path $env:LOCALAPPDATA "DONUT") "reports\$($job.HostName)-reboot-required.flag"
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
