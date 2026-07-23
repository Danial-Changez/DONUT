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
        # 8 concurrent superset warms (AD + Lens graph + binary module imports per
        # runspace) contend the process-wide module-analysis/loader locks and blew
        # the barrier on real hardware ("Pre-warmed 0 of 8", every feature starved).
        Test-Path (Join-Path $ScriptsDir 'Warm-Runspace.ps1') | Should -BeFalse -Because (
            "the superset warm script was removed; AD/Lens graphs warm via the " +
            "deferred finder warms, never behind the startup barrier")
        (Get-Content $Coordinator -Raw) | Should -Not -Match 'Warm-Runspace' -Because (
            "WarmPool must submit the worker pass, not a graph superset")
    }

    It "the WarmRunspace pass warms the DCU scan launch path" {
        # A live scan once wedged silently between "Starting preliminary scan" and the
        # psexec launch - the first-ever execution of the InvokePsExec path on a live
        # job. The warm must pre-execute the CPU half of that path (arg build,
        # remote-script build + encode) so those first-use costs land on the barrier.
        $services = Join-Path $PSScriptRoot '../../src/Services/WorkerServices.psm1'
        $raw = Get-Content $services -Raw
        $raw | Should -Match '\[void\]\s+WarmScanLaunchPath\(\)' -Because (
            "the scan launch path must have a warm pass or its first live execution " +
            "pays every first-use cost mid-job")
        $raw | Should -Match '\$this\.WarmScanLaunchPath\(\)' -Because (
            "WarmScanLaunchPath must actually be invoked from the WarmRunspace branch")
    }

    It "the scan launch-path warm performs no network operation" {
        # The warm once probed loopback 445 "to bind the socket stack". Security
        # stacks hook socket connects, and the hook can block INSIDE the native call
        # - below any PowerShell-level timeout - so every warm job hung, WarmPool's
        # 30 s barrier lapsed, and the app never showed a window. This warm stays
        # pure CPU; nothing unproven goes under the barrier.
        $services = Join-Path $PSScriptRoot '../../src/Services/WorkerServices.psm1'
        $raw = Get-Content $services -Raw
        $raw -match '(?s)\[void\] WarmScanLaunchPath\(\)(.*?)\r?\n    \}' | Should -BeTrue
        $Matches[1] | Should -Not -Match 'Probe|TcpClient|Socket|Reachable|Connect' -Because (
            "no socket/network call may run inside the scan-path warm - a hooked " +
            "connect wedges below PowerShell and once held app startup hostage")
    }

    It "the runtime-assembly warm exercises the DNS/TCP/CIM stacks, not just loads" {
        # The recipe of every known-good build (64dbec8 through 36c7536): exercise
        # each heavy stack against localhost so a live job's first resolve, socket,
        # or CIM call is never also this runspace's first. A loads-only variant
        # shipped once, and the first live resolve-IP and disk-scan jobs - whose
        # opening act is exactly a first DNS/socket connect - stopped completing.
        # Wedge risk is carried by WarmPool's barrier (park + reap + capacity
        # compensation), never by removing the exercises.
        $services = Join-Path $PSScriptRoot '../../src/Services/WorkerServices.psm1'
        $raw = Get-Content $services -Raw
        $raw -match '(?s)\[void\] WarmRuntimeAssemblies\(\)(.*?)\r?\n    \}' | Should -BeTrue
        foreach ($exercise in 'Resolve-DnsName', 'TcpClient', 'New-CimSession ') {
            $Matches[1] | Should -Match ([regex]::Escape($exercise)) -Because (
                "dropping the $($exercise.Trim()) first-use warm-up regressed the " +
                "first live resolve/disk-scan job on machines where 64dbec8 worked")
        }
    }

    It "startup submits only the warm shells + DC warm; other pool work is deferred" {
        # At 64dbec8 (known good) startup submitted exactly the warm shells and the
        # DC warm. The stampede that accreted afterwards - one live-LDAP finder warm
        # per forest, the Lens agent bring-up (20 s mutex + ScheduledTasks COM), the
        # startup-task heal (whose own retry comment records the 'Collection was
        # modified' module-analysis race) - all inside the same two seconds contended
        # the process-wide module-analysis/loader locks against the warm barrier, and
        # pool jobs froze for minutes in pure-CPU segments.
        $homePresenter = Join-Path $PSScriptRoot '../../src/UI/Presenters/HomePresenter.psm1'
        $rawHome = Get-Content $homePresenter -Raw
        $rawHome | Should -Match 'StartDeferredWarms' -Because (
            "finder/Lens warms must wait for the DC warm (or the fallback timer)")
        $rawHome | Should -Match 'DeferredWarmTimer' -Because (
            "a fallback must still release the warms when the DC warm never lands")
        (Get-Content $Coordinator -Raw) | Should -Match 'StartDeferredWarms' -Because (
            "CompleteResolve must release the deferred warms when the DC warm lands")
        $donutApp = Join-Path $ScriptsDir 'DonutApp.ps1'
        (Get-Content $donutApp -Raw) |
            Should -Match '(?s)DispatcherTimer.{0,800}ApplyStartupTask' -Because (
            "the startup-task heal must run on a deferral timer, never as a " +
            "boot-time pool job racing the warm shells")
    }

    It "WarmPool never blocks on - and never kills - a warm job that missed the deadline" {
        # Dispose/Stop on a still-running pipeline waits for it synchronously; a
        # pipeline wedged in a hooked native call never yields, and that hang shipped
        # once (the UI thread, pre-window). Async-stopping shipped too - and it
        # destroyed warms that were merely SLOW, wasting the work seconds before it
        # finished. The contract: the barrier stops the WAITING, never the WORK -
        # park the shell running, reap it when it completes, give back the
        # compensating capacity.
        $raw = Get-Content $Coordinator -Raw
        $raw | Should -Not -Match 'BeginStop|\.Stop\(' -Because (
            "stopping a parked warm either blocks forever (wedged) or throws away " +
            "nearly finished warm work (slow)")
        $raw | Should -Match 'AbandonedWarmShells' -Because (
            "unfinished warm shells must be parked, not disposed inline - Dispose " +
            "waits on the pipeline synchronously and can block forever")
        $raw | Should -Match 'ReapWarmShells' -Because (
            "parked warms must be harvested on completion so the runspace counts as " +
            "warmed and the raised pool capacity is restored")
        $homePresenter = Join-Path $PSScriptRoot '../../src/UI/Presenters/HomePresenter.psm1'
        (Get-Content $homePresenter -Raw) | Should -Match 'ReapWarmShells' -Because (
            "something must actually drive the reap - the job pump tick is the hook")
    }

    It "WarmPool raises pool capacity when warm jobs miss the barrier" {
        # Parked warm shells hold their runspaces until they finish - never, if
        # wedged - so without compensation the pool starves and every job (the DC
        # resolve first) queues forever. The lapse path must grow the max so real
        # work always finds a runspace.
        $raw = Get-Content $Coordinator -Raw
        $raw | Should -Match 'SetMaxRunspaces' -Because (
            "a lapsed barrier must self-heal the pool instead of leaving the app " +
            "alive but unable to run any job")
    }
}
