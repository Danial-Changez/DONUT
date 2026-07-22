<#
    Regression guard for the "app froze mid-scan during a user search" class of bug.

    Cold-loading a worker's class/module graph takes the process-wide CLR loader
    lock; if a pool job cold-loads while the WPF dispatcher is rendering (e.g. a
    scan is streaming updates), the UI freezes until the load finishes.
    ResolutionCoordinator.WarmPool pre-loads the worker graph into every pool
    runspace at startup so no job cold-loads on the hot path - but that only helps
    if the warm covers EVERY graph a pool worker uses.

    The freeze regressed when the AD-finder (AdSearchWorker -> ActiveDirectoryService)
    and user Lens (LensLookupWorker -> PersonLensService) shipped with graphs the warm
    didn't load. These tests fail if Warm-Runspace.ps1 stops covering any pool
    worker's imports, or if WarmPool stops running it.

    Also guards the sibling regression: pre-loading the graph WITHOUT executing
    RemoteWorker.ps1 once per runspace left the first real worker execution to a live
    job, which wedged it silently - the startup DC discovery never logged, so every
    resolve/inventory no-oped (the machine-list regression). The warm must therefore
    invoke RemoteWorker.ps1 in Mode='WarmRunspace', with the log/report dirs threaded
    through so the worker pass logs into Donut.log.
#>

Describe "Runspace warm coverage" {

    BeforeAll {
        $script:ScriptsDir = Join-Path $PSScriptRoot '../../src/Scripts'
        $script:WarmScript = Join-Path $ScriptsDir 'Warm-Runspace.ps1'
        $script:Coordinator = Join-Path $PSScriptRoot '../../src/UI/Presenters/ResolutionCoordinator.psm1'

        # Scripts dispatched onto the shared runspace pool (via StartPoolScript / AsyncJob).
        # A NEW pool worker must be added here *and* covered by Warm-Runspace.ps1's imports.
        $script:PoolWorkers = @(
            'RemoteWorker.ps1'      # scan / apply / inventory / disk / resolve
            'AdSearchWorker.ps1'    # AD finder fan-out
            'LensLookupWorker.ps1'  # user Lens lookup + agent warm/teardown
            'AdUnlockWorker.ps1'    # inline account unlock
        )

        # The set of module files a script imports via `using module`, as normalized
        # absolute paths (resolved relative to the script, backslashes made portable).
        function Get-UsingModulePaths([string]$scriptPath) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptPath, [ref]$null, [ref]$null)
            $usings = $ast.FindAll({
                    param($n)
                    ($n -is [System.Management.Automation.Language.UsingStatementAst]) -and
                    ($n.UsingStatementKind -eq
                    [System.Management.Automation.Language.UsingStatementKind]::Module)
                }, $true)
            $dir = Split-Path $scriptPath -Parent
            $set = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($u in $usings) {
                if ($null -eq $u.Name) { continue }   # module-spec hashtable form: not used by workers
                $rel = ([string]$u.Name.Value) -replace '\\', '/'
                [void]$set.Add([System.IO.Path]::GetFullPath((Join-Path $dir $rel)))
            }
            return $set
        }
    }

    It "Warm-Runspace.ps1 exists and parses cleanly" {
        Test-Path $WarmScript | Should -BeTrue
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $WarmScript, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
    }

    It "every pool worker script exists" {
        foreach ($w in $PoolWorkers) {
            Test-Path (Join-Path $ScriptsDir $w) | Should -BeTrue -Because "$w is listed as a pool worker"
        }
    }

    It "warms every module graph a pool worker imports (nothing cold-loads on the hot path)" {
        $warm = Get-UsingModulePaths $WarmScript
        foreach ($w in $PoolWorkers) {
            $needed = Get-UsingModulePaths (Join-Path $ScriptsDir $w)
            foreach ($mod in $needed) {
                $warm.Contains($mod) | Should -BeTrue -Because (
                    "$w imports $(Split-Path $mod -Leaf), so Warm-Runspace.ps1 must import it too " +
                    "or that worker cold-loads under the loader lock and can freeze the UI mid-scan")
            }
        }
    }

    It "WarmPool is wired to run Warm-Runspace.ps1" {
        (Get-Content $Coordinator -Raw) | Should -Match 'Warm-Runspace\.ps1'
    }

    It "runs the real worker pipeline once per runspace (Mode='WarmRunspace')" {
        $raw = Get-Content $WarmScript -Raw
        $raw | Should -Match 'RemoteWorker\.ps1' -Because (
            "the warm must execute RemoteWorker.ps1, not just pre-load its graph - " +
            "a runspace whose first worker execution lands on a real job wedges it " +
            "(the silent DC-warm / machine-list regression)")
        $raw | Should -Match "Mode\s*=\s*'WarmRunspace'"
    }

    It "WarmPool threads the log/report dirs the worker warm pass needs" {
        $raw = Get-Content $Coordinator -Raw
        $raw | Should -Match "AddParameter\('LogsDir'"
        $raw | Should -Match "AddParameter\('ReportsDir'"
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
        # 30 s barrier lapsed, and the app never showed a window. The warm must stay
        # pure CPU; first-use socket costs belong on a live job's bounded gate, never
        # on the startup barrier.
        $services = Join-Path $PSScriptRoot '../../src/Services/WorkerServices.psm1'
        $raw = Get-Content $services -Raw
        $raw -match '(?s)\[void\] WarmScanLaunchPath\(\)(.*?)\r?\n    \}' | Should -BeTrue
        $Matches[1] | Should -Not -Match 'Probe|TcpClient|Socket|Reachable|Connect' -Because (
            "no socket/network call may run inside the startup warm - a hooked " +
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

    It "Warm-Runspace.ps1 exercises the CIM/ScheduledTasks machinery, not just imports" {
        # Importing the binary modules does not pay their first-call loader hit; the
        # known-good recipe (36c7536) invokes one cheap local cmdlet per stack. An
        # imports-only variant shipped once alongside the loads-only runtime warm and
        # the first live jobs stopped completing.
        $raw = Get-Content $WarmScript -Raw
        $raw | Should -Match 'Get-CimInstance' -Because (
            "the CIM stack must be exercised, not merely imported, or the first live " +
            "CIM call pays the loader hit mid-job")
        $raw | Should -Match 'Get-ScheduledTask' -Because (
            "the ScheduledTasks stack backs the Lens-agent bring-up and must be " +
            "exercised at warm")
    }

    It "WarmPool raises pool capacity when warm jobs miss the barrier" {
        # Parked warm shells hold their runspaces until their background stop lands -
        # which a wedged pipeline never honors - so without compensation the pool
        # starves and every job (the DC resolve first) queues forever. The lapse path
        # must grow the max so real work always finds a runspace.
        $raw = Get-Content $Coordinator -Raw
        $raw | Should -Match 'SetMaxRunspaces' -Because (
            "a lapsed barrier must self-heal the pool instead of leaving the app " +
            "alive but unable to run any job")
    }

    It "WarmPool never blocks on - and never kills - a warm job that missed the deadline" {
        # Dispose/Stop on a still-running pipeline waits for it synchronously; a
        # pipeline wedged in a hooked native call never yields, and that hang shipped
        # once (the UI thread, pre-window). Async-stopping shipped too - and it
        # destroyed warms that were merely SLOW (first-run AV/AMSI scans push the
        # module-graph warm past the barrier), wasting the work seconds before it
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
}
