using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\..\src\Core\AsyncJob.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Services\RemoteServices.psm1"
using module "..\..\src\Services\HostResolver.psm1"

<#
    The production worker transport, end to end and for real: service-built args ->
    AsyncJob -> pool runspace -> WorkerProcess launcher -> child pwsh running the
    REAL RemoteWorker.ps1 over the ArgsFile/ResultFile protocol. Other files stub
    the worker (Core.Integration) or bypass the transport (StartupResolveSmoke);
    this one proves both the success and the failure verdict shapes.
#>
Describe "Worker child-process protocol (real RemoteWorker.ps1)" {

    BeforeAll {
        $script:testRoot = Join-Path $env:TEMP "DonutWorkerProtocol_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:logsDir = Join-Path $script:testRoot 'logs'
        $script:reportsDir = Join-Path $script:testRoot 'reports'
        New-Item -Path $script:logsDir, $script:reportsDir -ItemType Directory -Force | Out-Null

        $script:srcRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src')).Path
        $script:config = [AppConfig]::new($script:srcRoot, $script:logsDir, $script:reportsDir, @{})
        $script:probe = [NetworkProbe]::new()

        [RunspaceManager]::Close()
        [RunspaceManager]::Initialize(1, 2)
    }

    AfterAll {
        [RunspaceManager]::Close()
        Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # BuildWorkerArgs joins with '\', so normalize to keep the transport the same on Linux.
    BeforeEach {
        $script:normalize = { param($p) $p -replace '\\', [IO.Path]::DirectorySeparatorChar }
    }

    It "carries a service-built job to a Completed verdict through the result file" {
        $prep = ([HostResolver]::new($script:config, $script:probe)).PrepareWarm()

        $job = [AsyncJob]::new('', 'Resolve')
        $job.Start((& $script:normalize $prep.ScriptPath), $prep.Arguments, '')

        $deadline = [DateTime]::Now.AddSeconds(120)
        while ($job.Status -eq 'Running' -and [DateTime]::Now -lt $deadline) {
            $job.Poll()
            Start-Sleep -Milliseconds 200
        }

        $job.Status | Should -Be 'Completed'
        # The worker's hashtable came back across the process boundary as JSON.
        $job.Result.Mode | Should -Be 'Warm'
        $job.Cleanup()
    }

    It "surfaces a worker failure as a Failed verdict, not a hang or a throw" {
        $prep = ([RemoteUpdateService]::new($script:config, $script:probe, $null)).PrepareScanForUpdates('donut-proto-no-such-host-99')

        $job = [AsyncJob]::new('donut-proto-no-such-host-99', 'Scan')
        $job.Start((& $script:normalize $prep.ScriptPath), $prep.Arguments, '')

        $deadline = [DateTime]::Now.AddSeconds(120)
        while ($job.Status -eq 'Running' -and [DateTime]::Now -lt $deadline) {
            $job.Poll()
            Start-Sleep -Milliseconds 200
        }

        $job.Status | Should -Be 'Failed'
        $job.FailureMessage | Should -Not -BeNullOrEmpty
        $job.Cleanup()

        # The child's LogService wrote the real per-run log where the UI reads it.
        $donutLog = Join-Path $script:logsDir 'Donut.log'
        Test-Path -LiteralPath $donutLog | Should -BeTrue
        (Get-Content -LiteralPath $donutLog -Raw) | Should -Match 'donut-proto-no-such-host-99'
    }
}
