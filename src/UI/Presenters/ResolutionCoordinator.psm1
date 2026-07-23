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
    # Next time ReapWarmShells may dump parked-shell state lines (throttles to 1/min).
    hidden [datetime] $NextReapReportUtc = [datetime]::MinValue

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

    # Warms the pool ONE runspace at a time (serial is mandatory - concurrent
    # using-module compiles deadlock; implementation-notes: warm compile serialization).
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
                # One real worker pass; NOTHING more (the 64dbec8 recipe).
                $prep = $this.Resolver.PrepareWarmRunspace($tag)
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = $pool
                $ps.AddCommand($prep.ScriptPath) | Out-Null
                foreach ($k in $prep.Arguments.Keys) {
                    $ps.AddParameter($k, $prep.Arguments[$k]) | Out-Null
                }
                # Wait for THIS shell before submitting the next - never two graph
                # compiles in flight, or the pool deadlocks.
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
                    # A warm that never returns = the load lock is likely wedged; park
                    # it (never Dispose a running pipeline) and STOP piling on.
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
            # A parked shell holds its runspace, so raise the max so real jobs never
            # starve behind it; ReapWarmShells returns the slack when it lands.
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
            # Indexed reads only: enumerating a live stream while the worker appends
            # is the "Collection was modified" race (implementation-notes).
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

    # Pump-driven harvest of barrier-lapsed warm shells: a late finisher lands fully
    # warmed and returns one unit of raised capacity; a wedged one parks for life.
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
