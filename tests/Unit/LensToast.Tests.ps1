Describe "Lens toast sidecar script" {

    BeforeAll {
        # Dot-sourcing is safe off Windows because the [ADSI] binds live inside script blocks.
        . (Join-Path $PSScriptRoot '..\..\src\Scripts\LensAgent.Common.ps1')
    }

    It "builds a script that parses cleanly and targets the DONUT AppUserModelId" {
        $s = New-LensToastScript -title 'WS-1' -body 'Updates applied. A manual reboot is required.'

        # The payload only ever runs on a field machine, so pin its syntax here.
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $s.Contains("CreateToastNotifier('DONUT')") | Should -BeTrue
        $s.Contains('<text>WS-1</text>') | Should -BeTrue
    }

    It "escapes XML-hostile input so nothing breaks out of the toast payload" {
        $s = New-LensToastScript -title "</text><evil>" -body "x & y's ""z"""

        $s.Contains('</text><evil>') | Should -BeFalse
        $s.Contains('&lt;/text&gt;&lt;evil&gt;') | Should -BeTrue
        # The apostrophe escape is what keeps the single-quoted LoadXml line intact.
        $s.Contains('&apos;') | Should -BeTrue
        $s.Contains('&amp;') | Should -BeTrue
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$null, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
    }
}
