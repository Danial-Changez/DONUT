Describe "RemoteWorker Integration" {
    
    BeforeAll {
        $testDir = Join-Path $env:TEMP "DonutIntegrationTests"
        if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
        
        $logsDir = Join-Path $testDir "Logs"
        $reportsDir = Join-Path $testDir "Reports"
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
        New-Item -Path $reportsDir -ItemType Directory -Force | Out-Null

        # Path to the script under test
        $scriptPath = "$PSScriptRoot\..\..\src\Scripts\RemoteWorker.ps1"
        $sourceRoot = "$PSScriptRoot\..\..\src"
    }

    AfterAll {
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Should run and log failure when target is unreachable or missing dependencies" {
        # We expect this to fail because we aren't mocking the network or PsExec,
        # but we want to verify the script executes, initializes the service, and logs the attempt.
        
        $hostName = "NonExistentHost"
        $jobType = "Scan"
        $options = @{}

        # Construct command string for -Command
        # We use -Command to allow passing a hashtable literal
        $command = "& '$scriptPath' -HostName '$hostName' -JobType '$jobType' -Options @{} -SourceRoot '$sourceRoot' -LogsDir '$logsDir' -ReportsDir '$reportsDir'"
        
        # Run the script in a separate process
        $p = Start-Process -FilePath "pwsh" -ArgumentList "-Command", "`"$command`"" -PassThru -Wait -NoNewWindow

        # Assert exit code is 1 (failure)
        $p.ExitCode | Should -Be 1

        # Assert log file was created
        $logFile = Join-Path $logsDir "Donut.log"
        Test-Path $logFile | Should -Be $true

        # Assert log contains the hostname (proof that ExecutionService started and logged)
        $content = Get-Content $logFile
        $content | Should -Match "\[$hostName\]"
    }
}
