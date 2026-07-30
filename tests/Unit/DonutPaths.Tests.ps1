using module "..\..\src\Core\DonutPaths.psm1"

Describe "DonutPaths" {

    BeforeAll {
        $script:SavedProgramData = $env:ProgramData
        $script:SavedLocalAppData = $env:LOCALAPPDATA
    }

    AfterAll {
        $env:ProgramData = $script:SavedProgramData
        $env:LOCALAPPDATA = $script:SavedLocalAppData
    }

    Context "Layout" {
        # Real temp paths, not drive literals: Join-Path validates the drive, so 'X:\PD'
        # throws off Windows and the assertion never runs.
        BeforeEach {
            $script:pd = Join-Path ([IO.Path]::GetTempPath()) 'DonutPathsTests-PD'
            $env:ProgramData = $script:pd
        }

        It "hangs every folder off one machine-wide root" {
            $root = [DonutPaths]::DataRoot()

            $root | Should -Be (Join-Path $script:pd 'DONUT\data')
            [DonutPaths]::ConfigDir() | Should -Be (Join-Path $root 'config')
            [DonutPaths]::LogsDir() | Should -Be (Join-Path $root 'logs')
            [DonutPaths]::ReportsDir() | Should -Be (Join-Path $root 'reports')
        }

        It "is machine-wide, not per-account: LOCALAPPDATA does not move it" {
            # The whole point of the root. A de-elevated UI and an elevated instance run
            # as different accounts and must still read the same config, token and logs.
            $env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) 'someone'
            $first = [DonutPaths]::DataRoot()

            $env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) 'other'
            [DonutPaths]::DataRoot() | Should -Be $first
        }

        It "tracks ProgramData when the host relocates it" {
            $env:ProgramData = Join-Path ([IO.Path]::GetTempPath()) 'Relocated'
            [DonutPaths]::DataRoot() | Should -BeLike "*Relocated*DONUT*data"
        }
    }

    Context "LegacyRoot" {
        It "names the pre-move location so a caller can point at it" {
            $env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) 'someone'
            [DonutPaths]::LegacyRoot() | Should -Be (Join-Path $env:LOCALAPPDATA 'DONUT')
        }

        It "returns null when LOCALAPPDATA is unset rather than a bare 'DONUT'" {
            # Join-Path against an empty root would yield a relative path that resolves
            # somewhere unrelated; callers only use this to print a hint.
            $env:LOCALAPPDATA = ''
            [DonutPaths]::LegacyRoot() | Should -BeNullOrEmpty
        }
    }
}
