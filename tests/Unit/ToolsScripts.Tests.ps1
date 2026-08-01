<#
    Parse guard for the dev/lab tools scripts. They run standalone on field
    machines (never imported by the app), so nothing else in the suite would
    catch a syntax break before a diagnostic session needs them.
#>
Describe "tools scripts parse cleanly" {

    It "<name> has no parse errors" -ForEach @(
        @{ name = 'Invoke-DiagnosticRun.ps1' }
        @{ name = 'Get-DonutRunspaceStacks.ps1' }
        @{ name = 'Diagnose-LensAgent.ps1' }
        @{ name = 'Invoke-Tests.ps1' }
        @{ name = 'Import-PinnedPester.ps1' }
        @{ name = 'Generate-CoverageReport.ps1' }
    ) {
        $path = Join-Path (Resolve-Path "$PSScriptRoot\..\..\tools").Path $name
        Test-Path $path | Should -BeTrue
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
    }

    It "the diagnostic harness embeds a child script that parses cleanly" {
        # The child here-string is code too; a typo there only explodes at 2 a.m.
        # on a lab machine. Extract and parse it.
        $path = Join-Path (Resolve-Path "$PSScriptRoot\..\..\tools").Path 'Invoke-DiagnosticRun.ps1'
        $raw = Get-Content $path -Raw
        $match = [regex]::Match($raw, "(?s)@'\r?\n(.*?)\r?\n'@")
        $match.Success | Should -BeTrue
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $match.Groups[1].Value, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
    }
}
