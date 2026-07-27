#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses why "Start with Windows" registers a task that never launches DONUT.

.DESCRIPTION
    Run ON THE BOX THAT RUNS DONUT, in an ELEVATED pwsh, AFTER a logon that should
    have started DONUT but didn't. It answers the four questions the Donut.log
    "Registered startup task" line cannot, in order:

      1. WHICH BUILD IS INSTALLED. The launcher embeds src\ and self-extracts it to
         %ProgramData%\DONUT\app - so `git pull` alone changes NOTHING until
         Donut.Launcher.exe is rebuilt. Reports whether the extracted
         StartupTaskService.psm1 has the SYSTEM/psexec lane.
      2. WHAT ACTUALLY GOT REGISTERED. Principal (who it runs as), action, and
         trigger - a per-user principal on a NON-admin account is the known dead
         end (its RunLevel Highest degrades to a standard token).
      3. WHETHER IT FIRED AND WHAT WINDOWS SAID. LastTaskResult decoded, plus the
         TaskScheduler/Operational events for this task. 0x800702E4 = elevation
         required (CreateProcess refused the requireAdministrator launcher).
      4. WHETHER THE ACTION COULD EVEN RUN. psexec/launcher paths resolved the way
         the task will resolve them, from SYSTEM's environment.

.PARAMETER TaskName
    Task to inspect. Defaults to the installed DONUT-* startup task (NOT
    "DONUT-$env:USERNAME" - in a SYSTEM shell that resolves to DONUT-SYSTEM and
    finds nothing, which is the same $env: trap the service itself had).

.EXAMPLE
    pwsh -File tools\Diagnose-StartupTask.ps1
    Snapshot after a logon where DONUT never appeared.
#>
[CmdletBinding()]
param(
    [string] $TaskName
)

$appRoot = Join-Path $env:ProgramData 'DONUT\app'
$srcRoot = Join-Path $appRoot 'src'

