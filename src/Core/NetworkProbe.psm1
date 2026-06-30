using namespace System.Net
using namespace System.Net.Sockets
using module ".\LogService.psm1"

<#
.SYNOPSIS
    Authoritative, DC-backed host resolution + reachability checks.

.DESCRIPTION
    Resolves hostnames against an Active Directory domain controller so DNS
    answers come from an authoritative, online server rather than the local
    resolver cache. Domain controllers are discovered once and cached; the first
    reachable one is used as the DNS server for all subsequent lookups.

    Resolution is fail-hard: if no domain controller can be discovered or reached,
    ResolveHost / CheckReverseDNS log an [ERROR] and return $null/$false rather
    than silently falling back to the local resolver.

.NOTES
    The raw AD/DNS calls are isolated in overridable seam methods
    (QueryDomainControllers, ResolveViaServer, ResolvePtrViaServer,
    TestServerOnline) so the discovery/selection logic can be unit-tested off a
    domain by subclassing this type and faking those seams.
#>
class NetworkProbe {
    [LogService] $Logger

    # Cached discovery state. $null = not yet queried; an array (possibly empty)
    # means discovery has run.
    hidden [string[]] $DomainControllers = $null
    hidden [string] $ActiveDomainController = $null

    NetworkProbe() {
        $this.Logger = [NullLogService]::new()
    }

    NetworkProbe([LogService] $logger) {
        $this.Logger = [LogService]::Coalesce($logger)
    }

    # --- Domain controller discovery -------------------------------------------------

    # Returns the cached list of domain controllers, querying AD once on first use.
    [string[]] GetDomainControllers() {
        if ($null -ne $this.DomainControllers) {
            return $this.DomainControllers
        }

        try {
            $found = $this.QueryDomainControllers()
            $this.DomainControllers = @($found | Where-Object { $_ })

            if ($this.DomainControllers.Count -eq 0) {
                $this.Logger.LogWarning("Domain controller discovery returned no controllers.")
            }
            else {
                $this.Logger.LogInfo("Cached $($this.DomainControllers.Count) domain controller(s): $($this.DomainControllers -join ', ')")
            }
        }
        catch {
            $this.Logger.LogException("Failed to query domain controllers (is the ActiveDirectory module installed and the host domain-joined?)", $_)
            $this.DomainControllers = @()
        }

        return $this.DomainControllers
    }

    # Returns the first reachable domain controller, caching the selection.
    # Returns $null when none are reachable.
    [string] GetActiveDomainController() {
        if (-not [string]::IsNullOrWhiteSpace($this.ActiveDomainController)) {
            return $this.ActiveDomainController
        }

        $controllers = $this.GetDomainControllers()
        foreach ($dc in $controllers) {
            if ($this.TestServerOnline($dc)) {
                $this.ActiveDomainController = $dc
                $this.Logger.LogInfo("Selected active domain controller: $dc")
                return $dc
            }
        }

        $this.Logger.LogError("No reachable domain controller found among: $($controllers -join ', ')")
        return $null
    }

    # --- DNS resolution (fail-hard via active DC) ------------------------------------

    [IPAddress] ResolveHost([string]$hostName) {
        $server = $this.GetActiveDomainController()
        if ([string]::IsNullOrWhiteSpace($server)) {
            $this.Logger.LogError("DNS resolution failed for '$hostName': no active domain controller available.")
            return $null
        }

        try {
            $ip = $this.ResolveViaServer($hostName, $server)
            if ($null -ne $ip) {
                $this.Logger.LogStructured("DEBUG", "DNS_RESOLVE", @{ host = $hostName; server = $server; ip = $ip.ToString() })
                return $ip
            }
            $this.Logger.LogError("DNS resolution for '$hostName' via domain controller '$server' returned no address.")
            return $null
        }
        catch {
            $this.Logger.LogException("DNS resolution for '$hostName' via domain controller '$server' failed", $_)
            return $null
        }
    }

    # Resolves a host against an ALREADY-KNOWN domain controller, skipping DC
    # discovery (no AD module, just one Resolve-DnsName). Used by the background
    # pre-resolve path, which warms the active DC once at startup and then resolves
    # individual hosts cheaply. Returns $null (logged) on any failure.
    [IPAddress] ResolveWith([string]$hostName, [string]$dc) {
        if ([string]::IsNullOrWhiteSpace($dc)) {
            $this.Logger.LogError("ResolveWith for '$hostName': no domain controller supplied.")
            return $null
        }
        try {
            return $this.ResolveViaServer($hostName, $dc)
        }
        catch {
            $this.Logger.LogException("DNS resolution for '$hostName' via '$dc' failed", $_)
            return $null
        }
    }

