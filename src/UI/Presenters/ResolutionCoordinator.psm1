using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Core\RunspaceManager.psm1"
using module "..\..\Services\HostResolver.psm1"
using module "..\..\Models\JobEnums.psm1"

<#
.SYNOPSIS
    Coordinates host resolution: DC + runspace warm-up, background IP pre-resolve,
    identity verification, and the completion of Resolve-kind AsyncJobs.

.DESCRIPTION
    Extracted from HomePresenter (see docs/development/architecture/overview.md,
    "Design decisions"). Owns
    the Resolve-job lifecycle over the shared HostResolver: warms a live DC + the runspace
    pool at startup, pre-resolves host IPs single-flight, runs the pre-apply identity
    check, and handles CompleteResolve (cache the verdict / DC, then hand queued work
    back to HomePresenter to re-issue). HomePresenter keeps the AsyncJob pump and the
    PendingRuns / PendingGathers queue and forwards the Resolve kind here.

.NOTES
    Mirrors the FinderPresenter / InventoryPresenter seam: a duck-typed [object] $Home
    back-ref reaches HomePresenter's pump + machine seams (a typed import would be a
    using-module cycle). HostResolver is a shared collaborator - HomePresenter owns it
    and passes the same instance here, since the run / apply / inventory-gate flows use
    it too.
#>
class ResolutionCoordinator {
    [AppConfig]    $Config
    [LogService]   $Logger
    [object]       $ConfigManager   # duck-typed; used to persist the active DC
    [object]       $Toasts          # ToastService
    [HostResolver] $Resolver        # shared with HomePresenter (not owned here)
    [object]       $Home            # duck-typed back-ref to HomePresenter's pump + seams
    [bool]         $PoolWarmed = $false   # single-shot guard for WarmPool
    # Warm shells still running when the barrier lapsed, parked as
    # @{ Shell; Handle; Started } and left RUNNING - a late warm still delivers a
    # fully warmed runspace. ReapWarmShells (pump-driven) harvests each one when it
    # completes; a truly wedged one never completes and dies with the process.
    hidden [object[]] $AbandonedWarmShells = @()
    # WarmPool's barrier deadline; tests shrink it to drive the lapse path fast.
    hidden [int] $WarmTimeoutSeconds = 30

    ResolutionCoordinator(
        [AppConfig] $config,
        [LogService] $logger,
        [object] $configManager,
        [object] $toasts,
        [HostResolver] $resolver,
        [object] $homePresenter
    ) {
        $this.Config = $config
        $this.Logger = $logger
        $this.ConfigManager = $configManager
        $this.Toasts = $toasts
        $this.Resolver = $resolver
        $this.Home = $homePresenter
    }

    # One-time: discover and pick a live DC on the pool; cached when it completes.
    [void] StartWarm() {
        try {
            $prep = $this.Resolver.PrepareWarm()
            $job = [AsyncJob]::new('', [JobKind]::Resolve, $this.Logger)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.Home.ActiveJobs.Add($job)
            # Diagnostic: proves the warm started, and reports how many pool runspaces are
            # free right then. If this logs but no "Selected active domain controller" /
            # "DC warm-up ..." follows, the job is stuck Running - pool free 0 means it's
            # starved (search/agent binds holding every runspace); >0 means it ran and hung.
            $free = try { [RunspaceManager]::GetPool().GetAvailableRunspaces() } catch { -1 }
            $this.Logger.LogInfo("DC warm-up started (pool free: $free/$($this.Config.GetThrottleLimit())) - discovering a live controller...")
        }
        catch {
            $this.Logger.LogException("Resolver warm-up could not start", $_)
        }
    }

