using module "..\Core\LogService.psm1"

<#
.SYNOPSIS
    Registers/unregisters the elevated "start DONUT with Windows" scheduled task.

.DESCRIPTION
    A per-user Task Scheduler task (RunLevel Highest, logon trigger) starts DONUT
    minimized to the tray at logon with no UAC prompt. Registering requires
    elevation, which DONUT already has (PsExec). The task's owner comes from the
    process token, NOT $env: - when DONUT runs as SYSTEM (psexec -s, RMM shells)
    "$env:USERDOMAIN\$env:USERNAME" yields a nonexistent account (PRODUCTION\SYSTEM)
    that Task Scheduler rejects with "No mapping between account names and security
    IDs"; there the task is registered for the signed-in console user instead (the
    explorer-owner pattern PersonLensService.EnsureAgent uses to de-elevate).

.NOTES
    The pure helpers (BuildLaunchSpec, ReconcileDecision, TaskNameFor) are
    unit-tested; Apply is the thin CIM shell that dispatches on the decision and
    never throws to the caller (failure logs + toasts, real reason in LastFailure).
    The CIM/identity seams (GetExistingTask/RegisterTask/UnregisterTask,
    GetProcessIdentity/GetInteractiveUser) are overridable so a fake subclass can
    capture which ran without touching Task Scheduler or WindowsIdentity.
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

    # The account the task should run as: the process token's user, or - when the
    # token is SYSTEM - the signed-in console user. Empty when neither resolves.
    [string] ResolveTargetUser() {
        $identity = $this.GetProcessIdentity()
        if (-not $identity.IsSystem) { return $identity.Name }
        return $this.GetInteractiveUser()
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
            $user = $this.ResolveTargetUser()
            if (-not $user) {
                return $this.Fail('DONUT is running as SYSTEM and no signed-in user was found to own the startup task.')
            }
            $name = [StartupTaskService]::TaskNameFor($user)
            $spec = $this.BuildLaunchSpec([Environment]::ProcessPath, $this.SourceRoot)
            $existing = $this.GetExistingTask($name)
            switch ($this.ReconcileDecision($enabled, $existing, $spec)) {
                'Register' { $this.RegisterTask($name, $user, $spec) }
                'Reregister' { $this.RegisterTask($name, $user, $spec) }
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

    hidden [object] GetExistingTask([string]$name) {
        return Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    }

    hidden [void] RegisterTask([string]$name, [string]$user, [hashtable]$spec) {
        $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        # -ErrorAction Stop: an access-denied register is non-terminating by default and
        # would slip past Apply's try/catch (false success, no toast).
        Register-ScheduledTask -TaskName $name -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $this.Logger.LogInfo("Registered startup task $name for $user.")
    }

    hidden [void] UnregisterTask([string]$name) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        $this.Logger.LogInfo("Unregistered startup task $name.")
    }
}
