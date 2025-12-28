using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Core\ConfigManager.psm1"

Describe "ConfigManager" {

    BeforeAll {
        # Use a unique temp directory for tests to avoid conflicts with real config
        $script:testRoot = Join-Path $env:TEMP "DonutConfigManagerTests_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:testSourceRoot = Join-Path $testRoot "src"
        New-Item -Path $testSourceRoot -ItemType Directory -Force | Out-Null
        
        # Override LOCALAPPDATA for testing
        $script:originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $testRoot
    }

    AfterAll {
        # Restore original LOCALAPPDATA
        $env:LOCALAPPDATA = $script:originalLocalAppData
        
        # Cleanup
        if (Test-Path $script:testRoot) {
            Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        # Clean up any existing config for each test
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
            
            # Remove directories
            $configDir = Split-Path $manager.ConfigPath -Parent
            Remove-Item -Path $configDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $manager.LogsPath -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $manager.ReportsPath -Recurse -Force -ErrorAction SilentlyContinue
            
            # Call EnsureDirectories
            $manager.EnsureDirectories()
            
            Test-Path $configDir | Should -Be $true
            Test-Path $manager.LogsPath | Should -Be $true
            Test-Path $manager.ReportsPath | Should -Be $true
        }

        It "Should not fail if directories already exist" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            # Call twice - should not throw
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
                commands = @{
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
            
            # Create a config file manually
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
            
            # Ensure no config file exists
            if (Test-Path $manager.ConfigPath) {
                Remove-Item $manager.ConfigPath -Force
            }
            
            $config = $manager.LoadConfig()
            
            $config | Should -Not -BeNullOrEmpty
            $config.SourceRoot | Should -Be $script:testSourceRoot
        }

        It "Should create default config file when none exists" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            # Ensure no config file exists
            if (Test-Path $manager.ConfigPath) {
                Remove-Item $manager.ConfigPath -Force
            }
            
            $config = $manager.LoadConfig()
            
            Test-Path $manager.ConfigPath | Should -Be $true
        }

        It "Should handle malformed JSON gracefully" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            # Write invalid JSON
            "{ invalid json }" | Set-Content -Path $manager.ConfigPath
            
            # Should not throw, should return config with empty settings
            $config = $manager.LoadConfig()
            $config | Should -Not -BeNullOrEmpty
        }
    }

    Context "Round-trip Save and Load" {
        It "Should preserve settings through save and load cycle" {
            $manager = [ConfigManager]::new($script:testSourceRoot)
            
            $originalConfig = [AppConfig]::new($script:testSourceRoot, $manager.LogsPath, $manager.ReportsPath, @{
                activeCommand = "scan"
                throttleLimit = 5
                commands = @{
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