    # Warms every pool runspace's COMPLETE worker module graph synchronously. One-shot;
    # loader-lock rationale in .NOTES.
    [void] WarmPool() {
        if ($this.PoolWarmed) { return }
        $this.PoolWarmed = $true
        $n = $this.Config.GetThrottleLimit()
        if ($n -lt 1) { $n = 1 }

        # Load the FULL pool-worker graph (WorkerServices + ActiveDirectoryService +
        # PersonLensService) into every runspace, not just RemoteWorker's WorkerServices
        # graph. Otherwise the first AD search / Lens lookup to land on an un-warmed
        # runspace cold-loads its graph under the CLR loader lock, and if that happens
        # while the dispatcher is rendering (e.g. mid-scan) the UI freezes. The warm also
        # runs RemoteWorker.ps1 once per runspace (Mode='WarmRunspace') - a runspace whose
        # first worker execution happens on a real job wedges it silently (the DC-warm /
        # machine-list regression) - which is why LogsDir/ReportsDir thread through. The N
        # jobs run concurrently and the WaitOne barrier below holds each runspace, so all
        # N warm.
        $warmScript = Join-Path $this.Config.SourceRoot 'Scripts\Warm-Runspace.ps1'
        $pool = [RunspaceManager]::GetPool()
        $shells = [System.Collections.Generic.List[object]]::new()
        $handles = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $n; $i++) {
            try {
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = $pool
                $ps.AddCommand($warmScript) | Out-Null
                $ps.AddParameter('SourceRoot', $this.Config.SourceRoot) | Out-Null
                $ps.AddParameter('LogsDir', $this.Config.LogsPath) | Out-Null
                $ps.AddParameter('ReportsDir', $this.Config.ReportsPath) | Out-Null
                $handles.Add($ps.BeginInvoke())
                $shells.Add($ps)
            }
            catch {
                $this.Logger.LogException("Runspace warm-up could not start", $_)
            }
        }

