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
            $job = [AsyncJob]::new('', [JobKind]::Resolve)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.Home.ActiveJobs.Add($job)
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
        # while the dispatcher is rendering (e.g. mid-scan) the UI freezes. The N jobs run
        # concurrently and the WaitOne barrier below holds each runspace, so all N warm.
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
                $handles.Add($ps.BeginInvoke())
                $shells.Add($ps)
            }
            catch {
                $this.Logger.LogException("Runspace warm-up could not start", $_)
            }
        }

        # WaitHandle.WaitAll throws on an STA thread, so wait per-handle with WaitOne.
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        for ($i = 0; $i -lt $shells.Count; $i++) {
            try {
                $remaining = [int][Math]::Max(0,
                    [Math]::Ceiling(($deadline - [datetime]::UtcNow).TotalMilliseconds))
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

    # Resolves a host's IP in the background (single-flight); no-op until a DC is warm
    # or if the host is already cached / in flight.
    [void] PrefetchIp([string]$hostName) {
        if (-not $this.Resolver.NeedsResolve($hostName)) { return }
        try {
            $this.Resolver.MarkInFlight($hostName)
            $prep = $this.Resolver.PrepareResolve($hostName)
            $job = [AsyncJob]::new($hostName, [JobKind]::Resolve)
            $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.Home.ActiveJobs.Add($job)
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
            $job = [AsyncJob]::new($hostName, [JobKind]::Resolve)
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
}
