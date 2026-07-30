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

    # --- Domain controller discovery ---

    # Returns the cached DC list, discovering once: RSAT/ADWS, then .NET DirectoryServices
    # (plain LDAP works under tokens ADWS refuses, e.g. SYSTEM), then DNS SRV (no auth).
    [string[]] GetDomainControllers() {
        if ($null -ne $this.DomainControllers) {
            return $this.DomainControllers
        }

        $found = @()
        try {
            $this.Logger.LogDebug("DC discovery: querying AD for domain controllers...")
            $found = @($this.QueryDomainControllers() | Where-Object { $_ })
        }
        catch {
            $this.Logger.LogWarning("DC discovery via Get-ADDomainController (RSAT/ADWS) failed: $($_.Exception.Message)")
        }
        if ($found.Count -eq 0) {
            try {
                $found = @($this.QueryDomainControllersViaLdap() | Where-Object { $_ })
                if ($found.Count -gt 0) { $this.Logger.LogInfo("DC discovery fell back to .NET DirectoryServices (LDAP).") }
            }
            catch {
                $this.Logger.LogWarning("DC discovery via .NET DirectoryServices failed: $($_.Exception.Message)")
            }
        }
        if ($found.Count -eq 0) {
            try {
                $found = @($this.QueryDomainControllersViaDns() | Where-Object { $_ })
                if ($found.Count -gt 0) { $this.Logger.LogInfo("DC discovery fell back to DNS SRV records.") }
            }
            catch {
                $this.Logger.LogWarning("DC discovery via DNS SRV failed: $($_.Exception.Message)")
            }
        }
        $this.DomainControllers = $found

        if ($this.DomainControllers.Count -eq 0) {
            $this.Logger.LogError("All three DC discovery stages failed (ADWS, LDAP, DNS SRV) - is the host domain-joined with working DNS?")
        }
        else {
            $this.Logger.LogInfo("Cached $($this.DomainControllers.Count) domain controller(s): $($this.DomainControllers -join ', ')")
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
            $this.Logger.LogDebug("DC discovery: probing '$dc'...")
            if ($this.TestServerOnline($dc)) {
                $this.ActiveDomainController = $dc
                $this.Logger.LogInfo("Selected active domain controller: $dc")
                return $dc
            }
            $this.Logger.LogDebug("DC discovery: '$dc' not reachable, trying next.")
        }

        $this.Logger.LogError("No reachable domain controller found among: $($controllers -join ', ')")
        return $null
    }

    # --- DNS resolution (fail-hard via active DC) ---

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

    # Resolves a host against an already-known DC (one Resolve-DnsName, no discovery)
    # - the cheap background pre-resolve path. Returns $null (logged) on any failure.
    [IPAddress] ResolveWith([string]$hostName, [string]$dc) {
        if ([string]::IsNullOrWhiteSpace($dc)) {
            $this.Logger.LogError("ResolveWith for '$hostName': no domain controller supplied.")
            return $null
        }
        try {
            $this.Logger.LogDebug("DNS: resolving '$hostName' via DC '$dc'...")
            $ip = $this.ResolveViaServer($hostName, $dc)
            $ipText = if ($null -ne $ip) { $ip.ToString() } else { 'no address' }
            $this.Logger.LogDebug("DNS: '$hostName' via '$dc' -> $ipText.")
            return $ip
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

    # --- Connectivity probes ---

    # Shared bounded (2s) TCP connect probe behind IsRpcAvailable/IsSmbAvailable. The two
    # label params preserve each wrapper's exact log strings. Logs a DEBUG line on failure.
    hidden [bool] IsPortOpen([string]$hostName, [int]$port,
        [string]$portDesc, [string]$checkLabel) {
        return $this.IsPortOpen($hostName, $port, $portDesc, $checkLabel, $true)
    }

    # $logFailure=$false silences the failure DEBUG line for hot, high-frequency callers
    # (the per-tick tail gate) that would otherwise log every ~1.5s while a host is down.
    hidden [bool] IsPortOpen([string]$hostName, [int]$port,
        [string]$portDesc, [string]$checkLabel, [bool]$logFailure) {
        try {
            # Pre-connect on purpose: a hooked BeginConnect never returns, so only a
            # line logged before it can name the wedged call, host, and port.
            if ($logFailure) {
                $this.Logger.LogDebug(
                    "$checkLabel probe: connecting to '$hostName':$port (2 s cap)...")
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $client = [TcpClient]::new()
            $result = $client.BeginConnect($hostName, $port, $null, $null)
            $success = $result.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(2))
            if ($success) {
                $client.EndConnect($result)
                $client.Close()
                if ($logFailure) {
                    $ms = $sw.ElapsedMilliseconds
                    $this.Logger.LogDebug("$checkLabel probe: '$hostName':$port open ($ms ms).")
                }
                return $true
            }
            $client.Close()
            if ($logFailure) { $this.Logger.LogDebug("$portDesc (port $port) not reachable on '$hostName'.") }
            return $false
        }
        catch {
            if ($logFailure) { $this.Logger.LogDebug("$checkLabel availability check for '$hostName' failed: $($_.Exception.Message)") }
            return $false
        }
    }

    # TCP 135 (RPC endpoint mapper) - what psexec/CIM need to connect.
    [bool] IsRpcAvailable([string]$hostName) {
        return $this.IsPortOpen($hostName, 135, 'RPC endpoint mapper', 'RPC')
    }

    # TCP 445 (SMB) = the admin share + psexec transport. An open 135 doesn't imply
    # 445; when blocked, UNC ops hang with no timeout - so check it up front.
    [bool] IsSmbAvailable([string]$hostName) {
        return $this.IsPortOpen($hostName, 445, 'SMB', 'SMB')
    }

    # Same 445 reachability check, but silent on failure. The live-tail gate calls this every
    # ~1.5s; when a host drops mid-run the noisy variant spammed a DEBUG line per tick.
    [bool] IsSmbReachableQuiet([string]$hostName) {
        return $this.IsPortOpen($hostName, 445, 'SMB', 'SMB', $false)
    }

    # Cheap non-blocking "is MY network up" check; the reconnect loop uses it to tell
    # own-Wi-Fi-down from target-unreachable. Overridable seam for the worker tests.
    [bool] IsLocalOnline() {
        try {
            return [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
        }
        catch {
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

    # Asks the machine at an IP for its own name (the identity check gating a
    # destructive apply), via WMI over DCOM. Returns '' (logged) on failure.
    [string] ResolveComputerName([string]$ip) {
        if ([string]::IsNullOrWhiteSpace($ip)) { return '' }
        try {
            # Pre-call breadcrumb: DCOM binds below PowerShell; if the query wedges,
            # this line names it.
            $this.Logger.LogDebug("Identity check: querying computer name at '$ip' (WMI/DCOM)...")
            $actual = $this.QueryComputerName($ip)
            $this.Logger.LogDebug("Identity check: '$ip' reports '$actual'.")
            return $actual
        }
        catch {
            $this.Logger.LogException("Computer-name query for '$ip' failed", $_)
            return ''
        }
    }

    # --- Overridable seams (raw side effects; faked in unit tests) ---

    # Queries Active Directory for all domain controllers and returns their host names.
    hidden [string[]] QueryDomainControllers() {
        return @(Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName)
    }

    # Same LDAP stack as user search (DirectorySearcher), which is proven to work as
    # the machine account; GetComputerDomain reads domain membership, not the token.
    hidden [string[]] QueryDomainControllersViaLdap() {
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
        return @($domain.DomainControllers | Select-Object -ExpandProperty Name)
    }

    # Last resort: the DC locator SRV records every domain publishes in DNS.
    hidden [string[]] QueryDomainControllersViaDns() {
        $fqdn = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Domain
        return @(Resolve-DnsName -Type SRV -Name "_ldap._tcp.dc._msdcs.$fqdn" -ErrorAction Stop |
                Where-Object NameTarget | Select-Object -ExpandProperty NameTarget -Unique)
    }

    # Reads Win32_ComputerSystem.Name from the host at $ip over a DCOM CIM session
    # (root\cimv2, single property - none of the root\wmi serialization issues).
    hidden [string] QueryComputerName([string]$ip) {
        # -OperationTimeoutSec bounds the open (see GatherRemoteInventory): a box that
        # died between the RPC gate and this call must fail in seconds, not minutes.
        $open = @{
            ComputerName        = $ip
            SessionOption       = (New-CimSessionOption -Protocol Dcom)
            OperationTimeoutSec = 15
            ErrorAction         = 'Stop'
        }
        $session = New-CimSession @open
        try {
            $query = @{
                CimSession          = $session
                ClassName           = 'Win32_ComputerSystem'
                Property            = 'Name'
                OperationTimeoutSec = 10
                ErrorAction         = 'Stop'
            }
            $cs = Get-CimInstance @query
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
