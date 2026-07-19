using module "..\..\src\Models\MachineNameMatcher.psm1"

Describe "MachineNameMatcher" {

    BeforeAll {
        $script:P = @('^CAP-', '^B[0-9]{4}', '^WVD')
    }

    Context "LooksLikeMachine - default org patterns" {
        It "Matches the common CAP- prefix" {
            [MachineNameMatcher]::LooksLikeMachine('CAP-1024', $P) | Should -BeTrue
        }
        It "Matches B followed by 4-plus digits, then more" {
            [MachineNameMatcher]::LooksLikeMachine('B3132', $P) | Should -BeTrue
            [MachineNameMatcher]::LooksLikeMachine('B30120099-01', $P) | Should -BeTrue
        }
        It "Matches the WVD virtual-machine prefix" {
            [MachineNameMatcher]::LooksLikeMachine('WVD-EAST-07', $P) | Should -BeTrue
        }
        It "Is case-insensitive" {
            [MachineNameMatcher]::LooksLikeMachine('cap-1024', $P) | Should -BeTrue
            [MachineNameMatcher]::LooksLikeMachine('wvd07', $P) | Should -BeTrue
        }
    }

    Context "LooksLikeMachine - people and non-machines" {
        It "Rejects a SAM-style name with no machine prefix" {
            [MachineNameMatcher]::LooksLikeMachine('jsmith', $P) | Should -BeFalse
        }
        It "Rejects a first name that starts with B but not B+4digits" {
            [MachineNameMatcher]::LooksLikeMachine('Bob', $P) | Should -BeFalse
            [MachineNameMatcher]::LooksLikeMachine('Brian', $P) | Should -BeFalse
        }
        It "Rejects B with fewer than 4 digits" {
            [MachineNameMatcher]::LooksLikeMachine('B312', $P) | Should -BeFalse
            [MachineNameMatcher]::LooksLikeMachine('B3', $P) | Should -BeFalse
        }
        It "Rejects a two-word person name (has whitespace)" {
            [MachineNameMatcher]::LooksLikeMachine('John Smith', $P) | Should -BeFalse
            [MachineNameMatcher]::LooksLikeMachine('CAP-1 is down', $P) | Should -BeFalse
        }
        It "Rejects blank / whitespace / null" {
            [MachineNameMatcher]::LooksLikeMachine('', $P) | Should -BeFalse
            [MachineNameMatcher]::LooksLikeMachine('   ', $P) | Should -BeFalse
            [MachineNameMatcher]::LooksLikeMachine($null, $P) | Should -BeFalse
        }
        It "Trims surrounding whitespace before matching" {
            [MachineNameMatcher]::LooksLikeMachine('  CAP-1024  ', $P) | Should -BeTrue
        }
    }

    Context "LooksLikeMachine - pattern list handling" {
        It "Falls back to the built-in defaults when patterns are null or empty" {
            [MachineNameMatcher]::LooksLikeMachine('CAP-1024', $null) | Should -BeTrue
            [MachineNameMatcher]::LooksLikeMachine('CAP-1024', @()) | Should -BeTrue
        }
        It "Honors a custom pattern list" {
            [MachineNameMatcher]::LooksLikeMachine('LAB-9', @('^LAB-')) | Should -BeTrue
            [MachineNameMatcher]::LooksLikeMachine('CAP-1024', @('^LAB-')) | Should -BeFalse
        }
        It "Skips a malformed pattern instead of throwing" {
            { [MachineNameMatcher]::LooksLikeMachine('CAP-1024', @('[', '^CAP-')) } | Should -Not -Throw
            [MachineNameMatcher]::LooksLikeMachine('CAP-1024', @('[', '^CAP-')) | Should -BeTrue
        }
        It "Ignores blank entries in the pattern list" {
            [MachineNameMatcher]::LooksLikeMachine('CAP-1024', @('', '  ', '^CAP-')) | Should -BeTrue
        }
    }
}
