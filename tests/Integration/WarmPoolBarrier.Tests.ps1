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
using module "..\Helpers\CapturingLogService.psm1"

Describe "WarmPool barrier" {

    BeforeAll {
        # Own the static pool for this file: 2 runspaces, matching throttleLimit below.
        [RunspaceManager]::Close()
        [RunspaceManager]::Initialize(1, 2)

        # A coordinator whose Config roots a stub Scripts/Warm-Runspace.ps1, plus the
        # capturing logger it writes to. The stub receives WarmPool's parameters.
        function New-BarrierFixture([string]$stubBody) {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) `
                ("DonutBarrier-" + [guid]::NewGuid().ToString('N'))
            $scripts = Join-Path $root 'Scripts'
            New-Item -ItemType Directory -Force -Path $scripts | Out-Null
            $stubParams = "param([string]`$SourceRoot = '', [string]`$LogsDir = '', " +
            "[string]`$ReportsDir = '')"
            ($stubParams + "`n" + $stubBody) |
                Set-Content -Path (Join-Path $scripts 'Warm-Runspace.ps1')
            $log = [CapturingLogService]::new()
            $config = [AppConfig]::new($root, '', '', @{ throttleLimit = 2 })
            $coord = [ResolutionCoordinator]::new($config, $log, $null, $null, $null, $null)
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
        $f.Log.Contains('did not finish within') | Should -BeTrue
        $f.Log.Contains('Pre-warmed 0 of 2') | Should -BeTrue
        $f.Coordinator.AbandonedWarmShells.Count | Should -Be 2

        # Self-heal: capacity must grow by the parked count so real jobs never starve
        # behind held runspaces - in the field the pool sat 0/8 free for minutes and
        # the DC resolve heartbeated unrun until the app was killed.
        $f.Log.Contains('Pool capacity raised to 4') | Should -BeTrue
        [RunspaceManager]::GetPool().GetMaxRunspaces() | Should -Be 4

        # THE user-facing contract: a job submitted immediately after a lapsed
        # barrier must still run, even while both parked shells hold their runspaces.
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
}
