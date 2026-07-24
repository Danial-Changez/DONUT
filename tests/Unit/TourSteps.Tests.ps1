using module "..\..\src\Models\TourSteps.psm1"

Describe "TourSteps" {
    BeforeAll { $script:Steps = [TourSteps]::Build() }

    It "Is short - six steps (per the Guided Tour pattern)" {
        $Steps.Count | Should -Be 6
    }

    It "Opens with a centered welcome that has no target" {
        $Steps[0].Placement | Should -Be 'center'
        $Steps[0].TargetKey | Should -Be ''
        $Steps[0].Title | Should -Match 'Welcome'
    }

    It "Every non-welcome step targets a control and has a placement" {
        foreach ($s in $Steps[1..($Steps.Count - 1)]) {
            $s.TargetKey | Should -Not -BeNullOrEmpty
            $s.Placement | Should -BeIn @('below', 'above', 'right', 'left')
        }
    }

    It "Covers the essential controls in order" {
        ($Steps | ForEach-Object { $_.TargetKey }) | Should -Be @('', 'search', 'mode', 'list', 'detail', 'settings')
    }

    It "Gives every step a title and body" {
        foreach ($s in $Steps) {
            $s.Title | Should -Not -BeNullOrEmpty
            $s.Body | Should -Not -BeNullOrEmpty
        }
    }
}
