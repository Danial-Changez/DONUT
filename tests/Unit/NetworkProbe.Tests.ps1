using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\Helpers\CapturingLogService.psm1"
using namespace System.Net

# Fakes NetworkProbe's raw AD/DNS seams so the discovery/selection/resolution
# logic can be exercised off a domain.
class FakeNetworkProbe : NetworkProbe {
    [string[]] $DCs = @()
    [string[]] $LdapDCs = @()
    [string[]] $DnsDCs = @()
    [hashtable] $OnlineMap = @{}     # server -> bool
    [hashtable] $ForwardMap = @{}    # hostname -> ip string
    [int] $QueryCount = 0
    [int] $LdapQueryCount = 0
    [int] $DnsQueryCount = 0
    [bool] $ThrowOnQuery = $false
    [bool] $ThrowOnLdap = $false
    [bool] $ThrowOnDns = $false

    FakeNetworkProbe() : base() {}
    FakeNetworkProbe([LogService]$logger) : base($logger) {}

    hidden [string[]] QueryDomainControllers() {
        $this.QueryCount++
        if ($this.ThrowOnQuery) { throw "ActiveDirectory module not available" }
        return $this.DCs
    }

    hidden [string[]] QueryDomainControllersViaLdap() {
        $this.LdapQueryCount++
        if ($this.ThrowOnLdap) { throw "LDAP bind failed" }
        return $this.LdapDCs
    }

    hidden [string[]] QueryDomainControllersViaDns() {
        $this.DnsQueryCount++
        if ($this.ThrowOnDns) { throw "SRV lookup failed" }
        return $this.DnsDCs
    }

    hidden [bool] TestServerOnline([string]$server) {
        return [bool]$this.OnlineMap[$server]
    }

    hidden [IPAddress] ResolveViaServer([string]$hostName, [string]$server) {
        if ($this.ForwardMap.ContainsKey($hostName)) {
            return [IPAddress]::Parse($this.ForwardMap[$hostName])
        }
        return $null
    }

    [hashtable] $NameMap = @{}     # ip string -> computer name
    [bool] $ThrowOnName = $false
    hidden [string] QueryComputerName([string]$ip) {
        if ($this.ThrowOnName) { throw "RPC unavailable" }
        if ($this.NameMap.ContainsKey($ip)) { return $this.NameMap[$ip] }
        return ''
    }
}

