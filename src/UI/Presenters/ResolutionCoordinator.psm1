using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Core\ResolveProcessJob.psm1"
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

    Per-host resolves ride the fast lane (architecture/runspaces-and-workers): a
    slim class-free ResolveWorker child spawned directly (ResolveProcessJob), capped at
    FastResolveCap with a FIFO overflow queue - so resolves never wait behind scans in
    the pool. ProcessFaults retry once on the classic worker path; three consecutive
    faults latch the lane off for the session.

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
    [object]       $ConfigManager   # duck-typed, used to persist the active DC
    [object]       $Toasts          # ToastService
    [HostResolver] $Resolver        # shared with HomePresenter (not owned here)
    [object]       $Home            # duck-typed back-ref to HomePresenter's pump + seams
    [bool]         $PoolWarmed = $false   # single-shot guard for WarmPool
    # Barrier-lapsed warm shells, parked still running until ReapWarmShells harvests them.
    hidden [object[]] $AbandonedWarmShells = @()
    # WarmPool's barrier deadline, shrunk by tests to drive the lapse path fast.
    hidden [int] $WarmTimeoutSeconds = 30
    # Next time ReapWarmShells may dump parked-shell state lines (throttles to 1/min).
    hidden [datetime] $NextReapReportUtc = [datetime]::MinValue

    # Fast-lane cap: a paste-add must not spawn an unbounded pwsh burst.
    hidden [int] $FastResolveCap = 4
    hidden [int] $FastResolveActive = 0
    hidden [System.Collections.Generic.Queue[string]] $PendingFastResolves = [System.Collections.Generic.Queue[string]]::new()
    # One classic-path retry per host attempt (cleared on a successful verdict).
    hidden [System.Collections.Generic.HashSet[string]] $FastFallbacks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Latched off for the session after 3 consecutive ProcessFaults (worst case = classic path).
    hidden [bool] $FastLaneHealthy = $true
    hidden [int] $FastFaultStreak = 0

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

    # One-time: discover and pick a live DC on the pool, cached when it completes.
    [void] StartWarm() {
        try {
            $prep = $this.Resolver.PrepareWarm()
            $this.Home.StartJob([AsyncJob]::new('', [JobKind]::Resolve, $this.Logger), $prep)
            # Diagnostic: free 0 means a starved pool, free > 0 means the worker hung.
            $free = try { [RunspaceManager]::GetPool().GetAvailableRunspaces() } catch { -1 }
            $this.Logger.LogInfo("DC warm-up started (pool free: $free/$($this.Config.GetThrottleLimit())) - discovering a live controller...")
        }
        catch {
            $this.Logger.LogException("Resolver warm-up could not start", $_)
        }
    }

    # Warms the pool serially: concurrent using-module compiles deadlock.
    [void] WarmPool() {
        if ($this.PoolWarmed) { return }
        $this.PoolWarmed = $true
        $n = $this.Config.GetThrottleLimit()
        if ($n -lt 1) { $n = 1 }
        $pool = [RunspaceManager]::GetPool()

        $warmed = 0
        $erred = 0
        $parked = 0
        for ($i = 0; $i -lt $n; $i++) {
            $tag = "warm-$($i + 1)"
            $ps = $null
            $handle = $null
            $started = [datetime]::UtcNow
            try {
                # One real worker pass and nothing more (the 64dbec8 recipe).
                $prep = $this.Resolver.PrepareWarmRunspace($tag)
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = $pool
                $ps.AddCommand($prep.ScriptPath) | Out-Null
                foreach ($k in $prep.Arguments.Keys) {
                    $ps.AddParameter($k, $prep.Arguments[$k]) | Out-Null
                }
                # Wait for this shell first: two graph compiles in flight deadlock the pool.
                $handle = $ps.BeginInvoke()
                if ($handle.AsyncWaitHandle.WaitOne($this.WarmTimeoutSeconds * 1000)) {
                    $ps.EndInvoke($handle)
                    if ($ps.HadErrors) {
                        $erred++
                        $this.Logger.LogError("Runspace warm completed with errors: " +
                            $this.DescribeShell($ps, $tag, $started))
                    }
                    else {
                        $warmed++
                    }
                    try { $ps.Dispose() }
                    catch {
                        $this.Logger.LogDebug("Warm shell dispose failed: $($_.Exception.Message)")
                    }
                }
                else {
                    # Never Dispose a running pipeline: park the wedged warm and stop piling on.
                    $this.Logger.LogWarning("Warm shell parked at barrier lapse: " +
                        $this.DescribeShell($ps, $tag, $started))
                    $this.AbandonedWarmShells += @{
                        Shell = $ps; Handle = $handle; Started = $started; Tag = $tag
                    }
                    $parked++
                    break
                }
            }
            catch {
                $this.Logger.LogException("Runspace warm-up failed ($tag)", $_)
                if ($null -ne $ps -and $null -eq $handle) {
                    try { $ps.Dispose() }
                    catch { $this.Logger.LogDebug("Warm shell dispose failed: $($_.Exception.Message)") }
                }
            }
        }

        if ($parked -gt 0) {
            # A parked shell holds its runspace, so raise the max or real jobs starve.
            try {
                $newMax = $pool.GetMaxRunspaces() + $parked
                if ($pool.SetMaxRunspaces($newMax)) {
                    $this.Logger.LogWarning(
                        "Pool capacity raised to $newMax to compensate for $parked " +
                        "runspace(s) held by an unfinished warm job.")
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
        $suffix = if ($erred -gt 0) { " ($erred completed with errors)" } else { '' }
        $this.Logger.LogInfo("Pre-warmed $warmed of $n runspace(s)$suffix.")
        if ($this.AbandonedWarmShells.Count -gt 0) {
            $this.NextReapReportUtc = [datetime]::UtcNow.AddSeconds(60)
        }
    }

    # One-line forensic snapshot of a warm shell: state, failure reason, first errors.
    # Safe on a running pipeline (PSDataCollection reads are thread-safe).
    hidden [string] DescribeShell([object]$shell, [string]$tag, [datetime]$started) {
        try {
            $elapsed = [int]([datetime]::UtcNow - $started).TotalSeconds
            $info = $shell.InvocationStateInfo
            $line = "$tag state=$($info.State) hadErrors=$($shell.HadErrors) elapsed=${elapsed}s"
            if ($null -ne $info.Reason) {
                $line += " reason=$($info.Reason.GetType().Name): $($info.Reason.Message)"
            }
            # Indexed reads only: enumerating a live stream races the worker's appends.
            $take = [Math]::Min(3, $shell.Streams.Error.Count)
            if ($take -gt 0) {
                $errs = for ($j = 0; $j -lt $take; $j++) { "$($shell.Streams.Error[$j])" }
                $line += " errors=[" + ($errs -join ' | ') + "]"
            }
            return $line
        }
        catch {
            return "$tag (state unreadable: $($_.Exception.Message))"
        }
    }

    # Pump-driven harvest of barrier-lapsed warm shells: a late finisher lands warmed and
    # returns one unit of raised capacity, while a wedged one parks for life.
    [void] ReapWarmShells() {
        if ($this.AbandonedWarmShells.Count -eq 0) { return }
        $report = [datetime]::UtcNow -ge $this.NextReapReportUtc
        if ($report) { $this.NextReapReportUtc = [datetime]::UtcNow.AddSeconds(60) }
        $stillRunning = @()
        foreach ($entry in $this.AbandonedWarmShells) {
            if (-not $entry.Handle.IsCompleted) {
                if ($report) {
                    $this.Logger.LogWarning("Warm shell still parked: " +
                        $this.DescribeShell($entry.Shell, [string]$entry.Tag, $entry.Started))
                }
                $stillRunning += $entry
                continue
            }
            $elapsed = [int]([datetime]::UtcNow - $entry.Started).TotalSeconds
            try {
                $entry.Shell.EndInvoke($entry.Handle)
                $this.Logger.LogInfo(
                    "A runspace warm ($($entry.Tag)) finished late ($elapsed s) - that runspace is warm.")
            }
            catch {
                $this.Logger.LogWarning(
                    "A late runspace warm ($($entry.Tag)) failed after $elapsed s - its runspace " +
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

    # Background single-flight IP resolve, a no-op until a DC is warm or the host is
    # cached or in flight. The capped fast lane runs by default, worker path is the fallback.
    [void] PrefetchIp([string]$hostName) {
        if (-not $this.Resolver.NeedsResolve($hostName)) { return }
        if (-not $this.FastLaneHealthy) { $this.StartClassicResolve($hostName); return }
        if ($this.FastResolveActive -ge $this.FastResolveCap) {
            # Latch while queued so single-flight holds, then drain from CompleteResolve.
            $this.Resolver.MarkInFlight($hostName)
            $this.PendingFastResolves.Enqueue($hostName)
            return
        }
        $this.StartFastResolve($hostName)
    }

    hidden [void] StartFastResolve([string]$hostName) {
        try {
            $this.Resolver.MarkInFlight($hostName)
            $prep = $this.Resolver.PrepareResolveFast($hostName)
            $this.Home.StartJob($this.NewFastResolveJob($hostName), $prep)
            $this.FastResolveActive++
            $this.Logger.LogDebug("[$hostName] fast IP pre-resolve submitted (direct child, no pool slot).")
        }
        catch {
            # Release the latch if the job never started, or the host wedges forever.
            $this.Resolver.ClearInFlight($hostName)
            $this.Logger.LogException("[$hostName] fast IP pre-resolve could not start", $_)
        }
    }

    # Overridable seam (tests): the fast lane's job construction.
    hidden [AsyncJob] NewFastResolveJob([string]$hostName) {
        return [ResolveProcessJob]::new($hostName, [JobKind]::Resolve, $this.Logger)
    }

    # The pre-fast-lane PrefetchIp body: a full worker child via the pool. Used when
    # the lane is latched off and as the per-host ProcessFault fallback.
    hidden [void] StartClassicResolve([string]$hostName) {
        try {
            $this.Resolver.MarkInFlight($hostName)
            $prep = $this.Resolver.PrepareResolve($hostName)
            $this.Home.StartJob([AsyncJob]::new($hostName, [JobKind]::Resolve, $this.Logger), $prep)
            $this.Logger.LogDebug("[$hostName] IP pre-resolve job submitted (worker path).")
        }
        catch {
            $this.Resolver.ClearInFlight($hostName)
            $this.Logger.LogException("[$hostName] IP pre-resolve could not start", $_)
        }
    }

    # Starts queued fast resolves as slots free up. A lane latched off mid-queue sends
    # the remainder down the classic path instead of dropping them.
    hidden [void] StartNextFastResolve() {
        while ($this.PendingFastResolves.Count -gt 0 -and
            ($this.FastResolveActive -lt $this.FastResolveCap -or -not $this.FastLaneHealthy)) {
            $next = $this.PendingFastResolves.Dequeue()
            if ($this.FastLaneHealthy) { $this.StartFastResolve($next) }
            else { $this.StartClassicResolve($next) }
        }
    }

    # A failed job may mean a dead cached IP: drop it and re-resolve for the retry.
    [void] InvalidateResolved([string]$hostName) {
        $this.Resolver.Invalidate($hostName)
        $this.PrefetchIp($hostName)
    }

    # Fires the identity check as its own pool job, since its verdict gates the apply.
    [void] StartVerifyName([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($this.Resolver.GetCachedIp($hostName))) { return }
        $this.Resolver.ClearVerifiedName($hostName)
        try {
            $prep = $this.Resolver.PrepareName($hostName)
            $this.Home.StartJob([AsyncJob]::new($hostName, [JobKind]::Resolve, $this.Logger), $prep)
        }
        catch {
            $this.Logger.LogException("[$hostName] identity check could not start", $_)
        }
    }

    # Resolve finished: cache the DC (warm) or the per-host verdict and refresh the indicator.
    # HomePresenter owns the run/gather queue, so re-issuing queued work is handed back to it.
    [void] CompleteResolve([AsyncJob]$job) {
        $isFast = $job -is [ResolveProcessJob]
        if ($isFast) { $this.FastResolveActive = [Math]::Max(0, $this.FastResolveActive - 1) }
        try { $this.CompleteResolveCore($job, $isFast) }
        finally {
            # Whatever happened, a finished fast job frees a slot: drain the queue.
            if ($isFast) { $this.StartNextFastResolve() }
        }
    }

    hidden [void] CompleteResolveCore([AsyncJob]$job, [bool]$isFast) {
        if ($job.Status -eq 'Failed') {
            if ($isFast) { $this.OnFastResolveFault($job); return }
            # Surface why a resolve failed (an empty HostName is the startup DC warm).
            $who = if ([string]::IsNullOrWhiteSpace($job.HostName)) { 'DC warm-up' } else { "[$($job.HostName)] resolve" }
            $this.Logger.LogWarning("$who failed: $($job.FailureMessage)")
            # Even a failed resolve must release the single-flight latch, or the host wedges.
            $this.Resolver.ClearInFlight($job.HostName)
            $this.Home.DropPendingRunOnResolveFailure($job.HostName)
            # No auto re-probe: it churns while the DC is down, so the next action re-resolves.
            if (-not [string]::IsNullOrWhiteSpace($job.HostName)) {
                $this.Resolver.Invalidate($job.HostName)
                $this.Home.RenderReachability($job.HostName)
            }
            # Even a failed DC warm ends the startup crunch, so release the deferred warms.
            if ([string]::IsNullOrWhiteSpace($job.HostName)) {
                $this.Home.StartDeferredWarms('DC warm-up finished (failed)')
            }
            return
        }
        if ($isFast) { $this.FastFaultStreak = 0 }
        $items = @(@($job.Result) | Where-Object { $null -ne $_ })
        if ($items.Count -eq 0) {
            # An empty payload must still release the latch, or the host wedges forever.
            $who = if ([string]::IsNullOrWhiteSpace($job.HostName)) { 'DC warm-up' } else { "[$($job.HostName)] resolve" }
            $this.Logger.LogWarning("$who completed with no verdict payload - treating it as failed.")
            $this.Resolver.ClearInFlight($job.HostName)
            $this.Home.DropPendingRunOnResolveFailure($job.HostName)
            if ([string]::IsNullOrWhiteSpace($job.HostName)) {
                $this.Home.StartDeferredWarms('DC warm-up returned empty')
            }
            return
        }
        foreach ($item in $items) {
            $mode = [string]$item.Mode
            if ($mode -eq 'Warm') {
                $dc = [string]$item.ActiveDc
                $this.Logger.LogDebug(
                    "DC warm-up result received: dc='$dc', " +
                    "controllers=$(@($item.DomainControllers).Count).")
                if (-not [string]::IsNullOrWhiteSpace($dc)) {
                    $this.Resolver.SetActiveDc($dc)
                    $this.PersistDomainController($dc)
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
                # Log only a first find or an actual change, never a same-IP TTL refresh.
                if (-not [string]::IsNullOrWhiteSpace($newIp) -and $oldIp -ne $newIp) {
                    if ([string]::IsNullOrWhiteSpace($oldIp)) { $this.Logger.LogInfo("[$hn] resolved IP $newIp") }
                    else { $this.Logger.LogInfo("[$hn] IP changed: $oldIp -> $newIp") }
                }
                $this.Resolver.CacheVerdict($hn, $newIp, $online)
                # A landed verdict re-arms this host's one-shot classic fallback.
                [void]$this.FastFallbacks.Remove($hn)
                $this.Home.RenderReachability($hn)
                # Surface the fresh IP in the detail subtitle if this host's panel is open.
                if ($hn -eq $this.Home.SelectedHost) {
                    $row = $this.Home.GetRow($hn)
                    if ($row) { $row.SetResolvedIp($this.Resolver.GetCachedIp($hn)) }
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

    # Fast child faulted with no verdict: retry the host once on the classic path, and
    # 3 consecutive faults latch the lane off (worst case is pre-lane behaviour).
    hidden [void] OnFastResolveFault([AsyncJob]$job) {
        $hn = $job.HostName
        $this.FastFaultStreak++
        if ($this.FastFaultStreak -ge 3 -and $this.FastLaneHealthy) {
            $this.FastLaneHealthy = $false
            $this.Logger.LogWarning(
                "Fast resolve lane disabled for this session after $($this.FastFaultStreak) consecutive faults; " +
                "resolves fall back to the worker path.")
        }
        $this.Resolver.ClearInFlight($hn)
        if ($this.FastFallbacks.Add($hn)) {
            $this.Logger.LogWarning("[$hn] fast resolve fault: $($job.FailureMessage); retrying on the worker path.")
            $this.StartClassicResolve($hn)
        }
        else {
            # Second fault in one attempt: give up like a classic failure would.
            $this.Logger.LogWarning("[$hn] fast resolve fault after a fallback: $($job.FailureMessage)")
            $this.Home.DropPendingRunOnResolveFailure($hn)
        }
    }

    # Persists the active DC so the next launch skips AD discovery. Writes only on change.
    hidden [void] PersistDomainController([string]$dc) {
        if ($null -eq $this.ConfigManager) { return }
        if ([string]$this.Config.Settings['activeDomainController'] -eq $dc) { return }
        $this.Config.Settings['activeDomainController'] = $dc
        try { $this.ConfigManager.SaveConfig($this.Config) }
        catch { $this.Logger.LogException("Could not persist domain controller", $_) }
    }
}
