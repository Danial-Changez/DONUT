#Requires -Version 5.1
<#
.SYNOPSIS
    Runspace-pool warm job: loads every pool worker's module graph, then returns.

.DESCRIPTION
    Cold-loading a worker's class/module graph takes the process-wide CLR loader
    lock; if a job cold-loads while the WPF dispatcher is rendering (e.g. during a
    scan), the UI freezes until the load finishes. ResolutionCoordinator.WarmPool
    runs this script once per pool runspace at startup - concurrently, behind a
    barrier - so every runspace has the COMPLETE worker graph resident before any
    real job runs, and nothing cold-loads on the hot path.

    The `using module` set below must stay a superset of every pool worker's imports
    (RemoteWorker.ps1, LensLookupWorker.ps1, AdUnlockWorker.ps1);
    RunspaceWarmCoverage.Tests.ps1 fails if a worker imports a module this doesn't.

    The body then Import-Modules the binary CIM/ScheduledTasks modules that
    PersonLensService.EnsureAgent loads implicitly (Get-CimInstance / *-ScheduledTask).
    Those aren't `using module` imports, so the class graph above misses them - and
    cold-loading them on the finder's search path took the loader lock and froze the UI.

.PARAMETER SourceRoot
    Accepted for call-site symmetry with the other pool workers; unused (the warm's
    only effect is the imports above).

.NOTES
    Runs on a pool runspace, never the WPF dispatcher. No agent/network/directory
    work: loading the graph must not depend on a reachable DC / SCCM / AD.
#>
using module "..\Services\WorkerServices.psm1"
using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Services\PersonLensService.psm1"
using module "..\Models\AppConfig.psm1"
using module "..\Core\ConfigManager.psm1"
using module "..\Models\AdSearchResult.psm1"

param(
    [string] $SourceRoot = ''
)

# EnsureAgent cold-loads the CIM + ScheduledTasks stacks (Get-CimInstance / *-ScheduledTask),
# and that load takes the process-wide CLR loader lock. Importing isn't enough - the real hit
# lands on the FIRST call, not on Import-Module - so actually invoke each cheap, local cmdlet
# here on the warm barrier. Otherwise the load happens on a pool runspace during startup and
# stalls the WPF dispatcher (the "UI dispatcher was blocked / loader-lock stall" warning).
Import-Module CimCmdlets, ScheduledTasks -ErrorAction SilentlyContinue
try { [void](Get-CimInstance -ClassName Win32_Process -Filter "Handle=$PID" -ErrorAction SilentlyContinue) } catch { }
try { [void](Get-ScheduledTask -TaskName 'DONUT-loader-warm-probe' -ErrorAction SilentlyContinue) } catch { }
