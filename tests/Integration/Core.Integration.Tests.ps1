using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\..\src\Core\AsyncJob.psm1"
using module "..\..\src\Core\ConfigManager.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Models\AppConfig.psm1"

Describe "Core Module Integration" {

    BeforeAll {
        # Setup test environment
        $script:testRoot = Join-Path $env:TEMP "DonutCoreIntegration_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        
        $script:testSourceRoot = Join-Path $script:testRoot "src"
        New-Item -Path $script:testSourceRoot -ItemType Directory -Force | Out-Null
        
        # Create test scripts directory
        $script:scriptsDir = Join-Path $script:testSourceRoot "Scripts"
        New-Item -Path $script:scriptsDir -ItemType Directory -Force | Out-Null
        
        # Create a test worker script
        $script:testWorker = Join-Path $script:scriptsDir "TestWorker.ps1"
        @'
param(
    [string]$HostName,
    [string]$JobType,
    [string]$ConfigPath
)

# Simulate work
Write-Output "Processing $JobType for $HostName"

if ($ConfigPath -and (Test-Path $ConfigPath)) {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Write-Output "Loaded config with activeCommand: $($config.activeCommand)"
}

return @{
    HostName = $HostName
    JobType = $JobType
    Success = $true
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}
'@ | Set-Content -Path $script:testWorker

        # Override LOCALAPPDATA for ConfigManager tests
        $script:originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $script:testRoot
        
        # Initialize RunspaceManager
        [RunspaceManager]::Initialize(1, 5)
    }

    AfterAll {
        [RunspaceManager]::Close()
        
        # Restore LOCALAPPDATA
        $env:LOCALAPPDATA = $script:originalLocalAppData
        
        # Cleanup
        if (Test-Path $script:testRoot) {
            Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "RunspaceManager + AsyncJob Integration" {
        It "Should execute multiple jobs concurrently using shared pool" {
            $jobs = @()
            
            # Create multiple jobs
            for ($i = 1; $i -le 3; $i++) {
                $job = [AsyncJob]::new("Host$i", "Scan")
                $job.Start($script:testWorker, @{
                    HostName = "Host$i"
                    JobType = "Scan"
                    ConfigPath = ""
                }, "")
                $jobs += $job
            }
            
            # Wait for all to complete
            $timeout = [DateTime]::Now.AddSeconds(30)
            $allComplete = $false
            
            while (-not $allComplete -and [DateTime]::Now -lt $timeout) {
                $allComplete = $true
                foreach ($job in $jobs) {
                    $job.Poll()
                    if ($job.Status -eq "Running") {
                        $allComplete = $false
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            
            # Verify all completed
            foreach ($job in $jobs) {
                $job.Status | Should -Be "Completed"
                $job.Cleanup()
            }
        }

        It "Should properly share RunspacePool across AsyncJobs" {
            $pool1 = [RunspaceManager]::GetPool()
            
            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:testWorker, @{
                HostName = "TestHost"
                JobType = "Scan"
                ConfigPath = ""
            }, "")
            
            # The job should use the same pool
            $pool2 = [RunspaceManager]::GetPool()
            $pool1 | Should -Be $pool2
            
            # Wait and cleanup
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            $job.Cleanup()
        }
    }

    Context "ConfigManager + AsyncJob Integration" {
        It "Should pass config to AsyncJob via temp file" {
            $configManager = [ConfigManager]::new($script:testSourceRoot)
            
            # Create and save config
            $config = [AppConfig]::new($script:testSourceRoot, $configManager.LogsPath, $configManager.ReportsPath, @{
                activeCommand = "scan"
                throttleLimit = 5
            })
            $configManager.SaveConfig($config)
            
            # Create temp config for job
            $tempConfig = Join-Path $script:testRoot "temp_job_config.json"
            $config.Settings | ConvertTo-Json -Depth 10 | Set-Content -Path $tempConfig
            
            # Start job with config
            $job = [AsyncJob]::new("ConfigTestHost", "Scan")
            $job.Start($script:testWorker, @{
                HostName = "ConfigTestHost"
                JobType = "Scan"
                ConfigPath = $tempConfig
            }, $tempConfig)
            
            # Wait for completion
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Status | Should -Be "Completed"
            
            # Cleanup should remove temp config
            $job.Cleanup()
            Test-Path $tempConfig | Should -Be $false
        }

        It "Should load config, modify, save, and reload correctly" {
            $configManager = [ConfigManager]::new($script:testSourceRoot)
            
            # Initial save
            $config1 = [AppConfig]::new($script:testSourceRoot, $configManager.LogsPath, $configManager.ReportsPath, @{
                activeCommand = "scan"
                throttleLimit = 3
            })
            $configManager.SaveConfig($config1)
            
            # Load
            $loaded = $configManager.LoadConfig()
            $loaded.Settings.activeCommand | Should -Be "scan"
            
            # Modify and save
            $loaded.Settings.activeCommand = "applyUpdates"
            $loaded.Settings.throttleLimit = 10
            $configManager.SaveConfig($loaded)
            
            # Reload and verify
            $reloaded = $configManager.LoadConfig()
            $reloaded.Settings.activeCommand | Should -Be "applyUpdates"
            $reloaded.Settings.throttleLimit | Should -Be 10
        }
    }

    Context "NetworkProbe + AsyncJob Integration" {
        It "Should use NetworkProbe to validate host before creating job" {
            $probe = [NetworkProbe]::new()
            
            # Check localhost (should be online)
            $isOnline = $probe.IsOnline("localhost")
            
            if ($isOnline) {
                $job = [AsyncJob]::new("localhost", "Scan")
                $job.Start($script:testWorker, @{
                    HostName = "localhost"
                    JobType = "Scan"
                    ConfigPath = ""
                }, "")
                
                # Wait for completion
                $timeout = [DateTime]::Now.AddSeconds(10)
                while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                    $job.Poll()
                    Start-Sleep -Milliseconds 50
                }
                
                $job.Status | Should -Be "Completed"
                $job.Cleanup()
            }
            
            $isOnline | Should -Be $true
        }

        It "Should skip job creation for offline hosts" {
            $probe = [NetworkProbe]::new()
            
            $isOnline = $probe.IsOnline("definitely-not-a-real-host-xyz-99999")
            
            $isOnline | Should -Be $false
            
            # In real code, we'd skip job creation here
            # This test verifies the probe correctly identifies offline hosts
        }

        It "Should resolve hostname before job execution" {
            $probe = [NetworkProbe]::new()
            
            $ip = $probe.ResolveHost("localhost")
            $ip | Should -Not -BeNullOrEmpty
            
            # Create job with resolved info
            $job = [AsyncJob]::new("localhost", "Scan")
            $job.Start($script:testWorker, @{
                HostName = "localhost"
                JobType = "Scan"
                ConfigPath = ""
            }, "")
            
            # Wait for completion
            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }
            
            $job.Status | Should -Be "Completed"
            $job.Cleanup()
        }
    }

    Context "Full Pipeline Integration" {
        It "Should execute complete workflow: Config -> Probe -> AsyncJob" {
            # 1. Setup ConfigManager
            $configManager = [ConfigManager]::new($script:testSourceRoot)
            $config = [AppConfig]::new($script:testSourceRoot, $configManager.LogsPath, $configManager.ReportsPath, @{
                activeCommand = "scan"
                throttleLimit = 5
            })
            $configManager.SaveConfig($config)
            
            # 2. Probe host
            $probe = [NetworkProbe]::new()
            $targetHost = "localhost"
            $isOnline = $probe.IsOnline($targetHost)
            $isOnline | Should -Be $true
            
            # 3. Create temp config for job
            $tempConfig = Join-Path $script:testRoot "pipeline_config.json"
            $config.Settings | ConvertTo-Json -Depth 10 | Set-Content -Path $tempConfig
            
            # 4. Execute job
            $job = [AsyncJob]::new($targetHost, $config.Settings.activeCommand)
            $job.Start($script:testWorker, @{
                HostName = $targetHost
                JobType = $config.Settings.activeCommand
                ConfigPath = $tempConfig
            }, $tempConfig)
            
            # 5. Poll until complete
            $timeout = [DateTime]::Now.AddSeconds(15)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 100
            }
            
            # 6. Verify results
            $job.Status | Should -Be "Completed"
            $job.Result | Should -Not -BeNullOrEmpty
            
            # 7. Cleanup
            $job.Cleanup()
            Test-Path $tempConfig | Should -Be $false
        }
    }
}
