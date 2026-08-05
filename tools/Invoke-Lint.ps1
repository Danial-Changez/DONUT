<#
.SYNOPSIS
    Run PSScriptAnalyzer over DONUT's source with the repo settings, cleanly.

.DESCRIPTION
    Encodes the two corrections a bare `Invoke-ScriptAnalyzer -Path .\src -Recurse`
    needs:
      1. Build output under src\Launcher\bin (bundled PowerShell runtime modules) is
         excluded - those aren't our code.
      2. TypeNotFound is a parser diagnostic that ExcludeRules can't suppress; the only
         hits are the runtime-compiled C# types (ObservableObject / RelayCommand /
         WindowChromeHelper / Donut.Qr.QrCode / Donut.Interop.HotkeyManager), so
         they're filtered here by name.

    Also sweeps the C# sources, which PSScriptAnalyzer cannot see at all, for the
    comment-length rule in docs/development/coding-style.md.

    Rule calibration lives in PSScriptAnalyzerSettings.psd1 at the repo root.

.PARAMETER Path
    Source root to scan. Defaults to the repo's src\ folder.

.PARAMETER FailOn
    Minimum severity that makes this script exit non-zero (for a hook / CI gate).
    One of None, Information, Warning, Error. Default None (report only).

.NOTES
    The gate skips what the listing skips. Layout rules are accepted style debt,
    and the remaining TypeNotFound hits are cross-module class references the
    analyzer cannot resolve because it parses each file without its `using module`
    graph. Both stay visible in the summary, and neither is a defect.

.EXAMPLE
    pwsh -File tools\Invoke-Lint.ps1
.EXAMPLE
    pwsh -File tools\Invoke-Lint.ps1 -FailOn Warning
#>
[CmdletBinding()]
param(
    [string] $Path = (Join-Path $PSScriptRoot '..\src'),
    [ValidateSet('None', 'Information', 'Warning', 'Error')]
    [string] $FailOn = 'None'
)

Import-Module PSScriptAnalyzer -ErrorAction Stop
$settings = Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1'

$files = Get-ChildItem -Path $Path -Recurse -Include *.ps1, *.psm1 -File |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }

# Runtime-compiled C# types the static analyzer can't resolve (see .DESCRIPTION).
$runtimeTypes = 'ObservableObject|RelayCommand|WindowChromeHelper|' +
'Donut\.Qr\.QrCode|Donut\.Interop\.HotkeyManager|Donut\.Interop\.TrayTheme'

# Piped because -Path takes one string, and the per-file loop was about 9x slower.
$results = $files.FullName | Invoke-ScriptAnalyzer -Settings $settings -ErrorAction SilentlyContinue |
    Where-Object {
        -not ($_.RuleName -eq 'TypeNotFound' -and $_.Message -match $runtimeTypes)
    }

Write-Host "Scanned $($files.Count) source files -> $($results.Count) findings.`n"

if ($results) {
    $results | Group-Object RuleName | Sort-Object Count -Descending |
        Select-Object Count, Name | Format-Table -AutoSize | Out-Host

    # Layout rules stay in the count but out of the listing, so real findings show.
    Write-Host 'Findings (excluding layout rules):'
    $results | Where-Object { $_.RuleName -notin @('PSAvoidTrailingWhitespace', 'PSAvoidLongLines') } |
        Select-Object @{ n = 'File'; e = { Split-Path $_.ScriptPath -Leaf } }, Line, RuleName |
        Sort-Object File, Line | Format-Table -AutoSize | Out-Host
}

