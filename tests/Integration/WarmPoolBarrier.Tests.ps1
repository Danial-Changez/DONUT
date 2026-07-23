<#
    Barrier-behavior smoke for ResolutionCoordinator.WarmPool - the startup gate the
    whole app sits behind.

    Two shipped regressions define the contract under test:
    - Warm jobs wedged and WarmPool Dispose()d their still-running pipelines;
      Dispose stops synchronously, so the UI thread hung before any window existed.
    - Warm shells parked after the deadline hold their pool runspaces, so real jobs
      (the startup DC resolve first among them) starve behind an empty pool.

    These tests run the REAL WarmPool against the REAL RunspaceManager pool with
    stub warm scripts: a fast stub proves the pool still dispatches work after the
    barrier; a slow-but-stoppable stub proves a lapsed barrier returns promptly,
    logs the lapse, parks the shells, and gets the runspaces back once the
    background stop lands. A truly unstoppable wedge cannot be simulated in-process
    (closing the pool would hang the test run); that case is covered by the
    no-network static guards in RunspaceWarmCoverage.Tests.ps1.
#>
using module "..\..\src\UI\Presenters\ResolutionCoordinator.psm1"
using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Services\HostResolver.psm1"
using module "..\Helpers\CapturingLogService.psm1"

# Stands in for HostResolver so WarmPool submits a stub script instead of the real
# RemoteWorker warm pass. base($null, $null) is safe - the base ctor only stores refs.
class StubWarmResolver : HostResolver {
    [string] $StubPath
    StubWarmResolver([string]$stubPath) : base($null, $null) {
        $this.StubPath = $stubPath
    }
    # The coordinator calls the TAGGED arity; overriding only the 0-arg one would
    # fall through to the real BuildWorkerArgs and submit the real worker.
    [hashtable] PrepareWarmRunspace([string]$tag) {
        return @{ ScriptPath = $this.StubPath; Arguments = @{} }
    }
}

Describe "WarmPool barrier" {

    BeforeAll {
        # Own the static pool for this file: 2 runspaces, matching throttleLimit below.
        [RunspaceManager]::Close()
        [RunspaceManager]::Initialize(1, 2)

        # A coordinator whose resolver hands WarmPool a stub warm script, plus the
        # capturing logger it writes to.
        function New-BarrierFixture([string]$stubBody) {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) `
                ("DonutBarrier-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            $stub = Join-Path $root 'StubWarm.ps1'
            $stubBody | Set-Content -Path $stub
            $log = [CapturingLogService]::new()
            $config = [AppConfig]::new($root, '', '', @{ throttleLimit = 2 })
            $resolver = [StubWarmResolver]::new($stub)
            $coord = [ResolutionCoordinator]::new($config, $log, $null, $null, $resolver, $null)
            return @{ Coordinator = $coord; Log = $log; Root = $root }
        }
    }

    AfterAll {
        [RunspaceManager]::Close()
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'DonutBarrier-*' |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "dispatches real work after a healthy warm (the pool is not starved)" {
        $f = New-BarrierFixture "'warm-ok'"
        $f.Coordinator.WarmPool()
        $f.Log.Contains('Pre-warmed 2 of 2') | Should -BeTrue

        # A job submitted right after the barrier must run - the seam that broke when
        # parked warm shells held every runspace ("Started Resolve job." -> silence).
        $ps = [powershell]::Create()
        $ps.RunspacePool = [RunspaceManager]::GetPool()
        [void]$ps.AddScript('42')
        $handle = $ps.BeginInvoke()
        $handle.AsyncWaitHandle.WaitOne(30000) | Should -BeTrue -Because (
            "a healthy warm must leave every pool runspace free for real jobs")
        [string]$ps.EndInvoke($handle) | Should -Be '42'
        $ps.Dispose()
    }

    It "a lapsed barrier returns promptly, heals the pool, and reaps late warms" {
        # The stubs outlive the 2 s barrier but finish on their own at ~8 s - the
        # "slow, not wedged" case from the field (first-run AV/AMSI scanning pushed
        # every warm past 30 s). The barrier must not kill them: a late finisher is
        # still a fully warmed runspace.
        $f = New-BarrierFixture "Start-Sleep -Seconds 8"
        $f.Coordinator.WarmTimeoutSeconds = 2
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $f.Coordinator.WarmPool()
        $sw.Stop()

        # The barrier must lapse near its deadline - it may never block on a running
        # pipeline (Dispose/Stop on one hangs until the pipeline yields, which a
        # wedged pipeline never does; that hang shipped once, pre-window).
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
        $f.Log.Contains('Pre-warmed 0 of 2') | Should -BeTrue

        # Serial warm parks the FIRST wedged shell and STOPS (a wedged compile holds
        # the load lock; submitting the next would only pile onto it).
        $f.Coordinator.AbandonedWarmShells.Count | Should -Be 1

        # Forensics: the parked shell must leave a per-shell state line naming its tag.
        $f.Log.Contains('Warm shell parked at barrier lapse: warm-1') | Should -BeTrue
        $f.Log.Contains('state=Running') | Should -BeTrue

        # Self-heal: capacity grows by the parked count so real jobs never starve
        # behind the held runspace.
        $f.Log.Contains('Pool capacity raised to 3') | Should -BeTrue
        [RunspaceManager]::GetPool().GetMaxRunspaces() | Should -Be 3

        # THE user-facing contract: a job submitted immediately after a lapsed
        # barrier must still run, even while the parked shell holds its runspace.
        $ps = [powershell]::Create()
        $ps.RunspacePool = [RunspaceManager]::GetPool()
        [void]$ps.AddScript('7')
        $handle = $ps.BeginInvoke()
        $handle.AsyncWaitHandle.WaitOne(30000) | Should -BeTrue -Because (
            "the healed pool must dispatch real work while warm shells are parked")
        [string]$ps.EndInvoke($handle) | Should -Be '7'
        $ps.Dispose()

        # Reap: when the late warms land (~8 s), the pump-driven harvest must claim
        # them and give the raised capacity back - the raise is temporary insurance,
        # not a permanent doubling.
        foreach ($attempt in 1..90) {
            $f.Coordinator.ReapWarmShells()
            if ($f.Coordinator.AbandonedWarmShells.Count -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
        $f.Coordinator.AbandonedWarmShells.Count | Should -Be 0 -Because (
            "a slow-but-healthy warm must eventually be harvested, not leak")
        $f.Log.Contains('finished late') | Should -BeTrue
        $f.Log.Contains('Pool capacity restored to 2') | Should -BeTrue
        [RunspaceManager]::GetPool().GetMaxRunspaces() | Should -Be 2 -Because (
            "after every late warm is harvested the pool must converge back on the " +
            "configured throttle")
    }

    It "a warm that completes with errors is counted apart and logged at ERROR" {
        # Non-terminating errors complete the pipeline, so before the forensics this
        # counted as a successful warm and the log showed nothing at all.
        $f = New-BarrierFixture "Write-Error 'boom' -ErrorAction Continue"
        $f.Coordinator.WarmPool()

        $f.Log.Contains('Pre-warmed 0 of 2') | Should -BeTrue
        $f.Log.Contains('(2 completed with errors)') | Should -BeTrue
        $f.Log.Contains('boom') | Should -BeTrue
        $f.Log.HasLevel('ERROR') | Should -BeTrue
        $f.Coordinator.AbandonedWarmShells.Count | Should -Be 0
        [RunspaceManager]::GetPool().GetMaxRunspaces() | Should -Be 2 -Because (
            "errored warms completed, so no capacity compensation may fire")
    }
}
