<#
    Regression guards for the startup warm - the gate the whole app sits behind.

    The barrier warm is the 64dbec8 recipe: ONE real worker pass (RemoteWorker.ps1
    Mode='WarmRunspace') per pool runspace - script compile, real pipeline
    construction, runtime-assembly exercises, scan-path prewarm - and nothing more.
    History, so nobody re-learns it the hard way:

    - Pre-loading a module graph WITHOUT executing the worker once left a
      runspace's first RemoteWorker execution to a live job, which wedged silently
      (the machine-list regression). The worker pass is mandatory.
    - A SUPERSET warm (full AD + Lens graph + binary CIM/ScheduledTasks imports
      per runspace, added 07-20 alongside the agent-AD work) multiplied the
      per-shell workload; 8 concurrent copies contend the process-wide
      module-analysis/loader locks, the shells stopped fitting the 30 s barrier
      at all ("Pre-warmed 0 of 8"), and every feature queued behind a starved
      pool. The AD/Lens graphs warm via the DEFERRED finder warms instead
      (HomePresenter.StartDeferredWarms); a first mid-scan search on an unwarmed
      runspace may pay a one-time cold-load - a deliberate, documented trade.
    - The barrier itself must never block on, kill, or waste a late warm, and a
      lapsed barrier must leave the pool usable (park + reap + capacity heal).
#>

Describe "Runspace warm coverage" {

    BeforeAll {
        $script:ScriptsDir = Join-Path $PSScriptRoot '../../src/Scripts'
        $script:Coordinator = Join-Path $PSScriptRoot '../../src/UI/Presenters/ResolutionCoordinator.psm1'

        # Scripts dispatched onto the shared runspace pool (via StartPoolScript / AsyncJob).
        $script:PoolWorkers = @(
            'RemoteWorker.ps1'      # scan / apply / inventory / disk / resolve
            'AdSearchWorker.ps1'    # AD finder fan-out
            'LensLookupWorker.ps1'  # user Lens lookup + agent warm/teardown
            'AdUnlockWorker.ps1'    # inline account unlock
        )
    }

    It "every pool worker script exists" {
        foreach ($w in $PoolWorkers) {
            Test-Path (Join-Path $ScriptsDir $w) | Should -BeTrue -Because "$w is listed as a pool worker"
        }
    }

    It "WarmPool runs the real worker pass per runspace (the 64dbec8 recipe)" {
        $raw = Get-Content $Coordinator -Raw
        $raw | Should -Match 'PrepareWarmRunspace' -Because (
            "the barrier must execute RemoteWorker.ps1 Mode='WarmRunspace' per runspace - " +
            "a runspace whose first worker execution lands on a real job wedges it silently")
    }

    It "the barrier never runs a superset graph warm" {
        # 8 concurrent superset warms contend the loader locks and blew the barrier. See header.
        Test-Path (Join-Path $ScriptsDir 'Warm-Runspace.ps1') | Should -BeFalse -Because (
            "the superset warm script was removed; AD/Lens graphs warm via the " +
            "deferred finder warms, never behind the startup barrier")
        (Get-Content $Coordinator -Raw) | Should -Not -Match 'Warm-Runspace' -Because (
            "WarmPool must submit the worker pass, not a graph superset")
    }

    It "nothing unproven goes back under the barrier" {
        # Three re-introductions, each of which shipped once and hung startup:
        # - a socket probe in the scan-path warm, which wedges below any PowerShell timeout
        # - Stop/BeginStop on a parked warm, which blocks forever or discards near-done work
        # - accumulating warm handles before waiting, which deadlocks the module-load lock
        $services = Get-Content (Join-Path $PSScriptRoot '../../src/Services/WorkerServices.psm1') -Raw
        $services -match '(?s)\[void\] WarmScanLaunchPath\(\)(.*?)\r?\n    \}' | Should -BeTrue
        $Matches[1] | Should -Not -Match 'Probe|TcpClient|Socket|Reachable|Connect' -Because (
            "no socket/network call may run inside the scan-path warm")

        $raw = Get-Content $Coordinator -Raw
        $raw | Should -Not -Match 'BeginStop|\.Stop\(' -Because (
            "the barrier stops the waiting, never the work - park, reap, compensate")
        $raw | Should -Not -Match '\$handles\.Add' -Because (
            "WarmPool must wait for each shell before submitting the next")
    }
}
