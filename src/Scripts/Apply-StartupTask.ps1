<#
.SYNOPSIS
    Runspace-pool worker that reconciles the "start DONUT with Windows" task.

.DESCRIPTION
    Runs StartupTaskService.Apply off the UI thread (Get/Register-ScheduledTask can
    stall). Returns @{ Ok = <bool> } so the caller can toast on failure. Loaded as a
    file (not AddScript) so its using-module class types resolve in the pool runspace,
    the same pattern RemoteWorker.ps1 uses.

.PARAMETER Enabled
    Desired state: $true registers the task, $false unregisters it.

.PARAMETER SourceRoot
    DONUT's src root, used to build the launch action.

.PARAMETER LogsPath
    Directory for the worker's LogService.
#>
using module "..\Core\LogService.psm1"
using module "..\Services\StartupTaskService.psm1"

param(
    [bool]$Enabled,
    [string]$SourceRoot,
    [string]$LogsPath
)

# ScheduledTasks auto-loads lazily; under the boot-time pool storm its module analysis can
# hit a transient "Collection was modified" race, so import it explicitly with a short retry.
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try { Import-Module ScheduledTasks -ErrorAction Stop; break }
    catch { if ($attempt -lt 5) { Start-Sleep -Milliseconds 200 } }
}

$service = [StartupTaskService]::new([LogService]::new($LogsPath), $null, $SourceRoot)
return @{ Ok = $service.Apply($Enabled) }
