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
    WPF-free and does NO network itself — the resolution runs in the worker
    (ExecutionService.RunResolvePhase). HostResolver only holds the cached state
    plus the "do we still need to resolve this?" decision, and builds the worker
    args (subclassing RemoteJobService purely to reuse BuildWorkerArgs; it does
    NOT call AssertHostReachable, so nothing here touches the network/UI thread).
#>
class HostResolver : RemoteJobService {
    hidden [string]    $ActiveDc = ''
    hidden [hashtable] $IpCache  = @{}   # host -> @{ Ip; Online; CheckedAt } (case-insensitive keys)
    hidden [hashtable] $InFlight = @{}   # host -> $true while a resolve job is queued
    hidden [hashtable] $VerifiedNames = @{}   # host -> name the box at its IP reported (identity check)

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

    # Runspace-warm job: a no-op whose only effect is loading the worker module graph
    # into the pool runspace it lands on, so later concurrent jobs never cold-load.
    [hashtable] PrepareWarmRunspace() {
        return $this.BuildWorkerArgs('', 'Resolve', @{ Mode = 'WarmRunspace' })
    }

    # Per-host job: resolve $hostName against the already-warmed active DC.
    [hashtable] PrepareResolve([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, 'Resolve', @{ Mode = 'Host'; Dc = $this.ActiveDc })
    }

    # Identity job: ask the box at the host's cached IP for its own name. Fired in
    # parallel with the apply-scan; the verdict gates the destructive apply.
    [hashtable] PrepareName([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, 'Resolve', @{ Mode = 'Name'; Ip = $this.GetCachedIp($hostName) })
    }

    # --- Verified computer-name cache (identity check) --------------------------------

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
