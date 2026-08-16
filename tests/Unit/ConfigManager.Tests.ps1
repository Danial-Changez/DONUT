using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Core\ConfigManager.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

Describe "ConfigManager" {

    BeforeAll {
        . "$PSScriptRoot\..\Helpers\New-RedirectedDataRoot.ps1"
        # ConfigManager anchors on DonutPaths, so an unredirected run edits the real config.
        $script:redirect = New-RedirectedDataRoot -Prefix 'ConfigManager' -Under $TestDrive
        $script:testRoot = $script:redirect.Root
        $script:testSourceRoot = Join-Path $testRoot "src"
        New-Item -Path $testSourceRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-RedirectedDataRoot $script:redirect
    }

    BeforeEach {
        $configDir = Join-Path $script:testRoot "DONUT\config"
        if (Test-Path $configDir) {
            Remove-Item -Path $configDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Constructor" {
        It "Should initialize with correct paths" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            $manager.SourceRoot | Should -Be $script:testSourceRoot
            $manager.ConfigPath | Should -BeLike "*DONUT*config*config.json"
            $manager.LogsPath | Should -BeLike "*DONUT*logs"
            $manager.ReportsPath | Should -BeLike "*DONUT*reports"
        }

        It "Should create necessary directories on initialization" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            $configDir = Split-Path $manager.ConfigPath -Parent
            Test-Path $configDir | Should -Be $true
            Test-Path $manager.LogsPath | Should -Be $true
            Test-Path $manager.ReportsPath | Should -Be $true
        }
    }

    Context "EnsureDirectories" {
        It "Should create directories if they do not exist" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            $configDir = Split-Path $manager.ConfigPath -Parent
            Remove-Item -Path $configDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $manager.LogsPath -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $manager.ReportsPath -Recurse -Force -ErrorAction SilentlyContinue
            
            $manager.EnsureDirectories()
            
            Test-Path $configDir | Should -Be $true
            Test-Path $manager.LogsPath | Should -Be $true
            Test-Path $manager.ReportsPath | Should -Be $true
        }

        It "Should not fail if directories already exist" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            { $manager.EnsureDirectories() } | Should -Not -Throw
        }
    }

    Context "SaveConfig" {
        It "Should save config to JSON file" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            $config = [AppConfig]::new($script:testSourceRoot, $manager.LogsPath, $manager.ReportsPath, @{
                activeCommand = "scan"
                throttleLimit = 10
            })
            
            $manager.SaveConfig($config)
            
            Test-Path $manager.ConfigPath | Should -Be $true
            $content = Get-Content $manager.ConfigPath -Raw
            $content | Should -BeLike "*activeCommand*"
            $content | Should -BeLike "*scan*"
        }

        It "Should save nested settings correctly" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            $config = [AppConfig]::new($script:testSourceRoot, $manager.LogsPath, $manager.ReportsPath, @{
                activeCommand = "scan"
                commands      = @{
                    scan = @{
                        args = @{
                            silent = $true
                        }
                    }
                }
            })
            
            $manager.SaveConfig($config)
            
            $json = Get-Content $manager.ConfigPath -Raw | ConvertFrom-Json -AsHashtable
            $json.commands.scan.args.silent | Should -Be $true
        }
    }

    Context "LoadConfig" {
        It "Should load existing config from file" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            $testSettings = @{
                activeCommand = "applyUpdates"
                throttleLimit = 8
            }
            $testSettings | ConvertTo-Json -Depth 10 | Set-Content -Path $manager.ConfigPath
            
            $config = $manager.LoadConfig()
            
            $config | Should -Not -BeNullOrEmpty
            $config.Settings.activeCommand | Should -Be "applyUpdates"
            $config.Settings.throttleLimit | Should -Be 8
        }

        It "Should return default config when file does not exist" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            if (Test-Path $manager.ConfigPath) {
                Remove-Item $manager.ConfigPath -Force
            }
            
            $config = $manager.LoadConfig()
            
            $config | Should -Not -BeNullOrEmpty
            $config.SourceRoot | Should -Be $script:testSourceRoot
        }

        It "Should create default config file when none exists" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            if (Test-Path $manager.ConfigPath) {
                Remove-Item $manager.ConfigPath -Force
            }
            
            $config = $manager.LoadConfig()
            
            Test-Path $manager.ConfigPath | Should -Be $true
        }

        It "Should handle malformed JSON gracefully" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            "{ invalid json }" | Set-Content -Path $manager.ConfigPath

            $config = $manager.LoadConfig()
            $config | Should -Not -BeNullOrEmpty
        }
    }

    Context "Logging" {
        It "Should log an error through the injected logger on malformed JSON" {
            $logger = [CapturingLogService]::new()
            $manager = [ConfigManager]::new($script:testSourceRoot, $logger)

            "{ invalid json }" | Set-Content -Path $manager.ConfigPath

            $config = $manager.LoadConfig()

            $config | Should -Not -BeNullOrEmpty
            $logger.HasLevel("ERROR") | Should -Be $true
        }

        It "Should log an info entry when a config is loaded" {
            $logger = [CapturingLogService]::new()
            $manager = [ConfigManager]::new($script:testSourceRoot, $logger)
            @{ activeCommand = "scan" } | ConvertTo-Json | Set-Content -Path $manager.ConfigPath

            $manager.LoadConfig() | Out-Null

            $logger.HasLevel("INFO") | Should -Be $true
        }

        It "Should default to a no-op logger when constructed without one" {
            $manager = [ConfigManager]::new($script:testSourceRoot)

            $manager.Logger | Should -Not -BeNullOrEmpty
            "{ invalid json }" | Set-Content -Path $manager.ConfigPath
            { $manager.LoadConfig() } | Should -Not -Throw
        }
    }

    Context "Round-trip Save and Load" {
        It "Should preserve settings through save and load cycle" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            $originalConfig = [AppConfig]::new($script:testSourceRoot, $manager.LogsPath, $manager.ReportsPath, @{
                activeCommand = "scan"
                throttleLimit = 5
                commands      = @{
                    scan = @{
                        args = @{
                            silent = $false
                            report = "C:\Reports"
                        }
                    }
                }
            })
            
            $manager.SaveConfig($originalConfig)
            $loadedConfig = $manager.LoadConfig()
            
            $loadedConfig.Settings.activeCommand | Should -Be "scan"
            $loadedConfig.Settings.throttleLimit | Should -Be 5
            $loadedConfig.Settings.commands.scan.args.silent | Should -Be $false
            $loadedConfig.Settings.commands.scan.args.report | Should -Be "C:\Reports"
        }
    }
}
