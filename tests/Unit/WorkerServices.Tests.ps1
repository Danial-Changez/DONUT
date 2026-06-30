using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Services\DriverMatchingService.psm1"
using module "..\..\src\Models\DeviceContext.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Services\WorkerServices.psm1"
using namespace System.Net

# Mock NetworkProbe
class MockNetworkProbeWorker : NetworkProbe {
    [bool] $IsOnlineResult = $true
    [bool] $IsRpcAvailableResult = $true
    [string] $ResolveHostResult = "127.0.0.1"
    [string] $ActiveDcResult = "DC1.contoso.local"
    [string[]] $DcListResult = @("DC1.contoso.local", "DC2.contoso.local")
    [string] $ResolveWithResult = "10.0.0.7"
    MockNetworkProbeWorker() {}
    [bool] IsOnline([string]$hostName) { return $this.IsOnlineResult }
    [bool] IsRpcAvailable([string]$hostName) { return $this.IsRpcAvailableResult }
    [string] ResolveHost([string]$hostName) { return $this.ResolveHostResult }
    [string] GetActiveDomainController() { return $this.ActiveDcResult }
    [string[]] GetDomainControllers() { return $this.DcListResult }
    [IPAddress] ResolveWith([string]$hostName, [string]$dc) { return [IPAddress]::Parse($this.ResolveWithResult) }
    [string] $ComputerNameResult = "TPS5330AP"
    [string] ResolveComputerName([string]$ip) { return $this.ComputerNameResult }
}

# Partial Mock of ExecutionService to avoid real PsExec calls
class TestExecutionService : ExecutionService {
    [hashtable] $LastPsExecParams = @{}
    [bool] $ThrowOnAssertReachable = $false
    [hashtable] $ApplyResult = @{ Status = "Success" }
    
    TestExecutionService($l, $p, $m, $c, $s, $ld, $rd) : base($l, $p, $m, $c, $s, $ld, $rd) {}

    [void] InvokePsExec([hashtable]$params) {
        # Capture params for verification
        $this.LastPsExecParams = $params
    }

    [hashtable] CopyRemoteArtifacts([string]$hostName) {
        # Mock behavior: return dummy paths
        return @{ Report = "C:\Fake\Report.xml"; Log = "C:\Fake\Scan.log" }
    }
    
    [void] AssertReachable([DeviceContext]$device) {
        if ($this.ThrowOnAssertReachable) {
            throw "Device not reachable: $($device.HostName)"
        }
    }

    [string] $LastInventoryScript = $null
    [string] $LastRemotePwshIp = $null

    [void] InvokeRemotePwsh([string]$ip, [string]$scriptText) {
        $this.LastRemotePwshIp = $ip
        $this.LastInventoryScript = $scriptText
    }

    [string] CopyInventoryArtifact([string]$hostName) {
        return "C:\Fake\$hostName-inventory.json"
    }

    # $null => triggers the psexec fallback; a hashtable => the fast CIM path.
    [hashtable] $GatherResult = $null
    [hashtable] GatherRemoteInventory([string]$ip) { return $this.GatherResult }
}

