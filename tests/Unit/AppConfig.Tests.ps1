using module "..\..\src\Models\AppConfig.psm1"

Describe "AppConfig" {

    BeforeAll {
        $script:testSourceRoot = "C:\TestSource"
        $script:testLogsPath = "C:\TestLogs"
        $script:testReportsPath = "C:\TestReports"
    }

    Context "Static Defaults" {
        It "Should have default activeCommand as 'scan'" {
            [AppConfig]::Defaults.activeCommand | Should -Be 'scan'
        }

        It "Should have default throttleLimit as 5" {
            [AppConfig]::Defaults.throttleLimit | Should -Be 5
        }

        It "Should have 'scan' command with args" {
            [AppConfig]::Defaults.commands.scan | Should -Not -BeNullOrEmpty
            [AppConfig]::Defaults.commands.scan.args | Should -Not -BeNullOrEmpty
        }

        It "Should have 'applyUpdates' command with args" {
            [AppConfig]::Defaults.commands.applyUpdates | Should -Not -BeNullOrEmpty
            [AppConfig]::Defaults.commands.applyUpdates.args | Should -Not -BeNullOrEmpty
        }

        It "Should have autoSuspendBitLocker defaulted to true for applyUpdates" {
            [AppConfig]::Defaults.commands.applyUpdates.args.autoSuspendBitLocker | Should -Be $true
        }
    }

    Context "Constructor" {
        It "Should initialize with provided paths" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $config.SourceRoot | Should -Be $script:testSourceRoot
            $config.LogsPath | Should -Be $script:testLogsPath
            $config.ReportsPath | Should -Be $script:testReportsPath
        }

        It "Should merge user settings with defaults" {
            $userSettings = @{
                activeCommand = 'applyUpdates'
                throttleLimit = 10
            }
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, $userSettings)
            
            $config.Settings.activeCommand | Should -Be 'applyUpdates'
            $config.Settings.throttleLimit | Should -Be 10
            # Defaults should still be present
            $config.Settings.commands | Should -Not -BeNullOrEmpty
        }

        It "Should handle null settings gracefully" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, $null)
            
            $config.Settings | Should -Not -BeNullOrEmpty
            $config.Settings.activeCommand | Should -Be 'scan'
        }

        It "Should deep merge command args" {
            $userSettings = @{
                commands = @{
                    scan = @{
                        args = @{
                            silent = $true
                            report = 'C:\CustomReport'
                        }
                    }
                }
            }
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, $userSettings)
            
            $config.Settings.commands.scan.args.silent | Should -Be $true
            $config.Settings.commands.scan.args.report | Should -Be 'C:\CustomReport'
            # Other defaults should still exist
            $config.Settings.commands.applyUpdates | Should -Not -BeNullOrEmpty
        }
    }

    Context "GetSetting / SetSetting" {
        It "Should get existing setting" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                customKey = 'customValue'
            })
            
            $config.GetSetting('customKey', 'default') | Should -Be 'customValue'
        }

        It "Should return default when setting does not exist" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $config.GetSetting('nonExistentKey', 'fallback') | Should -Be 'fallback'
        }

        It "Should set a new setting" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $config.SetSetting('newKey', 'newValue')
            
            $config.Settings.newKey | Should -Be 'newValue'
        }

        It "Should overwrite existing setting" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                existingKey = 'oldValue'
            })
            
            $config.SetSetting('existingKey', 'updatedValue')
            
            $config.Settings.existingKey | Should -Be 'updatedValue'
        }
    }

    Context "GetActiveCommand / SetActiveCommand" {
        It "Should return default 'scan' when not set" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $config.GetActiveCommand() | Should -Be 'scan'
        }

        It "Should return configured active command" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                activeCommand = 'applyUpdates'
            })
            
            $config.GetActiveCommand() | Should -Be 'applyUpdates'
        }

        It "Should set active command" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $config.SetActiveCommand('applyUpdates')
            
            $config.GetActiveCommand() | Should -Be 'applyUpdates'
        }
    }

    Context "GetCommandArgs / SetCommandArg" {
        It "Should return args for existing command" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $args = $config.GetCommandArgs('scan')
            
            $args | Should -Not -BeNullOrEmpty
            $args.ContainsKey('silent') | Should -Be $true
        }

        It "Should return empty hashtable for non-existent command" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $args = $config.GetCommandArgs('nonExistentCommand')
            
            $args | Should -BeOfType [hashtable]
            $args.Count | Should -Be 0
        }

        It "Should set command arg for existing command" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $config.SetCommandArg('scan', 'silent', $true)
            
            $config.GetCommandArgs('scan').silent | Should -Be $true
        }

        It "Should create command structure when setting arg for new command" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $config.SetCommandArg('newCommand', 'newArg', 'newValue')
            
            $config.GetCommandArgs('newCommand').newArg | Should -Be 'newValue'
        }
    }

    Context "GetThrottleLimit / SetThrottleLimit" {
        It "Should return default 5 when not set" {
            # Start fresh without the defaults being merged
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            $config.Settings.Remove('throttleLimit')  # Remove to test default
            
            $config.GetThrottleLimit() | Should -Be 5
        }

        It "Should return configured throttle limit" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                throttleLimit = 10
            })
            
            $config.GetThrottleLimit() | Should -Be 10
        }

        It "Should parse string throttle limit as int" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                throttleLimit = '15'
            })
            
            $config.GetThrottleLimit() | Should -Be 15
        }

        It "Should set throttle limit" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{})
            
            $config.SetThrottleLimit(20)
            
            $config.GetThrottleLimit() | Should -Be 20
        }
    }

    Context "BuildDcuArgs" {
        It "Should build empty string when args are all empty or false" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                commands = @{
                    customCmd = @{
                        args = @{
                            silent = $false
                            report = ''
                        }
                    }
                }
            })
            
            $result = $config.BuildDcuArgs('customCmd', @{})
            
            $result | Should -BeNullOrEmpty
        }

        It "Should build -silent flag for boolean true" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                commands = @{
                    scan = @{
                        args = @{
                            silent = $true
                        }
                    }
                }
            })
            
            $result = $config.BuildDcuArgs('scan', @{})
            
            $result | Should -BeLike "*-silent*"
            $result | Should -Not -BeLike "*=enable*"
        }

        It "Should build -reboot=enable for non-silent boolean true" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                commands = @{
                    applyUpdates = @{
                        args = @{
                            reboot = $true
                        }
                    }
                }
            })
            
            $result = $config.BuildDcuArgs('applyUpdates', @{})
            
            $result | Should -BeLike "*-reboot=enable*"
        }

        It "Should not include boolean false args" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                commands = @{
                    scan = @{
                        args = @{
                            silent = $false
                        }
                    }
                }
            })
            
            $result = $config.BuildDcuArgs('scan', @{})
            
            $result | Should -Not -BeLike "*-silent*"
        }

        It "Should build string args correctly" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                commands = @{
                    scan = @{
                        args = @{
                            report = 'C:\temp\DONUT'
                            updateSeverity = 'critical'
                        }
                    }
                }
            })
            
            $result = $config.BuildDcuArgs('scan', @{})
            
            $result | Should -BeLike "*-report=C:\temp\DONUT*"
            $result | Should -BeLike "*-updateSeverity=critical*"
        }

        It "Should quote paths with spaces" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                commands = @{
                    scan = @{
                        args = @{
                            report = 'C:\Program Files\DONUT Reports'
                        }
                    }
                }
            })
            
            $result = $config.BuildDcuArgs('scan', @{})
            
            $result | Should -BeLike '*-report="C:\Program Files\DONUT Reports"*'
        }

        It "Should apply runtime overrides" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                commands = @{
                    scan = @{
                        args = @{
                            report = 'C:\Original'
                        }
                    }
                }
            })
            
            $result = $config.BuildDcuArgs('scan', @{ report = 'C:\Override' })
            
            $result | Should -BeLike "*-report=C:\Override*"
            $result | Should -Not -BeLike "*C:\Original*"
        }

        It "Should skip empty string values" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                commands = @{
                    scan = @{
                        args = @{
                            report = ''
                            catalogLocation = '   '
                        }
                    }
                }
            })
            
            $result = $config.BuildDcuArgs('scan', @{})
            
            $result | Should -Not -BeLike "*-report=*"
            $result | Should -Not -BeLike "*-catalogLocation=*"
        }

        It "Should combine multiple args with spaces" {
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, @{
                commands = @{
                    scan = @{
                        args = @{
                            silent = $true
                            report = 'C:\temp'
                        }
                    }
                }
            })
            
            $result = $config.BuildDcuArgs('scan', @{})
            
            $result | Should -BeLike "*-silent*"
            $result | Should -BeLike "*-report=C:\temp*"
        }
    }

    Context "MergeWithDefaults (via Constructor)" {
        It "Should preserve default commands when user provides custom settings" {
            $userSettings = @{
                customSetting = 'customValue'
            }
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, $userSettings)
            
            $config.Settings.commands.scan | Should -Not -BeNullOrEmpty
            $config.Settings.commands.applyUpdates | Should -Not -BeNullOrEmpty
            $config.Settings.customSetting | Should -Be 'customValue'
        }

        It "Should deep merge user command args with defaults" {
            $userSettings = @{
                commands = @{
                    scan = @{
                        args = @{
                            silent = $true
                            customArg = 'customValue'
                        }
                    }
                }
            }
            $config = [AppConfig]::new($script:testSourceRoot, $script:testLogsPath, $script:testReportsPath, $userSettings)
            
            # User values
            $config.Settings.commands.scan.args.silent | Should -Be $true
            $config.Settings.commands.scan.args.customArg | Should -Be 'customValue'
            # Default values from scan should still exist
            $config.Settings.commands.scan.args.ContainsKey('report') | Should -Be $true
        }
    }
}
