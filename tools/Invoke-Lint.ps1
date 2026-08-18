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
    repo's own rules (tools\Rules\DonutRules.psm1) run beside the stock set: the layout
    rule (one named parameter per line past two, continuations aligned under the first)
    gates as a Warning, and the function-size rule (clang-tidy's 150 lines / 100
    statements, plus 20 branches and nesting 5) reports at Information, so the known
    hotspots print on every run without blocking it.

.PARAMETER Path
    Roots to scan. Defaults to the repo's src\, tests\ and tools\ folders.

.PARAMETER FailOn
    Minimum severity that makes this script exit non-zero (for a hook / CI gate).
    One of None, Information, Warning, Error. Default None (report only).

.NOTES
    Everything at or above -FailOn gates, and every rule starts clean: PSAvoidLongLines
    (120, PSScriptAnalyzer's own default), PSAvoidTrailingWhitespace (Invoke-Format
    strips it), and TypeNotFound, which gates only when the UI assemblies loaded,
    since off Windows the parser cannot resolve WPF types at all.

    PSUseCmdletCorrectly is reported but never gates: it flaps between runs on
    valid positional calls (e.g. Split-Path -Parent $x) when the analyzer session
    fails to resolve the cmdlet's metadata, so a hit proves nothing by itself.

    The scan stays serial, and the piped form above is the fast one. ForEach-Object
    -Parallel cannot host the analyzer at all (it writes from the wrong thread and
    returns nothing), and splitting the files across child processes does run, but
    each session resolves cmdlet metadata independently: measured over 200 files it
    returned 156, 91 and 70 findings on three runs of identical input, and corrupted
    an internal collection on a fourth. That is the session-dependence above, once per
    process instead of once per run. A gate that answers differently each time is
    worse than a slow one, so the wall-clock win was not taken.

.EXAMPLE
    pwsh -File tools\Invoke-Lint.ps1
.EXAMPLE
    pwsh -File tools\Invoke-Lint.ps1 -FailOn Warning
#>
[CmdletBinding()]
param(
    [string[]] $Path = @(
        (Join-Path $PSScriptRoot '..\src'),
        (Join-Path $PSScriptRoot '..\tests'),
        $PSScriptRoot
    ),
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
    Where-Object { $_.FullName -notmatch '\\(bin|obj|\.cache)\\' }

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

    Write-Host 'Findings:'
    $results | Where-Object { $_.RuleName -ne 'DonutFunctionSize' } |
        Select-Object @{ n = 'File'; e = { Split-Path $_.ScriptPath -Leaf } }, Line, RuleName |
        Sort-Object File, Line | Format-Table -AutoSize | Out-Host

    # Report only, so the message (which function, by how much) is the useful part.
    $sizes = @($results | Where-Object { $_.RuleName -eq 'DonutFunctionSize' } | Sort-Object ScriptPath, Line)
    if ($sizes) {
        Write-Host "Functions past the size limits ($($sizes.Count), report only):"
        foreach ($s in $sizes) {
            Write-Host ("  {0}:{1}  {2}" -f (Split-Path $s.ScriptPath -Leaf), $s.Line, $s.Message)
        }
        Write-Host ''
    }
}

# --- Comment length ---
# One scanner (CommentRules.ps1) serves this sweep and the per-edit style hook.
. (Join-Path $PSScriptRoot 'CommentRules.ps1')
# Swept repo-wide rather than over -Path, because the rule is not src-only.
$repo = Split-Path $PSScriptRoot -Parent
$excluded = '\\(bin|obj|\.cache|node_modules|dist|\.astro|\.diag)\\'
$sweep = Get-ChildItem -Path $repo `
                       -Recurse `
                       -File `
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
    # Only the flaky rule sits out, and TypeNotFound where the parser cannot see WPF. See .NOTES.
    $nonGating = @('PSUseCmdletCorrectly')
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
