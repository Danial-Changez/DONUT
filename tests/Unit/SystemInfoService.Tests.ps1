using module "..\..\src\Services\SystemInfoService.psm1"

# Fakes every raw seam so Gather's wiring and per-probe resilience are testable
# off Windows - the same overridable-seam pattern the other services use.
class FakeSystemInfoService : SystemInfoService {
    [string] $Hostname = 'HOST-1'
    [string] $Ipv4 = '10.0.0.5'
    [hashtable] $Domain = @{ Domain = 'corp.example'; Joined = $true }
    [hashtable] $Battery = @{ Percent = 76; Charging = $true }
    [string[]] $Throws = @()

    FakeSystemInfoService([object]$probe) : base($probe, $null) {}

    hidden [string] GetHostname() { $this.Gate('host'); return $this.Hostname }
    hidden [string] GetPrimaryIPv4() { $this.Gate('ip'); return $this.Ipv4 }
    hidden [hashtable] GetDomainInfo() { $this.Gate('domain'); return $this.Domain }
    hidden [hashtable] GetBatteryRaw() { $this.Gate('battery'); return $this.Battery }
    hidden [void] Gate([string]$name) {
        if ($this.Throws -contains $name) { throw "$name probe down" }
    }
}

# Duck-typed stand-in for NetworkProbe's cached DC discovery.
class FakeDcProbe {
    [string] $Dc = 'DC01.corp.example'
    [bool] $ThrowOnLookup = $false
    [string] GetActiveDomainController() {
        if ($this.ThrowOnLookup) { throw 'no DC' }
        return $this.Dc
    }
}

Describe "SystemInfoService" {

    Context "BatteryLabel" {
        It "Shows charge and charging state when a battery is present" {
            [SystemInfoService]::BatteryLabel($true, 76, $true) | Should -Be '76% - charging'
        }

        It "Shows 'on battery' when discharging" {
            [SystemInfoService]::BatteryLabel($true, 42, $false) | Should -Be '42% - on battery'
        }

        It "Shows an AC label when there is no battery" {
            [SystemInfoService]::BatteryLabel($false, -1, $false) | Should -Be 'AC - no battery'
        }
    }

    Context "Gather (faked seams)" {
        It "assembles every field from the seams" {
            $info = [FakeSystemInfoService]::new([FakeDcProbe]::new()).Gather()

            $info.Hostname         | Should -Be 'HOST-1'
            $info.IPv4             | Should -Be '10.0.0.5'
            $info.Domain           | Should -Be 'corp.example'
            $info.DomainJoined     | Should -BeTrue
            $info.HasBattery       | Should -BeTrue
            $info.BatteryPercent   | Should -Be 76
            $info.Charging         | Should -BeTrue
            $info.DomainController | Should -Be 'DC01.corp.example'
            $info.DcReachable      | Should -BeTrue
        }

        It "reports desktop defaults when the battery seam finds nothing" {
            $svc = [FakeSystemInfoService]::new([FakeDcProbe]::new())
            $svc.Battery = $null

            $info = $svc.Gather()

            $info.HasBattery     | Should -BeFalse
            $info.BatteryPercent | Should -Be -1
            $info.Charging       | Should -BeFalse
        }

        It "degrades a single failing probe without losing the rest" {
            foreach ($seam in 'host', 'ip', 'domain', 'battery') {
                $svc = [FakeSystemInfoService]::new([FakeDcProbe]::new())
                $svc.Throws = @($seam)

                $info = $svc.Gather()

                # The failed probe leaves its default; every other field still lands.
                if ($seam -ne 'host') { $info.Hostname | Should -Be 'HOST-1' -Because "only $seam failed" }
                if ($seam -ne 'ip') { $info.IPv4 | Should -Be '10.0.0.5' -Because "only $seam failed" }
                if ($seam -ne 'domain') { $info.DomainJoined | Should -BeTrue -Because "only $seam failed" }
                if ($seam -ne 'battery') { $info.HasBattery | Should -BeTrue -Because "only $seam failed" }
                $info.DcReachable | Should -BeTrue -Because "the DC probe is independent of $seam"
            }
        }

        It "leaves DC health empty without a probe" {
            $info = [FakeSystemInfoService]::new($null).Gather()
            $info.DcReachable      | Should -BeFalse
            $info.DomainController | Should -Be ''
        }

        It "leaves DC health empty when discovery throws" {
            $probe = [FakeDcProbe]::new()
            $probe.ThrowOnLookup = $true
            ([FakeSystemInfoService]::new($probe)).Gather().DcReachable | Should -BeFalse
        }

        It "treats a blank DC name as unreachable, not as a reachable blank" {
            $probe = [FakeDcProbe]::new()
            $probe.Dc = '   '
            $info = ([FakeSystemInfoService]::new($probe)).Gather()
            $info.DcReachable      | Should -BeFalse
            $info.DomainController | Should -Be ''
        }
    }
}
