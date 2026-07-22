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
    after the imports the body (1) imports the binary CIM + ScheduledTasks modules
    the workers and the Lens-agent bring-up bind, then (2) invokes
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
    Runs on a pool runspace, never the WPF dispatcher. The warm is LOAD-ONLY
    (module + assembly loads, script compilation); it must never depend on the
    DC / SCCM / AD being up, and it may never open a connection of any kind -
    not even to this machine. See the block comment above the module imports.
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

# Import the binary CIM + ScheduledTasks modules (hit by the workers and
# PersonLensService.EnsureAgent) so their assemblies are resident before any real job
# binds them. IMPORTS ONLY - no query may ever run here. This block once made two
# "cheap, local" first-call probes (a WMI query for our own PID and a task lookup) to
# prepay the first-call loader hit; both are RPC connects under the hood, and a
# security stack's hook on those connects wedged them below PowerShell - unstoppably,
# the pool still 0/8 free 90 s after the stop requests - on 7-8 of 8 warm runspaces,
# starving the DC resolve and every other job behind a dead pool. The first-call cost
# the probes prepaid now lands on a live pool job, bounded and off the startup barrier.
try {
    Import-Module CimCmdlets, ScheduledTasks -ErrorAction Stop
}
catch {
    $warmLog.LogWarning(
        "Runspace warm: CIM/ScheduledTasks module pre-load failed - first use pays " +
        "the loader hit on a live job: " + $_.Exception.Message)
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