# DONUT-LensAgent is PersonLensService's, not a startup task.
if (-not $TaskName) {
    $found = @(Get-ScheduledTask -TaskName 'DONUT-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -ne 'DONUT-LensAgent' })
    if ($found.Count -eq 1) { $TaskName = $found[0].TaskName }
    elseif ($found.Count -gt 1) {
        Write-Host "Multiple DONUT startup tasks installed - inspecting each in turn:" -ForegroundColor Yellow
        $found.TaskName | ForEach-Object { Write-Host "  $_" }
        $TaskName = $found[0].TaskName
    }
}

function Write-Section([string]$title) {
    Write-Host "`n=== $title ===" -ForegroundColor Cyan
}

# Task Scheduler reports launch faults as HRESULTs; these are the ones this feature hits.
function Get-ResultMeaning([int]$code) {
    $map = @{
        0          = 'success'
        267008     = 'task is ready (never run)'
        267009     = 'task is currently running'
        267011     = 'task has not yet run'
        267014     = 'task was terminated by the user'
        2147942402 = '0x80070002 FILE NOT FOUND - the action Execute path is wrong or unreachable from SYSTEM'
        2147942405 = '0x80070005 ACCESS DENIED'
        2147943140 = '0x800702E4 ELEVATION REQUIRED - CreateProcess refused a requireAdministrator exe under a non-elevated token'
    }
    if ($map.ContainsKey($code)) { return $map[$code] }
    return ('0x{0:X8} (see winerror.h)' -f $code)
}

Write-Section "1. Installed build (is your fix even running?)"
$svcPath = Join-Path $srcRoot 'Services\StartupTaskService.psm1'
$script:codeSplitsTrigger = $false
if (-not (Test-Path -LiteralPath $svcPath)) {
    Write-Host "No extracted app tree at $srcRoot - DONUT may run from the dev path (Start-Donut.ps1)." -ForegroundColor Yellow
}
else {
    $svc = Get-Content -LiteralPath $svcPath -Raw
    $hasLane = $svc -match 'BuildSystemSpec'
    $hasToken = $svc -match 'GetProcessIdentity'
    # The console-user trigger fix: RegisterTask takes $triggerUser, separate from the principal.
    $script:codeSplitsTrigger = $svc -match 'triggerUser'
    Write-Host "extracted : $svcPath"
    Write-Host "modified  : $((Get-Item -LiteralPath $svcPath).LastWriteTime)"
    Write-Host ("token-owner fix         : " + $(if ($hasToken) { 'PRESENT' } else { 'MISSING' })) -ForegroundColor $(if ($hasToken) { 'Green' } else { 'Red' })
    Write-Host ("SYSTEM psexec lane      : " + $(if ($hasLane) { 'PRESENT' } else { 'MISSING' })) -ForegroundColor $(if ($hasLane) { 'Green' } else { 'Red' })
    Write-Host ("console-user trigger fix: " + $(if ($script:codeSplitsTrigger) { 'PRESENT' } else { 'MISSING' })) -ForegroundColor $(if ($script:codeSplitsTrigger) { 'Green' } else { 'Red' })
    if (-not ($hasLane -and $script:codeSplitsTrigger)) {
        Write-Host "The installed launcher predates the current fixes. Rebuild Donut.Launcher.exe and reinstall - a git pull does not update an installed build." -ForegroundColor Red
    }
}

Write-Section "2. Registered task"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "No task named '$TaskName'. Installed DONUT tasks:" -ForegroundColor Yellow
    Get-ScheduledTask | Where-Object TaskName -like 'DONUT*' | Select-Object TaskName, State | Format-Table -AutoSize
    return
}
$principal = $task.Principal
$action = @($task.Actions)[0]
Write-Host "runs as   : $($principal.UserId)   LogonType=$($principal.LogonType)  RunLevel=$($principal.RunLevel)"
Write-Host "execute   : $($action.Execute)"
Write-Host "arguments : $($action.Arguments)"
$consoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
Write-Host "console user (who actually logs on): $consoleUser"
$script:triggerMismatch = $false
foreach ($t in $task.Triggers) {
    Write-Host "trigger   : $($t.CimClass.CimClassName) user=$($t.UserId) delay=$($t.Delay) enabled=$($t.Enabled)"
    if ($t.UserId -and $consoleUser -and $t.UserId -ine $consoleUser) {
        $script:triggerMismatch = $true
        Write-Host "PROBLEM: the logon trigger is bound to '$($t.UserId)', but '$consoleUser' is who signs in at the console. That account never logs on interactively, so this task stays Ready and never fires." -ForegroundColor Red
    }
}
$script:perUserLane = $principal.UserId -notmatch 'SYSTEM'
if ($script:perUserLane -and $principal.RunLevel -eq 'Highest') {
    # Direct members only - a domain account is usually admin via a nested group
    # (Domain Admins), which this cannot see, so absence is NOT proof of non-admin.
    $direct = $false
    try {
        $grp = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
        $direct = @($grp | Where-Object { $_.Name -ieq $principal.UserId }).Count -gt 0
    }
    catch { Write-Host "(could not enumerate local Administrators: $($_.Exception.Message))" -ForegroundColor DarkGray }
    if ($direct) {
        Write-Host "principal '$($principal.UserId)' is a direct local admin - RunLevel Highest will yield an elevated token."
    }
    else {
        Write-Host "NOTE: '$($principal.UserId)' is not a DIRECT member of local Administrators. It may still be admin via a domain group (Domain Admins), which this check cannot see. IF it is not, RunLevel Highest degrades to a standard token and the requireAdministrator launcher refuses to start (0x800702E4)." -ForegroundColor Yellow
    }
}

