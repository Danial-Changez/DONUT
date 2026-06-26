using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\Helpers\CapturingLogService.psm1"
using namespace System.Net

# Fakes NetworkProbe's raw AD/DNS seams so the discovery/selection/resolution
# logic can be exercised off a domain.
class FakeNetworkProbe : NetworkProbe {
    [string[]] $DCs = @()
    [hashtable] $OnlineMap = @{}     # server -> bool
    [hashtable] $ForwardMap = @{}    # hostname -> ip string
    [hashtable] $PtrMap = @{}        # ip string -> ptr name
    [int] $QueryCount = 0
    [bool] $ThrowOnQuery = $false

    FakeNetworkProbe() : base() {}
    FakeNetworkProbe([LogService]$logger) : base($logger) {}

    hidden [string[]] QueryDomainControllers() {
        $this.QueryCount++
        if ($this.ThrowOnQuery) { throw "ActiveDirectory module not available" }
        return $this.DCs
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

    hidden [string] ResolvePtrViaServer([IPAddress]$ip, [string]$server) {
        $key = $ip.ToString()
        if ($this.PtrMap.ContainsKey($key)) { return $this.PtrMap[$key] }
        return $null
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

        It "Should log a warning and cache empty when no controllers are found" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.DCs = @()

            $result = $probe.GetDomainControllers()

            $result.Count | Should -Be 0
            $logger.HasLevel("WARN") | Should -Be $true
        }

        It "Should log an exception and cache empty when the AD query throws" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.ThrowOnQuery = $true

            $result = $probe.GetDomainControllers()

            $result.Count | Should -Be 0
            $logger.HasLevel("ERROR") | Should -Be $true
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

    Context "CheckReverseDNS" {
        It "Should return true when the PTR record matches the expected host" {
            $probe = [FakeNetworkProbe]::new()
            $probe.DCs = @("DC1")
            $probe.OnlineMap = @{ "DC1" = $true }
            $probe.PtrMap = @{ "10.0.0.5" = "PC-01.contoso.local" }

            $probe.CheckReverseDNS([IPAddress]::Parse("10.0.0.5"), "PC-01") | Should -Be $true
        }

        It "Should return false when the PTR record does not match" {
            $probe = [FakeNetworkProbe]::new()
            $probe.DCs = @("DC1")
            $probe.OnlineMap = @{ "DC1" = $true }
            $probe.PtrMap = @{ "10.0.0.5" = "PC-99.contoso.local" }

            $probe.CheckReverseDNS([IPAddress]::Parse("10.0.0.5"), "PC-01") | Should -Be $false
        }

        It "Should fail hard (false + ERROR) when no domain controller is available" {
            $logger = [CapturingLogService]::new()
            $probe = [FakeNetworkProbe]::new($logger)
            $probe.DCs = @()

            $probe.CheckReverseDNS([IPAddress]::Parse("10.0.0.5"), "PC-01") | Should -Be $false
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