Describe "NetworkProbe" {

    Context "GetDomainControllers" {
        It "Should query AD once and cache the result across calls" {
            $probe = [FakeNetworkProbe]::new()
            $probe.DCs = @("DC1.contoso.local", "DC2.contoso.local")

            $first = $probe.GetDomainControllers()
            $second = $probe.GetDomainControllers()

            $first.Count | Should -Be 2
            $second.Count | Should -Be 2
            $probe.QueryCount | Should -Be 1
        }

        It "Should log an error and cache empty when every discovery stage comes back empty" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.DCs = @()

            $result = $probe.GetDomainControllers()

            $result.Count | Should -Be 0
            $probe.LdapQueryCount | Should -Be 1
            $probe.DnsQueryCount | Should -Be 1
            $logger.HasLevel("ERROR") | Should -Be $true
        }

        It "Should log an error and cache empty when every discovery stage throws" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.ThrowOnQuery = $true
            $probe.ThrowOnLdap = $true
            $probe.ThrowOnDns = $true

            $result = $probe.GetDomainControllers()

            $result.Count | Should -Be 0
            $logger.HasLevel("ERROR") | Should -Be $true
        }

        It "Should not touch the fallbacks when ADWS answers" {
            $probe = [FakeNetworkProbe]::new()
            $probe.DCs = @("DC1.contoso.local")

            $probe.GetDomainControllers().Count | Should -Be 1
            $probe.LdapQueryCount | Should -Be 0
            $probe.DnsQueryCount | Should -Be 0
        }

        # ADWS refuses the autostarted SYSTEM instance's machine account, so LDAP must work.
        It "Should fall back to LDAP when the ADWS query throws" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.ThrowOnQuery = $true
            $probe.LdapDCs = @("DC1.contoso.local", "DC2.contoso.local")

            $result = $probe.GetDomainControllers()

            $result.Count | Should -Be 2
            $probe.DnsQueryCount | Should -Be 0
            $logger.HasLevel("WARN") | Should -Be $true
        }

        It "Should fall back to DNS SRV when ADWS and LDAP both fail" {
            $probe = [FakeNetworkProbe]::new()
            $probe.ThrowOnQuery = $true
            $probe.ThrowOnLdap = $true
            $probe.DnsDCs = @("DC2.contoso.local")

            $probe.GetDomainControllers() | Should -Be @("DC2.contoso.local")
        }
    }

    Context "GetActiveDomainController" {
        It "Should select the first reachable controller" {
            $probe = [FakeNetworkProbe]::new()
            $probe.DCs = @("DC1", "DC2")
            $probe.OnlineMap = @{ "DC1" = $true; "DC2" = $true }

            $probe.GetActiveDomainController() | Should -Be "DC1"
        }

        It "Should skip offline controllers" {
            $probe = [FakeNetworkProbe]::new()
            $probe.DCs = @("DC1", "DC2")
            $probe.OnlineMap = @{ "DC1" = $false; "DC2" = $true }

            $probe.GetActiveDomainController() | Should -Be "DC2"
        }

        It "Should return null and log an error when none are reachable" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.DCs = @("DC1", "DC2")
            $probe.OnlineMap = @{ "DC1" = $false; "DC2" = $false }

            $probe.GetActiveDomainController() | Should -BeNullOrEmpty
            $logger.HasLevel("ERROR") | Should -Be $true
        }
    }

    Context "ResolveHost" {
        It "Should resolve a host via the active domain controller" {
            $probe = [FakeNetworkProbe]::new()
            $probe.DCs = @("DC1")
            $probe.OnlineMap = @{ "DC1" = $true }
            $probe.ForwardMap = @{ "PC-01" = "10.0.0.5" }

            $ip = $probe.ResolveHost("PC-01")

            $ip | Should -BeOfType [IPAddress]
            $ip.ToString() | Should -Be "10.0.0.5"
        }

        It "Should fail hard (null + ERROR) when no domain controller is available" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.DCs = @()

            $ip = $probe.ResolveHost("PC-01")

            $ip | Should -BeNullOrEmpty
            $logger.HasLevel("ERROR") | Should -Be $true
        }

        It "Should return null and log an error when the DC cannot resolve the host" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.DCs = @("DC1")
            $probe.OnlineMap = @{ "DC1" = $true }
            $probe.ForwardMap = @{}   # no record for the host

            $ip = $probe.ResolveHost("Unknown-PC")

            $ip | Should -BeNullOrEmpty
            $logger.HasLevel("ERROR") | Should -Be $true
        }
    }

    Context "ResolveWith" {
        It "Resolves against the supplied DC without discovering domain controllers" {
            $probe = [FakeNetworkProbe]::new()
            $probe.ForwardMap = @{ "PC-01" = "10.0.0.9" }

            $ip = $probe.ResolveWith("PC-01", "DC1")

            $ip.ToString() | Should -Be "10.0.0.9"
            $probe.QueryCount | Should -Be 0   # no DC discovery on this path
        }

        It "Returns null and logs when no DC is supplied" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)

            $probe.ResolveWith("PC-01", "") | Should -BeNullOrEmpty
            $logger.HasLevel("ERROR") | Should -Be $true
        }

        It "Returns null when the DC cannot resolve the host" {
            $probe = [FakeNetworkProbe]::new()
            $probe.ForwardMap = @{}

            $probe.ResolveWith("Unknown-PC", "DC1") | Should -BeNullOrEmpty
        }
    }

    Context "ResolveComputerName" {
        It "Returns the machine's own name at the given IP" {
            $probe = [FakeNetworkProbe]::new()
            $probe.NameMap = @{ "10.0.0.5" = "WS-5330" }
            $probe.ResolveComputerName("10.0.0.5") | Should -Be "WS-5330"
        }
        It "Returns '' for a blank IP without querying" {
            $probe = [FakeNetworkProbe]::new()
            $probe.ResolveComputerName("") | Should -Be ''
        }
        It "Returns '' (logged) when the query throws" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.ThrowOnName = $true
            $probe.ResolveComputerName("10.0.0.5") | Should -Be ''
            $logger.HasLevel("ERROR") | Should -Be $true
        }
    }

    Context "IsRpcAvailable" {
        It "Should return false for non-existent host" {
            $probe = [NetworkProbe]::new()
            $probe.IsRpcAvailable("non-existent-host-xyz-12345") | Should -Be $false
        }

        It "Should return a boolean for localhost" {
            $probe = [NetworkProbe]::new()
            $probe.IsRpcAvailable("127.0.0.1") | Should -BeOfType [bool]
        }

        It "Should handle empty hostname gracefully" {
            $probe = [NetworkProbe]::new()
            $probe.IsRpcAvailable("") | Should -Be $false
        }
    }

    Context "IsSmbAvailable" {
        It "Should return false for non-existent host" {
            $probe = [NetworkProbe]::new()
            $probe.IsSmbAvailable("non-existent-host-xyz-12345") | Should -Be $false
        }

        It "Should return a boolean for localhost" {
            $probe = [NetworkProbe]::new()
            $probe.IsSmbAvailable("127.0.0.1") | Should -BeOfType [bool]
        }

        It "Should handle empty hostname gracefully" {
            $probe = [NetworkProbe]::new()
            $probe.IsSmbAvailable("") | Should -Be $false
        }
    }

    Context "IsOnline" {
        It "Should return true for localhost" {
            $probe = [NetworkProbe]::new()
            $probe.IsOnline("localhost") | Should -Be $true
        }

        It "Should return true for 127.0.0.1" {
            $probe = [NetworkProbe]::new()
            $probe.IsOnline("127.0.0.1") | Should -Be $true
        }

        It "Should return false for non-existent host" {
            $probe = [NetworkProbe]::new()
            $probe.IsOnline("non-existent-host-xyz-12345") | Should -Be $false
        }

        It "Should return false for empty hostname" {
            $probe = [NetworkProbe]::new()
            $probe.IsOnline("") | Should -Be $false
        }
    }
}
