using module "..\Core\ElevationContext.psm1"
using module "..\Core\LogService.psm1"

<#
.SYNOPSIS
    Registers/unregisters the "start DONUT with Windows" scheduled task.

.DESCRIPTION
    A Task Scheduler task starts DONUT minimized to the tray at the console user's
    logon, running as that user at RunLevel Highest.

.NOTES
    RunLevel Highest, not Limited. Both are the console user - the difference is only
    which of that account's tokens the task gets. On an admin console account Highest
    starts DONUT elevated with no logon-time UAC prompt, which is what runAsAdmin
    defaults to wanting; Limited started it de-elevated and left it to relaunch itself
    through a consent prompt at logon, which is the error this replaced. On a non-admin
    console account Highest has no effect: it degrades to that account's standard token
    and DONUT elevates on demand exactly as before, so the setting is safe either way.

    There used to be a second lane: when DONUT ran as a separate admin account, a
    task could not start it elevated (an Interactive principal needs a logon session
    that account does not have, and RunLevel Highest on a non-admin console user
    degrades to a standard token), so a SYSTEM task relaunched DONUT into the console
    session through psexec. That lane is gone, and deleting it fixed a bug rather
    than only simplifying: running as SYSTEM meant authenticating on the network as
    the MACHINE account, which has no rights on fleet targets, so the autostarted
    instance painted a working UI and then failed every remote job on access denied.
    A de-elevated instance that elevates on demand gets a real admin token instead.
    Do not reintroduce it.

    A task triggered by an account that never logs on stays Ready forever, which is
    why the trigger is always the console user. Never derive the run-as account from
    $env: - under SYSTEM that names a nonexistent account Task Scheduler rejects
    ("No mapping between account names and security IDs").

    Registering a task for a principal still needs elevation, so the setting toggle
    is gated behind MainPresenter's elevation prompt like any other admin action.

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
    [string] $LastFailure  # Why the last Apply returned $false, for the caller's toast

    StartupTaskService([LogService]$logger, [object]$toast, [string]$sourceRoot) {
        $this.Logger = $logger
        $this.Toast = $toast
        $this.SourceRoot = $sourceRoot
    }

    # Pure: per-user task name from the owner account ("PROD\jdoe" -> "DONUT-jdoe").
    static [string] TaskNameFor([string]$user) {
        return "DONUT-$(($user -split '\\')[-1])"
    }

    # Whose logon fires the task: always the signed-in console user, '' when nobody is.
    [hashtable] ResolveOwner() {
        return @{ User = $this.GetInteractiveUser() }
    }

    # Pure: the task action for the current host. A pwsh.exe host (dev) re-launches the
    # script with -Tray, and any other exe is the launcher and takes --tray.
    [hashtable] BuildLaunchSpec([string]$processPath, [string]$sourceRoot) {
        $leaf = Split-Path $processPath -Leaf
        if ($leaf -ieq 'pwsh.exe') {
            $script = Join-Path $sourceRoot 'Start-Donut.ps1'
            return @{
                Execute          = $processPath
                Argument         = "-Sta -ExecutionPolicy Bypass -File `"$script`" -Tray"
                WorkingDirectory = $sourceRoot
            }
        }
        # Without one, Task Scheduler starts DONUT in %windir%\system32.
        return @{
            Execute          = $processPath
            Argument         = '--tray'
            WorkingDirectory = (Split-Path $processPath -Parent)
        }
    }

    # Pure: what Apply should do. 'Register' (wanted, absent), 'Reregister' (wanted, app
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
            # WorkingDirectory too, or tasks registered before it existed never re-register.
            return ($action.Execute -ne $spec.Execute) -or ($action.Arguments -ne $spec.Argument) -or
            ($action.WorkingDirectory -ne $spec.WorkingDirectory)
        }
        catch { return $true }
    }

    # Thin shell: reconcile the desired state against the installed task and apply it.
    # Returns $true on success or no-op. A failure logs and toasts the real reason.
    [bool] Apply([bool]$enabled) {
        $this.LastFailure = ''
        try {
            $owner = $this.ResolveOwner()
            # Both values decide whether the task fires, so a dead task stays diagnosable.
            $this.Logger.LogInfo(("Startup task: runs-as '{0}', signed-in console user '{1}'." -f
                    $this.GetProcessIdentity().Name, $owner.User))
            if (-not $owner.User) {
                return $this.Fail('no signed-in console user was found, so there is no logon to start DONUT at.')
            }
            $spec = $this.BuildLaunchSpec([Environment]::ProcessPath, $this.SourceRoot)
            $name = [StartupTaskService]::TaskNameFor($owner.User)
            $existing = $this.GetExistingTask($name)
            switch ($this.ReconcileDecision($enabled, $existing, $spec)) {
                'Register' { $this.RegisterTask($name, $owner.User, $spec) }
                'Reregister' { $this.RegisterTask($name, $owner.User, $spec) }
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
            $this.Toast.ShowError('Startup Task', "Could not update the startup task: $reason")
        }
        return $false
    }

    # --- CIM/identity seams (overridden by the test fake) ---

    # IsElevated rides along because registering a task for another principal needs it,
    # and the failure toast used to guess at the reason instead of asking.
    hidden [hashtable] GetProcessIdentity() {
        return @{
            Name       = [ElevationContext]::CurrentIdentityName()
            IsSystem   = [ElevationContext]::IsSystem()
            IsElevated = [ElevationContext]::IsElevated()
        }
    }

    # Who is signed in to the desktop DONUT shows on, never who DONUT runs as. The
    # session's explorer.exe owner answers, and Win32_ComputerSystem covers session 0.
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

    hidden [object] GetExistingTask([string]$name) {
        return Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    }

    # One lane: the console user's own logon, as that user. RunLevel Highest so an admin
    # console account starts elevated with no logon-time UAC prompt. See .NOTES.
    hidden [void] RegisterTask([string]$name, [string]$triggerUser, [hashtable]$spec) {
        $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument `
            -WorkingDirectory $spec.WorkingDirectory
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $triggerUser
        $principal = New-ScheduledTaskPrincipal -UserId $triggerUser -RunLevel Highest -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        # An access-denied register is non-terminating and would slip past Apply's catch.
        Register-ScheduledTask -TaskName $name -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $this.Logger.LogInfo("Registered startup task $name, triggered by $triggerUser's logon.")
    }

    hidden [void] UnregisterTask([string]$name) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        $this.Logger.LogInfo("Unregistered startup task $name.")
    }

    # Drops DONUT-* tasks left under a previous owner's name. Never DONUT-LensAgent,
    # which PersonLensService owns, and only actions that launch this install.
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
