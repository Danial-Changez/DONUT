using module "..\Core\LogService.psm1"

<#
.SYNOPSIS
    Registers/unregisters the elevated "start DONUT with Windows" scheduled task.

.DESCRIPTION
    A Task Scheduler task starts DONUT minimized to the tray at logon with no UAC
    prompt. Registering requires elevation, which DONUT already has. Two lanes,
    picked by the process token (never $env: - under SYSTEM it names a nonexistent
    account that Task Scheduler rejects with "No mapping between account names and
    security IDs"):
    - Named admin token: a per-user task (RunLevel Highest, Interactive logon
      trigger) running as that account.
    - SYSTEM token (psexec -s, RMM shells): the console user may not be an admin,
      so a per-user task cannot relaunch elevated (CreateProcess fails with
      ERROR_ELEVATION_REQUIRED against the launcher's requireAdministrator
      manifest). Instead the task runs as SYSTEM, triggered at the console user's
      logon, and relaunches DONUT into their session via psexec -s -i -
      reproducing the manual SYSTEM launch. AD access is unchanged: SYSTEM
      authenticates as the machine account either way.

.NOTES
    The pure helpers (BuildLaunchSpec, BuildSystemSpec, ReconcileDecision,
    TaskNameFor) are unit-tested; Apply is the thin CIM shell that dispatches on
    the decision and never throws to the caller (failure logs + toasts, real
    reason in LastFailure). The CIM/identity seams (GetExistingTask/RegisterTask/
    UnregisterTask, GetProcessIdentity/GetInteractiveUser/FindPsExec) are
    overridable so a fake subclass can capture which ran without touching Task
    Scheduler or WindowsIdentity. psexec -i with no session id targets the
    CONSOLE session - an RDP logon will not surface the tray (known limit).
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

    # Whose logon starts DONUT and which lane applies: the token's user, or - when
    # the token is SYSTEM - the signed-in console user (User = '' when none).
    [hashtable] ResolveOwner() {
        $identity = $this.GetProcessIdentity()
        if (-not $identity.IsSystem) { return @{ User = $identity.Name; IsSystem = $false } }
        return @{ User = $this.GetInteractiveUser(); IsSystem = $true }
    }

    # Pure: wraps a host spec in a psexec relaunch for the SYSTEM lane. -s -i puts
    # DONUT (as SYSTEM) on the console session's desktop; -d frees the task slot.
    static [hashtable] BuildSystemSpec([string]$psexecPath, [hashtable]$hostSpec) {
        return @{
            Execute  = $psexecPath
            Argument = "-accepteula -nobanner -s -i -d `"$($hostSpec.Execute)`" $($hostSpec.Argument)"
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
            if (-not $owner.User) {
                return $this.Fail('DONUT is running as SYSTEM and no signed-in user was found to own the startup task.')
            }
            $spec = $this.BuildLaunchSpec([Environment]::ProcessPath, $this.SourceRoot)
            if ($owner.IsSystem) {
                $psexec = $this.FindPsExec()
                if (-not $psexec) {
                    return $this.Fail('psexec.exe was not found (src\Tools or PATH) - the SYSTEM-hosted startup task needs it to reach your desktop.')
                }
                $spec = [StartupTaskService]::BuildSystemSpec($psexec, $spec)
            }
            $name = [StartupTaskService]::TaskNameFor($owner.User)
            $existing = $this.GetExistingTask($name)
            switch ($this.ReconcileDecision($enabled, $existing, $spec)) {
                'Register' { $this.RegisterTask($name, $owner.User, $owner.IsSystem, $spec) }
                'Reregister' { $this.RegisterTask($name, $owner.User, $owner.IsSystem, $spec) }
                'Unregister' { $this.UnregisterTask($name) }
                default { }
            }
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

    # The console session's user via explorer's owner (works from a SYSTEM token,
    # where WindowsIdentity and $env: yield no mappable account).
    hidden [string] GetInteractiveUser() {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $explorer) { return $null }
        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
        if (-not $owner.User) { return $null }
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

    hidden [void] RegisterTask([string]$name, [string]$user, [bool]$asSystem, [hashtable]$spec) {
        $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        if ($asSystem) {
            # psexec -i needs the logon session's desktop up before the task fires.
            $trigger.Delay = 'PT15S'
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        }
        else {
            $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
        }
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        # -ErrorAction Stop: an access-denied register is non-terminating by default and
        # would slip past Apply's try/catch (false success, no toast).
        Register-ScheduledTask -TaskName $name -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $lane = if ($asSystem) { ' (SYSTEM + psexec relaunch)' } else { '' }
        $this.Logger.LogInfo("Registered startup task $name for $user$lane.")
    }

    hidden [void] UnregisterTask([string]$name) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        $this.Logger.LogInfo("Unregistered startup task $name.")
    }
}
