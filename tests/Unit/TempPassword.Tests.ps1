using module "..\..\src\Models\TempPassword.psm1"

Describe "TempPassword.Generate" {
    It "matches the phone-readable Xxxxx-Xxxxx-99! format at 15 chars" {
        foreach ($i in 1..50) {
            $p = [TempPassword]::Generate()
            $p.Length | Should -Be 15
            $p | Should -MatchExactly '^[A-Z][a-z]{4}-[A-Z][a-z]{4}-[2-9]{2}[!#$%+=]$'
        }
    }

    It "never emits an ambiguous glyph (0 O 1 l I i o)" {
        foreach ($i in 1..200) {
            [TempPassword]::Generate() | Should -Not -MatchExactly '[0O1lIio]'
        }
    }

    It "meets AD complexity by construction (upper + lower + digit + special)" {
        $p = [TempPassword]::Generate()
        $p | Should -Match '[A-Z]'
        $p | Should -Match '[a-z]'
        $p | Should -Match '[2-9]'
        $p | Should -MatchExactly '[!#$%+=]'
    }

    It "does not repeat across generations" {
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($i in 1..100) {
            $seen.Add([TempPassword]::Generate()) | Should -BeTrue
        }
    }
}

Describe "TempPassword.ToSecure" {
    It "round-trips length and comes back read-only" {
        $s = [TempPassword]::ToSecure('Abcde-Fghjk-23')
        $s | Should -BeOfType [securestring]
        $s.Length | Should -Be 14
        $s.IsReadOnly() | Should -BeTrue
    }

    It "returns an empty read-only SecureString for null/empty input" {
        ([TempPassword]::ToSecure('')).Length | Should -Be 0
        ([TempPassword]::ToSecure($null)).Length | Should -Be 0
    }
}
