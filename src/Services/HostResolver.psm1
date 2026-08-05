using module "..\Models\AppConfig.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\LogService.psm1"
using module ".\RemoteServices.psm1"

<#
.SYNOPSIS
    Start-early IP-resolution cache that keeps DNS work off the hot path.

.DESCRIPTION
    The expensive AD-authoritative resolution (discover domain controllers, pick
    a live one, resolve via it) is kept off the critical path: the active DC is
    warmed once at startup and each host's IP is resolved in the background the
    moment it's selected, then cached here. When a remote job starts, the
    presenter reads the cached IP and threads it to the worker so the worker never
    resolves on the critical path.

.NOTES
    WPF-free and does no network itself - the resolution runs in the worker
    (ExecutionService.RunResolvePhase). HostResolver only holds the cached state
    plus the "do we still need to resolve this?" decision, and builds the worker
    args (subclassing RemoteJobService purely to reuse BuildWorkerArgs, so
    nothing here touches the network/UI thread).
#>
class HostResolver : RemoteJobService {
    hidden [string]    $ActiveDc = ''
    # host -> @{ Ip, Online, CheckedAt } (case-insensitive keys).
    hidden [hashtable] $IpCache = @{}
    hidden [hashtable] $InFlight = @{}   # host -> $true while a resolve job is queued
    # host -> the name the box at its IP reported (identity check).
    hidden [hashtable] $VerifiedNames = @{}

    # A DHCP IP can move, so a verdict older than this re-resolves on the next select.
    [timespan] $Ttl = [timespan]::FromMinutes(5)

