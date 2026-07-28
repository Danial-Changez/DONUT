using module "..\Core\LogService.psm1"

<#
.SYNOPSIS
    Registers/unregisters the elevated "start DONUT with Windows" scheduled task.

.DESCRIPTION
    A Task Scheduler task starts DONUT minimized to the tray at logon with no UAC
    prompt. Registering requires elevation, which DONUT already has. TWO DIFFERENT
    ACCOUNTS are involved and must not be conflated: the task is always TRIGGERED by
    the console user's logon (the only account that actually signs in), while what it
    RUNS AS depends on the process token (never $env: - under SYSTEM that names a
    nonexistent account Task Scheduler rejects with "No mapping between account names
    and security IDs"):
    - DONUT already runs as the console user: a per-user task, RunLevel Highest,
      Interactive - it runs inside that user's own logon session.
    - Anything else - a SYSTEM token, OR over-the-shoulder UAC (sign in as a standard
      user, elevate DONUT with a separate admin account, both in the same session):
      the task runs AS SYSTEM and relaunches DONUT into the console session
      (powershell shim -> psexec -s -i <id>), reproducing the manual launch. A
      per-user task cannot work here -
      an Interactive principal needs a logon session the admin account does not have,
      and RunLevel Highest on a non-admin console user degrades to a standard token
      that CreateProcess refuses against the launcher's requireAdministrator manifest
      (ERROR_ELEVATION_REQUIRED). Known trade-off: the SYSTEM instance authenticates
      on the network as the MACHINE account, not the admin account a manual
      over-the-shoulder launch uses - AD rights may differ.

.NOTES
    The pure helpers (BuildLaunchSpec, BuildSystemSpec, ReconcileDecision,
    TaskNameFor) are unit-tested; Apply is the thin CIM shell that dispatches on
    the decision and never throws to the caller (failure logs + toasts, real
    reason in LastFailure). The CIM/identity seams (GetExistingTask/RegisterTask/
    UnregisterTask, GetProcessIdentity/GetInteractiveUser/FindPsExec) are
    overridable so a fake subclass can capture which ran without touching Task
    Scheduler or WindowsIdentity. The shim (Start-DonutInConsoleSession.ps1)
    exists because psexec -i with no session id targets the CALLER's session,
    NOT the console session its docs claim (field-verified: a SYSTEM task put
    DONUT in session 0). Injection targets the physical console - an RDP-only
    logon will not surface the tray (known limit).
#>
class StartupTaskService {
    [LogService] $Logger
    [object] $Toast        # ToastService, duck-typed and optional (null in headless runs)
    [string] $SourceRoot
    [string] $LastFailure  # why the last Apply returned $false, for the caller's toast

    StartupTaskService([LogService]$logger, [object]$toast, [string]$sourceRoot) {
        $this.Logger = $logger
        $this.Toast = $toast
        $this.SourceRoot = $sourceRoot
    }

    # Pure: per-user task name from the owner account ("PROD\jdoe" -> "DONUT-jdoe").
    static [string] TaskNameFor([string]$user) {
        return "DONUT-$(($user -split '\\')[-1])"
    }

    # Who TRIGGERS the task (the console user - the only account that actually logs
    # on) and whether it must RUN AS SYSTEM. These are different people whenever
    # DONUT runs under a separate admin account: a task triggered by an account that
    # never logs on stays Ready forever, and an Interactive principal for an account
    # with no session cannot run at all. User = '' when nobody is signed in.
    [hashtable] ResolveOwner() {
        $identity = $this.GetProcessIdentity()
        $console = $this.GetInteractiveUser()
        if (-not $console) { return @{ User = ''; IsSystem = $true } }
        # Only the console user's own logon can host a per-user interactive task.
        $sameUser = (-not $identity.IsSystem) -and ($identity.Name -ieq $console)
        return @{ User = $console; IsSystem = (-not $sameUser) }
    }

    # Pure: the SYSTEM-lane action - powershell.exe (5.1, always present) runs the shim,
    # which resolves the console session id AT FIRE TIME and hands psexec -i that id.
    # Without an explicit id psexec targets the CALLER's session - 0 for a SYSTEM task,
    # a desktop nobody can see. Host args go base64: they carry nested quotes (dev pwsh).
    static [hashtable] BuildSystemSpec([string]$psexecPath, [string]$shimPath, [hashtable]$hostSpec) {
        $argB64 = [Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes([string]$hostSpec.Argument))
        return @{
            Execute  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            Argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden ' +
                "-File `"$shimPath`" -PsExec `"$psexecPath`" -Execute `"$($hostSpec.Execute)`" -ArgB64 $argB64"
        }
    }

    # Pure: the task action for the current host - a pwsh.exe host (dev) re-launches the
    # script with -Tray, any other exe is the launcher and takes --tray. Paths quoted.
    [hashtable] BuildLaunchSpec([string]$processPath, [string]$sourceRoot) {
        $leaf = Split-Path $processPath -Leaf
        if ($leaf -ieq 'pwsh.exe') {
            $script = Join-Path $sourceRoot 'Start-Donut.ps1'
            return @{
                Execute  = $processPath
                Argument = "-Sta -ExecutionPolicy Bypass -File `"$script`" -Tray"
            }
        }
        return @{ Execute = $processPath; Argument = '--tray' }
    }

    # Pure: what Apply should do - 'Register' (wanted, absent), 'Reregister' (wanted, app
    # moved), 'Unregister' (unwanted, present), or 'NoOp'.
    [string] ReconcileDecision([bool]$enabled, [object]$existingTask, [hashtable]$spec) {
        if ($enabled) {
            if ($null -eq $existingTask) { return 'Register' }
            if ($this.ActionDiffers($existingTask, $spec)) { return 'Reregister' }
            return 'NoOp'
        }
        if ($null -ne $existingTask) { return 'Unregister' }
        return 'NoOp'
    }

    # True when the registered task's action no longer matches the current launch spec
    # (the install moved, or the host changed between pwsh and the launcher).
    hidden [bool] ActionDiffers([object]$existingTask, [hashtable]$spec) {
        try {
            $action = @($existingTask.Actions)[0]
            if ($null -eq $action) { return $true }
            return ($action.Execute -ne $spec.Execute) -or ($action.Arguments -ne $spec.Argument)
        }
        catch { return $true }
    }

    # Thin shell: reconcile the desired state against the installed task and apply it.
    # Returns $true on success/no-op; a failure logs+toasts the real reason, $false.
    [bool] Apply([bool]$enabled) {
        $this.LastFailure = ''
        try {
            $owner = $this.ResolveOwner()
            # The whole feature turns on these three values; log them so a task that
            # never fires is diagnosable from Donut.log alone.
            $this.Logger.LogInfo(("Startup task: runs-as '{0}', signed-in console user '{1}', lane {2}." -f
                $this.GetProcessIdentity().Name, $owner.User,
                $(if ($owner.IsSystem) { 'SYSTEM+psexec' } else { 'per-user' })))
            if (-not $owner.User) {
                return $this.Fail('no signed-in console user was found, so there is no logon to start DONUT at.')
            }
            $spec = $this.BuildLaunchSpec([Environment]::ProcessPath, $this.SourceRoot)
            if ($owner.IsSystem) {
                $psexec = $this.FindPsExec()
                if (-not $psexec) {
                    return $this.Fail('psexec.exe was not found (src\Tools or PATH) - the SYSTEM-hosted startup task needs it to reach your desktop.')
                }
                $shim = Join-Path $this.SourceRoot 'Scripts\Start-DonutInConsoleSession.ps1'
                $spec = [StartupTaskService]::BuildSystemSpec($psexec, $shim, $spec)
            }
            $name = [StartupTaskService]::TaskNameFor($owner.User)
            $existing = $this.GetExistingTask($name)
            switch ($this.ReconcileDecision($enabled, $existing, $spec)) {
                'Register' { $this.RegisterTask($name, $owner.User, $owner.IsSystem, $spec) }
                'Reregister' { $this.RegisterTask($name, $owner.User, $owner.IsSystem, $spec) }
                'Unregister' { $this.UnregisterTask($name) }
                default { }
            }
            # A task named for a previous owner would linger (and never fire) forever.
            $this.RemoveStaleTasks($name)
            return $true
        }
        catch {
            $this.Logger.LogException("Startup task update failed", $_)
            return $this.Fail($_.Exception.Message)
        }
    }

    # Records why Apply failed and toasts it (when a toast service is attached).
    hidden [bool] Fail([string]$reason) {
        $this.LastFailure = $reason
        $this.Logger.LogError("Startup task update failed: $reason")
        if ($this.Toast) {
            $this.Toast.ShowError('Startup task', "Could not update the startup task - $reason")
        }
        return $false
    }

    # --- CIM/identity seams (overridden by the test fake) ---

    hidden [hashtable] GetProcessIdentity() {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return @{ Name = $identity.Name; IsSystem = $identity.IsSystem }
    }

    # WHO IS SIGNED IN to the desktop DONUT is showing on - never who DONUT runs as.
    # Over-the-shoulder UAC (sign in as a standard user, elevate DONUT with a separate
    # admin account) puts both in the SAME session, so the session's own explorer.exe
    # owner is the authoritative answer; Win32_ComputerSystem.UserName is the fallback
    # for a session-0 (SYSTEM) host, where there is no explorer to ask.
    hidden [string] GetInteractiveUser() {
        $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $owner = $this.GetSessionOwner($session)
        if ($owner) { return $owner }
        $reported = $this.GetComputerSystemUser()
        if ($reported) { return $reported }
        return $this.GetSessionOwner($null)
    }

    hidden [string] GetComputerSystemUser() {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.UserName) { return [string]$cs.UserName }
        return $null
    }

    # explorer.exe's owner in $sessionId (any session when $null) = that desktop's user.
    hidden [string] GetSessionOwner([object]$sessionId) {
        $filter = "Name='explorer.exe'"
        if ($null -ne $sessionId) { $filter += " AND SessionId=$sessionId" }
        $explorer = Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $explorer) { return $null }
        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
        if (-not $owner -or -not $owner.User) { return $null }
        return "$($owner.Domain)\$($owner.User)"
    }

    # psexec for the SYSTEM lane's task action: bundled Tools copy first, then PATH.
    # The absolute path is baked in at register time - SYSTEM's logon PATH may differ.
    hidden [string] FindPsExec() {
        foreach ($exe in @('psexec.exe', 'PsExec64.exe')) {
            $bundled = Join-Path (Join-Path $this.SourceRoot 'Tools') $exe
            if (Test-Path -LiteralPath $bundled) { return $bundled }
        }
        $cmd = Get-Command psexec.exe -ErrorAction SilentlyContinue
        if ($cmd) { return [string]$cmd.Source }
        return $null
    }

    hidden [object] GetExistingTask([string]$name) {
        return Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    }

    # $triggerUser is whose LOGON fires the task (always the console user); $asSystem
    # decides what it RUNS AS. Conflating the two bound the trigger to an account that
    # never logs on, leaving the task Ready forever.
    hidden [void] RegisterTask([string]$name, [string]$triggerUser, [bool]$asSystem, [hashtable]$spec) {
        $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $triggerUser
        if ($asSystem) {
            # psexec -i needs the logon session's desktop up before the task fires.
            $trigger.Delay = 'PT15S'
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        }
        else {
            $principal = New-ScheduledTaskPrincipal -UserId $triggerUser -RunLevel Highest -LogonType Interactive
        }
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        # -ErrorAction Stop: an access-denied register is non-terminating by default and
        # would slip past Apply's try/catch (false success, no toast).
        Register-ScheduledTask -TaskName $name -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $lane = if ($asSystem) { ' (SYSTEM + psexec relaunch)' } else { '' }
        $this.Logger.LogInfo("Registered startup task $name, triggered by $triggerUser's logon$lane.")
    }

    hidden [void] UnregisterTask([string]$name) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        $this.Logger.LogInfo("Unregistered startup task $name.")
    }

    # Drops DONUT-* startup tasks left under a previous owner's name. Scoped hard:
    # never DONUT-LensAgent (PersonLensService owns it), and only tasks whose action
    # actually launches THIS install - best-effort, a failure here is not a toggle failure.
    hidden [void] RemoveStaleTasks([string]$keepName) {
        $exe = [Environment]::ProcessPath
        foreach ($task in @(Get-ScheduledTask -TaskName 'DONUT-*' -ErrorAction SilentlyContinue)) {
            if ($task.TaskName -ieq $keepName -or $task.TaskName -ieq 'DONUT-LensAgent') { continue }
            $action = @($task.Actions)[0]
            if ($null -eq $action) { continue }
            $launchesUs = ($action.Execute -ieq $exe) -or ([string]$action.Arguments -like "*$exe*") -or
                          ([string]$action.Arguments -like '*Start-Donut.ps1*')
            if (-not $launchesUs) { continue }
            try {
                Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
                $this.Logger.LogInfo("Removed stale startup task $($task.TaskName).")
            }
            catch { $this.Logger.LogWarning("Could not remove stale startup task $($task.TaskName): $($_.Exception.Message)") }
        }
    }
}
