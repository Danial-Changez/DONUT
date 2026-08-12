#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses why the persistent Lens agent isn't answering lookups (UI stuck "loading").

.DESCRIPTION
    Run on the box that runs DONUT, in a non-elevated pwsh (the same account the agent
    runs as - the agent is de-elevated to the interactive user), ideally right after a
    Lens pick that is stuck. It reports the agent's liveness (heartbeat age, process,
    scheduled task) and the exchange-dir contents, which together localize the failure to
    one of three stages:

      - heartbeat climbing past ~4s / stop.flag present / no agent process
            -> the agent is dead or wedged (the serve loop writes the beat, so a
               stale beat means it stopped serving and the next pick recycles it).
      - request-*.bin lingers while the beat stays fresh
            -> the serve loop isn't reading it (wrong dir).
      - request consumed but no result-*.bin within ~60s
            -> a lookup job is failing or hanging (AD / SCCM environmental).
      - timeouts.txt at 2 or more
            -> the parent force-recycles the agent on the next pick.
      - result-*.bin appears but the UI stays loading
            -> parent-side key or poll mismatch (not the agent).

    Use -Watch to poll the exchange dir + heartbeat once a second while you trigger a pick,
    and watch a request appear and whether it gets answered.

.PARAMETER Watch
    Poll the exchange dir + heartbeat every second for -Seconds seconds. Trigger the pick
    in DONUT during the watch.

.PARAMETER Seconds
    How long -Watch polls. Default 30.

.EXAMPLE
    pwsh -File tools\Diagnose-LensAgent.ps1
    One-shot snapshot - run right after a stuck pick.

.EXAMPLE
    pwsh -File tools\Diagnose-LensAgent.ps1 -Watch -Seconds 45
    Start it, then pick a person in DONUT and watch the request/result files.
#>
[CmdletBinding()]
param(
    [switch] $Watch,
    [int]    $Seconds = 30
)

$dir  = Join-Path $env:ProgramData  'DONUT\lens-agent'
$log  = Join-Path $env:ProgramData 'DONUT\data\logs\Donut.log'
$beat = Join-Path $dir 'heartbeat.txt'
$stop = Join-Path $dir 'stop.flag'

function Get-BeatAge {
    if (Test-Path -LiteralPath $beat) { return [int]((Get-Date) - (Get-Item -LiteralPath $beat).LastWriteTime).TotalSeconds }
    return $null
}

function Show-Snapshot {
    Write-Host "`n=== exchange dir ($dir) ===" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $dir) {
        $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Select-Object Name, Length, @{ n = 'AgeSec'; e = { [int]((Get-Date) - $_.LastWriteTime).TotalSeconds } }
        if ($items) { $items | Format-Table -AutoSize | Out-String | Write-Host } else { Write-Host '  (empty)' }
    }
    else { Write-Host '  (dir does not exist - the agent never cold-started on this box)' -ForegroundColor Yellow }

    Write-Host '=== heartbeat age (alive if < ~4s) ===' -ForegroundColor Cyan
    $age = Get-BeatAge
    if ($null -ne $age) {
        Write-Host "  $age s" -ForegroundColor ($(if ($age -lt 4) { 'Green' } else { 'Red' }))
    }
    else { Write-Host '  NO HEARTBEAT' -ForegroundColor Red }

    Write-Host '=== stop.flag (should be absent) ===' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $stop) {
        Write-Host ("  PRESENT -> '{0}'  (agent was told to exit)" -f ((Get-Content -LiteralPath $stop -Raw -ErrorAction SilentlyContinue) -replace '\s+$', '')) -ForegroundColor Red
    }
    else { Write-Host '  absent' -ForegroundColor Green }

    Write-Host '=== timeouts.txt (2+ forces a recycle on the next pick) ===' -ForegroundColor Cyan
    $strikes = Join-Path $dir 'timeouts.txt'
    if (Test-Path -LiteralPath $strikes) {
        $count = (Get-Content -LiteralPath $strikes -Raw -ErrorAction SilentlyContinue) -replace '\s+$', ''
        Write-Host ("  {0} consecutive lookup timeout(s)" -f $count) -ForegroundColor Yellow
    }
    else { Write-Host '  absent (no consecutive lookup timeouts)' -ForegroundColor Green }

    Write-Host '=== agent process (pwsh running LensAgent.ps1) ===' -ForegroundColor Cyan
    $procs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*LensAgent*' }
    if ($procs) { $procs | ForEach-Object { Write-Host "  PID $($_.ProcessId) is running LensAgent.ps1" -ForegroundColor Green } }
    else { Write-Host '  NOT running' -ForegroundColor Red }
}

Write-Host 'DONUT Lens agent diagnostic' -ForegroundColor White

Write-Host "`n=== scheduled task 'DONUT-LensAgent' ===" -ForegroundColor Cyan
$info = Get-ScheduledTaskInfo -TaskName 'DONUT-LensAgent' -ErrorAction SilentlyContinue
if ($info) { $info | Select-Object LastRunTime, LastTaskResult, NumberOfMissedRuns | Format-List | Out-String | Write-Host }
else { Write-Host '  not registered' -ForegroundColor Yellow }

Show-Snapshot

if ($Watch) {
    Write-Host "`n=== watching for $Seconds s - pick a person in DONUT now ===" -ForegroundColor Magenta
    Write-Host '  (watch a request-*.bin appear, then whether a result-*.bin follows)'
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Seconds 1
        $bins = if (Test-Path -LiteralPath $dir) {
            @(Get-ChildItem -LiteralPath $dir -Filter '*.bin' -File -ErrorAction SilentlyContinue).Name -join ', '
        }
        else { '(dir gone)' }
        $age = Get-BeatAge
        $ageStr = if ($null -ne $age) { "${age}s" } else { 'none' }
        Write-Host ('  {0:HH:mm:ss}  beat={1,-5}  bins=[{2}]' -f (Get-Date), $ageStr, $bins)
    }
}

Write-Host "`n=== Donut.log - recent Lens lines ===" -ForegroundColor Cyan
if (Test-Path -LiteralPath $log) {
    $hits = Get-Content -LiteralPath $log -Tail 500 -ErrorAction SilentlyContinue |
        Select-String -Pattern 'Lens|agent' | Select-Object -Last 20
    if ($hits) { $hits | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (no Lens lines in the last 500)' }
}
else { Write-Host "  (no log at $log)" -ForegroundColor Yellow }

Write-Host "`nInterpretation:" -ForegroundColor White
Write-Host '  heartbeat past ~4s / stop.flag present / no agent process -> agent dead or wedged (next pick recycles it).'
Write-Host '  request-*.bin lingers while the beat stays fresh          -> serve loop not reading it (wrong dir).'
Write-Host '  request consumed but no result-*.bin within ~60s          -> a lookup job failing/hanging (AD / SCCM).'
Write-Host '  timeouts.txt at 2+                                        -> the next pick force-recycles despite a fresh beat.'
Write-Host '  result-*.bin appears but the UI stays loading             -> parent-side key/poll mismatch (not the agent).'
