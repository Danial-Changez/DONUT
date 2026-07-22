<#
    Regression guard for the "job failed and Donut.log shows nothing" class of bug.

    AsyncJob's 2-arg constructor coalesces to NullLogService, so a job built without
    a logger reports start failures, per-error stream lines, and completion
    exceptions to a no-op. Every production presenter did exactly that, which is why
    a DCU scan that died produced no log line at all - the wedge took days to triage
    because the one component that knew the failure reason couldn't say it.

    These tests fail if any production call site under src/ constructs an AsyncJob
    without passing a logger. Test code may still use the 2-arg convenience form.
#>

Describe "AsyncJob logger coverage" {

    BeforeAll {
        $script:SrcRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../src'))

        # All [AsyncJob]::new(...) invocations in a file, via AST (comment/string safe).
        function Get-AsyncJobConstructions([string]$path) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $path, [ref]$null, [ref]$null)
            return $ast.FindAll({
                    param($n)
                    ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -and
                    ($n.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) -and
                    ($n.Expression.TypeName.Name -eq 'AsyncJob') -and
                    ([string]$n.Member.SafeGetValue() -eq 'new')
                }, $true)
        }
    }

    It "every production AsyncJob is constructed with a logger (3-arg form)" {
        $files = Get-ChildItem -Path $SrcRoot -Recurse -Include '*.psm1', '*.ps1' -File
        $checked = 0
        foreach ($file in $files) {
            foreach ($ctor in (Get-AsyncJobConstructions $file.FullName)) {
                $checked++
                @($ctor.Arguments).Count | Should -Be 3 -Because (
                    "$($file.Name):$($ctor.Extent.StartLineNumber) constructs an AsyncJob " +
                    "without a logger, so if that job fails, Donut.log will never say why " +
                    "(the silent-scan-wedge regression)")
            }
        }
        # The pump presenters + resolution coordinator construct jobs; if this drops to
        # zero the search above went blind (moved class, renamed type), not clean.
        $checked | Should -BeGreaterThan 0
    }
}
