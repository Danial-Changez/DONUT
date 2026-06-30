using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\RemoteError.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Services\DriverMatchingService.psm1"
using module "..\..\src\Services\RemoteServices.psm1"
using module "..\Helpers\CapturingLogService.psm1"
using namespace System.Net

# Mock NetworkProbe for testing
class MockNetworkProbe : NetworkProbe {
    [bool] $IsOnlineResult = $true
    [bool] $IsRpcAvailableResult = $true
    [IPAddress] $ResolveHostResult = [IPAddress]::Parse("127.0.0.1")
    [bool] $ReverseDnsResult = $true

    MockNetworkProbe() {}

    [bool] IsOnline([string]$hostName) { return $this.IsOnlineResult }
    [bool] IsRpcAvailable([string]$hostName) { return $this.IsRpcAvailableResult }
    [IPAddress] ResolveHost([string]$hostName) { return $this.ResolveHostResult }
    [bool] CheckReverseDNS([IPAddress]$ip, [string]$hostName) { return $this.ReverseDnsResult }
}

Describe "RemoteServices" {
    
    BeforeAll {
        # Setup
        $tempDir = Join-Path $env:TEMP "DonutTests_Remote"
        if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }
        $scriptsDir = Join-Path $tempDir "Scripts"
        if (-not (Test-Path $scriptsDir)) { New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null }
        New-Item -Path (Join-Path $scriptsDir "RemoteWorker.ps1") -ItemType File -Force | Out-Null
        
        $config = [AppConfig]::new($tempDir, (Join-Path $tempDir "Logs"), (Join-Path $tempDir "Reports"), @{})
    }

    AfterAll {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "ScanService" {
        It "Should initialize correctly" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)
            $service | Should -Not -BeNullOrEmpty
        }

        It "PrepareScan should return correct arguments (no network on the UI thread)" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)

            $result = $service.PrepareScan("TestHost")

            # Pester 5 assertions
            $result.ScriptPath | Should -Match "Scripts\\RemoteWorker.ps1$"
            $result.Arguments.HostName | Should -Be "TestHost"
            $result.Arguments.JobType | Should -Be "Scan"
        }

        It "PrepareScan does NOT probe connectivity (that is the worker's job, off the UI thread)" {
            # An offline host must not make the UI-thread Prepare* block or throw;
            # reachability is asserted later by the worker on the runspace pool.
            $probe = [MockNetworkProbe]::new()
            $probe.IsOnlineResult = $false
            $service = [ScanService]::new($config, $probe)

            { $service.PrepareScan("OfflineHost") } | Should -Not -Throw
        }
    }

    Context "RemoteUpdateService" {
        It "Should initialize correctly" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)
            $service | Should -Not -BeNullOrEmpty
        }

        It "PrepareScanForUpdates should return correct arguments" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            $result = $service.PrepareScanForUpdates("TestHost")
            
            $result.Arguments.JobType | Should -Be "Scan"
        }

        It "PrepareApplyUpdates should return correct arguments" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)
            
            $updates = @{ "KB123456" = "Security Update" }
            $result = $service.PrepareApplyUpdates("TestHost", $updates)

            $result.Arguments.JobType | Should -Be "Apply"
            $result.Arguments.Options | Should -Be $updates
        }
    }

    Context "ParseUpdateReport" {
        BeforeAll {
            $script:reportsDir = Join-Path $tempDir "Reports"
            if (-not (Test-Path $script:reportsDir)) {
                New-Item -Path $script:reportsDir -ItemType Directory -Force | Out-Null
            }
        }

        It "Should return null when report file does not exist" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            $result = $service.ParseUpdateReport("NonExistentHost")
            
            $result | Should -BeNullOrEmpty
        }

        It "Should parse valid XML report" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            # Create a test XML report
            $testXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<updates>
    <update name="BIOS Update" version="1.2.3" category="BIOS"/>
    <update name="Audio Driver" version="6.0.1" category="Audio"/>
</updates>
"@
            $reportPath = Join-Path $script:reportsDir "TestHost-Updates.xml"
            Set-Content -Path $reportPath -Value $testXml

            $result = $service.ParseUpdateReport("TestHost")
            
            $result | Should -Not -BeNullOrEmpty
            $result.updates.update.Count | Should -Be 2
            $result.updates.update[0].name | Should -Be "BIOS Update"

            # Cleanup
            Remove-Item -Path $reportPath -Force -ErrorAction SilentlyContinue
        }

        It "Should return null for malformed XML" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            # Create an invalid XML file
            $reportPath = Join-Path $script:reportsDir "BadHost-Updates.xml"
            Set-Content -Path $reportPath -Value "This is not valid XML <unclosed"

            $result = $service.ParseUpdateReport("BadHost")
            
            $result | Should -BeNullOrEmpty

            # Cleanup
            Remove-Item -Path $reportPath -Force -ErrorAction SilentlyContinue
        }
    }

    Context "CountUpdates" {
        It "Returns 0 for a null report" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            $service.CountUpdates($null) | Should -Be 0
        }

        It "Counts //update nodes in a report" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            [xml]$report = @"
<updates>
    <update name="BIOS" version="1.0"/>
    <update name="Audio" version="2.0"/>
    <update name="Video" version="3.0"/>
