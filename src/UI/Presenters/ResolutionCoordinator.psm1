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
    # Barrier-lapsed warm shells, parked STILL RUNNING as @{ Shell; Handle; Started }
    # until ReapWarmShells harvests them (implementation-notes: pool warm).
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
            # Free-count diagnostic: if this logs with no "Selected active domain
            # controller" after it, free 0 = starved pool, free > 0 = the worker hung.
            $free = try { [RunspaceManager]::GetPool().GetAvailableRunspaces() } catch { -1 }
            $this.Logger.LogInfo("DC warm-up started (pool free: $free/$($this.Config.GetThrottleLimit())) - discovering a live controller...")
        }
        catch {
            $this.Logger.LogException("Resolver warm-up could not start", $_)
        }
    }

    # Warms every pool runspace with one real worker pass, synchronously behind a
    # barrier. One-shot; recipe rationale on the submission loop below.
    [void] WarmPool() {
        if ($this.PoolWarmed) { return }
        $this.PoolWarmed = $true
        $n = $this.Config.GetThrottleLimit()
        if ($n -lt 1) { $n = 1 }

        # One real worker pass per runspace and NOTHING more (the 64dbec8 recipe): a
        # superset warm here blew the barrier (implementation-notes: pool warm).
        $pool = [RunspaceManager]::GetPool()
        $shells = [System.Collections.Generic.List[object]]::new()
        $handles = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $n; $i++) {
            try {
                $prep = $this.Resolver.PrepareWarmRunspace()
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = $pool
                $ps.AddCommand($prep.ScriptPath) | Out-Null
                foreach ($k in $prep.Arguments.Keys) {
                    $ps.AddParameter($k, $prep.Arguments[$k]) | Out-Null
                }
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
                    # Never Dispose/Stop a running warm (sync forms hang on a wedged
                    # pipeline; async stops waste slow warms): park it, reap later.
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
            # Self-heal: parked shells hold their runspaces, so raise the max to keep
            # jobs running; ReapWarmShells returns the slack as late warms land.
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

    # Pump-driven harvest of barrier-lapsed warm shells: a late finisher lands fully
    # warmed and returns one unit of raised capacity; a wedged one parks for life.
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
            # A finished DC warm - even a failed one - ends the startup crunch: let
            # the deferred finder/Lens warms go.
            if ([string]::IsNullOrWhiteSpace($job.HostName)) {
                $this.Home.StartDeferredWarms('DC warm-up finished (failed)')
            }
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
                # The startup crunch is over either way: release the deferred warms.
                $this.Home.StartDeferredWarms('DC warm-up completed')
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
            # Compare as sets: AD order is nondeterministic, and an order-only "change"
            # would re-serialize the whole config on the dispatcher mid-warm-landing.
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
