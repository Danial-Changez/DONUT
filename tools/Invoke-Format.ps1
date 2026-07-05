<#
.SYNOPSIS
    Auto-format DONUT's PowerShell source with the repo formatting rules.

.DESCRIPTION
    The repo's "clang-format": runs Invoke-Formatter with the Rules section of
    PSScriptAnalyzerSettings.psd1 (brace placement, 4-space indentation, consistent
    whitespace, cmdlet casing, hashtable alignment) over every source file, and
    guarantees a trailing newline at end of file (Zephyr's InsertNewlineAtEndOfFile;
    no PSSA rule covers it).

    Formatting only moves whitespace and fixes cmdlet-name casing - it never changes
    tokens, so string/here-string content (e.g. the remote probe-script templates) is
    untouched. Files with a UTF-8 BOM keep it; files without one stay BOM-free.

.PARAMETER Path
    Source root to format. Defaults to the repo's src\ folder; build output under
    bin\/obj\ is always skipped.

.PARAMETER Check
    Report files that need formatting and exit 1 instead of rewriting them
    (the CI / pre-commit gate). Default is to fix in place.

.EXAMPLE
    pwsh -File tools\Invoke-Format.ps1              # fix src\ in place
.EXAMPLE
    pwsh -File tools\Invoke-Format.ps1 -Check       # gate: exit 1 if anything is unformatted
.EXAMPLE
    pwsh -File tools\Invoke-Format.ps1 -Path .\tools
#>
[CmdletBinding()]
param(
    [string] $Path = (Join-Path $PSScriptRoot '..\src'),
    [switch] $Check
)

Import-Module PSScriptAnalyzer -ErrorAction Stop
$settings = Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1'

$files = Get-ChildItem -Path $Path -Recurse -Include *.ps1, *.psm1 -File |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }

$needWork = [System.Collections.Generic.List[string]]::new()

foreach ($file in $files) {
    $original = [System.IO.File]::ReadAllText($file.FullName)

    $formatted = Invoke-Formatter -ScriptDefinition $original -Settings $settings
    if (-not $formatted.EndsWith("`n")) { $formatted += "`r`n" }

    if ($formatted -ceq $original) { continue }
    $needWork.Add($file.FullName)

    if (-not $Check) {
        # Preserve the file's BOM state: ReadAllText strips a BOM, so re-detect it
        # from the raw bytes and write with a matching encoding.
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
