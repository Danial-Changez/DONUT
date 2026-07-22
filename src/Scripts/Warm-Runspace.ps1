#Requires -Version 5.1
<#
.SYNOPSIS
    Runspace-pool warm job: loads every pool worker's module graph, then runs the
    real worker pipeline once so nothing cold-executes on the hot path.

.DESCRIPTION
    Cold-loading a worker's class/module graph takes the process-wide CLR loader
    lock; if a job cold-loads while the WPF dispatcher is rendering (e.g. during a
    scan), the UI freezes until the load finishes. ResolutionCoordinator.WarmPool
    runs this script once per pool runspace at startup - concurrently, behind a
    barrier - so every runspace has the COMPLETE worker graph resident before any
    real job runs.

    The `using module` set below must stay a superset of every pool worker's imports
    (RemoteWorker.ps1, AdSearchWorker.ps1, LensLookupWorker.ps1, AdUnlockWorker.ps1);
    RunspaceWarmCoverage.Tests.ps1 fails if a worker imports a module this doesn't.

    Loading the class graph alone is NOT enough. A runspace whose FIRST
    RemoteWorker.ps1 execution happens on a real job wedges that job silently: the
    startup DC discovery never logs a line, HostResolver never gets an active DC, and
    every resolve/inventory quietly no-ops (the machine-list regression introduced
    when 9304ab3 replaced the per-runspace worker pass with a graph-only warm). So
    after the imports the body (1) exercises the binary CIM + ScheduledTasks module
    machinery the workers and the Lens-agent bring-up bind, then (2) invokes
    RemoteWorker.ps1 in Mode='WarmRunspace' - compiling the worker script and
    constructing its real pipeline (LogService / AppConfig / ExecutionService +
    WarmRuntimeAssemblies) in this runspace, exactly what the pre-9304ab3 WarmPool
    did per runspace.

.PARAMETER SourceRoot
    The 'src' root; locates RemoteWorker.ps1 for the worker warm pass.

.PARAMETER LogsDir
    Local logs directory, threaded to the worker pass so its warm log lines land
    in the app's Donut.log.

.PARAMETER ReportsDir
    Local reports directory, threaded to the worker pass.

.NOTES
    Runs on a pool runspace, never the WPF dispatcher. The warm is LOCAL only
    (localhost CIM / task / assembly warm-ups); it must never depend on the
    DC / SCCM / AD being up. WarmPool's barrier parks an overrunning warm and
    compensates capacity, so a slow or stuck warm cannot hold up the app.
#>
using module "..\Services\WorkerServices.psm1"
using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Services\PersonLensService.psm1"
using module "..\Models\AppConfig.psm1"
using module "..\Core\ConfigManager.psm1"
using module "..\Core\LogService.psm1"
using module "..\Models\AdSearchResult.psm1"

param(
    [string] $SourceRoot = '',
    [string] $LogsDir = '',
    [string] $ReportsDir = ''
)

# A warm step that fails leaves this runspace to cold-load on a real job, so every
# failure below is logged, not swallowed. No LogsDir (test harnesses) -> no-op logger.
$warmLog = if ([string]::IsNullOrWhiteSpace($LogsDir)) { [NullLogService]::new() }
else { [LogService]::new($LogsDir) }

# The binary CIM + ScheduledTasks stacks (hit by the workers and
# PersonLensService.EnsureAgent) take the process-wide CLR loader lock on their FIRST
# call - importing alone doesn't pay that cost - so invoke each cheap, local cmdlet
# here instead of on a live pool job. This is the recipe of every known-good build
# (36c7536: DC discovery completed; earlier trees: resolve + disk scan worked for
# weeks). An imports-only variant shipped once and the first live jobs stopped
# completing. A probe that wedges here can no longer hurt the app: WarmPool's
# barrier parks an overrunning warm (still running) and compensates capacity.
try {
    Import-Module CimCmdlets, ScheduledTasks -ErrorAction Stop
    $cimProbe = @{
        ClassName   = 'Win32_Process'
        Filter      = "Handle=$PID"
        ErrorAction = 'Stop'
    }
    [void](Get-CimInstance @cimProbe)
    # The probe task never exists: the miss itself pays the ScheduledTasks loader hit,
    # which is all this call is for - so the expected not-found is not worth logging.
    [void](Get-ScheduledTask -TaskName 'DONUT-loader-warm-probe' -ErrorAction SilentlyContinue)
}
catch {
    $warmLog.LogWarning(
        "Runspace warm: CIM/ScheduledTasks pre-load failed - first use will cold-load: " +
        $_.Exception.Message)
}

# Run the real worker once (Mode='WarmRunspace' -> WarmRuntimeAssemblies): the script
# compiles and its whole pipeline constructs in THIS runspace, so the first real job -
# the startup DC discovery included - never cold-executes RemoteWorker here.
$worker = Join-Path $SourceRoot 'Scripts\RemoteWorker.ps1'
if (Test-Path $worker) {
    try {
        $warmArgs = @{
            HostName   = ''
            JobType    = 'Resolve'
            Options    = @{ Mode = 'WarmRunspace' }
            ResolvedIp = ''
            SourceRoot = $SourceRoot
            LogsDir    = $LogsDir
            ReportsDir = $ReportsDir
        }
        & $worker @warmArgs | Out-Null
    }
    catch {
        $warmLog.LogWarning(
            "Runspace warm: worker warm pass failed - first real job cold-executes " +
            "RemoteWorker here: $($_.Exception.Message)")
    }
}
else {
    $warmLog.LogWarning(
        "Runspace warm: RemoteWorker.ps1 not found at $worker - worker warm pass skipped.")
}
