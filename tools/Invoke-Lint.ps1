<#
.SYNOPSIS
    Run PSScriptAnalyzer over DONUT's source with the repo settings, cleanly.

.DESCRIPTION
    Encodes the three corrections a bare `Invoke-ScriptAnalyzer -Path .\src -Recurse`
    needs:
      1. Build output under src\Launcher\bin (bundled PowerShell runtime modules) is
         excluded - those aren't our code.
      2. TypeNotFound is a parser diagnostic, not a rule: the parser resolves type
         literals against the assemblies loaded in THIS session, so the WPF/WinForms
         assemblies are loaded first (as Start-Donut does) and every [DispatcherTimer],
         [Brush], [Key]... then resolves. ExcludeRules cannot suppress it.
      3. The hits left after that are the runtime-compiled C# types (ObservableObject /
         RelayCommand / WindowChromeHelper / Donut.Qr.QrCode / Donut.Interop.*), which
         no static session can know, so they're filtered here by name.

    Also sweeps the C# sources, which PSScriptAnalyzer cannot see at all, for the
    comment-length rule in docs/development/coding-style.md.

    Rule calibration lives in PSScriptAnalyzerSettings.psd1 at the repo root, and the
    repo's own rules (tools\Rules\DonutRules.psm1: one named parameter per line past two,
    continuations aligned under the first) run beside the stock set.

.PARAMETER Path
    Source root to scan. Defaults to the repo's src\ folder.

.PARAMETER FailOn
    Minimum severity that makes this script exit non-zero (for a hook / CI gate).
    One of None, Information, Warning, Error. Default None (report only).

.NOTES
    The gate skips what the listing skips: trailing whitespace is accepted style
    debt. PSAvoidLongLines (120, PSScriptAnalyzer's own default) and TypeNotFound
    both start clean and gate. TypeNotFound gates only when the UI assemblies
    loaded, since off Windows the parser cannot resolve WPF types at all.

    PSUseCmdletCorrectly is reported but never gates: it flaps between runs on
    valid positional calls (e.g. Split-Path -Parent $x) when the analyzer session
    fails to resolve the cmdlet's metadata, so a hit proves nothing by itself.

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

# The parser resolves type literals against this session, so load what the app loads.
$uiLoaded = $true
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase,
    System.Windows.Forms, System.Xaml -ErrorAction Stop
} catch {
    $uiLoaded = $false
    Write-Warning "UI assemblies did not load ($($_.Exception.Message)); TypeNotFound will not gate."
}

$files = Get-ChildItem -Path $Path -Recurse -Include *.ps1, *.psm1 -File |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }

# Runtime-compiled C# types no static session can resolve (see .DESCRIPTION).
$runtimeTypes = 'ObservableObject|RelayCommand|WindowChromeHelper|' +
'Donut\.Qr\.QrCode|Donut\.Interop\.HotkeyManager|Donut\.Interop\.TrayTheme|' +
'Donut\.Interop\.LensWarmTriggers'

# The repo's own rules, by module file: the analyzer's folder discovery finds nothing.
$customRules = Join-Path $PSScriptRoot 'Rules\DonutRules.psm1'

# Piped because -Path takes one string, and the per-file loop was about 9x slower.
$results = $files.FullName |
    Invoke-ScriptAnalyzer -Settings $settings `
                          -CustomRulePath $customRules `
                          -IncludeDefaultRules `
                          -ErrorAction SilentlyContinue |
    Where-Object {
        -not ($_.RuleName -eq 'TypeNotFound' -and $_.Message -match $runtimeTypes)
    }

Write-Host "Scanned $($files.Count) source files -> $($results.Count) findings.`n"

if ($results) {
    $results | Group-Object RuleName | Sort-Object Count -Descending |
        Select-Object Count, Name | Format-Table -AutoSize | Out-Host

    # Trailing whitespace stays in the count but out of the listing, so real findings show.
    Write-Host 'Findings (excluding layout rules):'
    $results | Where-Object { $_.RuleName -ne 'PSAvoidTrailingWhitespace' } |
        Select-Object @{ n = 'File'; e = { Split-Path $_.ScriptPath -Leaf } }, Line, RuleName |
        Sort-Object File, Line | Format-Table -AutoSize | Out-Host
}

# --- Comment length ---
# One scanner (CommentRules.ps1) serves this sweep and the per-edit style hook.
. (Join-Path $PSScriptRoot 'CommentRules.ps1')
# Swept repo-wide rather than over -Path, because the rule is not src-only.
$repo = Split-Path $PSScriptRoot -Parent
$excluded = '\\(bin|obj|\.cache|node_modules|dist|\.astro|\.diag)\\'
$sweep = Get-ChildItem -Path $repo -Recurse -File `
    -Include *.ps1, *.psm1, *.cs, *.mjs, *.js, *.ts, *.astro, *.xaml |
    Where-Object { $_.FullName -notmatch $excluded }
$longComments = @(Get-CommentFinding -Files $sweep)
if ($longComments) {
    Write-Host "Comments over the line limit ($($longComments.Count)):"
    $longComments | Sort-Object File, Line | Format-Table -AutoSize | Out-Host
} else {
    Write-Host "Comment length clean across $($sweep.Count) source files.`n"
}

if ($FailOn -ne 'None') {
    $order = @{ Information = 1; Warning = 2; Error = 3 }
    # The gate skips what the listing skips, plus the flaky rule. See .NOTES.
    $nonGating = @('PSAvoidTrailingWhitespace', 'PSUseCmdletCorrectly')
    if (-not $uiLoaded) { $nonGating += 'TypeNotFound' }
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
