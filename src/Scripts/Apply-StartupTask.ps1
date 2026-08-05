<#
.SYNOPSIS
    Runspace-pool worker that reconciles the "start DONUT with Windows" task.

.DESCRIPTION
    Runs StartupTaskService.Apply off the UI thread (Get/Register-ScheduledTask can
    stall). Returns @{ Ok = <bool>; Reason = <string> } so the caller can toast the
    real failure. Loaded as a file (not AddScript) so its using-module class types
    resolve in the pool runspace, the same pattern RemoteWorker.ps1 uses.

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

# Lazy auto-load hits a transient "Collection was modified" race under the boot pool storm.
$imported = $false
$importError = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try { Import-Module ScheduledTasks -ErrorAction Stop; $imported = $true; break }
    catch { $importError = $_.Exception.Message; if ($attempt -lt 5) { Start-Sleep -Milliseconds 200 } }
}
if (-not $imported) {
    [LogService]::new($LogsPath).LogError("Startup task worker: ScheduledTasks module failed to load: $importError")
    return @{ Ok = $false; Reason = "the ScheduledTasks module failed to load ($importError)" }
}

$service = [StartupTaskService]::new([LogService]::new($LogsPath), $null, $SourceRoot)
return @{ Ok = $service.Apply($Enabled); Reason = $service.LastFailure }
