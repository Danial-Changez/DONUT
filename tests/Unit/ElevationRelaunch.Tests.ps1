using module "..\..\src\Core\ElevationRelaunch.psm1"

Describe "ElevationRelaunch" {

    Context "BuildSpec" {
        BeforeAll {
            # The host is whatever runs the suite, so assert on the branch it selects rather
            # than on a path only one platform produces.
            $script:spec = [ElevationRelaunch]::BuildSpec('C:\My App\src')
            $script:isPwshHost =
            [IO.Path]::GetFileName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -ieq 'pwsh.exe'
        }

        It "names the running host, never a guessed path" {
            $expected = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $script:spec.FilePath | Should -Be $expected
        }

        It "tells the successor which PID to wait for" {
            # Local\ mutex scope is per-session, so the elevated instance would collide with
            # the de-elevated one that spawned it if it did not wait.
            $ownPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
            $script:spec.Arguments | Should -Match "\b$ownPid\b"
        }

        It "spells the wait in the host's own argument syntax" {
            if ($script:isPwshHost) {
                $script:spec.Arguments | Should -Match '-AwaitPid \d+'
                $script:spec.Arguments | Should -Match '-File "C:\\My App\\src\\Start-Donut\.ps1"'
            }
            else {
                $script:spec.Arguments | Should -Match '--await-pid \d+'
            }
        }

        It "quotes the script path so a space or OneDrive segment survives" -Skip:(-not $script:isPwshHost) {
            $spaced = [ElevationRelaunch]::BuildSpec('C:\Users\x\OneDrive\DONUT\src')
            $spaced.Arguments | Should -BeLike '*-File "C:\Users\x\OneDrive\DONUT\src\Start-Donut.ps1"*'
        }
    }

    Context "Spawn" {
        It "reports a declined prompt as declined, not as a breakage" {
            # 1223 is ERROR_CANCELLED. It has to stay distinguishable: a decline leaves a
            # working de-elevated app, anything else is worth a real error.
            Mock -CommandName Start-Process -ModuleName ElevationRelaunch {
                throw [System.ComponentModel.Win32Exception]::new(1223)
            }
            $result = [ElevationRelaunch]::Spawn(@{ FilePath = 'x'; Arguments = 'y' })
            $result.Ok | Should -BeFalse
            $result.Declined | Should -BeTrue
        }

        It "reports any other failure as not declined, with the reason kept" {
            Mock -CommandName Start-Process -ModuleName ElevationRelaunch {
                throw [System.ComponentModel.Win32Exception]::new(5)
            }
            $result = [ElevationRelaunch]::Spawn(@{ FilePath = 'x'; Arguments = 'y' })
            $result.Ok | Should -BeFalse
            $result.Declined | Should -BeFalse
            $result.Reason | Should -Not -BeNullOrEmpty
        }

        It "never throws, so a caller can always keep running de-elevated" {
            Mock -CommandName Start-Process -ModuleName ElevationRelaunch { throw 'anything at all' }
            { [ElevationRelaunch]::Spawn(@{ FilePath = 'x'; Arguments = 'y' }) } | Should -Not -Throw
        }
    }
}
