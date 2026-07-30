using module "..\..\src\Core\ElevationContext.psm1"

Describe "ElevationContext" {

    BeforeDiscovery {
        # -Skip evaluates at discovery, before any BeforeAll runs. The capability, not the
        # OS: WindowsIdentity throws PlatformNotSupportedException wherever it is absent.
        $script:HasWindowsIdentity = $true
        try { [void][System.Security.Principal.WindowsIdentity]::GetCurrent() }
        catch { $script:HasWindowsIdentity = $false }
    }

    Context "Classify" {
        It "reports NotRequired for an action that does not need admin, elevated or not" {
            [ElevationContext]::Classify($false, $false) | Should -Be ([ElevationState]::NotRequired)
            [ElevationContext]::Classify($false, $true) | Should -Be ([ElevationState]::NotRequired)
        }

        It "reports Satisfied when an admin action runs in an elevated process" {
            [ElevationContext]::Classify($true, $true) | Should -Be ([ElevationState]::Satisfied)
        }

        It "reports RelaunchRequired when an admin action runs de-elevated" {
            [ElevationContext]::Classify($true, $false) | Should -Be ([ElevationState]::RelaunchRequired)
        }

        It "never reports Satisfied for an admin action without elevation" {
            # The gate this enum exists for: a de-elevated process must not reach psexec
            # or remote CIM, where the failure surfaces as an access denial on the target.
            foreach ($needsAdmin in @($true, $false)) {
                $verdict = [ElevationContext]::Classify($needsAdmin, $false)
                $verdict | Should -Not -Be ([ElevationState]::Satisfied)
            }
        }
    }

    Context "Token reads" {
        It "agrees with itself: the one-arg overload classifies against the live token" -Skip:(-not $script:HasWindowsIdentity) {
            $live = [ElevationContext]::IsElevated()
            [ElevationContext]::Classify($true) | Should -Be ([ElevationContext]::Classify($true, $live))
            [ElevationContext]::Classify($false) | Should -Be ([ElevationState]::NotRequired)
        }

        It "returns usable values for the current process" -Skip:(-not $script:HasWindowsIdentity) {
            [ElevationContext]::IsElevated() | Should -BeOfType [bool]
            [ElevationContext]::IsSystem() | Should -BeOfType [bool]
            [ElevationContext]::CurrentIdentityName() | Should -Not -BeNullOrEmpty
        }

        It "treats SYSTEM as a narrower question than elevated" -Skip:(-not $script:HasWindowsIdentity) {
            # Conflating the two is what sent autostart down the machine-account lane: a
            # SYSTEM token is elevated, so IsSystem implies IsElevated but never the reverse.
            if ([ElevationContext]::IsSystem()) {
                [ElevationContext]::IsElevated() | Should -BeTrue
            }
        }
    }
}
