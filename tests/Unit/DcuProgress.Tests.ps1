using module "..\..\src\Models\DcuProgress.psm1"

Describe "DcuProgress" {

    Context "ParsePercent - real DCU lines" {
        It "Reads 0.00% from a downloading line" {
            $line = "Downloading updates (0 of 0), 0 bytes of 1.8 GB transferred (0.00%)..."
            [DcuProgress]::ParsePercent($line) | Should -Be 0
        }

        It "Reads 100.00% from a downloaded line" {
            $line = "Downloaded updates (0 of 0)., 1.8 GB of 1.8 GB transferred (100.00%)..."
            [DcuProgress]::ParsePercent($line) | Should -Be 100
        }

        It "Reads a mid-transfer fractional percentage" {
            $line = "Downloading updates (1 of 9), 0.9 GB of 1.8 GB transferred (47.50%)..."
            [DcuProgress]::ParsePercent($line) | Should -Be 47.5
        }
    }

    Context "ParsePercent - comma decimal locale" {
        It "Reads a comma-decimal percentage (real lab line)" {
            $line = "Downloading updates (3 of 3), 185,1 MB of 1,5 GB transferred (12,26%)..."
            [DcuProgress]::ParsePercent($line) | Should -Be 12.26
        }

        It "Reads a small comma-decimal percentage" {
            $line = "Downloading updates (1 of 3), 3,8 MB of 1,5 GB transferred (0,25%)..."
            [DcuProgress]::ParsePercent($line) | Should -Be 0.25
        }

        It "Is not confused by comma-decimals elsewhere in the line" {
            # '1,5 GB' and '(1 of 3)' must not be mistaken for the percentage.
            $line = "Downloading updates (1 of 3), 0 bytes of 1,5 GB transferred (0,00%)..."
            [DcuProgress]::ParsePercent($line) | Should -Be 0
        }
    }

    Context "ParsePercent - no progress present" {
        It "Returns -1 for a line with a count but no percent" {
            [DcuProgress]::ParsePercent("9 updates were selected. Download Size: 1.8 GB") | Should -Be -1
        }

        It "Returns -1 for an unrelated status line" {
            [DcuProgress]::ParsePercent("Scanning system devices ...") | Should -Be -1
        }

        It "Returns -1 for null or empty input" {
            [DcuProgress]::ParsePercent($null) | Should -Be -1
            [DcuProgress]::ParsePercent("") | Should -Be -1
        }
    }

    Context "IsInstalling - the apply install phase" {
        It "matches dcu install lines (case-insensitive), not download or scan" {
            [DcuProgress]::IsInstalling("Installing updates (1 of 3)...") | Should -BeTrue
            [DcuProgress]::IsInstalling("installing update...") | Should -BeTrue
            [DcuProgress]::IsInstalling("Downloading updates (1 of 3), (12.26%)...") | Should -BeFalse
            [DcuProgress]::IsInstalling("Scanning system devices ...") | Should -BeFalse
            [DcuProgress]::IsInstalling($null) | Should -BeFalse
        }
    }

    Context "ParsePercent - robustness" {
        It "Takes the last percentage when several appear" {
            [DcuProgress]::ParsePercent("phase (10.00%) then (90.00%)") | Should -Be 90
        }

        It "Tolerates whitespace inside the parentheses" {
            [DcuProgress]::ParsePercent("transferred ( 25.0 % )...") | Should -Be 25
        }

        It "Clamps values above 100" {
            [DcuProgress]::ParsePercent("weird (150%)") | Should -Be 100
        }
    }

    Context "ParseScanStep - the five scan milestones" {
        It "maps each milestone line (with its outputLog timestamp prefix) to its step" {
            [DcuProgress]::ParseScanStep("[2026-07-02 15:14:33] : Checking for updates...")                       | Should -Be 1
            [DcuProgress]::ParseScanStep("[2026-07-02 15:14:33] : Checking for application component updates...") | Should -Be 2
            [DcuProgress]::ParseScanStep("[2026-07-02 15:14:38] : Scanning system devices...")                    | Should -Be 3
            [DcuProgress]::ParseScanStep("[2026-07-02 15:15:01] : Determining available updates...")              | Should -Be 4
            [DcuProgress]::ParseScanStep("[2026-07-02 15:15:43] : Check for updates completed")                   | Should -Be 5
        }

        It "does not mistake the component check (step 2) for the update check (step 1)" {
            # "Checking for application component updates" would also match a naive
            # 'checking for' pattern - the more specific line must win.
            [DcuProgress]::ParseScanStep("Checking for application component updates...") | Should -Be 2
        }

        It "returns 0 for non-milestone, blank, or null lines" {
            [DcuProgress]::ParseScanStep("The computer manufacturer is 'Dell'") | Should -Be 0
            [DcuProgress]::ParseScanStep("Downloading updates (1 of 3)...")     | Should -Be 0
            [DcuProgress]::ParseScanStep("")                                    | Should -Be 0
            [DcuProgress]::ParseScanStep($null)                                 | Should -Be 0
        }

        It "labels every step and knows the step count" {
            [DcuProgress]::ScanStepCount | Should -Be 5
            foreach ($s in 1..5) { [DcuProgress]::ScanStepLabel($s) | Should -Not -BeNullOrEmpty }
            [DcuProgress]::ScanStepLabel(0) | Should -Be ''
        }
    }

    Context "Reconnect status lines" {
        It "recognizes and strips the worker's reconnect marker" {
            $line = "$([DcuProgress]::ReconnectMarker)Reconnecting to WS-5330 to resume…"
            [DcuProgress]::IsReconnectLine($line)         | Should -BeTrue
            [DcuProgress]::StripReconnectMarker($line)    | Should -Be 'Reconnecting to WS-5330 to resume…'
        }

        It "does not flag a normal dcu-cli line, and leaves it untouched" {
            $dcu = '[2026-07-09 14:55:43] : Installing updates (4 of 4)...'
            [DcuProgress]::IsReconnectLine($dcu)      | Should -BeFalse
            [DcuProgress]::StripReconnectMarker($dcu) | Should -Be $dcu
            [DcuProgress]::IsReconnectLine('')        | Should -BeFalse
            [DcuProgress]::IsReconnectLine($null)     | Should -BeFalse
        }

        It "a reconnect line never registers as a percent or a scan step (can't disturb the bar)" {
            $line = "$([DcuProgress]::ReconnectMarker)this machine is offline. Waiting to reconnect…"
            [DcuProgress]::ParsePercent($line)  | Should -Be -1
            [DcuProgress]::ParseScanStep($line) | Should -Be 0
        }
    }
}
