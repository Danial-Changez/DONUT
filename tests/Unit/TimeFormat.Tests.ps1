using module "..\..\src\Core\TimeFormat.psm1"

Describe "TimeFormat" {

    Context "Relative" {
        It "Returns 'just now' for the present" {
            [TimeFormat]::Relative([datetime]::UtcNow) | Should -Be 'just now'
        }

        It "Returns 'just now' for small clock skew into the future" {
            [TimeFormat]::Relative([datetime]::UtcNow.AddSeconds(5)) | Should -Be 'just now'
        }

        It "Returns minutes for a few minutes ago" {
            [TimeFormat]::Relative([datetime]::UtcNow.AddMinutes(-2)) | Should -Be '2 min ago'
        }

        It "Returns hours for a few hours ago" {
            [TimeFormat]::Relative([datetime]::UtcNow.AddHours(-3)) | Should -Be '3 hr ago'
        }

        It "Returns 'yesterday' between 24 and 48 hours" {
            [TimeFormat]::Relative([datetime]::UtcNow.AddHours(-30)) | Should -Be 'yesterday'
        }

        It "Returns day count within the week" {
            [TimeFormat]::Relative([datetime]::UtcNow.AddDays(-3)) | Should -Be '3 days ago'
        }

        It "Returns a short absolute date beyond a week" {
            $when = [datetime]::UtcNow.AddDays(-20)
            $expected = $when.ToLocalTime().ToString('MMM d')
            [TimeFormat]::Relative($when) | Should -Be $expected
        }

        It "Normalises a local-kind input the same as UTC" {
            $local = [datetime]::Now.AddMinutes(-5)
            [TimeFormat]::Relative($local) | Should -Be '5 min ago'
        }
    }
}
