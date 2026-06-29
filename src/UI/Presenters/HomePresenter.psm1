using namespace System.Windows.Controls
using namespace System.Windows.Shapes
using namespace System.Windows.Threading
using namespace System.Collections.Generic
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
using module ".\ConnectionRow.psm1"
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
using module "..\..\Services\ActiveDirectoryService.psm1"
using module "..\..\Models\AdSearchResult.psm1"

class HomePresenter : AsyncJobPresenter {
    [AppConfig] $Config
    [object] $ConfigManager           # duck-typed; used to persist recents
    [System.Windows.FrameworkElement] $ViewContent
    [TextBox] $SearchBar
    [Button] $SearchButton
    [Button] $ClearButton
    [Button] $RefreshButton
    [ItemsControl] $MachineList
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
    [string] $SelectedHost
    [hashtable] $LogBuffers   # hostname -> List[string] of accumulated job-log lines

    # Detail-panel controls
    [System.Windows.UIElement] $DetailEmptyHint
    [System.Windows.UIElement] $DetailContent
    [TextBlock] $DetailHostText
    [TextBlock] $DetailProbed
    [Button] $DetailRefreshButton
    [Button] $DetailRunButton
    [TextBox] $DetailLog
    [ProgressBar] $DetailProgress
    [Button] $FindFoldersButton
    [ItemsControl] $DiskFoldersList
    [System.Windows.UIElement] $DiskFoldersHint

    # Overview tile controls (mirror the selected remote machine)
    [TextBlock] $OvModel
    [TextBlock] $OvModelSub
    [TextBlock] $OvBattery
    [TextBlock] $OvBatterySub
    [TextBlock] $OvDisk
    [TextBlock] $OvDiskSub
    [TextBlock] $OvUpdates
    [TextBlock] $OvUpdatesSub

    # AD live-search (search-bar dropdown: computers + locked-out users)
    [ActiveDirectoryService] $AdService
    [object]          $SearchPopup        # System.Windows.Controls.Primitives.Popup
    [object]          $SearchList         # StackPanel inside the popup
    [DispatcherTimer] $SearchDebounce
    [DispatcherTimer] $SearchPollTimer
    [int]             $SearchToken = 0
    [List[hashtable]] $SearchJobs          # in-flight @{ Ps; Handle; Token }
    [List[object]]    $SearchResults       # accumulated rows for the current token (forests stream in)
    [HashSet[string]] $SearchSeen          # dedupe keys (Kind|Domain|Sam) for the current token
    [bool]            $SuppressSearch = $false
    [List[hashtable]] $UnlockJobs          # in-flight @{ Ps; Handle; Upn }
    [DispatcherTimer] $UnlockPollTimer
    [System.Windows.Window] $HostWindow    # parent window; hooked so the popup tracks moves/resizes

    # Async state ($ActiveJobs is inherited from AsyncJobPresenter)
    [DispatcherTimer] $Timer

    # Host name -> ConnectionRow
    [hashtable] $Rows

