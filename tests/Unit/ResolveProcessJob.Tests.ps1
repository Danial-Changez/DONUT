<#
    Unit tests for ResolveProcessJob - the fast lane's direct child spawn. Real pwsh
    children run stub scripts so the whole file protocol (verdict / crash / timeout /
    cleanup) is exercised end-to-end; Linux-safe (no pool, no WPF).
#>
using module "..\..\src\Core\ResolveProcessJob.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Models\JobEnums.psm1"
using module "..\Helpers\CapturingLogService.psm1"

Describe "ResolveProcessJob" {

    BeforeAll {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) `
            ("DonutFastJob-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null

        function New-Stub([string]$name, [string]$body) {
            $path = Join-Path $script:root $name
            Set-Content -Path $path -Value $body
            return $path
        }

        # Drives the pump's contract: Poll() until terminal or ~15s.
        function Wait-Terminal([object]$job) {
            for ($i = 0; $i -lt 150; $i++) {
                $job.Poll()
                if ($job.Status -in @([JobStatus]::Completed, [JobStatus]::Failed)) { return $true }
                Start-Sleep -Milliseconds 100
            }
            return $false
        }

        $script:fastArgs = @{ HostName = 'PC1'; Dc = 'DC1'; LogsDir = $script:root }
    }

    AfterAll {
        Remove-Item -Path $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "completes with the verdict from the result file and cleans its temp file up" {
        $stub = New-Stub 'verdict.ps1' @'
param($HostName, $Dc, $LogsDir, $ResultFile)
@{ Mode = 'Host'; HostName = $HostName; Ip = '10.0.0.9'; Online = $true } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultFile
'@
        $job = [ResolveProcessJob]::new('PC1', [JobKind]::Resolve, [CapturingLogService]::new())
        $job.Start($stub, $script:fastArgs, $null)

        Wait-Terminal $job | Should -BeTrue
        $job.Status | Should -Be ([JobStatus]::Completed)
        $job.ProcessFault | Should -BeFalse
        $job.Result.Mode | Should -Be 'Host'
        $job.Result.Ip | Should -Be '10.0.0.9'

        $resultFile = $job.FastResultFile
        Test-Path -LiteralPath $resultFile | Should -BeTrue
        $job.Cleanup()
        Test-Path -LiteralPath $resultFile | Should -BeFalse
    }

    It "flags ProcessFault when the child exits without writing a verdict" {
        $stub = New-Stub 'crash.ps1' 'param($HostName, $Dc, $LogsDir, $ResultFile) exit 3'
        $log = [CapturingLogService]::new()
        $job = [ResolveProcessJob]::new('PC1', [JobKind]::Resolve, $log)
        $job.Start($stub, $script:fastArgs, $null)

        Wait-Terminal $job | Should -BeTrue
        $job.Status | Should -Be ([JobStatus]::Failed)
        $job.ProcessFault | Should -BeTrue
        $job.FailureMessage | Should -Match 'no verdict'
        $log.Contains('no verdict') | Should -BeTrue
        $job.Cleanup()
    }

    It "kills a wedged child at the watchdog timeout (the one clean recovery a wedge has)" {
        $stub = New-Stub 'sleep.ps1' 'param($HostName, $Dc, $LogsDir, $ResultFile) Start-Sleep -Seconds 120'
        $job = [ResolveProcessJob]::new('PC1', [JobKind]::Resolve, [CapturingLogService]::new())
        $job.TimeoutSeconds = 2
        $job.Start($stub, $script:fastArgs, $null)

        Wait-Terminal $job | Should -BeTrue
        $job.Status | Should -Be ([JobStatus]::Failed)
        $job.ProcessFault | Should -BeTrue
        $job.FailureMessage | Should -Match 'timed out'
        # The kill must actually land, not just flip the status.
        for ($i = 0; $i -lt 50 -and -not $job.Process.HasExited; $i++) { Start-Sleep -Milliseconds 100 }
        $job.Process.HasExited | Should -BeTrue
        $job.Cleanup()
    }

    It "flags ProcessFault when the spawn itself fails" {
        $job = [ResolveProcessJob]::new('PC1', [JobKind]::Resolve, [CapturingLogService]::new())
        # An unwritable result-file path makes Start fault before any child exists.
        $job.Start((Join-Path $script:root 'missing-dir/nope.ps1'), @{}, $null)
        # pwsh itself starts fine with a bad -File, so drive to terminal either way.
        Wait-Terminal $job | Should -BeTrue
        $job.Status | Should -Be ([JobStatus]::Failed)
        $job.ProcessFault | Should -BeTrue
        $job.Cleanup()
    }
}