        # WaitHandle.WaitAll throws on an STA thread, so wait per-handle with WaitOne.
        $started = [datetime]::UtcNow
        $deadline = $started.AddSeconds($this.WarmTimeoutSeconds)
        $warmed = 0
        for ($i = 0; $i -lt $shells.Count; $i++) {
            $completed = $false
            try {
                $remaining = [int][Math]::Max(0,
                    [Math]::Ceiling(($deadline - [datetime]::UtcNow).TotalMilliseconds))
                $completed = $handles[$i].AsyncWaitHandle.WaitOne($remaining)
                if ($completed) {
                    $shells[$i].EndInvoke($handles[$i])
                    $warmed++
                }
            }
            catch {
                $this.Logger.LogException("Runspace warm-up failed", $_)
            }
            finally {
                if ($completed) {
                    try { $shells[$i].Dispose() }
                    catch {
                        $this.Logger.LogDebug(
                            "Warm shell dispose failed: $($_.Exception.Message)")
                    }
                }
                else {
                    # NEVER Dispose or Stop a still-running warm. The synchronous
                    # forms wait on the pipeline, and a pipeline wedged below
                    # PowerShell can't yield - this thread (the UI thread, before
                    # any window exists) would block forever; that hang shipped
                    # once. Async-stopping shipped too - and destroyed warms that
                    # were merely SLOW (first-run AV/AMSI scanning of the module
                    # graph pushes them past the barrier), killing the work seconds
                    # before it finished. The barrier stops the WAITING, never the
                    # WORK: park the shell running; ReapWarmShells harvests it
                    # whenever it completes.
                    $this.AbandonedWarmShells += @{
                        Shell   = $shells[$i]
                        Handle  = $handles[$i]
                        Started = $started
                    }
                }
            }
        }
        if ($warmed -lt $shells.Count) {
            $parked = $shells.Count - $warmed
            $this.Logger.LogWarning(
                "$parked of $($shells.Count) runspace warm job(s) did not finish within " +
                "$($this.WarmTimeoutSeconds) s. They keep running in the background; each " +
                "is harvested when it completes and holds its pool runspace until then.")
            # Self-heal: a parked shell holds its runspace until its warm completes -
            # never, if it is wedged - and in the field the pool sat 0/8 free for
            # minutes while every job (the DC resolve first) queued unrun. Raising the
            # max mints fresh runspaces: cold, so a first job on one pays the loader
            # hit, but it RUNS. The raise is temporary insurance - ReapWarmShells
            # gives a slot back each time a late warm lands - and stays only for
            # shells that never finish, where it is what keeps the app alive.
            try {
                $newMax = $pool.GetMaxRunspaces() + $parked
                if ($pool.SetMaxRunspaces($newMax)) {
                    $this.Logger.LogWarning(
                        "Pool capacity raised to $newMax to compensate for $parked " +
                        "runspace(s) held by unfinished warm jobs.")
                }
                else {
                    $this.Logger.LogWarning(
                        "Pool capacity raise to $newMax was rejected; jobs may starve " +
                        "behind $parked held runspace(s).")
                }
            }
            catch {
                $this.Logger.LogException("Pool capacity compensation failed", $_)
            }
        }
        $this.Logger.LogInfo("Pre-warmed $warmed of $($shells.Count) runspace(s).")
    }

    # Pump-driven: harvests parked warm shells that finished after the barrier
    # lapsed. A late warm still delivers a fully warmed runspace - the work is never
    # thrown away - and each harvest gives back one unit of the capacity the lapse
    # raised, so the pool converges on the configured throttle. A wedged shell never
    # completes: it stays parked (dying with the process) and its replacement
    # capacity stays with it. The late/never split in the log is also the
    # slow-vs-wedged diagnostic for the warm itself.
    [void] ReapWarmShells() {
        if ($this.AbandonedWarmShells.Count -eq 0) { return }
        $stillRunning = @()
        foreach ($entry in $this.AbandonedWarmShells) {
            if (-not $entry.Handle.IsCompleted) {
                $stillRunning += $entry
                continue
            }
            $elapsed = [int]([datetime]::UtcNow - $entry.Started).TotalSeconds
            try {
                $entry.Shell.EndInvoke($entry.Handle)
                $this.Logger.LogInfo(
                    "A runspace warm finished late ($elapsed s) - that runspace is warm.")
            }
            catch {
                $this.Logger.LogWarning(
                    "A late runspace warm failed after $elapsed s - its runspace " +
                    "cold-loads on first use: $($_.Exception.Message)")
            }
            try { $entry.Shell.Dispose() }
            catch {
                $this.Logger.LogDebug("Late warm dispose failed: $($_.Exception.Message)")
            }
            try {
                $pool = [RunspaceManager]::GetPool()
                $floor = $this.Config.GetThrottleLimit()
                $max = $pool.GetMaxRunspaces()
                if ($max -gt $floor) {
                    [void]$pool.SetMaxRunspaces($max - 1)
                    $this.Logger.LogInfo(
                        "Pool capacity restored to $($max - 1) (late warm harvested).")
                }
            }
            catch {
                $this.Logger.LogException("Pool capacity restore failed", $_)
            }
        }
        $this.AbandonedWarmShells = $stillRunning
    }

    # Resolves a host's IP in the background (single-flight); no-op until a DC is warm
    # or if the host is already cached / in flight.
    [void] PrefetchIp([string]$hostName) {
        if (-not $this.Resolver.NeedsResolve($hostName)) { return }
        try {
            $this.Resolver.MarkInFlight($hostName)
            $prep = $this.Resolver.PrepareResolve($hostName)
            $job = [AsyncJob]::new($hostName, [JobKind]::Resolve, $this.Logger)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.Home.ActiveJobs.Add($job)
            $this.Logger.LogDebug("[$hostName] IP pre-resolve job submitted.")
        }
        catch {
            # Release the latch if the job never started, or NeedsResolve stays false
            # forever and the host wedges.
            $this.Resolver.ClearInFlight($hostName)
            $this.Logger.LogException("[$hostName] IP pre-resolve could not start", $_)
        }
    }

    # A failed job may mean a dead cached IP: drop it and re-resolve for the retry.
    [void] InvalidateResolved([string]$hostName) {
        $this.Resolver.Invalidate($hostName)
        $this.PrefetchIp($hostName)
    }

    # Fires the identity check (what name does the box at this IP report?) as its own
    # pool job; its verdict gates the destructive apply.
    [void] StartVerifyName([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($this.Resolver.GetCachedIp($hostName))) { return }
        $this.Resolver.ClearVerifiedName($hostName)
        try {
            $prep = $this.Resolver.PrepareName($hostName)
            $job = [AsyncJob]::new($hostName, [JobKind]::Resolve, $this.Logger)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.Home.ActiveJobs.Add($job)
        }
        catch {
            $this.Logger.LogException("[$hostName] identity check could not start", $_)
        }
    }

    # Resolve finished: cache the DC (warm) or the per-host verdict and refresh the indicator.
    # HomePresenter owns the run/gather queue, so re-issuing queued work is handed back to it.
    [void] CompleteResolve([AsyncJob]$job) {
        if ($job.Status -eq 'Failed') {
            # A failed resolve/warm was silent, so a DC-warm or host-resolve failure looked
            # like nothing happened at all. Surface why (empty HostName = the startup DC warm).
            $who = if ([string]::IsNullOrWhiteSpace($job.HostName)) { 'DC warm-up' } else { "[$($job.HostName)] resolve" }
            $this.Logger.LogWarning("$who failed: $($job.FailureMessage)")
            # Even a failed resolve must release the single-flight latch, or the host wedges.
            $this.Resolver.ClearInFlight($job.HostName)
            $this.Home.DropPendingRunOnResolveFailure($job.HostName)
            return
        }
        foreach ($item in @($job.Result)) {
            if ($null -eq $item) { continue }
            $mode = [string]$item.Mode
            if ($mode -eq 'Warm') {
                $dc = [string]$item.ActiveDc
                $this.Logger.LogDebug(
                    "DC warm-up result received: dc='$dc', " +
                    "controllers=$(@($item.DomainControllers).Count).")
                if (-not [string]::IsNullOrWhiteSpace($dc)) {
                    $this.Resolver.SetActiveDc($dc)
                    $this.PersistDomainController($dc, @($item.DomainControllers))
                }
                else {
                    $this.Logger.LogWarning("DC warm-up completed but found no reachable controller.")
                }
            }
            elseif ($mode -eq 'Host') {
                $hn = [string]$item.HostName
                $newIp = [string]$item.Ip
                $online = [bool]$item.Online
                $this.Logger.LogDebug(
                    "[$hn] Resolve verdict received: ip='$newIp', online=$online.")
                $oldIp = $this.Resolver.GetCachedIp($hn)
                # Log only a first find or an actual change - never a same-IP TTL refresh.
                if (-not [string]::IsNullOrWhiteSpace($newIp) -and $oldIp -ne $newIp) {
                    if ([string]::IsNullOrWhiteSpace($oldIp)) { $this.Logger.LogInfo("[$hn] resolved IP $newIp") }
                    else { $this.Logger.LogInfo("[$hn] IP changed: $oldIp -> $newIp") }
                }
                $this.Resolver.CacheVerdict($hn, $newIp, $online)
                $this.Home.RenderReachability($hn)
                # Surface the fresh IP in the detail subtitle if this host's panel is open.
                if ($hn -eq $this.Home.SelectedHost) {
                    $rcSel = $this.Home.GetRecord($hn)
                    $iso = ''
                    if ($null -ne $rcSel -and $null -ne $rcSel.Inventory) {
                        $iso = $rcSel.Inventory.ProbedAt
                    }
                    $this.Home.Detail.RenderDetailSubtitle($hn, $iso)
                }
                # HomePresenter owns the queue: hand the verdict back to re-issue queued work.
                $this.Home.ReissueAfterResolve($hn, $online)
            }
            elseif ($mode -eq 'Name') {
                $this.Resolver.CacheName([string]$item.HostName, [string]$item.ActualName)
            }
            elseif ($mode -eq 'WarmRunspace') {
                # No-op: the job's purpose was loading the module graph into its runspace.
            }
        }
    }

    # Persists the active DC (and list) so the next launch resolves without waiting
    # on AD discovery. Only writes when something changed.
    hidden [void] PersistDomainController([string]$dc, [string[]]$list) {
        if ($null -eq $this.ConfigManager) { return }
        $changed = $false
        if ([string]$this.Config.Settings['activeDomainController'] -ne $dc) {
            $this.Config.Settings['activeDomainController'] = $dc
            $changed = $true
        }
        if ($null -ne $list -and $list.Count -gt 0) {
            $existing = @($this.Config.Settings['domainControllers'])
            # Compare as sets: AD returns controllers in nondeterministic order, and an
            # order-only "change" would re-serialize the whole config on the dispatcher
            # right as the DC warm completes (a multi-second UI stall once the recents
            # carry cached inventory/disk trees).
            $before = (@($existing) | Sort-Object) -join '|'
            $after = (@($list) | Sort-Object) -join '|'
            if ($before -ne $after) {
                $this.Config.Settings['domainControllers'] = @($list)
                $changed = $true
            }
        }
        if ($changed) {
            try { $this.ConfigManager.SaveConfig($this.Config) }
            catch { $this.Logger.LogException("Could not persist domain controller", $_) }
        }
    }
}
