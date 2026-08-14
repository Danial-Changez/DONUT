#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses why "Start with Windows" registers a task that never launches DONUT.

.DESCRIPTION
    Run on the box that runs DONUT, in an elevated pwsh, after a logon that should
    have started DONUT but didn't. It answers the four questions the Donut.log
    "Registered startup task" line cannot, in order:

      1. Which build is installed. The launcher embeds src\ and self-extracts it to
         %ProgramData%\DONUT\app - so `git pull` alone changes nothing until
         Donut.Launcher.exe is rebuilt. Reports whether the extracted
         StartupTaskService.psm1 still carries the deleted SYSTEM/psexec lane.
      2. What actually got registered. Principal (who it runs as), action, and
         trigger - it should run as the console user at RunLevel Highest, which is
         that account's elevated token if it is an admin and its ordinary one if not.
      3. Whether it fired and what Windows said. LastTaskResult decoded, plus the
         TaskScheduler/Operational events for this task. 0x800702E4 = elevation
         required (CreateProcess refused the requireAdministrator launcher).
      4. Whether the action could even run, with the launcher path resolved the
         way the task will resolve it.

.PARAMETER TaskName
    Task to inspect. Defaults to the installed DONUT-* startup task (not
    "DONUT-$env:USERNAME" - in a SYSTEM shell that resolves to DONUT-SYSTEM and
    finds nothing, which is the same $env: trap the service itself had).

.NOTES
    LastTaskResult is an unsigned HRESULT. 0x800702E4 is 2147943140, past [int]'s
    range, so casting it threw before it could ever be decoded, and some hosts hand
    it back already wrapped negative. ConvertTo-TaskResult normalizes to uint32 and
    the table is keyed on hex, so no numeric literal type has to match.

    Section 6 exists because the launcher runs src\Start-Donut.ps1 out of
    %ProgramData%\DONUT\app. ProgramData is user-writable, so allowlisting policies
    can block scripts there, and the default AppLocker rule set exempts
    BUILTIN\Administrators. That makes the same build run elevated and die
    de-elevated while every ACL on the path still reads Full Control. A
    DONUT-LensAgent task in the Running state is evidence against this on a box.

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

$script:dataRoot = Join-Path $env:ProgramData 'DONUT\data'

# Mirrors StartupTaskService.TaskNameFor, so a MISSING task can still be named.
function Get-ExpectedTaskName {
    $who = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $who) { return '' }
    return "DONUT-$(($who -split '\\')[-1])"
}

function Get-DonutSetting([string]$key) {
    $path = Join-Path $script:dataRoot 'config\config.json'
    if (-not (Test-Path -LiteralPath $path)) { return '(no config.json)' }
    try {
        $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($null -eq $cfg.$key) { return '(unset - falls back to the default)' }
        return [string]$cfg.$key
    }
    catch { return "(unreadable: $($_.Exception.Message))" }
}

# Apply() logs the resolved console user and the real failure reason. Nothing surfaced them.
function Write-StartupTaskLog {
    $log = Join-Path $script:dataRoot 'logs\Donut.log'
    if (-not (Test-Path -LiteralPath $log)) {
        Write-Host "Donut.log: $log - not present" -ForegroundColor Yellow
        return
    }
    $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue |
            Where-Object { $_ -match 'Startup task' } | Select-Object -Last 12)
    if ($lines.Count -eq 0) {
        Write-Host "Donut.log has no 'Startup task' lines - Apply() has never run. The toggle is off, or its side effect never fired." -ForegroundColor Yellow
        return
    }
    Write-Host "Donut.log, last $($lines.Count) startup-task lines:" -ForegroundColor Green
    $lines | ForEach-Object {
        $color = if ($_ -match 'failed|denied|Access|error') { 'Red' } else { 'Gray' }
        Write-Host "  $_" -ForegroundColor $color
    }
}

