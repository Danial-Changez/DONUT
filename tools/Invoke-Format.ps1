<#
.SYNOPSIS
    Auto-format DONUT's PowerShell source with the repo formatting rules.

.DESCRIPTION
    The repo's "clang-format": runs Invoke-Formatter with the Rules section of
    PSScriptAnalyzerSettings.psd1 (brace placement, consistent whitespace, cmdlet
    casing, hashtable alignment) over every PowerShell file, then strips trailing
    whitespace from every line outside a here-string (the formatter leaves it, and
    a fixture's trailing spaces may be the point) and guarantees a trailing newline
    at end of file (Zephyr's InsertNewlineAtEndOfFile; no PSSA rule covers it).
    Indentation is not touched: the analyzer's rule is off so parameter continuations
    can align under the first parameter (tools\Rules\DonutRules.psm1 checks that
    shape in the lint instead).

    Formatting only moves whitespace and fixes cmdlet-name casing - it never changes
    tokens, so string/here-string content (e.g. the remote probe-script templates) is
    untouched. Files with a UTF-8 BOM keep it; files without one stay BOM-free.

.PARAMETER Path
    Roots to format. Defaults to the repo's src\, tests\ and tools\ folders; build
    output under bin\/obj\ and tool caches are always skipped.

.PARAMETER Check
    Report files that need formatting and exit 1 instead of rewriting them
    (the CI / pre-commit gate). Default is to fix in place.

.EXAMPLE
    pwsh -File tools\Invoke-Format.ps1              # fix src\, tests\ and tools\ in place
.EXAMPLE
    pwsh -File tools\Invoke-Format.ps1 -Check       # gate: exit 1 if anything is unformatted
.EXAMPLE
    pwsh -File tools\Invoke-Format.ps1 -Path .\tools
#>
[CmdletBinding()]
param(
    [string[]] $Path = @(
        (Join-Path $PSScriptRoot '..\src'),
        (Join-Path $PSScriptRoot '..\tests'),
        $PSScriptRoot
    ),
    [switch] $Check
)

Import-Module PSScriptAnalyzer -ErrorAction Stop
$settings = Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1'

$files = Get-ChildItem -Path $Path -Recurse -Include *.ps1, *.psm1 -File |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|\.cache)\\' }

# Trailing whitespace goes, except inside a here-string, whose content is not ours to edit.
function Remove-TrailingWhitespace([string]$text) {
    $tokens = $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    $protected = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($t in $tokens) {
        if ($t.Kind -notin 'HereStringLiteral', 'HereStringExpandable') { continue }
        for ($l = $t.Extent.StartLineNumber; $l -le $t.Extent.EndLineNumber; $l++) { [void]$protected.Add($l) }
    }
    $lines = $text -split "(?<=`n)"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($protected.Contains($i + 1)) { continue }
        $lines[$i] = $lines[$i] -replace '[ \t]+(?=\r?\n$|$)', ''
    }
    return ($lines -join '')
}

$needWork = [System.Collections.Generic.List[string]]::new()

foreach ($file in $files) {
    $original = [System.IO.File]::ReadAllText($file.FullName)

    $formatted = Invoke-Formatter -ScriptDefinition $original -Settings $settings
    $formatted = Remove-TrailingWhitespace $formatted
    if (-not $formatted.EndsWith("`n")) { $formatted += "`r`n" }

    if ($formatted -ceq $original) { continue }
    $needWork.Add($file.FullName)

    if (-not $Check) {
        # ReadAllText strips the BOM, so re-detect it from the raw bytes to preserve it.
        $hasBom = $false
        $head = [System.IO.File]::ReadAllBytes($file.FullName)
        if ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
            $hasBom = $true
        }
        $encoding = [System.Text.UTF8Encoding]::new($hasBom)
        [System.IO.File]::WriteAllText($file.FullName, $formatted, $encoding)
    }
}

if ($needWork.Count -eq 0) {
    Write-Host "All $($files.Count) source files are formatted."
    exit 0
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$verb = if ($Check) { 'need formatting' } else { 'reformatted' }
Write-Host "$($needWork.Count) of $($files.Count) file(s) ${verb}:"
foreach ($f in $needWork) { Write-Host "  $($f.Substring($root.Length).TrimStart('\'))" }

if ($Check) { exit 1 }
exit 0
