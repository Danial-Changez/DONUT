<#
    Startup smoke: the warm barrier and the first Resolve job must always terminate.

    Every regression in this family looked identical in the field: a line like
    "Started Resolve job." (or nothing at all) and then silence - the app up but
    dead, or never showing a window. Unit tests kept passing because each piece is
    correct in isolation; the failures live in the seams (pool dispatch, worker
    script bring-up, the warm barrier). This file runs the REAL scripts on a REAL
    runspace pool and asserts liveness: everything submitted must come back.

    The pool work runs in a CHILD pwsh process (same pattern as
    RemoteWorker.Integration.Tests.ps1), for two reasons: it mirrors production -
    the app is its own fresh process - and it is the only reliable arrangement in
    a full-suite run. When earlier test files have already imported the worker
    module graph into the Pester host process, a pool runspace compiling that same
    graph can deadlock process-wide: these very tests passed standalone and hung
    for minutes inside `Invoke-Pester -Path tests`. The child starts clean, so the
    smoke result reflects the scripts, not the test host's module state.

    What this catches: parse/parameter breaks in RemoteWorker.ps1, module-graph
    load failures, warm code that loops or blocks by construction, a pool left
    starved after the warm pass.
    What it cannot catch: environment-specific wedges (a security stack holding a
    native call below PowerShell). Those are guarded by the no-connect static rules
    in RunspaceWarmCoverage.Tests.ps1 and surfaced at runtime by AsyncJob's stall
    heartbeat.
#>

Describe "Startup warm + resolve smoke" {

    BeforeAll {
        $script:SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../src')).Path
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "DonutStartupSmoke-$PID"
        $script:LogsDir = Join-Path $WorkDir 'logs'
        $script:ReportsDir = Join-Path $WorkDir 'reports'
        New-Item -ItemType Directory `
                 -Force `
                 -Path $LogsDir, $ReportsDir | Out-Null

        # The harness deliberately leaks a lapsed shell, since disposing a running pipeline blocks.
        $script:ChildScript = Join-Path $WorkDir 'SmokeHarness.ps1'
        @'
param([string]$SourceRoot, [string]$LogsDir, [string]$ReportsDir, [string]$OutFile)
$result = [ordered]@{
    WarmCompleted     = $false
    FollowupCompleted = $false
    FollowupMode      = ''
    ResolveCompleted  = $false
    ResolveMode       = ''
    Error             = ''
}
try {
    $pool = [runspacefactory]::CreateRunspacePool(1, 2)
    $pool.Open()
    function Invoke-PoolScript([string]$path, [hashtable]$params, [int]$timeoutSec) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddCommand($path)
        foreach ($k in $params.Keys) { [void]$ps.AddParameter($k, $params[$k]) }
        $handle = $ps.BeginInvoke()
        $completed = $handle.AsyncWaitHandle.WaitOne($timeoutSec * 1000)
        $output = $null
        if ($completed) {
            try { $output = $ps.EndInvoke($handle) } catch { }
            $ps.Dispose()
        }
        return @{ Completed = $completed; Output = $output }
    }
    $scripts = Join-Path $SourceRoot 'Scripts'
    $common = @{ SourceRoot = $SourceRoot; LogsDir = $LogsDir; ReportsDir = $ReportsDir }
    $worker = Join-Path $scripts 'RemoteWorker.ps1'

    # The barrier body: one real worker pass (the 64dbec8 recipe WarmPool runs).
    $warm = Invoke-PoolScript $worker ($common + @{
            HostName = ''; JobType = 'Resolve'; ResolvedIp = ''
            Options = @{ Mode = 'WarmRunspace' }
        }) 120
    $result.WarmCompleted = $warm.Completed
    $followup = Invoke-PoolScript $worker ($common + @{
            HostName = ''; JobType = 'Resolve'; ResolvedIp = ''
            Options = @{ Mode = 'WarmRunspace' }
        }) 90
    $result.FollowupCompleted = $followup.Completed
    if ($followup.Completed -and @($followup.Output).Count -gt 0) {
        $result.FollowupMode = [string]@($followup.Output)[0].Mode
    }

    $resolve = Invoke-PoolScript $worker ($common + @{
            HostName = ''; JobType = 'Resolve'; ResolvedIp = ''
            Options = @{ Mode = 'Warm' }
        }) 90
    $result.ResolveCompleted = $resolve.Completed
    if ($resolve.Completed -and @($resolve.Output).Count -gt 0) {
        $result.ResolveMode = [string]@($resolve.Output)[0].Mode
    }
}
catch { $result.Error = $_.Exception.Message }
[pscustomobject]$result | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile
'@ | Set-Content -Path $script:ChildScript

        $script:OutJson = Join-Path $WorkDir 'smoke-result.json'
        $pwshPath = (Get-Process -Id $PID).Path
        if ([string]::IsNullOrWhiteSpace($pwshPath)) { $pwshPath = 'pwsh' }
        # Start-Process joins -ArgumentList unquoted and truncates paths with spaces.
        $psi = [System.Diagnostics.ProcessStartInfo]::new($pwshPath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($arg in @(
                '-NoProfile', '-File', $script:ChildScript,
                '-SourceRoot', $script:SourceRoot,
                '-LogsDir', $script:LogsDir,
                '-ReportsDir', $script:ReportsDir,
                '-OutFile', $script:OutJson)) {
            $psi.ArgumentList.Add($arg)
        }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $script:ChildTimedOut = -not $proc.WaitForExit(360000)
        if ($script:ChildTimedOut) {
            try { $proc.Kill() } catch { Write-Warning "Smoke child kill failed: $_" }
        }
        $script:Smoke = if (Test-Path $script:OutJson) {
            Get-Content $script:OutJson -Raw | ConvertFrom-Json
        } else { $null }
    }

    AfterAll {
        Remove-Item $script:WorkDir `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
    }

    It "the worker warm pass (the startup barrier body) terminates on a live pool" {
        $ChildTimedOut | Should -BeFalse -Because (
            "the smoke harness itself must finish - a wedged harness means a wedge " +
            "in the worker scripts")
        $Smoke | Should -Not -BeNullOrEmpty
        [string]$Smoke.Error | Should -BeNullOrEmpty
        [bool]$Smoke.WarmCompleted | Should -BeTrue -Because (
            "the startup barrier waits on this pass per runspace; if it cannot " +
            "finish, the app never shows a window")
    }

    It "a worker job dispatched after the warm completes (the pool is not starved)" {
        [bool]$Smoke.FollowupCompleted | Should -BeTrue -Because (
            "a job queued after the warm pass must actually run - parked warm shells " +
            "holding every runspace is exactly how 'Started Resolve job.' went silent")
        [string]$Smoke.FollowupMode | Should -Be 'WarmRunspace'
    }

    It "the startup DC-discovery job (Resolve/Warm) always terminates" {
        # Off-domain finding no controller still passes: the guarantee is that the job reports.
        [bool]$Smoke.ResolveCompleted | Should -BeTrue -Because (
            "the startup DC warm-up must always come back - a Resolve job that " +
            "neither completes nor fails leaves the whole app without an active DC")
        [string]$Smoke.ResolveMode | Should -Be 'Warm'
        # The worker's entry marker is exactly what the bring-up wedge silently omits.
        $logFile = Join-Path $LogsDir 'Donut.log'
        Test-Path $logFile | Should -BeTrue
        (Get-Content $logFile -Raw) | Should -Match 'DC discovery running on the pool'
    }
}