# Traverse is needed on EVERY parent, and it is the one an ACL viewer on the leaf will not
# show you. C:\Windows\IMECache is a real example: restrictive parents, permissive leaf.
function Test-PathReachable([string]$path) {
    if (-not $path) { return }
    $leaf = $path.Trim('"')
    Write-Host "execute path: $leaf"
    Write-Host ("  exists to THIS shell: " + $(if (Test-Path -LiteralPath $leaf) { 'yes' } else { 'NO' })) `
        -ForegroundColor $(if (Test-Path -LiteralPath $leaf) { 'Green' } else { 'Red' })
    $dir = Split-Path $leaf -Parent
    while ($dir -and (Split-Path $dir -Parent)) {
        try {
            $acl = Get-Acl -LiteralPath $dir -ErrorAction Stop
            $users = @($acl.Access | Where-Object {
                    $_.IdentityReference -match 'Users|Everyone|Authenticated' -and
                    $_.FileSystemRights -match 'ReadAndExecute|ExecuteFile|FullControl|Modify'
                })
            $verdict = if ($users.Count -gt 0) { 'standard users can traverse' } else { 'NO standard-user traverse' }
            Write-Host ("  {0,-55} {1}" -f $dir, $verdict) -ForegroundColor $(if ($users.Count) { 'Gray' } else { 'Red' })
        }
        catch { Write-Host ("  {0,-55} ACL unreadable" -f $dir) -ForegroundColor Yellow }
        $dir = Split-Path $dir -Parent
    }
}

# LastTaskResult is an unsigned HRESULT that overflows [int]. See .NOTES.
function ConvertTo-TaskResult($value) {
    $n = [int64]$value
    if ($n -lt 0) { $n += 4294967296 }
    return [uint32]$n
}

function Get-ResultMeaning([uint32]$code) {
    $hex = '0x{0:X8}' -f $code
    $map = @{
        '0x00000000' = 'success'
        '0x00041300' = 'task is ready (never run)'
        '0x00041301' = 'task is currently running'
        '0x00041303' = 'task has not yet run'
        '0x00041306' = 'task was terminated by the user'
        '0x80070002' = 'FILE NOT FOUND - the action Execute path is wrong or unreachable'
        '0x80070005' = 'ACCESS DENIED'
        '0x8007010B' = 'DIRECTORY NAME INVALID - the action WorkingDirectory is missing or unreachable'
        '0x800702E4' = 'ELEVATION REQUIRED - CreateProcess refused an elevation-requiring exe under a non-elevated token'
        '0x800704DD' = 'NOT LOGGED ON - the principal has no interactive session'
        '0x800704EC' = 'BLOCKED BY POLICY - AppLocker/WDAC/SRP refused this exe or script for this token, which is NOT a file ACL'
        '0xC0000142' = 'DLL INIT FAILED - the process could not initialize on this session/desktop'
    }
    if ($map.ContainsKey($hex)) { return "$hex $($map[$hex])" }
    return "$hex (see winerror.h)"
}

function Write-PolicySection {
    Write-Section "6. APPLICATION ALLOWLISTING (AppLocker / WDAC)"
    # ProgramData is user-writable, so allowlisting can block the app tree. See .NOTES.
    $script:policyBlocked = $false
    $appId = Get-Service AppIDSvc -ErrorAction SilentlyContinue
    Write-Host "AppIDSvc (AppLocker enforcement): $(if ($appId) { $appId.Status } else { 'not present' })"
    try {
        $pol = [xml](Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop)
        $modes = @($pol.AppLockerPolicy.RuleCollection |
                ForEach-Object { "$($_.Type)=$($_.EnforcementMode)" })
        Write-Host "effective policy : $($modes -join '  ')"
        if ($modes -match 'Script=(Enabled|AuditOnly)') {
            Write-Host "Script rules are active, and the app tree lives under ProgramData." -ForegroundColor Yellow
        }
    }
    catch { Write-Host "effective policy : none readable ($($_.Exception.Message))" }

    # Did it actually block us? 8004/8007 are the "was prevented from running" IDs.
    foreach ($log in 'Microsoft-Windows-AppLocker/EXE and DLL',
        'Microsoft-Windows-AppLocker/MSI and Script') {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 8003, 8004, 8006, 8007 } `
                -MaxEvents 40 -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match 'DONUT' })
        if ($ev.Count -gt 0) {
            $script:policyBlocked = $true
            Write-Host "$log - $($ev.Count) DONUT event(s):" -ForegroundColor Red
            $ev | Select-Object -First 5 | ForEach-Object {
                Write-Host ("  {0}  id={1}  {2}" -f $_.TimeCreated, $_.Id, ($_.Message -split "`n")[0]) -ForegroundColor Red
            }
        }
        else { Write-Host "$log - no DONUT events" }
    }

    # WDAC/Code Integrity is the other allowlisting engine and blocks the same way.
    $ci = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3076, 3077 } `
            -MaxEvents 40 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'DONUT' })
    if ($ci.Count -gt 0) {
        $script:policyBlocked = $true
        Write-Host "CodeIntegrity (WDAC) - $($ci.Count) DONUT block event(s)" -ForegroundColor Red
    }

    # A filtered token still lists Administrators, but deny-only, so grants to it do not apply.
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Host ""
    Write-Host "this shell       : $($id.Name)  elevated=$elevated"
    Write-Host "NOTE: run this script BOTH elevated and not. A path that resolves in one and not"
    Write-Host "the other is a policy/token difference, never a file ACL - the ACL is identical."
}

Write-Section "1. Installed build (is your fix even running?)"
$svcPath = Join-Path $srcRoot 'Services\StartupTaskService.psm1'
$script:codeSplitsTrigger = $false
if (-not (Test-Path -LiteralPath $svcPath)) {
    Write-Host "No extracted app tree at $srcRoot - DONUT may run from the dev path (Start-Donut.ps1)." -ForegroundColor Yellow
}
else {
    $svc = Get-Content -LiteralPath $svcPath -Raw
    $hasToken = $svc -match 'GetProcessIdentity'
    # The console-user trigger fix: RegisterTask takes $triggerUser, separate from the principal.
    $script:codeSplitsTrigger = $svc -match 'triggerUser'
    # The SYSTEM+psexec lane was deleted: as SYSTEM every remote job failed on access denied.
    $script:codeHasOldLane = $svc -match 'BuildSystemSpec'
    Write-Host "extracted : $svcPath"
    Write-Host "modified  : $((Get-Item -LiteralPath $svcPath).LastWriteTime)"
    Write-Host ("token-owner fix         : " + $(if ($hasToken) { 'PRESENT' } else { 'MISSING' })) -ForegroundColor $(if ($hasToken) { 'Green' } else { 'Red' })
    Write-Host ("console-user trigger fix: " + $(if ($script:codeSplitsTrigger) { 'PRESENT' } else { 'MISSING' })) -ForegroundColor $(if ($script:codeSplitsTrigger) { 'Green' } else { 'Red' })
    Write-Host ("de-elevated autostart   : " + $(if ($script:codeHasOldLane) { 'NO (old SYSTEM lane)' } else { 'YES' })) -ForegroundColor $(if ($script:codeHasOldLane) { 'Red' } else { 'Green' })
    if ($script:codeHasOldLane -or -not $script:codeSplitsTrigger) {
        Write-Host "The installed launcher predates the current fixes. Rebuild Donut.Launcher.exe and reinstall - a git pull does not update an installed build." -ForegroundColor Red
    }
}

Write-Section "2. Registered task"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    # No task is the interesting case: Apply() failing de-elevated leaves exactly this state.
    $expected = Get-ExpectedTaskName
    Write-Host "NO STARTUP TASK IS INSTALLED." -ForegroundColor Red
    Write-Host "expected name: $(if ($expected) { $expected } else { '(no signed-in console user - Apply refuses to register without one)' })"
    Write-Host "Installed DONUT tasks:" -ForegroundColor Yellow
    Get-ScheduledTask | Where-Object TaskName -Like 'DONUT*' | Select-Object TaskName, State | Format-Table -AutoSize

    Write-Section "2b. Is the toggle even on?"
    Write-Host "startWithWindows : $(Get-DonutSetting 'startWithWindows')"
    Write-Host "runAsAdmin       : $(Get-DonutSetting 'runAsAdmin')"
    Write-Host "config           : $(Join-Path $script:dataRoot 'config\config.json')"

    Write-Section "2c. What did Apply() say?"
    Write-StartupTaskLog

    Write-PolicySection

    Write-Section "VERDICT"
    Write-Host "Registering a task needs an elevated token. A de-elevated DONUT reaches Register-ScheduledTask, gets access denied, and reports it as one toast - which is what an absent task plus an access-denied line in Donut.log means." -ForegroundColor Yellow
    Write-Host "DO THIS: confirm above whether startWithWindows is true. If it is, relaunch DONUT as administrator and toggle it off and on - it should register immediately. If that works, the bug is that the toggle is not gated behind the elevation prompt." -ForegroundColor Green
    return
}
$principal = $task.Principal
$action = @($task.Actions)[0]
Write-Host "runs as   : $($principal.UserId)   LogonType=$($principal.LogonType)  RunLevel=$($principal.RunLevel)"
Write-Host "execute   : $($action.Execute)"
Write-Host "arguments : $($action.Arguments)"
$consoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
Write-Host "signed-in user (who actually logs on): $consoleUser"
# Under over-the-shoulder UAC the elevated DONUT shares the session the trigger must match.
Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
    ForEach-Object {
        $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($o) { Write-Host "  desktop in session $($_.SessionId) belongs to $($o.Domain)\$($o.User)" }
    }
$script:triggerMismatch = $false
foreach ($t in $task.Triggers) {
    Write-Host "trigger   : $($t.CimClass.CimClassName) user=$($t.UserId) delay=$($t.Delay) enabled=$($t.Enabled)"
    if ($t.UserId -and $consoleUser -and $t.UserId -ine $consoleUser) {
        $script:triggerMismatch = $true
        Write-Host "PROBLEM: the logon trigger is bound to '$($t.UserId)', but '$consoleUser' is who signs in at the console. That account never logs on interactively, so this task stays Ready and never fires." -ForegroundColor Red
    }
}
# The scheduler default of 7 boots DONUT below normal CPU class in the logon storm.
Write-Host "priority  : $($task.Settings.Priority) (current builds register 5, normal class)"
if ([int]$task.Settings.Priority -ge 7) {
    Write-Host "PROBLEM: priority $($task.Settings.Priority) runs the whole boot below normal CPU class while every other logon app competes for the disk. Toggle Start with Windows off and on to re-register it at 5." -ForegroundColor Red
}
# Any psexec or SYSTEM shape here is a task from before the lane was deleted.
if ($action.Execute -like '*PsExec*' -or $action.Arguments -like '*Start-DonutInConsoleSession*') {
    Write-Host "PROBLEM: this task is from an older build that started DONUT as SYSTEM via psexec. As SYSTEM it authenticates on the network as the machine account, which has no rights on fleet targets, so every remote job fails on access denied. Toggle Start with Windows off and on to re-register it." -ForegroundColor Red
}
if ($principal.UserId -match 'SYSTEM') {
    Write-Host "PROBLEM: the task runs as SYSTEM. Current builds run it as the console user at their own level and elevate on demand." -ForegroundColor Red
}
if ($principal.RunLevel -eq 'Highest') {
    # Direct members only, so absence is not proof: nested Domain Admins is invisible here.
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
$script:lastResult = ConvertTo-TaskResult $info.LastTaskResult
Write-Host "last result: $($info.LastTaskResult) - $(Get-ResultMeaning $script:lastResult)"
Write-Host "next run   : $($info.NextRunTime)"
if ($script:lastResult -eq 267011) {
    Write-Host "DIAGNOSIS: registered but NEVER RUN. The task itself is fine - its trigger never fired. Check the trigger user above against the console user." -ForegroundColor Red
}
if ($script:lastResult -eq 2147943660) {
    Write-Host "DIAGNOSIS: BLOCKED BY POLICY (0x800704EC). An allowlisting policy refused the action for this token - the file ACL is not involved, which is why the path still reads Full Control. Section 6 names the rule." -ForegroundColor Red
}
if ($action.Execute -like '*PsExec*' -and $script:lastResult -gt 4) {
    Write-Host "NOTE: this old-shape action calls psexec -d directly, whose exit code is the launched PID - a result like this usually means psexec SUCCEEDED. The shim-shaped action exits 0 instead." -ForegroundColor Yellow
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
Test-PathReachable $action.Execute
if ($action.WorkingDirectory) { Write-Host "working dir : $($action.WorkingDirectory)" }
else { Write-Host "working dir : (none - Task Scheduler will start it in %windir%\system32)" -ForegroundColor Yellow }
Write-Host "console session id: $((Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId)"
Write-Host "this shell session: $((Get-Process -Id $PID).SessionId)   running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
$donut = Get-Process -Name 'Donut.Launcher' -ErrorAction SilentlyContinue
Write-Host ("DONUT running now: " + $(if ($donut) { "yes (pid $($donut.Id), session $($donut.SessionId))" } else { 'no' }))

Write-Section "5. The autostarted instance (running, but no tray?)"
$consoleSession = (Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId
$running = @(Get-Process -Name 'Donut.Launcher' -ErrorAction SilentlyContinue)
if (-not $running) { Write-Host "No Donut.Launcher process is running." -ForegroundColor Yellow }
foreach ($proc in $running) {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
    $owner = if ($cim) { Invoke-CimMethod -InputObject $cim -MethodName GetOwner -ErrorAction SilentlyContinue } else { $null }
    $who = if ($owner -and $owner.User) { "$($owner.Domain)\$($owner.User)" } else { 'unknown' }
    Write-Host "pid $($proc.Id)  session $($proc.SessionId)  as $who  started $($cim.CreationDate)"
    if ($null -ne $consoleSession -and $proc.SessionId -ne $consoleSession) {
        Write-Host "  PROBLEM: not in the console session ($consoleSession) - it has no desktop, so no tray icon or window can ever appear." -ForegroundColor Red
    }
    if ($who -like '*\SYSTEM') {
        Write-Host "  NOTE: as SYSTEM it authenticates on the network as the machine account, which has no rights on fleet targets - remote jobs will fail with access denied." -ForegroundColor Yellow
    }
}

# One machine-wide data root, so every account's instance reads the same settings and logs.
$dataRoot = Join-Path $env:ProgramData 'DONUT\data'
if (Test-Path -LiteralPath $dataRoot) {
    Write-Host "data root: $dataRoot" -ForegroundColor Green
}
else {
    Write-Host "data root: $dataRoot - not present (DONUT has not run since the move off %LOCALAPPDATA%)" -ForegroundColor Yellow
}

# The shim narrates every firing here: resolved session id, the psexec line, the PID.
$autostartLog = Join-Path $env:ProgramData 'DONUT\logs\autostart.log'
if (Test-Path -LiteralPath $autostartLog) {
    Write-Host "shim log: $autostartLog" -ForegroundColor Green
    Get-Content -LiteralPath $autostartLog -Tail 10
}
else {
    Write-Host "shim log: $autostartLog - not present (the shim-shaped task has not fired yet)" -ForegroundColor Yellow
}

# Only an old SYSTEM-hosted DONUT logs under the system profile, so check your own log first.
Write-Host ""
foreach ($profileRoot in @("$env:SystemRoot\System32\config\systemprofile", "$env:SystemRoot\SysWOW64\config\systemprofile")) {
    $systemLog = Join-Path $profileRoot 'AppData\Local\DONUT\logs\Donut.log'
    if (Test-Path -LiteralPath $systemLog) {
        Write-Host "SYSTEM-profile log: $systemLog" -ForegroundColor Green
        Get-Content -LiteralPath $systemLog -Tail 25
    }
    else {
        Write-Host "SYSTEM-profile log: $systemLog - not present" -ForegroundColor Yellow
    }
}

Write-Section "Manual reproduction (run this to see psexec's own error)"
Write-Host "The task's action, run by hand from THIS elevated shell:"
Write-Host "  & `"$($action.Execute)`" $($action.Arguments)" -ForegroundColor Gray
Write-Host "If that surfaces DONUT here but the logon task does not, the failure is session-0 injection, not the command."
if ($action.Arguments -like '*--tray*') {
    Write-Host ""
    Write-Host "Then the same thing WITHOUT --tray, which proves whether that instance can draw on your desktop at all:"
    Write-Host "  & `"$($action.Execute)`" $(($action.Arguments -replace '\s--tray\b', ''))" -ForegroundColor Gray
    Write-Host "A window here but no tray icon = the tray call is the problem; neither = the session/desktop is."
}

Write-PolicySection

Write-Section "VERDICT"
if ($script:policyBlocked) {
    Write-Host "An allowlisting policy blocked DONUT. This is NOT an ACL problem, which is why the directory still shows Full Control." -ForegroundColor Red
    Write-Host "The launcher executes src\Start-Donut.ps1 from $appRoot. ProgramData is user-writable, so AppLocker/WDAC commonly forbid running scripts from it, while the default rule set exempts BUILTIN\Administrators - so an elevated DONUT runs and a de-elevated one is refused." -ForegroundColor Yellow
    Write-Host "DO THIS: either have the app tree path allowlisted for your account, or move the extraction root into the already-approved install directory so the exe and its scripts share one allowed location." -ForegroundColor Green
}
# The registered task is a snapshot of whichever build last applied it, not of the code.
$oldExecute = ($action.Execute -like '*PsExec*') -or ($action.Arguments -like '*Start-DonutInConsoleSession*')
$oldShape = $script:triggerMismatch -or ($principal.UserId -match 'SYSTEM') -or $oldExecute
if ($oldShape -and $script:codeSplitsTrigger -and -not $script:codeHasOldLane) {
    Write-Host "The installed code is current, but this task still has an OLD shape (a SYSTEM principal, a psexec action, and/or a trigger bound to a non-console account)." -ForegroundColor Yellow
    Write-Host "The task is a snapshot from whichever build last applied it - the current code has not re-registered yet." -ForegroundColor Yellow
    Write-Host "DO THIS: launch DONUT and wait ~2 minutes (the startup-task heal re-applies on a timer), or toggle Start with Windows off and on. It will register DONUT-<console user> to run as that user, and sweep this stale task. Then re-run this script." -ForegroundColor Green
}
elseif ($oldShape) {
    Write-Host "This task has the OLD shape AND the installed build lacks the fix." -ForegroundColor Red
    Write-Host "DO THIS: rebuild Donut.Launcher.exe from the current source and reinstall - an installed build runs src\ from INSIDE the exe, so pulling alone changes nothing. Then launch DONUT and re-run this script." -ForegroundColor Green
}
elseif (-not $script:policyBlocked) {
    Write-Host "Task shape looks correct: the console user is both the trigger and the principal, at RunLevel Highest." -ForegroundColor Green
    Write-Host "If DONUT is running but invisible, section 5 says why: a session other than the console one means it never reached your desktop; the console session means the process is there but its UI is not." -ForegroundColor Green
}