Write-Section "3. Did it fire?"
$info = $task | Get-ScheduledTaskInfo
Write-Host "last run   : $($info.LastRunTime)"
Write-Host "last result: $($info.LastTaskResult) - $(Get-ResultMeaning ([int]$info.LastTaskResult))"
Write-Host "next run   : $($info.NextRunTime)"
if ([int]$info.LastTaskResult -eq 267011) {
    Write-Host "DIAGNOSIS: registered but NEVER RUN. The task itself is fine - its trigger never fired. Check the trigger user above against the console user." -ForegroundColor Red
}

Write-Section "TaskScheduler/Operational events for this task"
$filter = @{ LogName = 'Microsoft-Windows-TaskScheduler/Operational'; StartTime = (Get-Date).AddDays(-2) }
$events = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -like "*$TaskName*" } | Select-Object -First 25
if ($events) {
    $events | Select-Object TimeCreated, Id, @{ n = 'Message'; e = { ($_.Message -split "`n")[0] } } | Format-Table -AutoSize -Wrap
}
else {
    Write-Host "No events (log may be disabled, or the task never fired)." -ForegroundColor Yellow
    Write-Host "Enable with: wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true"
}

Write-Section "4. Can the action run?"
$bundled = Join-Path $srcRoot 'Tools\psexec.exe'
Write-Host ("bundled psexec ($bundled): " + $(if (Test-Path -LiteralPath $bundled) { 'FOUND' } else { 'missing' }))
$onPath = Get-Command psexec.exe -ErrorAction SilentlyContinue
Write-Host ("psexec on PATH: " + $(if ($onPath) { $onPath.Source } else { 'NOT FOUND' }))
if ($action.Execute -and -not (Test-Path -LiteralPath ($action.Execute.Trim('"')))) {
    Write-Host "PROBLEM: the task's Execute path does not exist: $($action.Execute)" -ForegroundColor Red
}
Write-Host "console session id: $((Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId)"
Write-Host "this shell session: $((Get-Process -Id $PID).SessionId)   running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
$donut = Get-Process -Name 'Donut.Launcher' -ErrorAction SilentlyContinue
Write-Host ("DONUT running now: " + $(if ($donut) { "yes (pid $($donut.Id), session $($donut.SessionId))" } else { 'no' }))

Write-Section "Manual reproduction (run this to see psexec's own error)"
Write-Host "The task's action, run by hand from THIS elevated shell:"
Write-Host "  & `"$($action.Execute)`" $($action.Arguments)" -ForegroundColor Gray
Write-Host "If that surfaces DONUT here but the logon task does not, the failure is session-0 injection, not the command."

Write-Section "VERDICT"
# The registered task is a snapshot of whichever build last applied it - so new code
# plus an old-shaped task means the fix simply has not run yet.
$oldShape = $script:triggerMismatch -or $script:perUserLane
if ($oldShape -and $script:codeSplitsTrigger) {
    Write-Host "The installed code HAS the console-user trigger fix, but this task still has the OLD shape (per-user principal and/or a trigger bound to a non-console account)." -ForegroundColor Yellow
    Write-Host "The task is a snapshot from whichever build last applied it - the fix has not re-registered yet." -ForegroundColor Yellow
    Write-Host "DO THIS: launch DONUT and wait ~2 minutes (the startup-task heal re-applies on a timer), or toggle Start with Windows off and on. It will register DONUT-<console user> as SYSTEM and sweep this stale task. Then re-run this script." -ForegroundColor Green
}
elseif ($oldShape) {
    Write-Host "This task has the OLD shape AND the installed build lacks the fix." -ForegroundColor Red
    Write-Host "DO THIS: rebuild Donut.Launcher.exe from the current source and reinstall - an installed build runs src\ from INSIDE the exe, so pulling alone changes nothing. Then launch DONUT and re-run this script." -ForegroundColor Green
}
else {
    Write-Host "Task shape looks correct: SYSTEM principal, triggered by the console user." -ForegroundColor Green
    Write-Host "If DONUT still does not appear at logon, the remaining suspect is psexec's session-0 injection - run the manual reproduction above and capture its output." -ForegroundColor Green
}
