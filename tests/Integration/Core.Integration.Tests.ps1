using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\..\src\Core\AsyncJob.psm1"
using module "..\..\src\Core\ConfigManager.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Models\AppConfig.psm1"

Describe "Core Module Integration" {

    BeforeAll {
        . "$PSScriptRoot\..\Helpers\New-RedirectedDataRoot.ps1"
        # ConfigManager anchors on %ProgramData%, so an unredirected run edits the real config.
        $script:redirect = New-RedirectedDataRoot -Prefix 'DonutCoreIntegration'
        $script:testRoot = $script:redirect.Root

        $script:testSourceRoot = Join-Path $script:testRoot "src"
        New-Item -Path $script:testSourceRoot `
                 -ItemType Directory `
                 -Force | Out-Null

        $script:scriptsDir = Join-Path $script:testSourceRoot "Scripts"
        New-Item -Path $script:scriptsDir -ItemType Directory -Force | Out-Null

        # Test worker speaks AsyncJob's child-process protocol (args in, result out).
        $script:testWorker = Join-Path $script:scriptsDir "TestWorker.ps1"
        @'
param([string]$ArgsFile, [string]$ResultFile)
$a = if ($ArgsFile) { Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
$result = @{ HostName = [string]$a.HostName; JobType = [string]$a.JobType; Success = $true }
if ($a.ConfigPath -and (Test-Path $a.ConfigPath)) {
    $config = Get-Content -LiteralPath $a.ConfigPath -Raw | ConvertFrom-Json
    $result.ActiveCommand = $config.activeCommand
}
$result | ConvertTo-Json | Set-Content -LiteralPath $ResultFile
'@ | Set-Content -Path $script:testWorker

        [RunspaceManager]::Initialize(1, 5)
    }

    AfterAll {
        [RunspaceManager]::Close()

        Remove-RedirectedDataRoot $script:redirect
    }

    Context "RunspaceManager + AsyncJob Integration" {
        It "Should execute multiple jobs concurrently using shared pool" {
            $jobs = @()

            for ($i = 1; $i -le 3; $i++) {
                $job = [AsyncJob]::new("Host$i", "Scan")
                $job.Start($script:testWorker, @{
                    HostName   = "Host$i"
                    JobType    = "Scan"
                    ConfigPath = ""
                }, "")
                $jobs += $job
            }

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

            foreach ($job in $jobs) {
                $job.Status | Should -Be "Completed"
                $job.Cleanup()
            }
        }

        It "Should properly share RunspacePool across AsyncJobs" {
            $pool1 = [RunspaceManager]::GetPool()

            $job = [AsyncJob]::new("TestHost", "Scan")
            $job.Start($script:testWorker, @{
                HostName   = "TestHost"
                JobType    = "Scan"
                ConfigPath = ""
            }, "")

            $pool2 = [RunspaceManager]::GetPool()
            $pool1 | Should -Be $pool2

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

            $config = [AppConfig]::new($script:testSourceRoot, $configManager.LogsPath, $configManager.ReportsPath, @{
                activeCommand = "scan"
                throttleLimit = 5
            })
            $configManager.SaveConfig($config)

            $tempConfig = Join-Path $script:testRoot "temp_job_config.json"
            $config.Settings | ConvertTo-Json -Depth 10 | Set-Content -Path $tempConfig

            $job = [AsyncJob]::new("ConfigTestHost", "Scan")
            $job.Start($script:testWorker, @{
                HostName   = "ConfigTestHost"
                JobType    = "Scan"
                ConfigPath = $tempConfig
            }, $tempConfig)

            $timeout = [DateTime]::Now.AddSeconds(10)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 50
            }

            $job.Status | Should -Be "Completed"

            $job.Cleanup()
            Test-Path $tempConfig | Should -Be $false
        }

        It "Should load config, modify, save, and reload correctly" {
            $configManager = [ConfigManager]::new($script:testSourceRoot)

            $config1 = [AppConfig]::new($script:testSourceRoot, $configManager.LogsPath, $configManager.ReportsPath, @{
                activeCommand = "scan"
                throttleLimit = 3
            })
            $configManager.SaveConfig($config1)

            $loaded = $configManager.LoadConfig()
            $loaded.Settings.activeCommand | Should -Be "scan"

            $loaded.Settings.activeCommand = "applyUpdates"
            $loaded.Settings.throttleLimit = 10
            $configManager.SaveConfig($loaded)

            $reloaded = $configManager.LoadConfig()
            $reloaded.Settings.activeCommand | Should -Be "applyUpdates"
            $reloaded.Settings.throttleLimit | Should -Be 10
        }
    }

    Context "NetworkProbe + AsyncJob Integration" {
        It "Should use NetworkProbe to validate host before creating job" {
            $probe = [NetworkProbe]::new()

            $isOnline = $probe.IsOnline("localhost")

            if ($isOnline) {
                $job = [AsyncJob]::new("localhost", "Scan")
                $job.Start($script:testWorker, @{
                    HostName   = "localhost"
                    JobType    = "Scan"
                    ConfigPath = ""
                }, "")

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

        }

        It "Should resolve hostname before job execution" {
            $probe = [NetworkProbe]::new()

            # Resolution is DC-authoritative: an address only comes back when a DC is reachable.
            $ip = $probe.ResolveHost("localhost")
            if (Get-Command Get-ADDomainController -ErrorAction SilentlyContinue) {
                $ip | Should -Not -BeNullOrEmpty
            } else {
                # Off-domain (no AD module): resolution fails hard, returning null.
                $ip | Should -BeNullOrEmpty
            }

            $job = [AsyncJob]::new("localhost", "Scan")
            $job.Start($script:testWorker, @{
                HostName   = "localhost"
                JobType    = "Scan"
                ConfigPath = ""
            }, "")

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
            $configManager = [ConfigManager]::new($script:testSourceRoot)
            $config = [AppConfig]::new($script:testSourceRoot, $configManager.LogsPath, $configManager.ReportsPath, @{
                activeCommand = "scan"
                throttleLimit = 5
            })
            $configManager.SaveConfig($config)

            $probe = [NetworkProbe]::new()
            $targetHost = "localhost"
            $isOnline = $probe.IsOnline($targetHost)
            $isOnline | Should -Be $true

            $tempConfig = Join-Path $script:testRoot "pipeline_config.json"
            $config.Settings | ConvertTo-Json -Depth 10 | Set-Content -Path $tempConfig

            $job = [AsyncJob]::new($targetHost, $config.Settings.activeCommand)
            $job.Start($script:testWorker, @{
                HostName   = $targetHost
                JobType    = $config.Settings.activeCommand
                ConfigPath = $tempConfig
            }, $tempConfig)

            $timeout = [DateTime]::Now.AddSeconds(15)
            while ($job.Status -eq "Running" -and [DateTime]::Now -lt $timeout) {
                $job.Poll()
                Start-Sleep -Milliseconds 100
            }

            $job.Status | Should -Be "Completed"
            $job.Result | Should -Not -BeNullOrEmpty

            $job.Cleanup()
            Test-Path $tempConfig | Should -Be $false
        }
    }
}
