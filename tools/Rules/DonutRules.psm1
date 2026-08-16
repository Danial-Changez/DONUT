<#
.SYNOPSIS
    DONUT's own PSScriptAnalyzer rules, loaded by tools\Invoke-Lint.ps1 via -CustomRulePath.

.DESCRIPTION
    Encodes two conventions from docs/development/coding-style.md that no stock rule
    can express.

    DonutParameterLayout: a call with more than two named parameters goes one parameter
    per line, each continuation aligned under the first parameter.

      $auth = Get-CimInstance -Namespace 'root\ccm' `
                              -ClassName 'SMS_Authority' `
                              -ErrorAction Stop

    PSUseConsistentIndentation is off in the repo settings because it has no alignment
    mode, so this rule is what keeps continuation lines honest.

    DonutFunctionSize: a function or method that outgrows clang-tidy's readability
    limits (150 lines, 100 statements) or a branch and nesting cap (20 branches, depth 5)
    is reported at Information severity. That never gates, so the known hotspots stay a
    visible number rather than a blocked build, and the list cannot grow unnoticed.

.NOTES
    PSScriptAnalyzer calls each rule once per node of its parameter type, so nothing is
    double reported: every command for the layout rule, every function definition (class
    methods included, they carry one too) for the size rule.
    Report only: the formatter applies stock rules alone, so a hit is fixed by hand.
#>

using namespace System.Management.Automation.Language

# Named parameters on a single line above this width belong one per line.
$script:ShortLineLimit = 80

# clang-tidy's readability-function-size limits, plus a branch and nesting cap.
$script:MaxFunctionLines = 150
$script:MaxFunctionStatements = 100
$script:MaxFunctionBranches = 20
$script:MaxNestingDepth = 5

function New-RuleRecord {
    param(
        [string]$message,
        [IScriptExtent]$extent,
        [string]$ruleName,
        [string]$severity
    )
    return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
        Message  = $message
        Extent   = $extent
        RuleName = $ruleName
        Severity = $severity
    }
}

