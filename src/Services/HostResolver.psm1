using module "..\Models\AppConfig.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\LogService.psm1"
using module ".\RemoteServices.psm1"

# HostResolver
#
# Start-early IP-resolution cache. The expensive AD-authoritative resolution
# (discover domain controllers, pick a live one, resolve via it) is kept off the
# hot path: the active DC is warmed once at startup and each host's IP is resolved
# in the background the moment it's selected, then cached here. When a remote job
# starts, the presenter reads the cached IP and threads it to the worker so the
# worker never resolves on the critical path.
#
# This type is WPF-free and does NO network itself - the resolution runs in the
# worker (ExecutionService.RunResolvePhase). HostResolver only holds the cached
# state + the "do we still need to resolve this?" decision, and builds the worker
# args (subclassing RemoteJobService purely to reuse BuildWorkerArgs - it does NOT
# call ValidateHostConnectivity, so nothing here touches the network/UI thread).
class HostResolver : RemoteJobService {
    hidden [string]    $ActiveDc = ''
    hidden [hashtable] $IpCache  = @{}   # host -> @{ Ip; Online; CheckedAt } (case-insensitive keys)
    hidden [hashtable] $InFlight = @{}   # host -> $true while a resolve job is queued

    # How long a cached verdict is trusted before a re-validate is allowed. A
    # DHCP IP can move, so we re-resolve on the next select once an entry is stale.
    [timespan] $Ttl = [timespan]::FromMinutes(5)

    HostResolver([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    HostResolver([AppConfig] $config, [NetworkProbe] $probe, [LogService] $logger) : base($config, $probe, $logger) {}

    # --- Cache state ------------------------------------------------------------------

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
        if ([string]::IsNullOrWhiteSpace($ip)) { return }
        $this.IpCache[$name] = @{ Ip = $ip.Trim(); Online = $online; CheckedAt = [datetime]::UtcNow }
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

    # Drops a host's cached verdict so the next attempt re-resolves (e.g. after a
    # job fails - the cached IP may be dead/stale).
    [void] Invalidate([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        $this.IpCache.Remove($hostName.Trim())
    }

    # True when we can and should (re)resolve now: a DC is known, no resolve is in
    # flight (single-flight), and the host is either uncached or its verdict has
    # aged past the TTL.
    [bool] NeedsResolve([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return $false }
        if (-not $this.HasActiveDc()) { return $false }
        $name = $hostName.Trim()
        if ($this.InFlight.ContainsKey($name)) { return $false }
        if (-not $this.IpCache.ContainsKey($name)) { return $true }
        $age = [datetime]::UtcNow - [datetime]$this.IpCache[$name]['CheckedAt']
        return ($age -gt $this.Ttl)
    }

    # --- Worker-arg builders (run the actual resolution on the pool) -------------------

    # Warm job: discover + pick a live domain controller (one-time, at startup).
    [hashtable] PrepareWarm() {
        return $this.BuildWorkerArgs('', 'Resolve', @{ Mode = 'Warm' })
    }

    # Per-host job: resolve $hostName against the already-warmed active DC.
    [hashtable] PrepareResolve([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, 'Resolve', @{ Mode = 'Host'; Dc = $this.ActiveDc })
    }
}
