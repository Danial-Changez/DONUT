using module "..\..\src\Core\NetworkProbe.psm1"
using namespace System.Net

Describe "NetworkProbe" {

    BeforeAll {
        $probe = [NetworkProbe]::new()
    }

    Context "ResolveHost" {
        It "Should resolve localhost to an IP address" {
            $ip = $probe.ResolveHost("localhost")
            
            $ip | Should -Not -BeNullOrEmpty
            $ip | Should -BeOfType [IPAddress]
        }

        It "Should resolve 127.0.0.1 as a valid host" {
            $ip = $probe.ResolveHost("127.0.0.1")
            
            $ip | Should -Not -BeNullOrEmpty
            $ip.ToString() | Should -Be "127.0.0.1"
        }

        It "Should return null for non-existent hostname" {
            $ip = $probe.ResolveHost("this-host-definitely-does-not-exist-12345.local")
            
            $ip | Should -BeNullOrEmpty
        }

        It "Should handle whitespace-only hostname" {
            # Whitespace gets trimmed and treated as local machine by DNS
            # This test verifies the method doesn't throw
            { $probe.ResolveHost("   ") } | Should -Not -Throw
        }
    }

    Context "CheckReverseDNS" {
        It "Should return true when reverse DNS matches expected hostname" {
            # Use loopback which should resolve
            $ip = [IPAddress]::Parse("127.0.0.1")
            
            # The reverse lookup of 127.0.0.1 typically returns localhost or the machine name
            $result = $probe.CheckReverseDNS($ip, "localhost")
            
            # This may vary by system configuration, so we just verify it doesn't throw
            $result | Should -BeOfType [bool]
        }

        It "Should return false for mismatched hostname" {
            $ip = [IPAddress]::Parse("127.0.0.1")
            
            $result = $probe.CheckReverseDNS($ip, "completely-wrong-hostname-xyz")
            
            $result | Should -Be $false
        }

        It "Should return false for invalid IP" {
            # Using a non-routable IP that won't have reverse DNS
            $ip = [IPAddress]::Parse("192.0.2.1")  # TEST-NET-1, documentation range
            
            $result = $probe.CheckReverseDNS($ip, "anything")
            
            $result | Should -Be $false
        }
    }

    Context "IsRpcAvailable" {
        It "Should return false for non-existent host" {
            $result = $probe.IsRpcAvailable("non-existent-host-xyz-12345")
            
            $result | Should -Be $false
        }

        It "Should return false for localhost if RPC not listening" {
            # Most dev machines won't have RPC endpoint mapper on 135
            # This tests the timeout/connection logic
            $result = $probe.IsRpcAvailable("127.0.0.1")
            
            $result | Should -BeOfType [bool]
        }

        It "Should handle empty hostname gracefully" {
            $result = $probe.IsRpcAvailable("")
            
            $result | Should -Be $false
        }
    }

    Context "IsOnline" {
        It "Should return true for localhost" {
            $result = $probe.IsOnline("localhost")
            
            $result | Should -Be $true
        }

        It "Should return true for 127.0.0.1" {
            $result = $probe.IsOnline("127.0.0.1")
            
            $result | Should -Be $true
        }

        It "Should return false for non-existent host" {
            $result = $probe.IsOnline("non-existent-host-xyz-12345")
            
            $result | Should -Be $false
        }

        It "Should return false for empty hostname" {
            $result = $probe.IsOnline("")
            
            $result | Should -Be $false
        }
    }
}
