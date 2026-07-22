<#
    Startup smoke: the warm barrier and the first Resolve job must always terminate.

    Every regression in this family looked identical in the field: a line like
    "Started Resolve job." (or nothing at all) and then silence - the app up but
    dead, or never showing a window. Unit tests kept passing because each piece is
    correct in isolation; the failures live in the seams (pool dispatch, worker
    script bring-up, the warm barrier). This file runs the REAL scripts on a REAL
    runspace pool and asserts liveness: everything submitted here must come back.

    What this catches: parse/parameter breaks in Warm-Runspace.ps1 or
    RemoteWorker.ps1, module-graph load failures, warm code that loops or blocks by
    construction, a pool left starved after the warm pass.
    What it cannot catch: environment-specific wedges (a security stack holding a
    native call below PowerShell). Those are guarded by the no-network static rules
    in RunspaceWarmCoverage.Tests.ps1 and surfaced at runtime by AsyncJob's stall
    heartbeat.
#>

Describe "Startup warm + resolve smoke" {

    BeforeAll {
        $script:SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../src')).Path
        $script:WarmScript = Join-Path (Join-Path $SourceRoot 'Scripts') 'Warm-Runspace.ps1'
        $script:Worker = Join-Path (Join-Path $SourceRoot 'Scripts') 'RemoteWorker.ps1'
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "DonutStartupSmoke-$PID"
        $script:LogsDir = Join-Path $WorkDir 'logs'
        $script:ReportsDir = Join-Path $WorkDir 'reports'
        New-Item -ItemType Directory -Force -Path $LogsDir, $ReportsDir | Out-Null

        $script:Pool = [runspacefactory]::CreateRunspacePool(1, 2)
        $script:Pool.Open()

        # Submits a script to the pool exactly the way WarmPool / AsyncJob do, with a
        # bounded wait so a wedge fails the test instead of hanging the whole run.
        function Invoke-PoolScript([string]$path, [hashtable]$params, [int]$timeoutSec) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $script:Pool
            [void]$ps.AddCommand($path)
            foreach ($k in $params.Keys) { [void]$ps.AddParameter($k, $params[$k]) }
            $handle = $ps.BeginInvoke()
            $completed = $handle.AsyncWaitHandle.WaitOne($timeoutSec * 1000)
            $output = $null
            $errors = @()
            if ($completed) {
                try { $output = $ps.EndInvoke($handle) }
                catch { $errors += $_.Exception.Message }
                $errors += @($ps.Streams.Error | ForEach-Object { $_.ToString() })
                $ps.Dispose()
            }
            else {
                # Deliberately leaked: disposing a still-running pipeline blocks (the
                # exact production hang this suite guards); it dies with the process.
                [void]$ps.BeginStop($null, $null)
            }
            return @{ Completed = $completed; Output = $output; Errors = $errors }
        }
    }

    AfterAll {
        try { $script:Pool.Close(); $script:Pool.Dispose() }
        catch { Write-Warning "Smoke pool close failed: $($_.Exception.Message)" }
        Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Warm-Runspace.ps1 (the startup barrier body) terminates on a live pool" {
        $r = Invoke-PoolScript $WarmScript @{
            SourceRoot = $SourceRoot
            LogsDir    = $LogsDir
            ReportsDir = $ReportsDir
        } 180
        $r.Completed | Should -BeTrue -Because (
            "the startup barrier waits on this script per runspace; if it cannot " +
            "finish, the app never shows a window")
    }

    It "a worker job dispatched after the warm completes (the pool is not starved)" {
        $r = Invoke-PoolScript $Worker @{
            HostName   = ''
            JobType    = 'Resolve'
            Options    = @{ Mode = 'WarmRunspace' }
            ResolvedIp = ''
            SourceRoot = $SourceRoot
            LogsDir    = $LogsDir
            ReportsDir = $ReportsDir
        } 120
        $r.Completed | Should -BeTrue -Because (
            "a job queued after the warm pass must actually run - parked warm shells " +
            "holding every runspace is exactly how 'Started Resolve job.' went silent")
        [string](@($r.Output)[0].Mode) | Should -Be 'WarmRunspace'
    }

    It "the startup DC-discovery job (Resolve/Warm) always terminates" {
        # Off-domain the discovery finds no controller and that is a PASS here: the
        # guarantee under test is that the job COMPLETES and reports, never that AD
        # is reachable from the test host.
        $r = Invoke-PoolScript $Worker @{
            HostName   = ''
            JobType    = 'Resolve'
            Options    = @{ Mode = 'Warm' }
            ResolvedIp = ''
            SourceRoot = $SourceRoot
            LogsDir    = $LogsDir
            ReportsDir = $ReportsDir
        } 120
        $r.Completed | Should -BeTrue -Because (
            "the startup DC warm-up must always come back - a Resolve job that " +
            "neither completes nor fails leaves the whole app without an active DC")
        [string](@($r.Output)[0].Mode) | Should -Be 'Warm'
        # The worker's entry marker proves the pipeline came up and logged; its
        # absence is the signature of the bring-up wedge this smoke exists to catch.
        $logFile = Join-Path $LogsDir 'Donut.log'
        Test-Path $logFile | Should -BeTrue
        (Get-Content $logFile -Raw) | Should -Match 'DC discovery running on the pool'
    }
}
