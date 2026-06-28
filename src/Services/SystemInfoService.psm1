using module "..\Core\NetworkProbe.psm1"
using module "..\Core\LogService.psm1"

# SystemInfoService
#
# Gathers the operator/controller environment shown in the Home overview strip:
# this machine's network identity, domain controller health (reused from
# NetworkProbe's DC discovery), and local battery state.
#
# All gathering is resilient (any probe failure degrades to a sensible default)
# so the dashboard never blocks or throws on an off-domain or desktop machine.
# The CIM/network calls live in seam methods; the pure label formatting is
# static and unit-tested.

class SystemInfo {
    [string] $Hostname = ''
    [string] $IPv4 = ''
    [string] $Domain = ''
    [bool]   $DomainJoined = $false
    [string] $DomainController = ''
    [bool]   $DcReachable = $false
    [bool]   $HasBattery = $false
    [int]    $BatteryPercent = -1
    [bool]   $Charging = $false
}

class SystemInfoService {
    hidden [object] $Probe       # NetworkProbe (duck-typed; may be $null)
    hidden [LogService] $Logger

    SystemInfoService([object]$probe, [LogService]$logger) {
        $this.Probe = $probe
        $this.Logger = if ($null -ne $logger) { $logger } else { [NullLogService]::new() }
    }

    [SystemInfo] Gather() {
        $info = [SystemInfo]::new()

        try { $info.Hostname = $this.GetHostname() } catch { $this.Logger.LogDebug("Hostname lookup failed: $_") }
        try { $info.IPv4 = $this.GetPrimaryIPv4() } catch { $this.Logger.LogDebug("IPv4 lookup failed: $_") }

        try {
            $dom = $this.GetDomainInfo()
            $info.Domain = [string]$dom.Domain
            $info.DomainJoined = [bool]$dom.Joined
        } catch { $this.Logger.LogDebug("Domain lookup failed: $_") }

        try {
            $bat = $this.GetBatteryRaw()
            if ($null -ne $bat) {
                $info.HasBattery = $true
                $info.BatteryPercent = [int]$bat.Percent
                $info.Charging = [bool]$bat.Charging
            }
        } catch { $this.Logger.LogDebug("Battery lookup failed: $_") }

        # Domain controller health (reuses NetworkProbe's cached discovery).
        try {
            if ($null -ne $this.Probe) {
                $dc = $this.Probe.GetActiveDomainController()
                if (-not [string]::IsNullOrWhiteSpace($dc)) {
                    $info.DomainController = $dc
                    $info.DcReachable = $true
                }
            }
        } catch { $this.Logger.LogDebug("DC lookup failed: $_") }

        return $info
    }

    # --- Pure formatting (unit-tested) -----------------------------------------------

    static [string] BatteryLabel([bool]$hasBattery, [int]$percent, [bool]$charging) {
        if (-not $hasBattery) { return 'AC - no battery' }
        $state = if ($charging) { 'charging' } else { 'on battery' }
        return "$percent% - $state"
    }

    # --- Seams (raw side effects; resilient) -----------------------------------------

    hidden [string] GetHostname() {
        return $env:COMPUTERNAME
    }

    hidden [string] GetPrimaryIPv4() {
        # Prefer the IPv4 on the interface that owns the default route.
        $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
            Select-Object -First 1
        if ($cfg -and $cfg.IPv4Address) {
            return $cfg.IPv4Address.IPAddress
        }

        # Fallback: first non-loopback IPv4 from DNS.
        $addrs = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())
        $v4 = $addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not [System.Net.IPAddress]::IsLoopback($_) } | Select-Object -First 1
        if ($v4) { return $v4.ToString() }
        return ''
    }

    hidden [hashtable] GetDomainInfo() {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        return @{
            Domain = if ($cs.PartOfDomain) { $cs.Domain } else { 'WORKGROUP' }
            Joined = [bool]$cs.PartOfDomain
        }
    }

    # Returns @{ Percent; Charging } or $null when there is no battery.
    hidden [hashtable] GetBatteryRaw() {
        $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $bat) { return $null }
        # BatteryStatus 1 = discharging; anything else implies AC/charging.
        return @{
            Percent  = [int]$bat.EstimatedChargeRemaining
            Charging = ([int]$bat.BatteryStatus -ne 1)
        }
    }
}
