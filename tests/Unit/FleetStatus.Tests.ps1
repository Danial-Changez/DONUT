using module "..\..\src\Models\FleetStatus.psm1"

Describe "FleetStatus" {

    Context "FromJob - running states" {
        It "Maps a running UpdateApply to Updating (purple, busy)" {
            $s = [FleetStatus]::FromJob('UpdateApply', 'Running', $false)

            $s.State    | Should -Be ([FleetState]::Updating)
            $s.Label    | Should -Be 'Updating…'
            $s.ColorKey | Should -Be 'AccentPurple'
            $s.IsBusy   | Should -Be $true
        }

        It "Maps a running Scan to Scanning (cyan, busy)" {
            $s = [FleetStatus]::FromJob('Scan', 'Running', $false)

            $s.State    | Should -Be ([FleetState]::Scanning)
            $s.ColorKey | Should -Be 'AccentCyan'
            $s.IsBusy   | Should -Be $true
        }

        It "Maps a running UpdateScan to Scanning too" {
            $s = [FleetStatus]::FromJob('UpdateScan', 'Running', $false)
            $s.State | Should -Be ([FleetState]::Scanning)
        }
    }

    Context "FromJob - terminal states" {
        It "Maps Completed without reboot to Completed (green, not busy)" {
            $s = [FleetStatus]::FromJob('UpdateApply', 'Completed', $false)

            $s.State    | Should -Be ([FleetState]::Completed)
            $s.Label    | Should -Be 'Completed'
            $s.ColorKey | Should -Be 'AccentGreen'
            $s.IsBusy   | Should -Be $false
        }

        It "Maps Completed with reboot flag to RebootRequired (yellow)" {
            $s = [FleetStatus]::FromJob('UpdateApply', 'Completed', $true)

            $s.State    | Should -Be ([FleetState]::RebootRequired)
            $s.Label    | Should -Be 'Reboot required'
            $s.ColorKey | Should -Be 'AccentYellow'
            $s.IsBusy   | Should -Be $false
        }

        It "Maps Failed to Failed (red), reboot flag ignored" {
            $s = [FleetStatus]::FromJob('UpdateApply', 'Failed', $true)

            $s.State    | Should -Be ([FleetState]::Failed)
            $s.ColorKey | Should -Be 'AccentRed'
            $s.IsBusy   | Should -Be $false
        }
    }

    Context "FromJob - queued / unknown" {
        It "Maps Created to Queued (muted, not busy)" {
            $s = [FleetStatus]::FromJob('Scan', 'Created', $false)

            $s.State    | Should -Be ([FleetState]::Queued)
            $s.ColorKey | Should -Be 'BodyTextTertiary'
            $s.IsBusy   | Should -Be $false
        }

        It "Falls back to Queued for an unrecognized status" {
            $s = [FleetStatus]::FromJob('Scan', 'Bogus', $false)
            $s.State | Should -Be ([FleetState]::Queued)
        }
    }
}