</updates>
"@
            $service.CountUpdates($report) | Should -Be 3
        }

        It "Returns 0 when there are no update nodes" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            [xml]$report = "<updates></updates>"
            $service.CountUpdates($report) | Should -Be 0
        }
    }

    # The connectivity assertion runs in the worker on the runspace-pool thread, so
    # it no longer runs in the UI-thread Prepare* methods. Its phase-level wiring is
    # covered by WorkerServices.Tests; the typed/leveled failure policy itself is
    # exercised directly here.
    Context "AssertHostReachable (typed, leveled failures)" {
        It "Throws HostOfflineException (Warning) when the host is offline" {
            $probe = [MockNetworkProbe]::new(); $probe.IsOnlineResult = $false
            $ex = $null
            try { [RemoteJobService]::AssertHostReachable($probe, [NullLogService]::new(), 'PC-OFF') } catch { $ex = $_.Exception }
            $ex.GetType().Name | Should -Be 'HostOfflineException'
            [string]$ex.Level | Should -Be 'Warning'
            $ex.HostName | Should -Be 'PC-OFF'
            $ex.Message | Should -BeLike '*offline*'
        }

        It "Throws HostUnresolvableException (Error) when the IP cannot be resolved" {
            $probe = [MockNetworkProbe]::new(); $probe.ResolveHostResult = $null
            $ex = $null
            try { [RemoteJobService]::AssertHostReachable($probe, [NullLogService]::new(), 'PC-DNS') } catch { $ex = $_.Exception }
            $ex.GetType().Name | Should -Be 'HostUnresolvableException'
            [string]$ex.Level | Should -Be 'Error'
            $ex.HostName | Should -Be 'PC-DNS'
        }

        It "Throws RpcUnavailableException (Error) when RPC (port 135) is blocked" {
            $probe = [MockNetworkProbe]::new(); $probe.IsRpcAvailableResult = $false
            $ex = $null
            try { [RemoteJobService]::AssertHostReachable($probe, [NullLogService]::new(), 'PC-RPC') } catch { $ex = $_.Exception }
            $ex.GetType().Name | Should -Be 'RpcUnavailableException'
            [string]$ex.Level | Should -Be 'Error'
            $ex.Message | Should -BeLike '*RPC*'
        }

        It "Logs the failure at its carried severity (Warning for offline)" {
            $probe = [MockNetworkProbe]::new(); $probe.IsOnlineResult = $false
            $log = [CapturingLogService]::new()
            try { [RemoteJobService]::AssertHostReachable($probe, $log, 'PC-OFF') } catch { }
            $log.HasLevel('WARN') | Should -BeTrue
            $log.Contains('offline') | Should -BeTrue
        }

        It "Returns the resolved IP string when the host passes every check" {
            $probe = [MockNetworkProbe]::new()
            [RemoteJobService]::AssertHostReachable($probe, [NullLogService]::new(), 'PC-OK') | Should -Be '127.0.0.1'
        }
    }

    Context "Logging" {
        It "Should default to a no-op logger when constructed without one" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)

            $service.Logger | Should -Not -BeNullOrEmpty
        }
    }

    Context "BuildWorkerArgs" {
        It "Should throw when RemoteWorker script is missing" {
            # Create config pointing to empty directory
            $emptyDir = Join-Path $env:TEMP "DonutTests_Empty_$(Get-Random)"
            New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
            
            $emptyConfig = [AppConfig]::new($emptyDir, (Join-Path $emptyDir "Logs"), (Join-Path $emptyDir "Reports"), @{})
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($emptyConfig, $probe)

            { $service.PrepareScan("TestHost") } | Should -Throw "*RemoteWorker script not found*"

            # Cleanup
            Remove-Item -Path $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should include SourceRoot in arguments" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)

            $result = $service.PrepareScan("TestHost")
            
            $result.Arguments.SourceRoot | Should -Be $config.SourceRoot
        }

        It "Should include LogsDir and ReportsDir in arguments" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)

            $result = $service.PrepareScan("TestHost")

            $result.Arguments.LogsDir | Should -Be $config.LogsPath
            $result.Arguments.ReportsDir | Should -Be $config.ReportsPath
        }

        It "Should send the live config Settings so the worker need not re-read config.json" {
            $probe = [MockNetworkProbe]::new()
            $cfg = [AppConfig]::new($tempDir, (Join-Path $tempDir "Logs"), (Join-Path $tempDir "Reports"), @{
                activeCommand = "applyUpdates"
            })
            $service = [ScanService]::new($cfg, $probe)

            $result = $service.PrepareScan("TestHost")

            $result.Arguments.Settings | Should -Be $cfg.Settings
            $result.Arguments.Settings.activeCommand | Should -Be "applyUpdates"
        }

        It "Should carry Settings on apply-phase arguments too" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $cfg = [AppConfig]::new($tempDir, (Join-Path $tempDir "Logs"), (Join-Path $tempDir "Reports"), @{
                activeCommand = "applyUpdates"
            })
            $service = [RemoteUpdateService]::new($cfg, $probe, $matcher)

            $result = $service.PrepareApplyUpdates("TestHost", @{})

            $result.Arguments.Settings.activeCommand | Should -Be "applyUpdates"
        }
    }
}
