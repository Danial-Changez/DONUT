using module "..\..\src\Models\FleetCardStatus.psm1"

Describe "FleetCardStatus" {

    Context "FromJob - running states" {
        It "Maps a running UpdateApply to Updating (purple, busy)" {
            $s = [FleetCardStatus]::FromJob('UpdateApply', 'Running', $false)

            $s.State    | Should -Be ([FleetCardState]::Updating)
            $s.Label    | Should -Be 'Updating…'
            $s.ColorKey | Should -Be 'AccentPurple'
            $s.IsBusy   | Should -Be $true
        }

        It "Maps a running Scan to Scanning (cyan, busy)" {
            $s = [FleetCardStatus]::FromJob('Scan', 'Running', $false)

            $s.State    | Should -Be ([FleetCardState]::Scanning)
            $s.ColorKey | Should -Be 'AccentCyan'
            $s.IsBusy   | Should -Be $true
        }

        It "Maps a running UpdateScan to Scanning too" {
            $s = [FleetCardStatus]::FromJob('UpdateScan', 'Running', $false)
            $s.State | Should -Be ([FleetCardState]::Scanning)
        }
    }

    Context "FromJob - terminal states" {
        It "Maps Completed without reboot to Completed (green, not busy)" {
            $s = [FleetCardStatus]::FromJob('UpdateApply', 'Completed', $false)

            $s.State    | Should -Be ([FleetCardState]::Completed)
            $s.Label    | Should -Be 'Completed'
            $s.ColorKey | Should -Be 'AccentGreen'
            $s.IsBusy   | Should -Be $false
        }

        It "Maps Completed with reboot flag to RebootRequired (yellow)" {
            $s = [FleetCardStatus]::FromJob('UpdateApply', 'Completed', $true)

            $s.State    | Should -Be ([FleetCardState]::RebootRequired)
            $s.Label    | Should -Be 'Reboot required'
            $s.ColorKey | Should -Be 'AccentYellow'
            $s.IsBusy   | Should -Be $false
        }

        It "Maps Failed to Failed (red), reboot flag ignored" {
            $s = [FleetCardStatus]::FromJob('UpdateApply', 'Failed', $true)

            $s.State    | Should -Be ([FleetCardState]::Failed)
            $s.ColorKey | Should -Be 'AccentRed'
            $s.IsBusy   | Should -Be $false
        }
    }

    Context "FromJob - queued / unknown" {
        It "Maps Created to Queued (muted, not busy)" {
            $s = [FleetCardStatus]::FromJob('Scan', 'Created', $false)

            $s.State    | Should -Be ([FleetCardState]::Queued)
            $s.ColorKey | Should -Be 'BodyTextTertiary'
            $s.IsBusy   | Should -Be $false
        }

        It "Falls back to Queued for an unrecognized status" {
            $s = [FleetCardStatus]::FromJob('Scan', 'Bogus', $false)
            $s.State | Should -Be ([FleetCardState]::Queued)
        }
    }

    Context "Reconnecting - drop recovery" {
        It "Reconnecting() is amber and busy (mirrors the Unconfirmed tone, keeps pulsing)" {
            $s = [FleetCardStatus]::Reconnecting()

            $s.State    | Should -Be ([FleetCardState]::Reconnecting)
            $s.Label    | Should -Be 'Reconnecting…'
            $s.ColorKey | Should -Be 'AccentOrange'
            $s.IsBusy   | Should -Be $true
        }
    }
}
