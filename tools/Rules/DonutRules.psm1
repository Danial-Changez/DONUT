<#
.SYNOPSIS
    DONUT's own PSScriptAnalyzer rules, loaded by tools\Invoke-Lint.ps1 via -CustomRulePath.

.DESCRIPTION
    Encodes the layout convention in docs/development/coding-style.md that no stock rule
    can express: a call with more than two named parameters goes one parameter per line,
    each continuation aligned under the first parameter.

      $auth = Get-CimInstance -Namespace 'root\ccm' `
                              -ClassName 'SMS_Authority' `
                              -ErrorAction Stop

    PSUseConsistentIndentation is off in the repo settings because it has no alignment
    mode, so this rule is what keeps continuation lines honest.

.NOTES
    PSScriptAnalyzer calls Measure-DonutParameterLayout once per CommandAst, so a nested
    script block's commands are visited on their own and nothing is double reported.
    Report only: the formatter applies stock rules alone, so a hit is fixed by hand.
#>

# Named parameters on a single line above this width belong one per line.
$script:ShortLineLimit = 80

function New-LayoutRecord([string]$message, [System.Management.Automation.Language.IScriptExtent]$extent) {
    return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
        Message  = $message
        Extent   = $extent
        RuleName = 'DonutParameterLayout'
        Severity = 'Warning'
    }
}

# One named parameter per line once a call carries more than two, aligned under the first.
function Measure-DonutParameterLayout {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Management.Automation.Language.CommandAst] $CommandAst
    )
    process {
        $elements = @($CommandAst.CommandElements)
        if ($elements.Count -lt 2) { return }
        $named = @($elements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
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

Export-ModuleMember -Function Measure-DonutParameterLayout