function New-LayoutRecord([string]$message, [IScriptExtent]$extent) {
    return New-RuleRecord -message $message `
                          -extent $extent `
                          -ruleName 'DonutParameterLayout' `
                          -severity 'Warning'
}

function Measure-DonutParameterLayout {
    <#
    .SYNOPSIS
        One named parameter per line once a call carries more than two, aligned under the first.
    .DESCRIPTION
        A single-line call over 80 columns with three or more named parameters is reported,
        as is any wrapped call whose continuation lines do not sit under the first argument
        or that puts two named parameters on one line.
    .PARAMETER CommandAst
        The call under inspection, supplied by PSScriptAnalyzer once per command.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [CommandAst] $CommandAst
    )
    process {
        $elements = @($CommandAst.CommandElements)
        if ($elements.Count -lt 2) { return }
        $named = @($elements | Where-Object { $_ -is [CommandParameterAst] })
        $extent = $CommandAst.Extent

        if ($extent.StartLineNumber -eq $extent.EndLineNumber) {
            # A short line stays as it is, whatever it carries.
            $lineText = [string]$extent.StartScriptPosition.Line
            if ($named.Count -gt 2 -and $lineText.TrimEnd().Length -gt $script:ShortLineLimit) {
                New-LayoutRecord ("'$($elements[0].Extent.Text)' carries $($named.Count) named parameters " +
                    'on one line: put each on its own line, aligned under the first.') $extent
            }
            return
        }

        # Multi-line: every element that opens a line sits under the first argument.
        $anchor = $elements[1].Extent.StartColumnNumber
        $perLine = @{}
        foreach ($p in $named) { $perLine[$p.Extent.StartLineNumber] = 1 + [int]$perLine[$p.Extent.StartLineNumber] }
        for ($i = 2; $i -lt $elements.Count; $i++) {
            $cur = $elements[$i]
            if ($cur.Extent.StartLineNumber -le $elements[$i - 1].Extent.EndLineNumber) { continue }
            if ($cur.Extent.StartColumnNumber -ne $anchor) {
                New-LayoutRecord ("Continuation of '$($elements[0].Extent.Text)' starts at column " +
                    "$($cur.Extent.StartColumnNumber), not under the first argument (column $anchor).") $cur.Extent
            }
        }
        # And past two named parameters, no line of the wrapped call holds two of them.
        if ($named.Count -le 2) { return }
        foreach ($p in $named) {
            if ($perLine[$p.Extent.StartLineNumber] -gt 1) {
                New-LayoutRecord ("Line $($p.Extent.StartLineNumber) of a wrapped '$($elements[0].Extent.Text)' " +
                    'holds more than one named parameter: one per line.') $p.Extent
                $perLine[$p.Extent.StartLineNumber] = 0
            }
        }
    }
}

function Measure-DonutFunctionSize {
    <#
    .SYNOPSIS
        A function past clang-tidy's size limits, or too branchy or deep, reported not gated.
    .DESCRIPTION
        Lines, block-level statements, branches (if/elseif/else, switch cases, loops, catch)
        and nesting depth are measured on the body; any over its limit joins one
        Information-severity record naming the function.
    .PARAMETER FunctionDefinitionAst
        The definition under inspection, supplied by PSScriptAnalyzer once per function,
        class methods included.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [FunctionDefinitionAst] $FunctionDefinitionAst
    )
    process {
        $body = $FunctionDefinitionAst.Body
        if ($null -eq $body) { return }
        $extent = $FunctionDefinitionAst.Extent
        $name = $FunctionDefinitionAst.Name
        # A class method's definition sits under its member node, which sits under the class.
        if ($FunctionDefinitionAst.Parent -is [FunctionMemberAst]) {
            $name = "$($FunctionDefinitionAst.Parent.Parent.Name).$name"
        }

        $lines = $extent.EndLineNumber - $extent.StartLineNumber + 1
        # Only what a block holds: an assignment's right side is a pipeline node of its own.
        $statements = @($body.FindAll({ param($n)
                    $n -is [StatementAst] -and
                    -not ($n -is [FunctionDefinitionAst]) -and
                    ($n.Parent -is [StatementBlockAst] -or $n.Parent -is [NamedBlockAst]) }, $true)).Count

        # Branches: every if/elseif/else, switch case and default, loop, and catch.
        $branches = 0
        foreach ($i in $body.FindAll({ param($n) $n -is [IfStatementAst] }, $true)) {
            $branches += @($i.Clauses).Count
            if ($i.ElseClause) { $branches++ }
        }
        foreach ($s in $body.FindAll({ param($n) $n -is [SwitchStatementAst] }, $true)) {
            $branches += @($s.Clauses).Count
            if ($s.Default) { $branches++ }
        }
        $branches += @($body.FindAll({ param($n) $n -is [LoopStatementAst] }, $true)).Count
        $branches += @($body.FindAll({ param($n) $n -is [CatchClauseAst] }, $true)).Count

        # Depth: levels of statement blocks below the body, the block itself included.
        $depth = 0
        foreach ($block in $body.FindAll({ param($n) $n -is [StatementBlockAst] }, $true)) {
            $d = 1
            $p = $block.Parent
            while ($null -ne $p -and $p -ne $body) {
                if ($p -is [StatementBlockAst]) { $d++ }
                $p = $p.Parent
            }
            if ($d -gt $depth) { $depth = $d }
        }

        $checks = @(
            @{ Unit = 'lines'; Value = $lines; Max = $script:MaxFunctionLines }
            @{ Unit = 'statements'; Value = $statements; Max = $script:MaxFunctionStatements }
            @{ Unit = 'branches'; Value = $branches; Max = $script:MaxFunctionBranches }
            @{ Unit = 'nesting depth'; Value = $depth; Max = $script:MaxNestingDepth }
        )
        $over = @($checks | Where-Object { $_.Value -gt $_.Max } |
                ForEach-Object { "$($_.Unit) $($_.Value) (limit $($_.Max))" })
        if ($over.Count -eq 0) { return }
        New-RuleRecord -message ("'$name' has outgrown one function: $($over -join ', '). " +
                                 'Split it when this file is next touched.') `
                       -extent $extent `
                       -ruleName 'DonutFunctionSize' `
                       -severity 'Information'
    }
}

Export-ModuleMember -Function Measure-DonutParameterLayout, Measure-DonutFunctionSize
