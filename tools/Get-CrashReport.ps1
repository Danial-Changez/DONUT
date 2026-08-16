#Requires -Version 5.1
<#
.SYNOPSIS
    Gathers the evidence an app crash leaves behind, for pasting into a report.

.DESCRIPTION
    Run on the box where DONUT crashed, soon after the crash. Read-only. It prints:

      1. The tail of Donut.log, whose last lines show what the app was doing when
         it died (a crash caught by no handler simply stops the log mid-thought).
      2. Application event-log entries from the last few hours for .NET Runtime,
         Application Error and Windows Error Reporting that mention pwsh or DONUT.
         These carry the exception type, faulting module and stack the process
         itself never got to log.

.PARAMETER Hours
    How far back to search the event log. Default 3.

.PARAMETER LogLines
    How many Donut.log lines to print. Default 40.

.EXAMPLE
    pwsh -File tools\Get-CrashReport.ps1
    Run right after a crash and paste the whole output.
#>
[CmdletBinding()]
param(
    [int] $Hours = 3,
    [int] $LogLines = 40
)

$log = Join-Path $env:ProgramData 'DONUT\data\logs\Donut.log'

Write-Host 'DONUT crash report (read-only)' -ForegroundColor White

Write-Host "`n=== Donut.log, last $LogLines line(s) ===" -ForegroundColor Cyan
if (Test-Path -LiteralPath $log) {
    Get-Content -LiteralPath $log -Tail $LogLines -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "  $_" }
} else { Write-Host "  (no log at $log)" -ForegroundColor Yellow }

Write-Host "`n=== Application event log, last $Hours hour(s) ===" -ForegroundColor Cyan
$since = (Get-Date).AddHours(-$Hours)
$providers = @('.NET Runtime', 'Application Error', 'Windows Error Reporting', 'PowerShell-7')
$events = @()
foreach ($p in $providers) {
    try {
        $events += @(Get-WinEvent -FilterHashtable @{
                LogName = 'Application'; ProviderName = $p; StartTime = $since
            } -ErrorAction Stop)
    } catch { }
}
$hits = @($events | Where-Object { $_.Message -match 'pwsh|donut' } |
        Sort-Object TimeCreated)
if ($hits.Count -eq 0) {
    Write-Host '  no pwsh or DONUT crash events found in the window' -ForegroundColor Yellow
}
foreach ($e in $hits) {
    Write-Host ("`n  -- {0}  {1}  (Id {2})" -f $e.TimeCreated, $e.ProviderName, $e.Id) `
        -ForegroundColor White
    # The first dozen lines carry the exception type, module and offset that matter.
    @(($e.Message -split "`r?`n") | Select-Object -First 12) |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host "`nInterpretation:" -ForegroundColor White
Write-Host '  log ends mid-lookup with no ERROR             -> the process died without a handler, read the events.'
Write-Host '  .NET Runtime event with an exception type     -> that type + stack is the answer, paste it whole.'
Write-Host '  Application Error naming a native dll         -> a native crash (renderer, driver), not script logic.'
Write-Host '  no events and a clean log                     -> the window may be wrong, rerun with -Hours 24.'