    HostResolver([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    HostResolver([AppConfig] $config, [NetworkProbe] $probe,
        [LogService] $logger) : base($config, $probe, $logger) {}

    # --- Cache state ---

    [void] SetActiveDc([string]$dc) {
        if (-not [string]::IsNullOrWhiteSpace($dc)) { $this.ActiveDc = $dc.Trim() }
    }

    [bool] HasActiveDc() {
        return -not [string]::IsNullOrWhiteSpace($this.ActiveDc)
    }

    [string] GetActiveDc() {
        return $this.ActiveDc
    }

    # Stores a verdict (fresh IP + reachability) and stamps it for the TTL.
    [void] CacheVerdict([string]$hostName, [string]$ip, [bool]$online) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $name = $hostName.Trim()
        $this.InFlight.Remove($name)
        # Cache even an unresolvable verdict, or the gates re-resolve it in a tight loop.
        $this.IpCache[$name] = @{ Ip = "$ip".Trim(); Online = $online; CheckedAt = [datetime]::UtcNow }
    }

    # Cached IP for a host, or $null when not resolved yet.
    [string] GetCachedIp([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return $null }
        $name = $hostName.Trim()
        if ($this.IpCache.ContainsKey($name)) { return [string]$this.IpCache[$name]['Ip'] }
        return $null
    }

    # Tri-state reachability for the UI: 'Online' / 'Offline' / 'Unknown'.
    [string] IsHostOnline([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return 'Unknown' }
        $name = $hostName.Trim()
        if (-not $this.IpCache.ContainsKey($name)) { return 'Unknown' }
        return $(if ([bool]$this.IpCache[$name]['Online']) { 'Online' } else { 'Offline' })
    }

    [void] MarkInFlight([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $this.InFlight[$hostName.Trim()] = $true
    }

    # Releases the single-flight latch without caching a verdict. A resolve that fails
    # or never starts would otherwise leave the host in flight forever.
    [void] ClearInFlight([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $this.InFlight.Remove($hostName.Trim())
    }

    # Drops a host's cached verdict so the next attempt re-resolves after a failed job.
    [void] Invalidate([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $this.IpCache.Remove($hostName.Trim())
    }

    # True when we can and should (re)resolve now: a DC is known, nothing is in flight
    # (single-flight), and the host is uncached or its verdict aged past the TTL.
    [bool] NeedsResolve([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return $false }
        if (-not $this.HasActiveDc()) { return $false }
        $name = $hostName.Trim()
        if ($this.InFlight.ContainsKey($name)) { return $false }
        if (-not $this.IpCache.ContainsKey($name)) { return $true }
        $age = [datetime]::UtcNow - [datetime]$this.IpCache[$name]['CheckedAt']
        return ($age -gt $this.Ttl)
    }

    # True when a cached verdict aged past the TTL. Unlike NeedsResolve it ignores DC
    # and in-flight state and uncached hosts, asking only whether the verdict is too old.
    [bool] IsVerdictStale([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return $false }
        $name = $hostName.Trim()
        if (-not $this.IpCache.ContainsKey($name)) { return $false }
        $age = [datetime]::UtcNow - [datetime]$this.IpCache[$name]['CheckedAt']
        return ($age -gt $this.Ttl)
    }

    # --- Worker-arg builders (the actual resolution runs on the pool) ---

    # Warm job: discover + pick a live domain controller (one-time, at startup).
    [hashtable] PrepareWarm() {
        return $this.BuildWorkerArgs('', 'Resolve', @{ Mode = 'Warm' })
    }

    # A no-op that loads the worker module graph into the pool runspace it lands on, so
    # later jobs never cold-load. $tag rides in HostName to give warm logs an identity.
    [hashtable] PrepareWarmRunspace([string]$tag) {
        return $this.BuildWorkerArgs($tag, 'Resolve', @{ Mode = 'WarmRunspace' })
    }

    # Per-host job: resolve $hostName against the already-warmed active DC.
    [hashtable] PrepareResolve([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, 'Resolve', @{ Mode = 'Host'; Dc = $this.ActiveDc })
    }

    # Fast-lane variant: args for the slim ResolveWorker child, which takes three CLI
    # strings and no Settings snapshot, so no per-resolve DeepClone on the UI thread.
    [hashtable] PrepareResolveFast([string]$hostName) {
        $scriptPath = Join-Path $this.Config.SourceRoot "Scripts\ResolveWorker.ps1"
        if (-not (Test-Path $scriptPath)) {
            $this.Logger.LogError("ResolveWorker script not found at $scriptPath")
            throw [System.IO.FileNotFoundException]::new('ResolveWorker script not found.', $scriptPath)
        }
        return @{
            ScriptPath     = $scriptPath
            TempConfigPath = $null
            Arguments      = @{
                HostName = $hostName
                Dc       = $this.ActiveDc
                LogsDir  = $this.Config.LogsPath
                DebugLog = $this.Logger.DebugEnabled
            }
        }
    }

    # Identity job: ask the box at the host's cached IP for its own name. It runs in
    # parallel with the apply-scan, and its verdict gates the destructive apply.
    [hashtable] PrepareName([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, 'Resolve', @{ Mode = 'Name'; Ip = $this.GetCachedIp($hostName) })
    }

    # --- Verified computer-name cache (identity check) ---

    [void] CacheName([string]$hostName, [string]$actualName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $this.VerifiedNames[$hostName.Trim()] = [string]$actualName
    }

    # The name the box at the host's IP reported, or '' if not checked yet.
    [string] GetVerifiedName([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return '' }
        $name = $hostName.Trim()
        if ($this.VerifiedNames.ContainsKey($name)) { return [string]$this.VerifiedNames[$name] }
        return ''
    }

    [void] ClearVerifiedName([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $this.VerifiedNames.Remove($hostName.Trim())
    }

    # Compares the target name to what the machine reported. 'Match' / 'Mismatch' /
    # 'Unknown' (not checked or query failed). Short-name, case-insensitive.
    [string] IdentityVerdict([string]$hostName) {
        $actual = $this.GetVerifiedName($hostName)
        if ([string]::IsNullOrWhiteSpace($actual)) { return 'Unknown' }
        $target = $hostName.Trim().Split('.')[0]
        $reported = $actual.Trim().Split('.')[0]
        return $(if ($target -ieq $reported) { 'Match' } else { 'Mismatch' })
    }
}
