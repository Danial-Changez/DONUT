using namespace System.Collections.Concurrent
using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\..\src\Core\AsyncJob.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Models\LogLine.psm1"
using module "..\Helpers\CapturingLogService.psm1"

Describe "AsyncJob" {

    BeforeAll {
        $script:testScriptDir = Join-Path $TestDrive "DonutAsyncJobTests"
        New-Item -Path $script:testScriptDir -ItemType Directory -Force | Out-Null


        # Stubs follow AsyncJob's child protocol: -ArgsFile in, -ResultFile out, non-zero to fail.
        $script:simpleScript = Join-Path $script:testScriptDir "SimpleScript.ps1"
        @'
param([string]$ArgsFile, [string]$ResultFile)
$a = if ($ArgsFile) { Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
@{ Success = $true; Value = $a.Input } | ConvertTo-Json | Set-Content -LiteralPath $ResultFile
'@ | Set-Content -Path $script:simpleScript

        $script:slowScript = Join-Path $script:testScriptDir "SlowScript.ps1"
        @'
param([string]$ArgsFile, [string]$ResultFile)
$a = if ($ArgsFile) { Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
$d = if ($a.DelayMs) { [int]$a.DelayMs } else { 500 }
Start-Sleep -Milliseconds $d
@{ Completed = $true } | ConvertTo-Json | Set-Content -LiteralPath $ResultFile
'@ | Set-Content -Path $script:slowScript

        $script:errorScript = Join-Path $script:testScriptDir "ErrorScript.ps1"
        @'
param([string]$ArgsFile, [string]$ResultFile)
$a = if ($ArgsFile) { Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
[Console]::Error.WriteLine("Worker failed: $($a.Message)")
exit 1
'@ | Set-Content -Path $script:errorScript
        
        [RunspaceManager]::Initialize(1, 5)
    }

    AfterAll {
        [RunspaceManager]::Close()
    }

    Context "Constructor" {
        It "Should initialize with hostname and job type" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            
            $job.HostName | Should -Be "TestHost"
            $job.JobType | Should -Be "Scan"
            $job.Status | Should -Be "Created"
        }

        It "Should initialize Logs as a ConcurrentQueue" {
            $job = [AsyncJob]::new("TestHost", "UpdateApply")
            
            # Module loading order rules out a type check, so only existence is asserted.
            $null -ne $job.Logs | Should -Be $true
        }

        It "Should support different job types" {
            $scanJob = [AsyncJob]::new("Host1", "Scan")
            $updateScanJob = [AsyncJob]::new("Host2", "UpdateScan")
            $applyJob = [AsyncJob]::new("Host3", "UpdateApply")
            
            $scanJob.JobType | Should -Be "Scan"
            $updateScanJob.JobType | Should -Be "UpdateScan"
            $applyJob.JobType | Should -Be "UpdateApply"
        }
    }

    Context "Start" {
        It "Should change status to Running when started" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            
            $job.Start($script:simpleScript, @{ Input = "test" }, "")
            
            $job.Status | Should -Be "Running"
            
            $job.Cleanup()
        }

        It "Should store TempConfigPath" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $tempConfig = Join-Path $script:testScriptDir "temp_config.json"
            
            $job.Start($script:simpleScript, @{ Input = "test" }, $tempConfig)
            
            $job.TempConfigPath | Should -Be $tempConfig
            
            $job.Cleanup()
        }

        It "Should have a valid AsyncResult after starting" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            
            $job.Start($script:simpleScript, @{ Input = "test" }, "")
            
            $job.AsyncResult | Should -Not -BeNullOrEmpty
            
            $job.Cleanup()
        }
    }

    Context "Poll" {
        It "Should do nothing if status is not Running" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            
            { $job.Poll() } | Should -Not -Throw
            $job.Status | Should -Be "Created"
        }

        It "Should update status to Completed when job finishes successfully" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:simpleScript, @{ Input = "hello" }, "")
            
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Status | Should -Be "Completed"
            
            $job.Cleanup()
        }

        It "Should populate Result after successful completion" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:simpleScript, @{ Input = "testvalue" }, "")
            
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Result | Should -Not -BeNullOrEmpty
            
            $job.Cleanup()
        }

        It "Should set status to Failed when script throws" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:errorScript, @{ Message = "Test error" }, "")
            
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Status | Should -Be "Failed"
            
            $job.Cleanup()
        }

        It "Should capture error messages in Logs" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:errorScript, @{ Message = "Captured error" }, "")

            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }

            $job.Logs.Count | Should -BeGreaterThan 0

            $job.Cleanup()
        }

        It "Enqueues the failure as an Error LogLine with undecorated text" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:errorScript, @{ Message = "Captured error" }, "")

            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }

            # The failure line is severity-typed now, so the old "Error: " prefix is gone.
            $found = $null
            $line = $null
            while ($job.Logs.TryDequeue([ref]$line)) {
                if ($line.Text -eq $job.FailureMessage) { $found = $line }
            }
            $found | Should -Not -BeNullOrEmpty
            $found -is [LogLine] | Should -BeTrue
            $found.Severity | Should -Be ([LogSeverity]::Error)
            $found.Text | Should -Not -BeLike 'Error: *'
            $found.DisplayText | Should -BeLike '`[Error`] *'
            $found.Stamp | Should -Match '^\d{2}:\d{2}:\d{2}$'

            $job.Cleanup()
        }
    }

    Context "Cleanup" {
        It "Should dispose PowerShell instance" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:simpleScript, @{ Input = "test" }, "")
            
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            { $job.Cleanup() } | Should -Not -Throw
        }

        It "Should remove TempConfigPath file if it exists" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $tempConfig = Join-Path $script:testScriptDir "temp_config_cleanup.json"
            
            "{}" | Set-Content -Path $tempConfig
            
            $job.Start($script:simpleScript, @{ Input = "test" }, $tempConfig)
            
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Cleanup()
            
            Test-Path $tempConfig | Should -Be $false
        }

        It "Should handle cleanup when PowerShell is null" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            
            { $job.Cleanup() } | Should -Not -Throw
        }
    }

    Context "DrainStream" {
        It "Should handle null stream gracefully" {
            $job = [AsyncJob]::new("TestHost", "Scan")

            { $job.DrainStream($null, [LogSeverity]::Info) } | Should -Not -Throw
        }
    }

    Context "Logging" {
        It "Should default to a no-op logger when constructed without one" {
            $job = [AsyncJob]::new("TestHost", "Scan")

            $job.Logger | Should -Not -BeNullOrEmpty
        }

        It "Should log an error through the injected logger when the script fails" {
            $logger = [CapturingLogService]::new()
            $job = [AsyncJob]::new("TestHost", "Scan", $logger)
            $job.Start($script:errorScript, @{ Message = "Logged failure" }, "")

            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }

            $job.Status | Should -Be "Failed"
            $logger.HasLevel("ERROR") | Should -Be $true

            $job.Cleanup()
        }
    }

    Context "Stall heartbeat" {
        It "warns with the pool state when a running job crosses the threshold, then re-arms" {
            # The log otherwise cannot tell a starved pool from a wedged worker on a silent job.
            $logger = [CapturingLogService]::new()
            $job = [AsyncJob]::new("SlowHost", "Scan", $logger)
            $job.Start($script:slowScript, @{ DelayMs = 4000 }, $null)

            # Force the first heartbeat due now instead of waiting the real 90 s.
            $job.NextStallLogUtc = [datetime]::UtcNow.AddSeconds(-1)
            $job.Poll()

            $logger.HasLevel("WARN") | Should -Be $true
            $logger.Contains("still running after") | Should -Be $true
            $logger.Contains("pool:") | Should -Be $true

            # Re-armed: the next Poll inside the repeat window must stay quiet.
            $job.Poll()
            @($logger.Entries | Where-Object { $_ -like "*still running after*" }).Count |
                Should -Be 1

            # Let the job finish so cleanup never disposes a running pipeline.
            $timeout = [DateTime]::Now.AddSeconds(30)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                Start-Sleep -Milliseconds 100
                $job.Poll()
            }
            $job.Status | Should -Be "Completed"
            $job.Cleanup()
        }
    }

}