    [bool] CheckReverseDNS([IPAddress]$ip, [string]$expectedHostName) {
        $server = $this.GetActiveDomainController()
        if ([string]::IsNullOrWhiteSpace($server)) {
            $this.Logger.LogError("Reverse DNS check failed for '$ip': no active domain controller available.")
            return $false
        }

        try {
            $resolvedName = $this.ResolvePtrViaServer($ip, $server)
            if ([string]::IsNullOrWhiteSpace($resolvedName)) {
                $this.Logger.LogWarning("Reverse DNS for '$ip' via domain controller '$server' returned no name.")
                return $false
            }
            return $resolvedName -like "*$expectedHostName*"
        }
        catch {
            $this.Logger.LogException("Reverse DNS check for '$ip' via domain controller '$server' failed", $_)
            return $false
        }
    }

    # --- Connectivity probes ---------------------------------------------------------

    [bool] IsRpcAvailable([string]$hostName) {
        # Test TCP port 135 (RPC Endpoint Mapper)
        try {
            $client = [TcpClient]::new()
            $result = $client.BeginConnect($hostName, 135, $null, $null)
            $success = $result.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(2))
            if ($success) {
                $client.EndConnect($result)
                $client.Close()
                return $true
            }
            $client.Close()
            $this.Logger.LogDebug("RPC endpoint mapper (port 135) not reachable on '$hostName'.")
            return $false
        }
        catch {
            $this.Logger.LogDebug("RPC availability check for '$hostName' failed: $($_.Exception.Message)")
            return $false
        }
    }

    [bool] IsOnline([string]$hostName) {
        try {
            return (Test-Connection -ComputerName $hostName -Count 1 -Quiet -ErrorAction SilentlyContinue)
        }
        catch {
            $this.Logger.LogDebug("Online check for '$hostName' failed: $($_.Exception.Message)")
            return $false
        }
    }

    # Asks the machine AT an IP for its own computer name (the identity check used
    # before a destructive Apply). Queries WMI over DCOM - the same RPC transport
    # psexec uses - so it works wherever a run would, and runs on its own thread,
    # never the dcu-cli path. Returns '' (logged) if it can't be determined.
    [string] ResolveComputerName([string]$ip) {
        if ([string]::IsNullOrWhiteSpace($ip)) { return '' }
        try {
            return $this.QueryComputerName($ip)
        }
        catch {
            $this.Logger.LogException("Computer-name query for '$ip' failed", $_)
            return ''
        }
    }

    # --- Overridable seams (raw side effects; faked in unit tests) --------------------

    # Queries Active Directory for all domain controllers and returns their host names.
    hidden [string[]] QueryDomainControllers() {
        return @(Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName)
    }

    # Reads Win32_ComputerSystem.Name from the host at $ip over a DCOM CIM session
    # (root\cimv2, single property - none of the root\wmi serialization issues).
    hidden [string] QueryComputerName([string]$ip) {
        $session = New-CimSession -ComputerName $ip -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop
        try {
            $cs = Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -Property Name -OperationTimeoutSec 10 -ErrorAction Stop
            return [string]$cs.Name
        }
        finally {
            Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
        }
    }

    # Resolves a host's A record using the given DNS server. Returns $null if none.
    hidden [IPAddress] ResolveViaServer([string]$hostName, [string]$server) {
        $records = Resolve-DnsName -Name $hostName -Server $server -Type A -ErrorAction Stop
        $aRecord = $records | Where-Object { $_.IPAddress } | Select-Object -First 1
        if ($null -ne $aRecord) {
            return [IPAddress]::Parse($aRecord.IPAddress)
        }
        return $null
    }

    # Resolves the PTR (reverse) record for an IP using the given DNS server.
    hidden [string] ResolvePtrViaServer([IPAddress]$ip, [string]$server) {
        $records = Resolve-DnsName -Name $ip.ToString() -Server $server -Type PTR -ErrorAction Stop
        $ptr = $records | Where-Object { $_.NameHost } | Select-Object -First 1
        if ($null -ne $ptr) {
            return $ptr.NameHost
        }
        return $null
    }

    # Reports whether a server is reachable (used to pick an active DC).
    hidden [bool] TestServerOnline([string]$server) {
        return $this.IsOnline($server)
    }
}
