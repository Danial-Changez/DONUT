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
    (RemoteWorker.ps1, AdSearchWorker.ps1, LensLookupWorker.ps1, AdUnlockWorker.ps1);
    RunspaceWarmCoverage.Tests.ps1 fails if a worker imports a module this doesn't.

    The body then warms the RUNTIME assemblies the resolve worker binds - LDAP
    (System.DirectoryServices) + a local DCOM CIM session + DNS + TCP - mirroring
    WorkerServices.WarmRuntimeAssemblies. The pre-9304ab3 WarmRunspace warm did this per
    runspace; 9304ab3 swapped in this class-graph warm and dropped it, so the DC warm's
    GetActiveDomainController cold-loaded those assemblies under the loader lock and hung.

.PARAMETER SourceRoot
    Accepted for call-site symmetry with the other pool workers; unused (the warm's
    only effect is the imports + local runtime warm below).

.NOTES
    Runs on a pool runspace, never the WPF dispatcher. The runtime warm is LOCAL only
    (localhost DNS/TCP/CIM); it must never depend on a reachable DC / SCCM / AD.
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

# Warm the runtime assemblies the resolve worker binds, so the DC warm / host resolves
# never cold-load them under the CLR loader lock (which stalls the job). Mirrors
# WorkerServices.WarmRuntimeAssemblies; all local, so it can't depend on a reachable DC.
try { Resolve-DnsName -Name 'localhost' -QuickTimeout -ErrorAction SilentlyContinue | Out-Null } catch { }
try { $tcp = [System.Net.Sockets.TcpClient]::new(); $tcp.Close() } catch { }
try { Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue } catch { }
try {
    $cimOpt = New-CimSessionOption -Protocol Dcom
    $cim = New-CimSession -SessionOption $cimOpt -ErrorAction Stop
    try { Get-CimInstance -CimSession $cim -ClassName Win32_ComputerSystem -Property Name -ErrorAction Stop | Out-Null } catch { }
    Remove-CimSession -CimSession $cim -ErrorAction SilentlyContinue
}
catch { }
