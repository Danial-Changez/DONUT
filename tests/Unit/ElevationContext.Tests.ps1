using module "..\..\src\Core\ElevationContext.psm1"

Describe "ElevationContext" {

    BeforeDiscovery {
        # -Skip evaluates at discovery, before any BeforeAll runs. The capability, not the
        # OS: WindowsIdentity throws PlatformNotSupportedException wherever it is absent.
        $script:HasWindowsIdentity = $true
        try { [void][System.Security.Principal.WindowsIdentity]::GetCurrent() }
        catch { $script:HasWindowsIdentity = $false }
    }

    Context "Token reads" {
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
