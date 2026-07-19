using module "..\..\src\Models\MachineListShaper.psm1"

Describe "MachineListShaper" {

    Context "Categorize - precedence" {
        It "Running wins over every idle/reachability state" {
            [MachineListShaper]::Categorize($true, 'Online', 'Failed') | Should -Be 'Running'
            [MachineListShaper]::Categorize($true, 'Offline', '') | Should -Be 'Running'
        }
        It "Maps terminal problem states to NeedsAttention" {
            [MachineListShaper]::Categorize($false, 'Online', 'Failed') | Should -Be 'NeedsAttention'
            [MachineListShaper]::Categorize($false, 'Online', 'RebootRequired') | Should -Be 'NeedsAttention'
            [MachineListShaper]::Categorize($false, 'Unknown', 'ConnectionLost') | Should -Be 'NeedsAttention'
        }
        It "Maps reachability when idle status is benign" {
            [MachineListShaper]::Categorize($false, 'Offline', 'Completed') | Should -Be 'Offline'
            [MachineListShaper]::Categorize($false, 'Online', 'Completed') | Should -Be 'Online'
        }
        It "Falls back to Unknown when nothing is known" {
            [MachineListShaper]::Categorize($false, 'Unknown', '') | Should -Be 'Unknown'
            [MachineListShaper]::Categorize($false, '', '') | Should -Be 'Unknown'
        }
    }

    Context "StatusRank - ordering" {
        It "Orders needs-attention, running, online, offline, unknown" {
            [MachineListShaper]::StatusRank('NeedsAttention') | Should -Be 0
            [MachineListShaper]::StatusRank('Running') | Should -Be 1
            [MachineListShaper]::StatusRank('Online') | Should -Be 2
            [MachineListShaper]::StatusRank('Offline') | Should -Be 3
            [MachineListShaper]::StatusRank('Unknown') | Should -Be 4
        }
        It "Ranks an unrecognized category last" {
            [MachineListShaper]::StatusRank('Nonsense') | Should -Be 4
        }
    }

    Context "MatchesStatus" {
        It "Matches everything for All or blank" {
            [MachineListShaper]::MatchesStatus('Offline', 'All') | Should -BeTrue
            [MachineListShaper]::MatchesStatus('Offline', '') | Should -BeTrue
            [MachineListShaper]::MatchesStatus('Offline', $null) | Should -BeTrue
        }
        It "Matches only the selected category otherwise" {
            [MachineListShaper]::MatchesStatus('Online', 'Online') | Should -BeTrue
            [MachineListShaper]::MatchesStatus('Online', 'Offline') | Should -BeFalse
            [MachineListShaper]::MatchesStatus('NeedsAttention', 'NeedsAttention') | Should -BeTrue
        }
    }
}
