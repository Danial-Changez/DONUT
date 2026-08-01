<#
    Unit tests for PoolScriptJob - the shared start/complete/async-stop/reap
    mechanics behind every in-process pool script (AD search, Lens broker, unlock,
    startup task). Runs a real 1-runspace pool with tiny stub scripts; Linux-safe.
#>
using module "..\..\src\Core\PoolScriptJob.psm1"
using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

Describe "PoolScriptJob" {

    BeforeAll {
        # Own the static pool for this file (the WarmPoolBarrier pattern).
        [RunspaceManager]::Close()
        [RunspaceManager]::Initialize(1, 1)

        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) `
            ("DonutPoolJob-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null

        function New-Stub([string]$name, [string]$body) {
            $path = Join-Path $script:root $name
            Set-Content -Path $path -Value $body
            return $path
        }

        # Polls until $condition returns $true or ~5s elapse; returns the final verdict.
        function Wait-Until([scriptblock]$condition) {
            for ($i = 0; $i -lt 50; $i++) {
                if (& $condition) { return $true }
                Start-Sleep -Milliseconds 100
            }
            return (& $condition)
        }
    }

    AfterAll {
        [RunspaceManager]::Close()
        Remove-Item -Path $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Start returns the @{ Ps; Handle; StartedAt } envelope and the script's output completes" {
        $stub = New-Stub 'ok.ps1' "'pool-ok'"
        $job = [PoolScriptJob]::Start($stub, @{})

        $job.Ps | Should -Not -BeNullOrEmpty
        $job.Handle | Should -Not -BeNullOrEmpty
        $job.StartedAt | Should -BeOfType [datetime]
        Wait-Until { $job.Handle.IsCompleted } | Should -BeTrue

        $result = [PoolScriptJob]::Complete($job, $null)
        @($result) -join '' | Should -Be 'pool-ok'
    }

    # StartedAt has to precede the script actually running, because the AD search breadcrumb
    # reports (script start - StartedAt) as its queue span and that must never go negative.
    It "stamps StartedAt no later than the moment the script begins running" {
        $stub = New-Stub 'stamp.ps1' '[datetime]::UtcNow.Ticks'
        $before = [datetime]::UtcNow
        $job = [PoolScriptJob]::Start($stub, @{})

        Wait-Until { $job.Handle.IsCompleted } | Should -BeTrue
        $ticks = [long](@([PoolScriptJob]::Complete($job, $null)) -join '')
        $ranAt = [datetime]::new($ticks, [System.DateTimeKind]::Utc)

        $job.StartedAt | Should -BeGreaterOrEqual $before
        $job.StartedAt | Should -BeLessOrEqual $ranAt
    }

    It "Start passes named parameters through to the script" {
        $stub = New-Stub 'echo.ps1' 'param($Name) "hello-$Name"'
        $job = [PoolScriptJob]::Start($stub, @{ Name = 'donut' })

        Wait-Until { $job.Handle.IsCompleted } | Should -BeTrue
        @([PoolScriptJob]::Complete($job, $null)) -join '' | Should -Be 'hello-donut'
    }

    It "the envelope accepts ad-hoc per-job keys (the poll loops' contract)" {
        $stub = New-Stub 'tag.ps1' "'x'"
        $job = [PoolScriptJob]::Start($stub, @{})
        $job.Token = 42
        $job.Upn = 'user@example.com'

        $job.Token | Should -Be 42
        Wait-Until { $job.Handle.IsCompleted } | Should -BeTrue
        [PoolScriptJob]::Complete($job, $null) | Out-Null
    }

    It "Complete logs a failing script and yields null instead of throwing" {
        $stub = New-Stub 'boom.ps1' "throw 'boom'"
        $job = [PoolScriptJob]::Start($stub, @{})
        Wait-Until { $job.Handle.IsCompleted } | Should -BeTrue

        $log = [CapturingLogService]::new()
        $result = [PoolScriptJob]::Complete($job, $log)

        $null -eq $result -or @($result).Count -eq 0 | Should -BeTrue
        $log.Contains('Pool job failed') | Should -BeTrue
    }

    It "DisposeSafe disposes a finished job inline (nothing parked)" {
        $stub = New-Stub 'done.ps1' "'x'"
        $job = [PoolScriptJob]::Start($stub, @{})
        Wait-Until { $job.Handle.IsCompleted } | Should -BeTrue

        $stopping = [System.Collections.Generic.List[object]]::new()
        [PoolScriptJob]::DisposeSafe($job.Ps, $stopping, $null) | Should -BeFalse
        $stopping.Count | Should -Be 0
    }

    It "DisposeSafe parks a running job via BeginStop and ReapStopping drains it" {
        $stub = New-Stub 'slow.ps1' "Start-Sleep -Seconds 30"
        $job = [PoolScriptJob]::Start($stub, @{})
        Wait-Until { $job.Ps.InvocationStateInfo.State -eq 'Running' } | Should -BeTrue

        $stopping = [System.Collections.Generic.List[object]]::new()
        [PoolScriptJob]::DisposeSafe($job.Ps, $stopping, $null) | Should -BeTrue
        $stopping.Count | Should -Be 1

        # The async stop lands off-thread; the reap then disposes and drains the list.
        Wait-Until { [PoolScriptJob]::ReapStopping($stopping, $null) } | Should -BeTrue
        $stopping.Count | Should -Be 0
    }

    It "DisposeSafe ignores null without touching the list" {
        $stopping = [System.Collections.Generic.List[object]]::new()
        [PoolScriptJob]::DisposeSafe($null, $stopping, $null) | Should -BeFalse
        $stopping.Count | Should -Be 0
    }
}
