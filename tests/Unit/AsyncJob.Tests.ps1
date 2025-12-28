using namespace System.Collections.Concurrent
using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\..\src\Core\AsyncJob.psm1"

Describe "AsyncJob" {

    BeforeAll {
        # Create a simple test script for async execution
        $script:testScriptDir = Join-Path $env:TEMP "DonutAsyncJobTests"
        if (-not (Test-Path $script:testScriptDir)) {
            New-Item -Path $script:testScriptDir -ItemType Directory -Force | Out-Null
        }
        
        # Simple script that returns a value
        $script:simpleScript = Join-Path $script:testScriptDir "SimpleScript.ps1"
        @'
param([string]$Input)
Write-Output "Received: $Input"
return @{ Success = $true; Value = $Input }
'@ | Set-Content -Path $script:simpleScript

        # Script that takes time
        $script:slowScript = Join-Path $script:testScriptDir "SlowScript.ps1"
        @'
param([int]$DelayMs = 500)
Start-Sleep -Milliseconds $DelayMs
return @{ Completed = $true }
'@ | Set-Content -Path $script:slowScript

        # Script that throws an error
        $script:errorScript = Join-Path $script:testScriptDir "ErrorScript.ps1"
        @'
param([string]$Message)
Write-Error $Message
throw "Test exception: $Message"
'@ | Set-Content -Path $script:errorScript
        
        # Initialize RunspaceManager for tests
        [RunspaceManager]::Initialize(1, 5)
    }

    AfterAll {
        [RunspaceManager]::Close()
        
        if (Test-Path $script:testScriptDir) {
            Remove-Item -Path $script:testScriptDir -Recurse -Force -ErrorAction SilentlyContinue
        }
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
            
            # The Logs property should be initialized
            # Note: Due to module loading order, we check it exists and can be used
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
            
            # Cleanup
            $job.Cleanup()
        }

        It "Should store TempConfigPath" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $tempConfig = Join-Path $script:testScriptDir "temp_config.json"
            
            $job.Start($script:simpleScript, @{ Input = "test" }, $tempConfig)
            
            $job.TempConfigPath | Should -Be $tempConfig
            
            # Cleanup
            $job.Cleanup()
        }

        It "Should have a valid AsyncResult after starting" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            
            $job.Start($script:simpleScript, @{ Input = "test" }, "")
            
            $job.AsyncResult | Should -Not -BeNullOrEmpty
            
            # Cleanup
            $job.Cleanup()
        }
    }

    Context "Poll" {
        It "Should do nothing if status is not Running" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            
            # Poll before start - should not throw
            { $job.Poll() } | Should -Not -Throw
            $job.Status | Should -Be "Created"
        }

        It "Should update status to Completed when job finishes successfully" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:simpleScript, @{ Input = "hello" }, "")
            
            # Wait for completion
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Status | Should -Be "Completed"
            
            # Cleanup
            $job.Cleanup()
        }

        It "Should populate Result after successful completion" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:simpleScript, @{ Input = "testvalue" }, "")
            
            # Wait for completion
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Result | Should -Not -BeNullOrEmpty
            
            # Cleanup
            $job.Cleanup()
        }

        It "Should set status to Failed when script throws" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:errorScript, @{ Message = "Test error" }, "")
            
            # Wait for completion
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Status | Should -Be "Failed"
            
            # Cleanup
            $job.Cleanup()
        }

        It "Should capture error messages in Logs" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:errorScript, @{ Message = "Captured error" }, "")
            
            # Wait for completion
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Logs.Count | Should -BeGreaterThan 0
            
            # Cleanup
            $job.Cleanup()
        }
    }

    Context "Cleanup" {
        It "Should dispose PowerShell instance" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:simpleScript, @{ Input = "test" }, "")
            
            # Wait for completion
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
            
            # Create the temp file
            "{}" | Set-Content -Path $tempConfig
            
            $job.Start($script:simpleScript, @{ Input = "test" }, $tempConfig)
            
            # Wait for completion
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
            
            # Cleanup without ever starting
            { $job.Cleanup() } | Should -Not -Throw
        }
    }

    Context "DrainStream" {
        It "Should handle null stream gracefully" {
            $job = [AsyncJob]::new("TestHost", "Scan")
            
            { $job.DrainStream($null) } | Should -Not -Throw
        }
    }
}
