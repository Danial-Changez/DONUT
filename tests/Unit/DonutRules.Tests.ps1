<#
    The custom PSScriptAnalyzer rule that keeps multi-parameter calls one per line and
    aligned (docs/development/coding-style.md). Each case is a snippet run through the
    real analyzer with only the custom rule path, so the assertions are on what lint
    would actually report.
#>
Describe "DonutParameterLayout rule" {

    BeforeAll {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        # The module file, not its folder: the analyzer's folder discovery finds nothing.
        $script:rulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\Rules\DonutRules.psm1')).Path
        function Get-LayoutFindings([string]$code) {
            return @(Invoke-ScriptAnalyzer -ScriptDefinition $code -CustomRulePath $script:rulePath |
                    Where-Object RuleName -EQ 'DonutParameterLayout')
        }
    }

    It "accepts one parameter per line aligned under the first" {
        $code = @'
$auth = Get-CimInstance -Namespace 'root\ccm' `
                        -ClassName 'SMS_Authority' `
                        -ErrorAction Stop
'@
        (Get-LayoutFindings $code).Count | Should -Be 0
    }

    It "flags a continuation indented instead of aligned" {
        $code = @'
$auth = Get-CimInstance -Namespace 'root\ccm' `
    -ClassName 'SMS_Authority' `
    -ErrorAction Stop
'@
        $f = Get-LayoutFindings $code
        $f.Count | Should -Be 2
        $f[0].Message | Should -BeLike '*not under the first argument*'
        $f[0].Line | Should -Be 2
    }

    It "flags three named parameters kept on one long line" {
        $code = "`$records = Resolve-DnsName -Name `$hostName -Server `$server -Type A -ErrorAction Stop -DnsOnly -NoHostsFile"
        $f = Get-LayoutFindings $code
        $f.Count | Should -Be 1
        $f[0].Message | Should -BeLike '*named parameters on one line*'
    }

    It "leaves a short line alone however many parameters it carries" {
        (Get-LayoutFindings 'New-Item -ItemType Directory -Path $dir -Force').Count | Should -Be 0
    }

    It "flags two named parameters sharing a line of a wrapped call" {
        $code = @'
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
              -ArgumentList $args
'@
        $f = Get-LayoutFindings $code
        $f.Count | Should -Be 1
        $f[0].Message | Should -BeLike '*more than one named parameter*'
    }

    It "lets a two-parameter call wrap without forcing one per line" {
        $code = @'
Write-Host -ForegroundColor Cyan -NoNewline `
           "DONUT probe"
'@
        (Get-LayoutFindings $code).Count | Should -Be 0
    }

    It "aligns under a positional first argument too" {
        $code = @'
$p = Join-Path (Split-Path $root -Parent) `
               'Assets\icon.ico'
'@
        (Get-LayoutFindings $code).Count | Should -Be 0
    }

    It "ignores a call whose only line break is inside a script block argument" {
        $code = @'
$job = Start-ThreadJob -ScriptBlock {
    param($x)
    $x
} -ArgumentList $a
'@
        (Get-LayoutFindings $code).Count | Should -Be 0
    }
}
