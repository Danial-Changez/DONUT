using module "..\..\src\Services\LogService.psm1"

Describe "LogService" {

    BeforeAll {
        $script:tempDir = Join-Path $env:TEMP "DonutTests_LogService_$(Get-Random)"
    }

    AfterAll {
        if (Test-Path $script:tempDir) {
            Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        # Create a fresh log directory for each test
        $script:testLogDir = Join-Path $script:tempDir "Logs_$(Get-Random)"
        if (-not (Test-Path $script:testLogDir)) {
            New-Item -Path $script:testLogDir -ItemType Directory -Force | Out-Null
        }
    }

    AfterEach {
        if (Test-Path $script:testLogDir) {
            Remove-Item -Path $script:testLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Constructor" {
        It "Should create log directory if it does not exist" {
            $newLogDir = Join-Path $script:tempDir "NewLogDir_$(Get-Random)"
            
            $logger = [LogService]::new($newLogDir)
            
            Test-Path $newLogDir | Should -Be $true
            
            # Cleanup
            Remove-Item -Path $newLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should set LogFilePath to Donut.log in the directory" {
            $logger = [LogService]::new($script:testLogDir)
            
            $expectedPath = Join-Path $script:testLogDir "Donut.log"
            $logger.LogFilePath | Should -Be $expectedPath
        }

        It "Should initialize SyncRoot for thread safety" {
            $logger = [LogService]::new($script:testLogDir)
            
            $logger.SyncRoot | Should -Not -BeNullOrEmpty
        }

        It "Should not fail if directory already exists" {
            $logger1 = [LogService]::new($script:testLogDir)
            $logger2 = [LogService]::new($script:testLogDir)
            
            $logger1.LogFilePath | Should -Be $logger2.LogFilePath
        }
    }

    Context "LogInfo" {
        It "Should write INFO level log entry" {
            $logger = [LogService]::new($script:testLogDir)
            
            $logger.LogInfo("Test info message")
            
            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -BeLike "*[INFO]*"
            $content | Should -BeLike "*Test info message*"
        }

        It "Should include timestamp in log entry" {
            $logger = [LogService]::new($script:testLogDir)
            $datePart = Get-Date -Format "yyyy-MM-dd"
            
            $logger.LogInfo("Timestamp test")
            
            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -BeLike "*$datePart*"
        }
    }

    Context "LogError" {
        It "Should write ERROR level log entry" {
            $logger = [LogService]::new($script:testLogDir)
            
            $logger.LogError("Test error message")
            
            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -BeLike "*[ERROR]*"
            $content | Should -BeLike "*Test error message*"
        }
    }

    Context "LogWarning" {
        It "Should write WARN level log entry" {
            $logger = [LogService]::new($script:testLogDir)
            
            $logger.LogWarning("Test warning message")
            
            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -BeLike "*[WARN]*"
            $content | Should -BeLike "*Test warning message*"
        }
    }

    Context "WriteLog" {
        It "Should format log entry with timestamp, level, and message" {
            $logger = [LogService]::new($script:testLogDir)
            
            $logger.WriteLog("DEBUG", "Custom level test")
            
            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -BeLike "*[DEBUG]*"
            $content | Should -BeLike "*Custom level test*"
            # Verify format: [timestamp] [level] message
            $content | Should -Match "\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[DEBUG\] Custom level test"
        }

        It "Should append to existing log file" {
            $logger = [LogService]::new($script:testLogDir)
            
            $logger.LogInfo("First message")
            $logger.LogInfo("Second message")
            $logger.LogError("Third message")
            
            $lines = Get-Content -Path $logger.LogFilePath
            $lines.Count | Should -Be 3
        }
    }

    Context "GetRecentLogs" {
        It "Should return empty array when no logs exist" {
            $emptyLogDir = Join-Path $script:tempDir "EmptyLogs_$(Get-Random)"
            New-Item -Path $emptyLogDir -ItemType Directory -Force | Out-Null
            $logger = [LogService]::new($emptyLogDir)
            # Don't write any logs
            
            # Remove the log file if it was created
            Remove-Item -Path $logger.LogFilePath -Force -ErrorAction SilentlyContinue
            
            $logs = $logger.GetRecentLogs(10)
            
            $logs.Count | Should -Be 0
            
            # Cleanup
            Remove-Item -Path $emptyLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should return specified number of recent logs" {
            $logger = [LogService]::new($script:testLogDir)
            
            1..10 | ForEach-Object { $logger.LogInfo("Message $_") }
            
            $logs = $logger.GetRecentLogs(5)
            
            $logs.Count | Should -Be 5
            $logs[-1] | Should -BeLike "*Message 10*"
        }

        It "Should return all logs if count exceeds total" {
            $logger = [LogService]::new($script:testLogDir)
            
            1..3 | ForEach-Object { $logger.LogInfo("Message $_") }
            
            $logs = $logger.GetRecentLogs(100)
            
            $logs.Count | Should -Be 3
        }

        It "Should return logs in chronological order" {
            $logger = [LogService]::new($script:testLogDir)
            
            $logger.LogInfo("First")
            $logger.LogInfo("Second")
            $logger.LogInfo("Third")
            
            $logs = $logger.GetRecentLogs(3)
            
            $logs[0] | Should -BeLike "*First*"
            $logs[1] | Should -BeLike "*Second*"
            $logs[2] | Should -BeLike "*Third*"
        }
    }

    Context "Thread Safety" {
        It "Should have a valid SyncRoot object" {
            $logger = [LogService]::new($script:testLogDir)
            
            $logger.SyncRoot | Should -BeOfType [System.Object]
        }

        It "Should handle concurrent writes without error" {
            $logger = [LogService]::new($script:testLogDir)
            
            # Write multiple logs quickly (simulating concurrent access)
            1..20 | ForEach-Object {
                $logger.LogInfo("Concurrent message $_")
            }
            
            $logs = $logger.GetRecentLogs(20)
            $logs.Count | Should -Be 20
        }
    }

    Context "Log Levels" {
        It "Should support all standard log levels" {
            $logger = [LogService]::new($script:testLogDir)
            
            $logger.LogInfo("Info test")
            $logger.LogWarning("Warning test")
            $logger.LogError("Error test")
            
            $content = Get-Content -Path $logger.LogFilePath -Raw
            
            $content | Should -BeLike "*[INFO]*Info test*"
            $content | Should -BeLike "*[WARN]*Warning test*"
            $content | Should -BeLike "*[ERROR]*Error test*"
        }
    }
}
