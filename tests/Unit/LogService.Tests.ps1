using module "..\..\src\Core\LogService.psm1"

Describe "LogService" {

    BeforeAll {
        $script:tempDir = Join-Path $TestDrive 'LogService'
    }

    BeforeEach {
        $script:testLogDir = Join-Path $script:tempDir "Logs_$(Get-Random)"
        New-Item -Path $script:testLogDir -ItemType Directory -Force | Out-Null
    }

    Context "Constructor" {
        It "Should create log directory if it does not exist" {
            $newLogDir = Join-Path $script:tempDir "NewLogDir_$(Get-Random)"

            $null = [LogService]::new($newLogDir)

            Test-Path $newLogDir | Should -Be $true
        }

        It "Should set LogFilePath to Donut.log in the directory" {
            $logger = [LogService]::new($script:testLogDir)

            $expectedPath = Join-Path $script:testLogDir "Donut.log"
            $logger.LogFilePath | Should -Be $expectedPath
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

    Context "Thread Safety" {
        It "Should handle concurrent writes without error" {
            $logger = [LogService]::new($script:testLogDir)

            1..20 | ForEach-Object {
                $logger.LogInfo("Concurrent message $_")
            }

            $logs = Get-Content -Path $logger.LogFilePath -Tail 20
            $logs.Count | Should -Be 20
            $logs[-1] | Should -BeLike "*Concurrent message 20*"
        }
    }

    Context "Log Levels" {
        It "Should support all standard log levels" {
            $logger = [LogService]::new($script:testLogDir)

            $logger.LogInfo("Info test")
            $logger.LogWarning("Warning test")
            $logger.LogError("Error test")
            $logger.LogDebug("Debug test")

            $content = Get-Content -Path $logger.LogFilePath -Raw

            $content | Should -BeLike "*[INFO]*Info test*"
            $content | Should -BeLike "*[WARN]*Warning test*"
            $content | Should -BeLike "*[ERROR]*Error test*"
            $content | Should -BeLike "*[DEBUG]*Debug test*"
        }
    }

    Context "LogDebug" {
        It "Should write DEBUG level log entry" {
            $logger = [LogService]::new($script:testLogDir)

            $logger.LogDebug("Test debug message")

            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -BeLike "*[DEBUG]*"
            $content | Should -BeLike "*Test debug message*"
        }

        It "Drops DEBUG (and only DEBUG) when DebugEnabled is off" {
            $logger = [LogService]::new($script:testLogDir)
            $logger.DebugEnabled = $false

            $logger.LogDebug("gated line")
            $logger.LogInfo("info still flows")
            $logger.LogWarning("warn still flows")

            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -Not -BeLike "*gated line*"
            $content | Should -BeLike "*info still flows*"
            $content | Should -BeLike "*warn still flows*"
        }

        It "Re-enabling DebugEnabled resumes DEBUG writes (live toggle)" {
            $logger = [LogService]::new($script:testLogDir)
            $logger.DebugEnabled = $false
            $logger.LogDebug("before")
            $logger.DebugEnabled = $true
            $logger.LogDebug("after")

            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -Not -BeLike "*before*"
            $content | Should -BeLike "*[DEBUG]*after*"
        }
    }

    Context "LogException" {
        It "Should log ERROR with the exception type and message" {
            $logger = [LogService]::new($script:testLogDir)

            try { throw [System.InvalidOperationException]::new("boom") }
            catch { $logger.LogException("While doing work", $_) }

            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -BeLike "*[ERROR]*"
            $content | Should -BeLike "*While doing work*"
            $content | Should -BeLike "*InvalidOperationException*"
            $content | Should -BeLike "*boom*"
        }

        It "Should not throw when given a null error record" {
            $logger = [LogService]::new($script:testLogDir)

            { $logger.LogException("No error attached", $null) } | Should -Not -Throw

            $content = Get-Content -Path $logger.LogFilePath -Raw
            $content | Should -BeLike "*[ERROR]*No error attached*"
            $content | Should -BeLike "*<no exception detail>*"
        }
    }

    Context "NullLogService" {
        It "Should be assignable to a LogService dependency" {
            $logger = [NullLogService]::new()

            ($logger -is [LogService]) | Should -Be $true
        }

        It "Should make all log writes no-ops without touching the file system" {
            $logger = [NullLogService]::new()

            { $logger.LogInfo("ignored") } | Should -Not -Throw
            { $logger.LogError("ignored") } | Should -Not -Throw
            { $logger.LogException("ignored", $null) } | Should -Not -Throw

            $logger.LogFilePath | Should -BeNullOrEmpty
        }
    }

    Context "Rotate" {
        It "rolls an oversized log to Donut.old.log and replaces the previous roll" {
            $log = Join-Path $script:testLogDir 'Donut.log'
            $old = Join-Path $script:testLogDir 'Donut.old.log'
            Set-Content -Path $log -Value ('x' * 64) -NoNewline
            Set-Content -Path $old -Value 'previous roll' -NoNewline

            [LogService]::Rotate($script:testLogDir, 10)

            Test-Path $log | Should -BeFalse
            Get-Content $old -Raw | Should -BeLike 'xxx*'
        }

        It "leaves a log under the limit alone" {
            $log = Join-Path $script:testLogDir 'Donut.log'
            Set-Content -Path $log -Value 'small' -NoNewline

            [LogService]::Rotate($script:testLogDir, 10MB)

            Test-Path $log | Should -BeTrue
            Test-Path (Join-Path $script:testLogDir 'Donut.old.log') | Should -BeFalse
        }

        It "does not throw when no log exists yet" {
            { [LogService]::Rotate($script:testLogDir, 10MB) } | Should -Not -Throw
        }
    }
}
