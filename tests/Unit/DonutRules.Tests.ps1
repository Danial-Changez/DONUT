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
        function Get-LayoutFinding([string]$code) {
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
        (Get-LayoutFinding $code).Count | Should -Be 0
    }

    It "flags a continuation indented instead of aligned" {
        $code = @'
$auth = Get-CimInstance -Namespace 'root\ccm' `
    -ClassName 'SMS_Authority' `
    -ErrorAction Stop
'@
        $f = Get-LayoutFinding $code
        $f.Count | Should -Be 2
        $f[0].Message | Should -BeLike '*not under the first argument*'
        $f[0].Line | Should -Be 2
    }

    It "flags three named parameters kept on one long line" {
        $code = '$records = Resolve-DnsName -Name $hostName -Server $server -Type A -ErrorAction Stop'
        $f = Get-LayoutFinding $code
        $f.Count | Should -Be 1
        $f[0].Message | Should -BeLike '*named parameters on one line*'
    }

    It "leaves a short line alone however many parameters it carries" {
        (Get-LayoutFinding 'New-Item -ItemType Directory -Path $dir -Force').Count | Should -Be 0
    }

    It "flags two named parameters sharing a line of a wrapped call" {
        $code = @'
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
              -ArgumentList $args
'@
        $f = Get-LayoutFinding $code
        $f.Count | Should -Be 1
        $f[0].Message | Should -BeLike '*more than one named parameter*'
    }

    It "lets a two-parameter call wrap without forcing one per line" {
        $code = @'
Write-Host -ForegroundColor Cyan -NoNewline `
           "DONUT probe"
'@
        (Get-LayoutFinding $code).Count | Should -Be 0
    }

    It "aligns under a positional first argument too" {
        $code = @'
$p = Join-Path (Split-Path $root -Parent) `
               'Assets\icon.ico'
'@
        (Get-LayoutFinding $code).Count | Should -Be 0
    }

    It "leaves Pester's Should alone, since its switches are assertion operators" {
        $code = '$dict | Should -Not -BeNullOrEmpty -Because "the resource dictionary must load, whatever the theme"'
        (Get-LayoutFinding $code).Count | Should -Be 0
    }

    It "flags a dropped backtick, which still parses but splits the statement" {
        $code = @'
$explorer = Get-CimInstance Win32_Process -Filter $filter
                                          -ErrorAction SilentlyContinue |
                                           Select-Object -First 1
'@
        $f = Get-LayoutFinding $code
        $f.Count | Should -Be 1
        $f[0].Line | Should -Be 2
        $f[0].Message | Should -BeLike "*'-ErrorAction' begins a statement*"
    }

    It "ignores a call whose only line break is inside a script block argument" {
        $code = @'
$job = Start-ThreadJob -ScriptBlock {
    param($x)
    $x
} -ArgumentList $a
'@
        (Get-LayoutFinding $code).Count | Should -Be 0
    }
}

Describe "DonutFunctionSize rule" {

    BeforeAll {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $script:rulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\Rules\DonutRules.psm1')).Path
        function Get-SizeFinding([string]$code) {
            return @(Invoke-ScriptAnalyzer -ScriptDefinition $code -CustomRulePath $script:rulePath |
                    Where-Object RuleName -EQ 'DonutFunctionSize')
        }
        # A body of N one-statement lines, to build functions right at a limit.
        function New-Body([int]$statements) { return (1..$statements | ForEach-Object { "    `$v$_ = $_" }) -join "`n" }
    }

    It "says nothing about a function inside every limit" {
        $code = "function Test-Small {`n$(New-Body 100)`n}"
        (Get-SizeFinding $code).Count | Should -Be 0
    }

    It "reports a function over the statement limit, at Information severity, once" {
        $code = "function Test-Big {`n$(New-Body 101)`n}"
        $f = Get-SizeFinding $code
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Information'
        $f[0].Message | Should -BeLike "'Test-Big' has outgrown one function: statements 101 (limit 100)*"
    }

    It "names a class method by its class and reports it once, not per wrapper node" {
        $code = "class Widget {`n    [void] Grow() {`n$(New-Body 101)`n    }`n}"
        $f = Get-SizeFinding $code
        $f.Count | Should -Be 1
        $f[0].Message | Should -BeLike "'Widget.Grow' has outgrown*"
    }

    It "counts branches across if, elseif, else, switch, loops and catch" {
        # 7 ifs x (if + elseif + else) = 21 branches on a body that is short otherwise.
        $ifs = (1..7 | ForEach-Object { "    if (`$a -eq $_) { 1 } elseif (`$a -eq -$_) { 2 } else { 3 }" }) -join "`n"
        $f = Get-SizeFinding "function Test-Branchy(`$a) {`n$ifs`n}"
        $f.Count | Should -Be 1
        $f[0].Message | Should -BeLike "*branches 21 (limit 20)*"
    }

    It "reports nesting deeper than five blocks, and not five" {
        $five = @'
function Test-Five($a) {
    if ($a) {
        foreach ($b in $a) {
            if ($b) {
                while ($b) {
                    if ($b -gt 1) { $b-- }
                }
            }
        }
    }
}
'@
        (Get-SizeFinding $five).Count | Should -Be 0

        $six = @'
function Test-Six($a) {
    if ($a) {
        foreach ($b in $a) {
            if ($b) {
                while ($b) {
                    try { $b-- } catch { if ($b) { $b = 0 } }
                }
            }
        }
    }
}
'@
        $f = Get-SizeFinding $six
        $f.Count | Should -Be 1
        $f[0].Message | Should -BeLike "*nesting depth 6 (limit 5)*"
    }
}