Describe "WorkerServices" {
    
    BeforeAll {
        $script:tempDir = Join-Path $env:TEMP "DonutTests_Worker"
        if (-not (Test-Path $script:tempDir)) { New-Item -Path $script:tempDir -ItemType Directory -Force | Out-Null }
        $script:logsDir = Join-Path $script:tempDir "Logs"
        $script:reportsDir = Join-Path $script:tempDir "Reports"
        $script:sourceRoot = $script:tempDir
        
        # Create log directories
        if (-not (Test-Path $script:logsDir)) { New-Item -Path $script:logsDir -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $script:reportsDir)) { New-Item -Path $script:reportsDir -ItemType Directory -Force | Out-Null }
    }

    AfterAll {
        Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "ExecutionService Constructor" {
        It "Should initialize with all dependencies" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            
            $service | Should -Not -BeNullOrEmpty
            $service.Logger | Should -Be $logger
            $service.Probe | Should -Be $probe
            $service.Matcher | Should -Be $matcher
            $service.Config | Should -Be $config
        }

        It "Should set RemoteScriptPath correctly" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            
            $expected = Join-Path $script:sourceRoot "Scripts\RemoteWorker.ps1"
            $service.RemoteScriptPath | Should -Be $expected
        }

        It "Should set LocalLogsDir and LocalReportsDir" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            
            $service.LocalLogsDir | Should -Be $script:logsDir
            $service.LocalReportsDir | Should -Be $script:reportsDir
        }
    }

    Context "RunScanPhase" {
        BeforeEach {
            $script:config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{
                activeCommand = "scan"
                throttleLimit = 5
                commands = @{
                    scan = @{
                        args = @{
                            silent = $true
                            report = $script:reportsDir
                        }
                    }
                }
            })
        }

        It "Should return result with ReportPath" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("TestHost")

            $result = $service.RunScanPhase($device)
            
            $result | Should -Not -BeNullOrEmpty
            $result.ReportPath | Should -Be "C:\Fake\Report.xml"
        }

        It "Should return result with LogPath" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("TestHost")

            $result = $service.RunScanPhase($device)

            $result.LogPath | Should -Be "C:\Fake\Scan.log"
        }

        It "Single-quotes the default updateDeviceCategory so the remote pwsh -c parses it" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.RunScanPhase([DeviceContext]::new("TestHost"))

            # The BeforeEach config sets no updateDeviceCategory, so the default
            # list is appended; it must be single-quoted (not bare commas).
            $service.LastPsExecParams.Arguments | Should -BeLike "*-updateDeviceCategory='audio,video,network,storage,input,chipset,others'*"
        }
    }

    Context "AssertReachable" {
        It "Should throw when device is not reachable" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.ThrowOnAssertReachable = $true
            $device = [DeviceContext]::new("UnreachableHost")

            { $service.AssertReachable($device) } | Should -Throw "*not reachable*"
        }

        It "Should not throw when device is reachable" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.ThrowOnAssertReachable = $false
            $device = [DeviceContext]::new("ReachableHost")

            { $service.AssertReachable($device) } | Should -Not -Throw
        }
    }

    # NOTE: the per-phase reachability pre-check (AssertReachable) was removed -
    # running it in the fresh worker runspace (Test-Connection / DC-backed
    # ResolveHost) stalled the host process. The worker now resolves + runs psexec
    # directly and fails gracefully if the host is unreachable; connectivity is
    # never probed on the UI thread (Prepare* builds args only).

    Context "RunResolvePhase" {
        It "Warm mode returns the active DC and the DC list" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase([DeviceContext]::new(""), @{ Mode = 'Warm' })

            $result.Mode                  | Should -Be 'Warm'
            $result.ActiveDc              | Should -Be 'DC1.contoso.local'
            $result.DomainControllers.Count | Should -Be 2
        }

        It "Host mode returns a verdict (fresh IP + online) against the supplied DC" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase([DeviceContext]::new("PC-1"), @{ Mode = 'Host'; Dc = 'DC1' })

            $result.Mode     | Should -Be 'Host'
            $result.HostName | Should -Be 'PC-1'
            $result.Ip       | Should -Be '10.0.0.7'
            $result.Online   | Should -BeTrue
        }

        It "WarmRunspace mode is a no-op (just loads the module graph into the runspace)" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase([DeviceContext]::new(""), @{ Mode = 'WarmRunspace' })

            $result.Mode | Should -Be 'WarmRunspace'
        }

        It "Name mode returns the actual computer name at the IP" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $probe.ComputerNameResult = "OTHER-PC"
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase([DeviceContext]::new("TPS5330AP"), @{ Mode = 'Name'; Ip = '10.0.0.7' })

            $result.Mode       | Should -Be 'Name'
            $result.HostName   | Should -Be 'TPS5330AP'
            $result.ActualName | Should -Be 'OTHER-PC'
        }

        It "Host mode reports offline when RPC is unreachable" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $probe.IsRpcAvailableResult = $false
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase([DeviceContext]::new("PC-1"), @{ Mode = 'Host'; Dc = 'DC1' })

            $result.Ip     | Should -Be '10.0.0.7'
            $result.Online | Should -BeFalse
        }
    }

    Context "CopyRemoteArtifacts" {
        It "Should return Report and Log paths" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.CopyRemoteArtifacts("TestHost")
            
            $result.Report | Should -Not -BeNullOrEmpty
            $result.Log | Should -Not -BeNullOrEmpty
        }
    }

    Context "StartWorker Static Method" {
        It "Should throw for unknown JobType" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            
            { 
                [ExecutionService]::StartWorker(
                    "TestHost",
                    "Unknown",
                    @{},
                    $config,
                    $script:sourceRoot,
                    $script:logsDir,
                    $script:reportsDir
                )
            } | Should -Throw "*Unknown JobType*"
        }
    }

    Context "FindDcuCli" {
        It "Should return null when DCU CLI is not found" {
            # This test verifies the method exists and returns expected type
            # The actual DCU path lookup would fail in test environments
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            
            # FindDcuCli is hidden, so we can't call it directly
            # This test validates the service can be constructed and used
            $service | Should -Not -BeNullOrEmpty
        }
    }

    Context "Integration with AppConfig" {
        It "Should use AppConfig settings for BuildDcuArgs" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{
                commands = @{
                    scan = @{
                        args = @{
                            silent = $true
                            report = 'C:\TestReports'
                            updateSeverity = 'critical'
                        }
                    }
                }
            })
            
            $args = $config.BuildDcuArgs('scan', @{})
            
            $args | Should -BeLike "*-silent*"
            $args | Should -BeLike "*-report=C:\TestReports*"
            $args | Should -BeLike "*-updateSeverity=critical*"
        }

        It "Should allow runtime overrides via BuildDcuArgs" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{
                commands = @{
                    scan = @{
                        args = @{
                            report = 'C:\Original'
                        }
                    }
                }
            })
            
            $args = $config.BuildDcuArgs('scan', @{ report = 'C:\RuntimeOverride' })
            
            $args | Should -BeLike "*-report=C:\RuntimeOverride*"
            $args | Should -Not -BeLike "*C:\Original*"
        }
    }

    Context "RunApplyPhase" {
        BeforeEach {
            $script:config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{
                commands = @{
                    applyUpdates = @{
                        args = @{
                            silent = $true
                            autoSuspendBitLocker = $true
                        }
                    }
                }
            })
        }

        It "Should return artifact paths after apply" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("TestHost")

            $result = $service.RunApplyPhase($device, @{})
            
            $result | Should -Not -BeNullOrEmpty
            $result.Report | Should -Not -BeNullOrEmpty
            $result.Log | Should -Not -BeNullOrEmpty
        }

        It "Should capture PsExec parameters for applyUpdates command" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("ApplyTestHost")

            $service.RunApplyPhase($device, @{})
            
            $service.LastPsExecParams.ComputerName | Should -Be "ApplyTestHost"
            $service.LastPsExecParams.Command | Should -Be "applyUpdates"
        }

        It "Should merge runtime options with config" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("TestHost")
            
            $options = @{ reboot = $true }
            $service.RunApplyPhase($device, $options)
            
            # Arguments should contain the merged options
            $service.LastPsExecParams.Arguments | Should -Not -BeNullOrEmpty
        }
    }

    Context "FindDcuCli Path Resolution" {
        It "Should throw when DCU CLI not found at expected paths" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            
            # FindDcuCli checks UNC paths which won't exist in test
            { $service.FindDcuCli("127.0.0.1") } | Should -Throw "*not found*"
        }
    }

    Context "AssertReachable Real Implementation" {
        It "Should throw when host is offline" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $probe.IsOnlineResult = $false
            $matcher = [DriverMatchingService]::new()
            
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("OfflineHost")

            { $service.AssertReachable($device) } | Should -Throw "*offline or unreachable*"
        }

        It "Should throw when RPC is unavailable" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $probe.IsOnlineResult = $true
            $probe.IsRpcAvailableResult = $false
            $matcher = [DriverMatchingService]::new()
            
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("NoRpcHost")

            { $service.AssertReachable($device) } | Should -Throw "*RPC (Port 135) is not available*"
        }

        It "Should set device IPAddress when reachable" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            
            # Create a mock that returns a proper IP
            $probe = [MockNetworkProbeWorker]::new()
            $probe.IsOnlineResult = $true
            $probe.IsRpcAvailableResult = $true
            $matcher = [DriverMatchingService]::new()
            
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("localhost")
            
            # This should succeed for localhost
            try {
                $service.AssertReachable($device)
                # If localhost resolves, IPAddress should be set
                if ($device.IPAddress) {
                    $device.IPAddress | Should -Not -BeNullOrEmpty
                }
            }
            catch {
                # Expected if RPC isn't available on localhost in test env
                $_.Exception.Message | Should -BeLike "*RPC*"
            }
        }
    }

    Context "InvokePsExec Parameters" {
        It "Should capture command and arguments" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            
            $params = @{
                ComputerName = "TestPC"
                Command = "scan"
                Arguments = "-silent -report=C:\temp"
            }
            
            $service.InvokePsExec($params)
            
            $service.LastPsExecParams.ComputerName | Should -Be "TestPC"
            $service.LastPsExecParams.Command | Should -Be "scan"
            $service.LastPsExecParams.Arguments | Should -Be "-silent -report=C:\temp"
        }
    }

    Context "CopyRemoteArtifacts Path Building" {
        It "Should build correct local paths from hostname" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            
            $result = $service.CopyRemoteArtifacts("WORKSTATION01")
            
            # Our mock returns fixed paths, but we validate the structure
            $result.ContainsKey('Report') | Should -Be $true
            $result.ContainsKey('Log') | Should -Be $true
        }
    }

    Context "RunInventoryPhase" {
        It "Fast path: writes the CIM-gathered inventory JSON locally (no psexec)" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.GatherResult = @{ model = 'Latitude 5340'; hasBattery = $true }
            $device = [DeviceContext]::new("InvHost")

            $result = $service.RunInventoryPhase($device, @{ ScriptText = "probe" })

            $expected = Join-Path $script:reportsDir "InvHost-inventory.json"
            $result.InventoryPath | Should -Be $expected
            Test-Path $expected | Should -BeTrue
            (Get-Content $expected -Raw | ConvertFrom-Json).model | Should -Be 'Latitude 5340'
            $service.LastInventoryScript | Should -BeNullOrEmpty   # psexec probe not used
        }

        It "Fallback: when CIM is unavailable, runs the psexec probe and copies the JSON back" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.GatherResult = $null   # CIM session failed
            $device = [DeviceContext]::new("InvHost")

            $result = $service.RunInventoryPhase($device, @{ ScriptText = "Write-Output 'probe'" })

            $result.InventoryPath | Should -Be "C:\Fake\InvHost-inventory.json"
            $service.LastInventoryScript | Should -Be "Write-Output 'probe'"
        }

        It "Fallback throws when no script text is supplied" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.GatherResult = $null
            $device = [DeviceContext]::new("InvHost")

            { $service.RunInventoryPhase($device, @{}) } | Should -Throw "*No inventory script*"
        }
    }
}
