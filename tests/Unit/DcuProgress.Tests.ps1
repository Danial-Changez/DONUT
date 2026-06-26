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
}
