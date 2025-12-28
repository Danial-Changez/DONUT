using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Services\DriverMatchingService.psm1"
using module "..\..\src\Services\RemoteServices.psm1"
using namespace System.Net

# Mock NetworkProbe for testing
class MockNetworkProbe : NetworkProbe {
    [bool] $IsOnlineResult = $true
    [bool] $IsRpcAvailableResult = $true
    [IPAddress] $ResolveHostResult = [IPAddress]::Parse("127.0.0.1")

    MockNetworkProbe() {}

    [bool] IsOnline([string]$hostName) { return $this.IsOnlineResult }
    [bool] IsRpcAvailable([string]$hostName) { return $this.IsRpcAvailableResult }
    [IPAddress] ResolveHost([string]$hostName) { return $this.ResolveHostResult }
    [bool] CheckReverseDNS([IPAddress]$ip, [string]$hostName) { return $true }
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

        It "PrepareScan should return correct arguments when host is online" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)
            
            $result = $service.PrepareScan("TestHost")
            
            # Pester 5 assertions
            $result.ScriptPath | Should -Match "Scripts\\RemoteWorker.ps1$"
            $result.Arguments.HostName | Should -Be "TestHost"
            $result.Arguments.JobType | Should -Be "Scan"
        }

        It "PrepareScan should throw if host is offline" {
            $probe = [MockNetworkProbe]::new()
            $probe.IsOnlineResult = $false
            $service = [ScanService]::new($config, $probe)

            { $service.PrepareScan("OfflineHost") } | Should -Throw "Host 'OfflineHost' is offline or unreachable."
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

    Context "ValidateHostConnectivity" {
        It "Should throw when host cannot be resolved" {
            $probe = [MockNetworkProbe]::new()
            $probe.ResolveHostResult = $null
            $service = [ScanService]::new($config, $probe)

            { $service.PrepareScan("UnresolvableHost") } | Should -Throw "*Could not resolve IP*"
        }

        It "Should throw when RPC is not available" {
            $probe = [MockNetworkProbe]::new()
            $probe.IsRpcAvailableResult = $false
            $service = [ScanService]::new($config, $probe)

            { $service.PrepareScan("NoRpcHost") } | Should -Throw "*RPC (Port 135) is not available*"
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
    }
}
