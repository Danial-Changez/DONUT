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

    Rule calibration lives in PSScriptAnalyzerSettings.psd1 at the repo root.

.PARAMETER Path
    Source root to scan. Defaults to the repo's src\ folder.

.PARAMETER FailOn
    Minimum severity that makes this script exit non-zero (for a hook / CI gate).
    One of None, Information, Warning, Error. Default None (report only).

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
'Donut\.Qr\.QrCode|Donut\.Interop\.HotkeyManager'

# One analyzer invocation for the whole list (piped: -Path only takes a single
# string) - the per-call setup cost made the old per-file loop ~9x slower.
$results = $files.FullName | Invoke-ScriptAnalyzer -Settings $settings -ErrorAction SilentlyContinue |
    Where-Object {
        -not ($_.RuleName -eq 'TypeNotFound' -and $_.Message -match $runtimeTypes)
    }

Write-Host "Scanned $($files.Count) source files -> $($results.Count) findings.`n"

if ($results) {
    $results | Group-Object RuleName | Sort-Object Count -Descending |
        Select-Object Count, Name | Format-Table -AutoSize | Out-Host

    # Layout rules (whitespace, the 100-column limit) stay in the summary count but
    # out of the listing, so the actionable findings aren't drowned out.
    Write-Host 'Findings (excluding layout rules):'
    $results | Where-Object { $_.RuleName -notin @('PSAvoidTrailingWhitespace', 'PSAvoidLongLines') } |
        Select-Object @{ n = 'File'; e = { Split-Path $_.ScriptPath -Leaf } }, Line, RuleName |
        Sort-Object File, Line | Format-Table -AutoSize | Out-Host
}

if ($FailOn -ne 'None') {
    $order = @{ Information = 1; Warning = 2; Error = 3 }
    $gate = $results | Where-Object { $order[[string]$_.Severity] -ge $order[$FailOn] }
    if ($gate) {
        Write-Host "FAIL: $($gate.Count) finding(s) at or above severity '$FailOn'." -ForegroundColor Red
        exit 1
    }
}
exit 0
