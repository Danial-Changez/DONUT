using module "..\Core\LogService.psm1"

<#
.SYNOPSIS
    Registers/unregisters the elevated "start DONUT with Windows" scheduled task.

.DESCRIPTION
    A per-user Task Scheduler task (RunLevel Highest, logon trigger) starts DONUT
    minimized to the tray at logon with no UAC prompt. Registering requires
    elevation, which DONUT already has (PsExec). The pure helpers (BuildLaunchSpec,
    ReconcileDecision) are unit-tested; Apply is the thin CIM shell that dispatches
    on the decision and never throws to the caller (failure logs + toasts).

.NOTES
    The CIM seams (GetExistingTask/RegisterTask/UnregisterTask) are overridable so
    a fake subclass can capture which ran without touching Task Scheduler. Confirm
    on the target OS that -ExecutionTimeLimit ([TimeSpan]::Zero) disables the limit;
    if the cmdlet rejects it, fall back to a schtasks XML definition.
#>
class StartupTaskService {
    [LogService] $Logger
    [object] $Toast        # ToastService, duck-typed and optional (null in headless runs)
    [string] $SourceRoot

    StartupTaskService([LogService]$logger, [object]$toast, [string]$sourceRoot) {
        $this.Logger = $logger
        $this.Toast = $toast
        $this.SourceRoot = $sourceRoot
    }

    static [string] TaskName() {
        return "DONUT-$env:USERNAME"
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
    # Returns $true on success/no-op; a failure (usually not elevated) logs+toasts, $false.
    [bool] Apply([bool]$enabled) {
        try {
            $spec = $this.BuildLaunchSpec([Environment]::ProcessPath, $this.SourceRoot)
            $existing = $this.GetExistingTask()
            switch ($this.ReconcileDecision($enabled, $existing, $spec)) {
                'Register' { $this.RegisterTask($spec) }
                'Reregister' { $this.RegisterTask($spec) }
                'Unregister' { $this.UnregisterTask() }
                default { }
            }
            return $true
        }
        catch {
            $this.Logger.LogException("Startup task update failed", $_)
            if ($this.Toast) {
                $this.Toast.ShowError('Startup task',
                    'Could not update the startup task - is DONUT running as administrator?')
            }
            return $false
        }
    }

    # --- CIM seams (overridden by the test fake) ---

    hidden [object] GetExistingTask() {
        return Get-ScheduledTask -TaskName ([StartupTaskService]::TaskName()) -ErrorAction SilentlyContinue
    }

    hidden [void] RegisterTask([hashtable]$spec) {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        # -ErrorAction Stop: an access-denied register is non-terminating by default and
        # would slip past Apply's try/catch (false success, no toast).
        Register-ScheduledTask -TaskName ([StartupTaskService]::TaskName()) -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $this.Logger.LogInfo("Registered startup task $([StartupTaskService]::TaskName()).")
    }

    hidden [void] UnregisterTask() {
        Unregister-ScheduledTask -TaskName ([StartupTaskService]::TaskName()) -Confirm:$false -ErrorAction Stop
        $this.Logger.LogInfo("Unregistered startup task $([StartupTaskService]::TaskName()).")
    }
}