    # Manual reboot queue - hosts that require manual reboot after update
    [System.Collections.Generic.List[string]] $ManualRebootQueue
    [int] $TotalJobsInBatch

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
        $this.HostListSource = [HostListSource]::new($config.SourceRoot)
        $this.InventoryService = [InventoryService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.DiskUsageService = [DiskUsageService]::new($config, $this.NetworkProbe, $this.Logger)
        $this.Resolver = [HostResolver]::new($config, $this.NetworkProbe, $this.Logger)

        # $this.ActiveJobs is initialized by the AsyncJobPresenter base constructor.
        $this.Rows = @{}
        $this.LogBuffers = @{}
        $this.ManualRebootQueue = [List[string]]::new()
        $this.TotalJobsInBatch = 0

        $presenter = $this
        $this.Timer = [DispatcherTimer]::new()
        $this.Timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $this.Timer.Add_Tick({ $presenter.OnTimerTick($this, $null) }.GetNewClosure())
        $this.Timer.Start()

        # AD live-finder: debounce typing, run the search on the runspace pool,
        # poll for completion (newest result wins).
        $this.AdService = [ActiveDirectoryService]::new($this.Config.GetDomains(), $this.Logger)
        $this.SearchJobs = [List[hashtable]]::new()
        $this.SearchResults = [List[object]]::new()
        $this.SearchSeen = [HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.SearchDebounce = [DispatcherTimer]::new()
        $this.SearchDebounce.Interval = [TimeSpan]::FromMilliseconds(350)
        $this.SearchDebounce.Add_Tick({ $presenter.RunAdSearch() }.GetNewClosure())
        $this.SearchPollTimer = [DispatcherTimer]::new()
        $this.SearchPollTimer.Interval = [TimeSpan]::FromMilliseconds(120)
        $this.SearchPollTimer.Add_Tick({ $presenter.PollSearch() }.GetNewClosure())
        $this.UnlockJobs = [List[hashtable]]::new()
        $this.UnlockPollTimer = [DispatcherTimer]::new()
        $this.UnlockPollTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $this.UnlockPollTimer.Add_Tick({ $presenter.PollUnlock() }.GetNewClosure())

        $this.Initialize()
    }

    [void] Initialize() {
        $this.SearchBar = $this.ViewContent.FindName('GoogleSearchBar')
        $this.SearchButton = $this.ViewContent.FindName('btnSearch')
        $this.ClearButton = $this.ViewContent.FindName('btnClearTabs')
        $this.RefreshButton = $this.ViewContent.FindName('btnRefresh')
        $this.MachineList = $this.ViewContent.FindName('MachineList')
        $this.EmptyHint = $this.ViewContent.FindName('FleetEmptyHint')
        $this.ModePill = $this.ViewContent.FindName('txtMode')
        $this.ModeButton = $this.ViewContent.FindName('btnMode')
        $this.SearchPopup = $this.ViewContent.FindName('SearchResultsPopup')
        $this.SearchList = $this.ViewContent.FindName('SearchResultsList')

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
        $this.DetailRunButton = $this.ViewContent.FindName('btnDetailRun')
        $this.DetailLog = $this.ViewContent.FindName('txtDetailLog')
        $this.DetailProgress = $this.ViewContent.FindName('DetailProgress')
        $this.FindFoldersButton = $this.ViewContent.FindName('btnFindFolders')
        $this.DiskFoldersList = $this.ViewContent.FindName('DiskFoldersList')
        $this.DiskFoldersHint = $this.ViewContent.FindName('DiskFoldersHint')

        $presenter = $this
        if ($this.SearchButton) { $this.SearchButton.Add_Click({ $presenter.OnSearch() }.GetNewClosure()) }
        if ($this.ClearButton) { $this.ClearButton.Add_Click({ $presenter.ClearCompleted() }.GetNewClosure()) }
        if ($this.RefreshButton) { $this.RefreshButton.Add_Click({ $presenter.RefreshAll() }.GetNewClosure()) }
        if ($this.ModeButton) { $this.ModeButton.Add_Click({ $presenter.CycleMode() }.GetNewClosure()) }
        if ($this.DetailRefreshButton) { $this.DetailRefreshButton.Add_Click({ $presenter.RefreshInventory($presenter.SelectedHost) }.GetNewClosure()) }
        if ($this.DetailRunButton) { $this.DetailRunButton.Add_Click({ $presenter.RunHost($presenter.SelectedHost) }.GetNewClosure()) }
        if ($this.FindFoldersButton) { $this.FindFoldersButton.Add_Click({ $presenter.FindBigFolders($presenter.SelectedHost) }.GetNewClosure()) }
        if ($this.SearchBar) {
            $this.SearchBar.Add_TextChanged({ $presenter.OnSearchTextChanged() }.GetNewClosure())
            $this.SearchBar.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $presenter.CloseSearchPopup() } }.GetNewClosure())
        }

        # A WPF Popup is a separate top-level window that does NOT follow the parent
        # when it moves/resizes. Hook the host window (once it's in the visual tree)
        # so the search dropdown stays glued under the search box.
        $this.ViewContent.Add_Loaded({ $presenter.HookHostWindow() }.GetNewClosure())

        # Seed recents from WSID.txt the first time, then build a row per recent.
        if ($this.Store.Count() -eq 0) {
            $this.Store.SeedFrom($this.ReadWsidHosts())
        }
        $this.BuildRows()

        $this.UpdateModePill()
        $this.RefreshAll()

        # Start-early: seed the domain controller saved from a prior run so the very
        # first selects can resolve immediately (no cold-start wait), then refresh it
        # in the background. A stale saved DC just falls back until the warm lands.
        $savedDc = [string]$this.Config.Settings['activeDomainController']
        if (-not [string]::IsNullOrWhiteSpace($savedDc)) { $this.Resolver.SetActiveDc($savedDc) }
        $this.StartWarm()

        # Pre-warm the rest of the pool's runspaces once the UI goes idle (after first
        # paint), so a later concurrent job never cold-loads the module graph and
        # freezes the dispatcher. Deferred to idle so the warm-up itself can't freeze
        # startup.
        $this.ViewContent.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
            [System.Action]({ $presenter.WarmPool() }.GetNewClosure())) | Out-Null
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

    # Warms every pool runspace's module graph so concurrent jobs (e.g. inventory +
    # scan, or a batch of scans) never cold-load on the hot path. Fires throttleLimit
    # no-op jobs at once - they overlap, forcing the pool to create + warm each
    # runspace (then free it, so capacity is unaffected). One-shot.
    [void] WarmPool() {
        if ($this.PoolWarmed) { return }
        $this.PoolWarmed = $true
        $n = $this.Config.GetThrottleLimit()
        if ($n -lt 1) { $n = 1 }
        for ($i = 0; $i -lt $n; $i++) {
            try {
                $prep = $this.Resolver.PrepareWarmRunspace()
                $job = [AsyncJob]::new('', [JobKind]::Resolve)
                $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
                $this.ActiveJobs.Add($job)
            }
            catch {
                $this.Logger.LogException("Runspace warm-up could not start", $_)
            }
        }
        $this.Logger.LogInfo("Pre-warming $n runspace(s).")
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
        if ($job.Status -eq 'Failed') { return }
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
            }
            elseif ($mode -eq 'Name') {
                $this.Resolver.CacheName([string]$item.HostName, [string]$item.ActualName)
            }
            elseif ($mode -eq 'WarmRunspace') {
                # No-op: the job's purpose was loading the module graph into its runspace.
            }
        }
    }

    # Fires the identity check (what name does the box at this host's IP report?) as
    # its own pool job, in parallel with the apply-scan. It never touches the dcu-cli
    # thread, so it adds no latency; its verdict gates the destructive apply.
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

    # Reflects a host's cached online/offline verdict on its idle row and, when it's
    # the selected host, in the detail header. No row update while a job is running
    # on that host (live status owns the dot/subtitle then).
    [void] RenderReachability([string]$hostName) {
        $state = $this.Resolver.IsHostOnline($hostName)
        $row = $this.GetRow($hostName)
        if ($row -and -not $this.IsRunning($hostName)) { $row.SetReachability($state) }
        if ($hostName -eq $this.SelectedHost -and $this.DetailHostText) {
            $this.DetailHostText.Text = if ($state -eq 'Offline') { "$hostName  -  offline" } else { $hostName }
        }
    }

    # Threads this host's prefetched IP into a worker-args bundle's Options, so the
    # worker skips DNS on the hot path. No-op when the IP isn't cached yet.
    hidden [void] AttachResolvedIp([hashtable]$prep, [string]$hostName) {
        $ip = $this.Resolver.GetCachedIp($hostName)
        if ([string]::IsNullOrWhiteSpace($ip)) { return }
        if ($prep -and $prep.Arguments -and $prep.Arguments.Options) {
            $prep.Arguments.Options.ResolvedIp = $ip
        }
    }

    [void] UpdateModePill() {
        $command = $this.Config.GetActiveCommand()
        $label = if ($command -eq 'applyUpdates') { "Apply Updates" } else { "Scan" }
        if ($this.SearchButton) { $this.SearchButton.Content = $label }
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
            $row = $this.EnsureRow($rc.Hostname)
            $row.SetIdleFrom($rc)
        }
        $this.UpdateEmptyHint()
    }

    [void] OnSearch() {
        $rawInput = $this.SearchBar.Text
        if ([string]::IsNullOrWhiteSpace($rawInput)) { return }

        $targetHosts = $rawInput -split "[\r\n,]+" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }

        if ($targetHosts.Count -eq 0) { return }

        # One confirmation for a destructive batch; single rows confirm in RunHost.
        $command = $this.Config.GetActiveCommand()
        if ($command -eq 'applyUpdates' -and $targetHosts.Count -gt 1) {
            $confirmed = $this.DialogPresenter.ShowConfirmation(
                "Confirm Apply Updates",
                "You are about to apply updates to $($targetHosts.Count) computers.",
                $targetHosts
            )
            if (-not $confirmed) { return }
        }

        $this.ManualRebootQueue.Clear()
        $this.TotalJobsInBatch = $targetHosts.Count

        foreach ($hostName in $targetHosts) {
            $this.StartProcess($hostName)
        }

        $this.SearchBar.Text = ""
    }

    # ===================== AD live search (search-bar dropdown) =====================

    # Restart the debounce window on each keystroke; close the dropdown when the
    # prefix is too short to search.
    [void] OnSearchTextChanged() {
        if ($this.SuppressSearch) { return }
        $text = if ($this.SearchBar) { $this.SearchBar.Text } else { '' }
        if ([string]::IsNullOrWhiteSpace($text) -or $text.Trim().Length -lt $this.AdService.MinPrefix) {
            $this.SearchDebounce.Stop()
            $this.CloseSearchPopup()
            return
        }
        $this.SearchDebounce.Stop()
        $this.SearchDebounce.Start()
    }

    # Debounce elapsed: kick a background search on the runspace pool.
    [void] RunAdSearch() {
        $this.SearchDebounce.Stop()
        $prefix = if ($this.SearchBar) { $this.SearchBar.Text.Trim() } else { '' }
        if ($prefix.Length -lt $this.AdService.MinPrefix) { $this.CloseSearchPopup(); return }

        # Drop any still-in-flight jobs from the previous keystroke so a new search
        # doesn't stack a fresh fan-out behind stale ones (best-effort, non-blocking;
        # the token guard already discards their late results).
        foreach ($job in @($this.SearchJobs)) { try { $job.Ps.Dispose() } catch { } }
        $this.SearchJobs.Clear()
        $this.SearchResults.Clear()
        $this.SearchSeen.Clear()

        $this.SearchToken++
        $token = $this.SearchToken

        # Fan out one job per forest: each forest is independent, so query them
        # concurrently on the pool and render hits as each lands (PollSearch), instead
        # of waiting on the sum of all forests' LDAP round-trips.
        $worker = Join-Path $this.Config.SourceRoot 'Scripts\AdSearchWorker.ps1'
        foreach ($domain in $this.AdService.Domains) {
            try {
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = [RunspaceManager]::GetPool()
                $ps.AddCommand($worker) | Out-Null
                $ps.AddParameter('Domains', @($domain)) | Out-Null
                $ps.AddParameter('Prefix', $prefix) | Out-Null
                $handle = $ps.BeginInvoke()
                $this.SearchJobs.Add(@{ Ps = $ps; Handle = $handle; Token = $token })
            }
            catch {
                $this.Logger.LogException("AD search could not start for '$domain'", $_)
            }
        }
        if ($this.SearchJobs.Count -gt 0) { $this.SearchPollTimer.Start() }
        else { $this.CloseSearchPopup() }
    }

    # Poll the in-flight per-forest searches; as each forest lands, fold its hits into
    # the current token's accumulator and re-render the growing union. Stale-token
    # jobs are discarded + disposed.
    [void] PollSearch() {
        foreach ($job in @($this.SearchJobs)) {
            if (-not $job.Handle.IsCompleted) { continue }
            $results = @()
            try { $results = @($job.Ps.EndInvoke($job.Handle)) }
            catch { $this.Logger.LogException("AD search failed", $_) }
            try { $job.Ps.Dispose() } catch { }
            [void]$this.SearchJobs.Remove($job)
            if ($job.Token -ne $this.SearchToken) { continue }
            foreach ($row in $results) {
                $key = "$($row.Kind)|$($row.Domain)|$($row.SamAccountName)"
                if ($this.SearchSeen.Add($key)) { $this.SearchResults.Add($row) }
            }
            $this.RenderAdResults($this.SearchResults.ToArray())
        }
        if ($this.SearchJobs.Count -eq 0) { $this.SearchPollTimer.Stop() }
    }

    [void] RenderAdResults([object[]]$results) {
        if (-not $this.SearchList) { return }
        $this.SearchList.Children.Clear()
        if ($null -eq $results -or $results.Count -eq 0) { $this.CloseSearchPopup(); return }

        $computers = @($results | Where-Object { $_.Kind -eq 'Computer' })
        $users = @($results | Where-Object { $_.Kind -eq 'User' })

        if ($computers.Count -gt 0) {
            [void]$this.SearchList.Children.Add($this.BuildSectionHeader('COMPUTERS'))
            foreach ($c in $computers) { [void]$this.SearchList.Children.Add($this.BuildSearchRow($c)) }
        }
        if ($users.Count -gt 0) {
            [void]$this.SearchList.Children.Add($this.BuildSectionHeader('USERS'))
            foreach ($u in $users) { [void]$this.SearchList.Children.Add($this.BuildSearchRow($u)) }
        }
        if ($this.SearchPopup) { $this.SearchPopup.IsOpen = $true }
    }

    hidden [object] BuildSectionHeader([string]$text) {
        $tb = [TextBlock]::new()
        $tb.Text = $text
        $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Montserrat')
        $tb.FontSize = 10
        $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
        $tb.Foreground = $this.ResBrush('BodyTextTertiary')
        $tb.Margin = [System.Windows.Thickness]::new(6, 6, 0, 4)
        return $tb
    }

    # Builds one dropdown row (imperative, like ConnectionRow). Computers pick into
    # the search bar; locked users get an inline Unlock button.
    hidden [object] BuildSearchRow([object]$r) {
        $presenter = $this
        $border = [Border]::new()
        $border.CornerRadius = [System.Windows.CornerRadius]::new(7)
        $border.Padding = [System.Windows.Thickness]::new(10, 6, 8, 6)
        $border.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)
        $border.Background = [System.Windows.Media.Brushes]::Transparent
        $hover = $this.ResBrush('PanelBackgroundHover')
        $border.Add_MouseEnter({ $border.Background = $hover }.GetNewClosure())
        $border.Add_MouseLeave({ $border.Background = [System.Windows.Media.Brushes]::Transparent }.GetNewClosure())

        $grid = [Grid]::new()
        $c0 = [ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $c1 = [ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::Auto
        $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add($c1)

        $stack = [StackPanel]::new()
        $stack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $primary = [TextBlock]::new()
        $primary.FontFamily = [System.Windows.Media.FontFamily]::new('Montserrat')
        $primary.FontSize = 13
        $primary.Foreground = $this.ResBrush('TitleTextPrimary')
        $primary.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $secondary = [TextBlock]::new()
        $secondary.FontFamily = [System.Windows.Media.FontFamily]::new('Montserrat')
        $secondary.FontSize = 11
        $secondary.Foreground = $this.ResBrush('BodyTextTertiary')
        $secondary.Margin = [System.Windows.Thickness]::new(0, 1, 0, 0)
        $secondary.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis

        if ($r.Kind -eq 'User') {
            $label = if (-not [string]::IsNullOrWhiteSpace($r.UserPrincipalName)) { [string]$r.UserPrincipalName } else { [string]$r.SamAccountName }
            if ($r.LockedOut) { $label = $label + " `u{1F512}" }
            $primary.Text = $label
            $sub = @([string]$r.DisplayName, [string]$r.Domain) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $secondary.Text = ($sub -join '  -  ')
        }
        else {
            $primary.Text = [string]$r.Name
            $secondary.Text = "$([string]$r.Domain)  -  computer"
            $cap = [string]$r.Name
            $border.Cursor = [System.Windows.Input.Cursors]::Hand
            $border.Add_MouseLeftButtonUp({ $presenter.OnPickComputer($cap) }.GetNewClosure())
        }
        [void]$stack.Children.Add($primary)
        [void]$stack.Children.Add($secondary)
        [Grid]::SetColumn($stack, 0)
        [void]$grid.Children.Add($stack)

        if ($r.Kind -eq 'User' -and $r.LockedOut) {
            $btn = [Button]::new()
            $btn.Content = 'Unlock'
            $btn.Height = 28
            $btn.FontSize = 11
            $btn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            if ($this.MachineList) {
                $style = $this.MachineList.TryFindResource('ButtonOutline')
                if ($style) { $btn.Style = $style }
            }
            $u = $r
            $btn.Add_Click({ $presenter.OnUnlockUser($u) }.GetNewClosure())
            [Grid]::SetColumn($btn, 1)
            [void]$grid.Children.Add($btn)
        }

        $border.Child = $grid
        return $border
    }

    # Computer chosen: drop it into the bar so the operator can run the active
    # command (suppressing the re-search the programmatic edit would trigger).
    [void] OnPickComputer([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $this.CloseSearchPopup()
        $this.SuppressSearch = $true
        if ($this.SearchBar) { $this.SearchBar.Text = $name; $this.SearchBar.CaretIndex = $name.Length }
        $this.SuppressSearch = $false
        # Start-early: a picked computer is about to be run - warm its IP now.
        $this.PrefetchIp($name)
    }

    # Locked user chosen: confirm, unlock against its home domain, toast the result.
    [void] OnUnlockUser([object]$r) {
        $this.CloseSearchPopup()
        if ($null -eq $r) { return }
        $upn = if (-not [string]::IsNullOrWhiteSpace($r.UserPrincipalName)) { [string]$r.UserPrincipalName } else { [string]$r.SamAccountName }

        $confirmed = $this.DialogPresenter.ShowConfirmation(
            "Unlock account",
            "Unlock the locked-out account '$upn'?",
            @("$([string]$r.SamAccountName)  @  $([string]$r.Domain)")
        )
        if (-not $confirmed) { return }

        # Run the unlock OFF the UI thread (Unlock-ADAccount can take a moment);
        # toast the result when the pool job completes.
        try {
            $worker = Join-Path $this.Config.SourceRoot 'Scripts\AdUnlockWorker.ps1'
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = [RunspaceManager]::GetPool()
            $ps.AddCommand($worker) | Out-Null
            $ps.AddParameter('Sam', [string]$r.SamAccountName) | Out-Null
            $ps.AddParameter('Domain', [string]$r.Domain) | Out-Null
            $handle = $ps.BeginInvoke()
            $this.UnlockJobs.Add(@{ Ps = $ps; Handle = $handle; Upn = $upn })
            $this.UnlockPollTimer.Start()
            if ($this.Toasts) { $this.Toasts.ShowInfo("Unlocking...", $upn) }
        }
        catch {
            $this.Logger.LogException("Unlock could not start for $upn", $_)
            if ($this.Toasts) { $this.Toasts.ShowError("Unlock failed", "Could not start unlock for $upn.") }
        }
    }

    # Poll in-flight unlocks; toast success/failure on completion.
    [void] PollUnlock() {
        foreach ($job in @($this.UnlockJobs)) {
            if (-not $job.Handle.IsCompleted) { continue }
            $ok = $false
            try { $res = @($job.Ps.EndInvoke($job.Handle)); $ok = [bool]($res | Select-Object -Last 1) }
            catch { $this.Logger.LogException("Unlock failed for $($job.Upn)", $_) }
            try { $job.Ps.Dispose() } catch { }
            [void]$this.UnlockJobs.Remove($job)
            if ($this.Toasts) {
                if ($ok) { $this.Toasts.ShowSuccess("Account unlocked", $job.Upn) }
                else { $this.Toasts.ShowError("Unlock failed", "Could not unlock $($job.Upn) (check rights / connectivity).") }
            }
        }
        if ($this.UnlockJobs.Count -eq 0) { $this.UnlockPollTimer.Stop() }
    }

    [void] CloseSearchPopup() {
        if ($this.SearchPopup) { $this.SearchPopup.IsOpen = $false }
    }

    # Subscribes (once) to the parent window's move/resize so an open search popup
    # is repositioned to stay under the search box. Fires from ViewContent.Loaded,
    # when the view is finally attached to a window.
    [void] HookHostWindow() {
        if ($null -ne $this.HostWindow) { return }
        $w = [System.Windows.Window]::GetWindow($this.ViewContent)
        if ($null -eq $w) { return }
        $this.HostWindow = $w
        $presenter = $this
        $w.Add_LocationChanged({ $presenter.RepositionSearchPopup() }.GetNewClosure())
        $w.Add_SizeChanged({ $presenter.RepositionSearchPopup() }.GetNewClosure())
    }

    # Nudges the open popup's offset to force WPF to recompute its placement
    # relative to the (now-moved) search box. No-op when the popup is closed.
    [void] RepositionSearchPopup() {
        if ($null -eq $this.SearchPopup -or -not $this.SearchPopup.IsOpen) { return }
        $cur = $this.SearchPopup.HorizontalOffset
        $this.SearchPopup.HorizontalOffset = $cur + 1
        $this.SearchPopup.HorizontalOffset = $cur
    }

    # Runs a single host from a row click; confirms first when destructive.
    [void] RunHost([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        if ($this.IsRunning($hostName)) { return }

        if ($this.Config.GetActiveCommand() -eq 'applyUpdates') {
            $confirmed = $this.DialogPresenter.ShowConfirmation(
                "Confirm Apply Updates",
                "Apply updates to $hostName now?",
                @($hostName)
            )
            if (-not $confirmed) { return }
        }
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

    [void] StartProcess([string]$hostName) {
        $row = $this.EnsureRow($hostName)

        $command = $this.Config.GetActiveCommand()
        $this.AppendLog($hostName, "Starting $command for $hostName...")

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
                # Run starts the scan/update only - inventory is gathered explicitly
                # on a double-click (OnRowActivated), never piggy-backed on a run.
                # Apply is destructive: kick the identity check now (separate thread),
                # in parallel with the scan, so its verdict can gate the apply.
                if ($command -eq 'applyUpdates') { $this.StartVerifyName($hostName) }
            }
        }
        catch {
            $this.AppendLog($hostName, "Error starting process: $_")
            $row.SetStatus([FleetStatus]::FromJob('Scan', 'Failed', $false))
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
        if ($job.JobType -eq [JobKind]::Inventory -or $job.JobType -eq [JobKind]::DiskScan) {
            $line = $null
            while ($job.Logs.TryDequeue([ref]$line)) { $this.AppendLog($job.HostName, $line) }
            return
        }

        $row = $this.GetRow($job.HostName)

        $logEntry = $null
        $latestPct = -1
        while ($job.Logs.TryDequeue([ref]$logEntry)) {
            $this.AppendLog($job.HostName, $logEntry)
            $pct = [DcuProgress]::ParsePercent($logEntry)
            if ($pct -ge 0) { $latestPct = $pct }
        }
        if ($row -and $latestPct -ge 0) { $row.SetPercent($latestPct) }

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

        $this.AppendLog($job.HostName, "Job $($job.JobType) finished: $($job.Status)")
        $this.AppendHostLogs($job.HostName)

        # Transition to apply phase after a successful update scan.
        $transitioned = $false
        if ($job.Status -eq 'Completed' -and $job.JobType -eq 'UpdateScan') {
            $transitioned = $this.HandleUpdateScanCompletion($job)
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

    # End of tick: refresh fleet counts and, once the batch is fully drained,
    # surface any pending manual-reboot notice.
    [void] AfterPump() {
        $this.RefreshOverview()
        if ($this.ActiveJobs.Count -eq 0 -and $this.ManualRebootQueue.Count -gt 0) {
            $this.ShowManualRebootNotice()
        }
    }

    # Records the host's final state into the recent store and renders the row idle.
    [void] SettleHost([AsyncJob]$job) {
        $reboot = $this.ManualRebootQueue.Contains($job.HostName)
        $status = if ($job.Status -eq 'Failed') {
            'Failed'
        } elseif ($reboot) {
            'RebootRequired'
        } else {
            'Completed'
        }

        $report = $this.UpdateService.ParseUpdateReport($job.HostName)
        $updateCount = $this.UpdateService.CountUpdates($report)

        $this.Store.Upsert($job.HostName, $status, $job.JobType, $updateCount, $reboot)

        $row = $this.GetRow($job.HostName)
        if ($row) {
            $rc = $this.GetRecord($job.HostName)
            if ($rc) { $row.SetIdleFrom($rc) }
        }
    }

    [RecentConnection] GetRecord([string]$hostName) {
        foreach ($rc in $this.Store.GetAll()) {
            if ($rc.Hostname -eq $hostName) { return $rc }
        }
        return $null
    }

    [void] RefreshCardStatus([AsyncJob]$job) {
        $row = $this.GetRow($job.HostName)
        if (-not $row) { return }
        $rebootRequired = $this.ManualRebootQueue.Contains($job.HostName)
        $row.SetStatus([FleetStatus]::FromJob($job.JobType, $job.Status, $rebootRequired))
    }

    # Returns $true when an apply job was started (so the caller defers settling).
    [bool] HandleUpdateScanCompletion([AsyncJob]$job) {
        $hostName = $job.HostName

        # Identity gate: the parallel name-check (run with the scan) verifies the box
        # we scanned is actually the target. On a confirmed mismatch the IP has moved
        # to a different machine - abort before applying, drop the stale IP, re-resolve.
        if ($this.Resolver.IdentityVerdict($hostName) -eq 'Mismatch') {
            $actual = $this.Resolver.GetVerifiedName($hostName)
            $this.AppendLog($hostName, "Apply aborted: that address answers as '$actual', not '$hostName' - its IP changed. Re-select to re-resolve.")
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Apply aborted: address now answers as '$actual'. Re-select and retry.") }
            $this.InvalidateResolved($hostName)
            return $false
        }

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

        $this.AppendLog($hostName, "Driver analysis complete. Waiting for confirmation...")
        $confirmed = $this.DialogPresenter.ShowConfirmation("Updates Available", "Updates found for $hostName", $displayList)

        if (-not $confirmed) {
            $this.AppendLog($hostName, "Cancelled by user.")
            return $false
        }

        $this.AppendLog($hostName, "Confirmed. Phase 2: Applying updates...")
        $this.CopyUpdatesToClipboard($hostName, $clipboardList)
        $this.AppendLog($hostName, "Updates list copied to clipboard.")

        try {
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

    # Returns the existing row for a host, or builds and inserts a new one.
    [ConnectionRow] EnsureRow([string]$hostName) {
        if ($this.Rows.ContainsKey($hostName)) {
            return $this.Rows[$hostName]
        }

        $row = [ConnectionRow]::new($hostName)
        $presenter = $this
        $row.RunAction = { param($h) $presenter.RunHost($h) }.GetNewClosure()
        $row.SelectAction = { param($h) $presenter.SelectHost($h) }.GetNewClosure()
        $row.GatherAction = { param($h) $presenter.OnRowActivated($h) }.GetNewClosure()
        $this.Rows[$hostName] = $row
        if ($this.MachineList) {
            $this.MachineList.Items.Add($row.Root) | Out-Null
            $row.AnimateIn()
        }
        $this.UpdateEmptyHint()
        return $row
    }

    [ConnectionRow] GetRow([string]$hostName) {
        if ($this.Rows.ContainsKey($hostName)) { return $this.Rows[$hostName] }
        return $null
    }

    # --- Detail panel + inventory probe ----------------------------------------------

    # Appends a job-output line to the host's buffer and, when it's the selected
    # host, to the live detail log. (Replaces the old per-row inline log.)
    [void] AppendLog([string]$hostName, [string]$text) {
        if (-not $this.LogBuffers.ContainsKey($hostName)) {
            $this.LogBuffers[$hostName] = [System.Collections.Generic.List[string]]::new()
        }
        $this.LogBuffers[$hostName].Add($text)

        if ($hostName -eq $this.SelectedHost -and $this.DetailLog) {
            $this.DetailLog.AppendText("$text`n")
            $this.DetailLog.ScrollToEnd()
        }
    }

    # Opens the detail panel for a host (single click): marks it selected and
    # renders cached inventory/folders instantly. Does NOT touch the network - a
    # fresh probe is gathered on double-click (OnRowActivated) or the Refresh
    # button, so selecting an offline machine can never block the UI thread.
    [void] SelectHost([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }

        if ($this.SelectedHost -and $this.Rows.ContainsKey($this.SelectedHost)) {
            $this.Rows[$this.SelectedHost].SetSelected($false)
        }
        $this.SelectedHost = $hostName
        if ($this.Rows.ContainsKey($hostName)) { $this.Rows[$hostName].SetSelected($true) }

        # Start-early: resolve this host's IP in the background now, so it's cached
        # before the operator double-clicks to gather inventory or hits Run.
        $this.PrefetchIp($hostName)

        if ($this.DetailEmptyHint) { $this.DetailEmptyHint.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($this.DetailContent) { $this.DetailContent.Visibility = [System.Windows.Visibility]::Visible }
        if ($this.DetailHostText) { $this.DetailHostText.Text = $hostName }

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
        $cachedDisk = if ($null -ne $rc) { $rc.DiskUsage } else { $null }
        $this.RenderBigFolders($cachedDisk)

        # Reflect any already-known reachability verdict immediately (a fresh
        # PrefetchIp above will update it when it lands).
        $this.RenderReachability($hostName)

        # Start-early: prefetch this machine's inventory in the background (skipped
        # when it's still fresh), so the detail panel fills itself without a
        # double-click. Runs on the pool - never blocks the UI.
        $this.StartInventory($hostName, $false)
    }

    # Double-clicking a row: select it (cheap, cached) and gather fresh inventory
    # in the background. The probe runs on the runspace pool, never the UI thread.
    [void] OnRowActivated([string]$hostName) {
        $this.SelectHost($hostName)
        $this.StartInventory($hostName)
    }

    # Clears the current selection and returns the detail pane to its empty state.
    [void] ClearSelection() {
        if ($this.SelectedHost -and $this.Rows.ContainsKey($this.SelectedHost)) {
            $this.Rows[$this.SelectedHost].SetSelected($false)
        }
        $this.SelectedHost = $null
        if ($this.DetailContent) { $this.DetailContent.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($this.DetailEmptyHint) { $this.DetailEmptyHint.Visibility = [System.Windows.Visibility]::Visible }
        $this.UpdateOverviewTiles()
    }

    # Explicit gather (double-click / Refresh): forces a fresh probe regardless of TTL.
    [void] StartInventory([string]$hostName) {
        $this.StartInventory($hostName, $true)
    }

    # Queues a background inventory probe. Single-flight (no-op if one is in flight).
    # When $force is false (select-time prefetch) it also skips a host whose cached
    # inventory is still fresh, so repeated selects don't re-gather needlessly.
    [void] StartInventory([string]$hostName, [bool]$force) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
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

    # Forces a re-probe of the selected host.
    [void] RefreshInventory([string]$hostName) {
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

        if ($hostName -eq $this.SelectedHost) {
            $rc = $this.GetRecord($hostName)
            $cached = if ($null -ne $rc -and $null -ne $rc.Inventory) { $rc.Inventory } else { $inv }
            $this.PopulateDetailCards($hostName, $cached, $rc)
        }
    }

    # Queues an on-demand "biggest folders on C:" scan for the host (no-op if one
    # is already in flight). Heavier than the inventory probe (deploys + runs a
    # WizTree MFT scan), so it only runs when the operator clicks the button.
    [void] FindBigFolders([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        foreach ($j in $this.ActiveJobs) {
            if ($j -and $j.HostName -eq $hostName -and $j.JobType -eq [JobKind]::DiskScan) { return }
        }
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

        if ($hostName -eq $this.SelectedHost) {
            $this.RenderBigFolders($report)
        }
    }

    # Renders the largest-folders list (or the empty-state hint when there's none).
    [void] RenderBigFolders([DiskUsageReport]$report) {
        if (-not $this.DiskFoldersList) { return }
        $this.DiskFoldersList.Items.Clear()

        if ($null -eq $report -or $report.Folders.Count -eq 0) {
            if ($this.DiskFoldersHint) { $this.DiskFoldersHint.Visibility = [System.Windows.Visibility]::Visible }
            return
        }

        if ($this.DiskFoldersHint) { $this.DiskFoldersHint.Visibility = [System.Windows.Visibility]::Collapsed }
        foreach ($node in [DiskUsageTree]::Build($report.Folders)) {
            [void]$this.DiskFoldersList.Items.Add($this.BuildFolderRow($node))
        }
    }

    # Builds one folder row (imperative, like BuildSearchRow): indented label on the
    # left (nested under its parent folder), size on the right. Deeper nodes are
    # dimmed slightly so the hierarchy reads at a glance.
    hidden [object] BuildFolderRow([FolderTreeNode]$node) {
        $grid = [Grid]::new()
        $grid.Margin = [System.Windows.Thickness]::new(0, 0, 0, 3)
        $c0 = [ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $c1 = [ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::Auto
        $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add($c1)

        $path = [TextBlock]::new()
        $path.Text = $node.Label
        $path.FontFamily = [System.Windows.Media.FontFamily]::new('Montserrat')
        $path.FontSize = 12
        $path.Foreground = if ($node.Depth -eq 0) { $this.ResBrush('TitleTextPrimary') } else { $this.ResBrush('BodyTextSecondary') }
        $path.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $path.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $path.ToolTip = $node.Path
        # 14px of indent per tree level (children sit under their parent folder).
        $path.Margin = [System.Windows.Thickness]::new(($node.Depth * 14), 0, 0, 0)
        [Grid]::SetColumn($path, 0)
        [void]$grid.Children.Add($path)

        $size = [TextBlock]::new()
        $size.Text = [DiskUsageFormat]::SizeLabel($node.SizeBytes)
        $size.FontFamily = [System.Windows.Media.FontFamily]::new('Montserrat')
        $size.FontSize = 12
        $size.FontWeight = [System.Windows.FontWeights]::SemiBold
        $size.Foreground = $this.ResBrush('BodyTextSecondary')
        $size.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
        $size.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [Grid]::SetColumn($size, 1)
        [void]$grid.Children.Add($size)

        return $grid
    }

    # Updates the detail header's "probed ..." stamp and refreshes the top overview
    # strip (which mirrors the selected machine). The per-machine model/battery/disk
    # facts live in that top strip; the detail pane shows host + folders + log.
    [void] PopulateDetailCards([string]$hostName, [MachineInventory]$inv, [RecentConnection]$rc) {
        if ($this.DetailProbed) {
            $probedIso = if ($null -ne $inv -and $inv.ProbedAt) { $inv.ProbedAt }
                         elseif ($null -ne $rc -and $null -ne $rc.Inventory) { $rc.Inventory.ProbedAt }
                         else { '' }
            $this.DetailProbed.Text = if ([string]::IsNullOrWhiteSpace($probedIso)) { '' } else {
                "probed " + [TimeFormat]::Relative([RecentConnectionsStore]::ParseSeen($probedIso))
            }
        }

        # The top overview strip mirrors the selected machine.
        $this.UpdateOverviewTiles()
    }

    # Removes idle (not currently running) machines from the list and recents.
    [void] ClearCompleted() {
        $toRemove = @($this.Rows.Keys | Where-Object { -not $this.IsRunning($_) })

        foreach ($hostName in $toRemove) {
            $row = $this.Rows[$hostName]
            if ($this.MachineList -and $row) { $this.MachineList.Items.Remove($row.Root) }
            $this.Rows.Remove($hostName)
            $this.Store.Remove($hostName)
            $this.LogBuffers.Remove($hostName)
            if ($hostName -eq $this.SelectedHost) { $this.ClearSelection() }
        }
        $this.UpdateEmptyHint()
        $this.RefreshOverview()
    }

    [void] UpdateEmptyHint() {
        if (-not $this.EmptyHint) { return }
        $this.EmptyHint.Visibility = if ($this.Rows.Count -eq 0) {
            [System.Windows.Visibility]::Visible
        } else {
            [System.Windows.Visibility]::Collapsed
        }
    }

    # Re-renders the overview strip + idle row timestamps; re-probes the selected
    # machine if one is open (this is what the top Refresh button now does).
    [void] RefreshAll() {
        if ($this.SelectedHost) { $this.RefreshInventory($this.SelectedHost) }
        $this.UpdateOverviewTiles()
        # Re-render idle rows so their relative times stay current.
        foreach ($rc in $this.Store.GetAll()) {
            if (-not $this.IsRunning($rc.Hostname)) {
                $row = $this.GetRow($rc.Hostname)
                if ($row) { $row.SetIdleFrom($rc) }
            }
        }
    }

    # Re-render the overview strip (e.g. after a job changes pending-update counts).
    [void] RefreshOverview() {
        $this.UpdateOverviewTiles()
    }

    # Populates the 4 overview tiles from the SELECTED machine's cached inventory
    # (mirrors the detail cards); shows placeholders when nothing is selected.
    [void] UpdateOverviewTiles() {
        $dash = '—'
        $hostName = $this.SelectedHost
        if ([string]::IsNullOrWhiteSpace($hostName)) {
            if ($this.OvModel) { $this.OvModel.Text = $dash }
            if ($this.OvModelSub) { $this.OvModelSub.Text = 'no machine selected' }
            if ($this.OvBattery) { $this.OvBattery.Text = $dash }
            if ($this.OvBatterySub) { $this.OvBatterySub.Text = '' }
            if ($this.OvDisk) { $this.OvDisk.Text = $dash }
            if ($this.OvDiskSub) { $this.OvDiskSub.Text = '' }
            if ($this.OvUpdates) { $this.OvUpdates.Text = $dash }
            if ($this.OvUpdatesSub) { $this.OvUpdatesSub.Text = '' }
            return
        }

        $rc = $this.GetRecord($hostName)
        $inv = if ($null -ne $rc) { $rc.Inventory } else { $null }

        if ($null -eq $inv) {
            if ($this.OvModel) { $this.OvModel.Text = $dash }
            if ($this.OvModelSub) { $this.OvModelSub.Text = 'double-click to gather inventory' }
            if ($this.OvBattery) { $this.OvBattery.Text = $dash }
            if ($this.OvBatterySub) { $this.OvBatterySub.Text = '' }
            if ($this.OvDisk) { $this.OvDisk.Text = $dash }
            if ($this.OvDiskSub) { $this.OvDiskSub.Text = '' }
        }
        else {
            if ($this.OvModel) { $this.OvModel.Text = if ($inv.Model) { $inv.Model } else { $dash } }
            if ($this.OvModelSub) { $this.OvModelSub.Text = if ($inv.ServiceTag) { "Tag $($inv.ServiceTag)" } else { $hostName } }

            $health = [InventoryFormat]::BatteryHealthPercent($inv.DesignCapacity, $inv.FullChargeCapacity)
            if ($this.OvBattery) { $this.OvBattery.Text = [InventoryFormat]::BatteryHealthLabel($inv.HasBattery, $health) }
            if ($this.OvBatterySub) {
                $this.OvBatterySub.Text = if ($inv.HasBattery -and $inv.ChargePercent -ge 0) {
                    $state = if ($inv.Charging) { 'charging' } else { 'on battery' }
                    "$($inv.ChargePercent)% - $state"
                } else { '' }
            }

            if ($this.OvDisk) { $this.OvDisk.Text = [InventoryFormat]::DiskFreeLabel($inv.FreeSpaceBytes, $inv.TotalSpaceBytes) }
            if ($this.OvDiskSub) { $this.OvDiskSub.Text = [InventoryFormat]::UptimeLabel([RecentConnectionsStore]::ParseSeen($inv.LastBootTime)) }
        }

        $pending = if ($null -ne $rc) { $rc.UpdateCount } else { 0 }
        if ($this.OvUpdates) { $this.OvUpdates.Text = "$pending" }
        if ($this.OvUpdatesSub) { $this.OvUpdatesSub.Text = 'pending update(s)' }
    }

    [System.Windows.Media.Brush] ResBrush([string]$key) {
        $res = $null
        if ($this.MachineList) { $res = $this.MachineList.TryFindResource($key) }
        if ($res -is [System.Windows.Media.Brush]) { return $res }
        return [System.Windows.Media.Brushes]::Gray
    }

    [void] AppendHostLogs([string]$hostName) {
        $logsDir = Join-Path $env:LOCALAPPDATA "DONUT\logs"
        $logFiles = @(
            (Join-Path $logsDir "$hostName.log"),
            (Join-Path $logsDir "default.log")
        )
        foreach ($logPath in $logFiles) {
            if (Test-Path $logPath) {
                try {
                    Get-Content -Path $logPath -ErrorAction Stop | ForEach-Object {
                        $this.AppendLog($hostName, $_)
                    }
                } catch { }
            }
        }
    }

    [void] CheckForManualReboot([AsyncJob]$job) {
        $appData = Join-Path $env:LOCALAPPDATA "DONUT"
        $rebootFlagPath = Join-Path $appData "reports\$($job.HostName)-reboot-required.flag"

        if (Test-Path $rebootFlagPath) {
            if (-not $this.ManualRebootQueue.Contains($job.HostName)) {
                $this.ManualRebootQueue.Add($job.HostName)
            }
            Remove-Item -Path $rebootFlagPath -Force -ErrorAction SilentlyContinue
        }

        if ($job.Result -and $job.Result -match 'reboot\s*required|needs\s*reboot|pending\s*reboot') {
            if (-not $this.ManualRebootQueue.Contains($job.HostName)) {
                $this.ManualRebootQueue.Add($job.HostName)
            }
        }
    }

    [void] ShowManualRebootNotice() {
        if ($this.ManualRebootQueue.Count -eq 0) { return }
        $hostList = $this.ManualRebootQueue.ToArray() -join ", "
        if ($this.Toasts) {
            $this.Toasts.ShowWarning(
                "Manual reboot required",
                "These machines need a manual reboot to finish updating: $hostList"
            )
        }
        $this.ManualRebootQueue.Clear()
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