# --- Comment length ---
# Finds comment blocks over coding-style.md's line limit. PSScriptAnalyzer has no
# such rule and cannot parse C# at all, so both languages are swept here.
function Get-LongComment {
    param(
        [System.IO.FileInfo[]] $Files,
        [string] $Marker,      # comment prefix regex, e.g. '//(?!/)' or '#'
        [string] $ExemptNext,  # a two-line block is allowed above a line matching this
        [switch] $PowerShell   # skip <# #> help blocks and here-strings
    )
    foreach ($file in $Files) {
        $lines = @(Get-Content $file.FullName)
        $run = 0; $inHelp = $false; $inHere = $false
        for ($i = 0; $i -le $lines.Count; $i++) {
            $line = if ($i -lt $lines.Count) { $lines[$i] } else { '' }
            if ($PowerShell) {
                # Help blocks carry the long rationale by design, and a here-string
                # is shipped payload rather than commentary.
                if ($inHere) {
                    if ($line -match "^\s*('@|""@)") { $inHere = $false }
                    $run = 0; continue
                }
                if ($inHelp) {
                    if ($line -match '#>') { $inHelp = $false }
                    $run = 0; continue
                }
                if ($line -match "@'|@""") { $inHere = $true; $run = 0; continue }
                if ($line -match '^\s*<#') {
                    if ($line -notmatch '#>') { $inHelp = $true }
                    $run = 0; continue
                }
            }
            $isComment = $line -match "^\s*$Marker" -and
            $line -notmatch '^\s*#(requires|region|endregion)' -and
            $line -notmatch '^\s*(#|//)\s*-{3,}'
            if ($i -lt $lines.Count -and $isComment) { $run++; continue }
            if ($run -ge 2) {
                $next = $line
                $exempt = ($i - $run) -eq 0 -or $next -match $ExemptNext
                # A dashed list may run long when it replaces denser prose.
                $bullets = @($lines[($i - $run)..($i - 1)] -match "^\s*$Marker\s+-\s").Count
                $limit = if ($bullets -ge 2) { $run } elseif ($exempt) { 2 } else { 1 }
                if ($run -gt $limit) {
                    [pscustomobject]@{
                        File  = $file.Name
                        Line  = $i - $run + 1
                        Lines = $run
                        Max   = $limit
                    }
                }
            }
            $run = 0
        }
    }
}

# Swept repo-wide rather than over -Path, because the rule is not src-only. The
# docs site's own sources count too, since they share the // comment style.
$repo = Split-Path $PSScriptRoot -Parent
$excluded = '\\(bin|obj|\.cache|node_modules|dist|\.astro|\.diag)\\'
$sweep = Get-ChildItem -Path $repo -Recurse -File `
    -Include *.ps1, *.psm1, *.cs, *.mjs, *.js, *.ts, *.astro |
    Where-Object { $_.FullName -notmatch $excluded }
$slashFiles = @($sweep | Where-Object { $_.Extension -ne '.ps1' -and $_.Extension -ne '.psm1' })
$psFiles = @($sweep | Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' })
$slashExempt = '^\s*(namespace|#nullable|export|import|const|function|class)|' +
'^\s*((public|internal|sealed|static|abstract|partial)\s+)*(class|record|struct|interface|enum)\s'
# A PowerShell method is a return type then a name, and a constructor is bare. The
# type class allows nested brackets so an array return like [string[]] still matches.
$psExempt = '^\s*(class|enum|function)\s|' +
'^\s*(hidden\s+)?(static\s+)?(\[[\w\.\[\]]+\]\s*)?[\w-]+\s*\('
$longComments = @(
    Get-LongComment -Files $slashFiles -Marker '//(?!/)' -ExemptNext $slashExempt
    Get-LongComment -Files $psFiles -Marker '#' -ExemptNext $psExempt -PowerShell
)
if ($longComments) {
    Write-Host "Comments over the line limit ($($longComments.Count)):"
    $longComments | Sort-Object File, Line | Format-Table -AutoSize | Out-Host
}
else {
    Write-Host ("Comment length clean across {0} PowerShell and {1} C#/JS files.`n" -f
        $psFiles.Count, $slashFiles.Count)
}

if ($FailOn -ne 'None') {
    $order = @{ Information = 1; Warning = 2; Error = 3 }
    # The gate skips what the listing skips, plus TypeNotFound. See .NOTES.
    $nonGating = @('PSAvoidTrailingWhitespace', 'PSAvoidLongLines', 'TypeNotFound')
    $gate = $results | Where-Object {
        $order[[string]$_.Severity] -ge $order[$FailOn] -and $_.RuleName -notin $nonGating
    }
    # The comment sweep gates unconditionally, since it starts clean.
    if ($gate -or $longComments) {
        $n = @($gate).Count + @($longComments).Count
        Write-Host "FAIL: $n finding(s) at or above severity '$FailOn'." -ForegroundColor Red
        exit 1
    }
}
exit 0
