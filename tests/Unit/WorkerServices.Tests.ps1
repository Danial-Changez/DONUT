using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Services\DriverMatchingService.psm1"
using module "..\..\src\Models\DeviceContext.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Services\WorkerServices.psm1"
using module "..\Helpers\CapturingLogService.psm1"
using namespace System.Net

# Mock NetworkProbe
class MockNetworkProbeWorker : NetworkProbe {
    [bool] $IsOnlineResult = $true
    [bool] $IsRpcAvailableResult = $true
    [bool] $IsSmbAvailableResult = $true
    [bool] $IsLocalOnlineResult = $true
    [string] $ResolveHostResult = "127.0.0.1"
    [string] $ActiveDcResult = "DC1.contoso.local"
    [string[]] $DcListResult = @("DC1.contoso.local", "DC2.contoso.local")
    [string] $ResolveWithResult = "10.0.0.7"
    MockNetworkProbeWorker() {}
    [bool] IsOnline([string]$hostName) { return $this.IsOnlineResult }
    [bool] IsRpcAvailable([string]$hostName) { return $this.IsRpcAvailableResult }
    [bool] IsSmbAvailable([string]$hostName) { return $this.IsSmbAvailableResult }
    [bool] IsSmbReachableQuiet([string]$hostName) { return $this.IsSmbAvailableResult }
    [bool] IsLocalOnline() { return $this.IsLocalOnlineResult }
    [string] ResolveHost([string]$hostName) { return $this.ResolveHostResult }
    [string] GetActiveDomainController() { return $this.ActiveDcResult }
    [string[]] GetDomainControllers() { return $this.DcListResult }
    [IPAddress] ResolveWith([string]$hostName, [string]$dc) { return [IPAddress]::Parse($this.ResolveWithResult) }
    [string] $ComputerNameResult = "WS-5330"
    [string] ResolveComputerName([string]$ip) { return $this.ComputerNameResult }
}

# Partial Mock of ExecutionService to avoid real PsExec calls
class TestExecutionService : ExecutionService {
    [hashtable] $LastPsExecParams = @{}
    [hashtable] $ApplyResult = @{ Status = "Success" }

    TestExecutionService($l, $p, $m, $c, $s, $ld, $rd) : base($l, $p, $m, $c, $s, $ld, $rd) {}

    [int] $PsExecReturnCode = 0   # dcu-cli code the mock reports back (0 = clean, 1/5 = reboot)
    [int] InvokePsExec([hashtable]$params) {
        # Capture params for verification; return the configured dcu-cli code.
        $this.LastPsExecParams = $params
        return $this.PsExecReturnCode
    }

    # Canned TailAndScanLog results so RecoverByResumeTail can be driven without a network;
    # when the queue empties, reports "reachable, no verdict yet" at the current offset.
    [System.Collections.Generic.Queue[hashtable]] $TailResults = [System.Collections.Generic.Queue[hashtable]]::new()
    [int] $TailCalls = 0
    [hashtable] TailAndScanLog([string]$ip, [string]$remoteLog, [int]$seenChars) {
        $this.TailCalls++
        if ($this.TailResults.Count -gt 0) { return $this.TailResults.Dequeue() }
        return @{ Seen = $seenChars; Code = @{ Found = $false; Code = 0 } }
    }

    [string] $LastCopiedOutputLog = $null
    [hashtable] CopyRemoteArtifacts([string]$hostName, [string]$outputLog) {
        # Mock behavior: capture which log the phase asked for; return dummy paths.
        $this.LastCopiedOutputLog = $outputLog
        return @{ Report = "C:\Fake\Report.xml"; Log = "C:\Fake\Scan.log" }
    }

    [string] $LastInventoryScript = $null
    [string] $LastRemotePwshIp = $null
    [string] $LastRemotePwshService = $null

    [void] InvokeRemotePwsh([string]$ip, [string]$scriptText, [string]$serviceName, [int]$maxMinutes) {
        $this.LastRemotePwshIp = $ip
        $this.LastInventoryScript = $scriptText
        $this.LastRemotePwshService = $serviceName
    }

    [string] CopyInventoryArtifact([string]$hostName) {
        return "C:\Fake\$hostName-inventory.json"
    }

    # $null => triggers the psexec fallback; a hashtable => the fast CIM path.
    # $ThrowOnGather => simulate the CIM gather blowing up.
    [hashtable] $GatherResult = $null
    [bool] $ThrowOnGather = $false
    [hashtable] GatherRemoteInventory([string]$ip) {
        if ($this.ThrowOnGather) { throw "Simulated CIM failure" }
        return $this.GatherResult
    }

    [void] WarmRuntimeAssemblies() { }   # no-op: tests never touch real DNS / CIM
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

    Context "InvokePsExec SMB gate" {
        It "Fails fast (RpcUnavailable) when the admin share (SMB/445) is unreachable" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $probe.IsSmbAvailableResult = $false   # gate throws before psexec is ever launched
            $matcher = [DriverMatchingService]::new()
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $params = @{ ComputerName = 'PC-5'; Command = 'scan'; Arguments = '-silent'; OutputLog = 'C:\temp\DONUT\scan.log' }
            $threw = $false; $errName = ''
            try { $service.InvokePsExec($params) } catch { $threw = $true; $errName = $_.Exception.GetType().Name }
            $threw  | Should -BeTrue
            $errName | Should -Be 'RpcUnavailableException'
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

        It "brackets the psexec launch with start/done breadcrumbs carrying the exit code" {
            # The scan hang lives in the silent launch->wait segment; a "start" with no
            # "done" pins it to psexec/dcu, and the exit code lands in the log.
            $logger = [CapturingLogService]::new()
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.PsExecReturnCode = 5

            $service.RunScanPhase([DeviceContext]::new("TestHost"))

            $logger.Contains("Scan: psexec launch start") | Should -BeTrue
            $logger.Contains("Scan: psexec launch done") | Should -BeTrue
            $logger.Contains("(exit 5)") | Should -BeTrue
        }
    }

    # NOTE: there is deliberately no worker-level reachability pre-check - running
    # one in a fresh worker runspace (Test-Connection / DC-backed ResolveHost)
    # stalled the host process. Each phase gates its own transport with bounded
    # port probes (RPC-135 / SMB-445) and fails typed if the host is unreachable;
    # connectivity is never probed on the UI thread (Prepare* builds args only).

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

        It "WarmRunspace mode loads the module graph + runtime assemblies, returns the marker" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            # TestExecutionService no-ops WarmRuntimeAssemblies so the test never opens a
            # real DNS/CIM session.
            $service = [TestExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase([DeviceContext]::new(""), @{ Mode = 'WarmRunspace' })

            $result.Mode | Should -Be 'WarmRunspace'
        }

        It "Name mode returns the actual computer name at the IP" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $probe.ComputerNameResult = "OTHER-PC"
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase([DeviceContext]::new("WS-5330"), @{ Mode = 'Name'; Ip = '10.0.0.7' })

            $result.Mode       | Should -Be 'Name'
            $result.HostName   | Should -Be 'WS-5330'
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

    Context "ToAdminShare" {
        It "maps a drive-rooted target path to its admin-share UNC" {
            [ExecutionService]::ToAdminShare('10.0.0.7', 'C:\temp\DONUT\apply.log') | Should -Be '\\10.0.0.7\C$\temp\DONUT\apply.log'
            [ExecutionService]::ToAdminShare('10.0.0.7', 'D:\logs\scan.log')        | Should -Be '\\10.0.0.7\D$\logs\scan.log'
        }
        It "returns '' for blank, UNC, or relative paths" {
            [ExecutionService]::ToAdminShare('10.0.0.7', '')                  | Should -Be ''
            [ExecutionService]::ToAdminShare('10.0.0.7', $null)               | Should -Be ''
            [ExecutionService]::ToAdminShare('10.0.0.7', '\\srv\share\x.log') | Should -Be ''
            [ExecutionService]::ToAdminShare('10.0.0.7', 'relative\x.log')    | Should -Be ''
        }
    }

    Context "CopyRemoteArtifacts" {
        It "Should return Report and Log paths" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.CopyRemoteArtifacts("TestHost", 'C:\temp\DONUT\scan.log')

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
                    "",
                    $config,
                    $script:sourceRoot,
                    $script:logsDir,
                    $script:reportsDir
                )
            } | Should -Throw "*Unknown JobType*"
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

        It "flags RebootRequired when dcu-cli returns a reboot code (1 or 5)" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("TestHost")

            $service.PsExecReturnCode = 1
            ($service.RunApplyPhase($device, @{})).RebootRequired | Should -BeTrue
            $service.PsExecReturnCode = 5
            ($service.RunApplyPhase($device, @{})).RebootRequired | Should -BeTrue
        }

        It "does not flag RebootRequired on a clean apply (code 0)" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("TestHost")

            ($service.RunApplyPhase($device, @{})).RebootRequired | Should -BeFalse
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

        It "Copies the apply's OWN outputLog back (apply.log, not the phase-1 scan.log)" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.RunApplyPhase([DeviceContext]::new("ApplyTestHost"), @{})

            $service.LastCopiedOutputLog | Should -Be 'C:\temp\DONUT\apply.log'
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

        It "Does not leak control keys (ResolvedIp) into the dcu-cli arguments" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = [DeviceContext]::new("ApplyTestHost")

            # Defense-in-depth: ResolvedIp now rides its own worker argument (not Options),
            # but should a non-option control key ever land in Options it must NOT reach
            # the dcu-cli line (DCU returns 105). A real option in the bag still passes.
            $service.RunApplyPhase($device, @{ ResolvedIp = '10.124.28.147'; reboot = $true })

            $service.LastPsExecParams.Arguments | Should -Not -Match 'ResolvedIp'
            $service.LastPsExecParams.Arguments | Should -Match 'reboot'
        }
    }

    Context "BuildRemoteDcuScript" {
        It "resolves dcu-cli on the target and clears the prior log (no controller-side UNC)" {
            $s = [ExecutionService]::BuildRemoteDcuScript('applyUpdates',
                '-silent -outputLog=C:\temp\DONUT\apply.log', 'C:\temp\DONUT\apply.log')

            # dcu-cli is discovered ON the target (Test-Path there), not over a controller UNC.
            $s.Contains('C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe') | Should -BeTrue
            $s.Contains('C:\Program Files\Dell\CommandUpdate\dcu-cli.exe')       | Should -BeTrue
            $s.Contains('Test-Path -LiteralPath')                               | Should -BeTrue
            # The prior log is cleared remotely, and dcu-cli runs with the given args.
            $s.Contains("Remove-Item -LiteralPath 'C:\temp\DONUT\apply.log'")    | Should -BeTrue
            $s.Contains('/applyUpdates -silent -outputLog=C:\temp\DONUT\apply.log') | Should -BeTrue
            # A missing dcu-cli comes back as the sentinel, not a hung path.
            $s.Contains("exit $([ExecutionService]::DcuNotFoundExit)")           | Should -BeTrue
        }

        It "omits the clear line when no outputLog is supplied" {
            $s = [ExecutionService]::BuildRemoteDcuScript('scan', '-silent', '')
            $s.Contains('Remove-Item') | Should -BeFalse
            $s.Contains('/scan -silent') | Should -BeTrue
        }

        It "uses a not-found sentinel outside every dcu-cli and psexec transport code" {
            # Past the driver-install range (2000-2007) so DescribeReturnCode never claims it,
            # and not one of the connection-lost transport codes.
            [ExecutionService]::DcuNotFoundExit | Should -BeGreaterThan 2007
            @(0, 1, 5, 64, 109, 121, 232, 233, 1236) |
                Should -Not -Contain ([ExecutionService]::DcuNotFoundExit)
        }
    }

    Context "TailAndScanLog" {
        It "streams new whole lines, advances the offset, and surfaces the return code" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()   # IsSmbAvailable = $true
            $matcher = [DriverMatchingService]::new()
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $logFile = Join-Path $script:tempDir 'apply-tail.log'
            "[2026-07-09 15:00:00] : Installing updates (4 of 4)...`n[2026-07-09 15:00:30] : The program exited with return code: 1" |
                Set-Content -LiteralPath $logFile -Encoding UTF8

            # A local temp file stands in for the admin-share UNC path; SMB gate is mocked open.
            $r = $service.TailAndScanLog('10.0.0.7', $logFile, 0)
            $r.Seen       | Should -BeGreaterThan 0
            $r.Code.Found | Should -BeTrue
            $r.Code.Code  | Should -Be 1
        }

        It "returns Found=false and the old offset when the share is unreachable (never blocks)" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new(); $probe.IsSmbAvailableResult = $false
            $matcher = [DriverMatchingService]::new()
            $service = [ExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $r = $service.TailAndScanLog('10.0.0.7', 'C:\temp\DONUT\apply.log', 42)
            $r.Seen       | Should -Be 42
            $r.Code.Found | Should -BeFalse
        }
    }

    Context "RecoverByResumeTail" {
        It "returns the recovered code as soon as a reachable read yields a verdict" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()   # local + SMB both online
            $matcher = [DriverMatchingService]::new()
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.TailResults.Enqueue(@{ Seen = 10; Code = @{ Found = $true; Code = 5 } })

            $r = $service.RecoverByResumeTail('10.0.0.7', 'PC-9', '\\10.0.0.7\C$\temp\DONUT\apply.log', 0)
            $r.Found          | Should -BeTrue
            $r.Code           | Should -Be 5
            $service.TailCalls | Should -Be 1   # returned on the first reachable read, no waiting
        }

        It "resumes past a not-yet-written verdict and recovers the code on a later read" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.TailResults.Enqueue(@{ Seen = 5;  Code = @{ Found = $false; Code = 0 } })  # dcu still installing
            $service.TailResults.Enqueue(@{ Seen = 20; Code = @{ Found = $true;  Code = 0 } })  # then the verdict

            $r = $service.RecoverByResumeTail('10.0.0.7', 'PC-9', '\\10.0.0.7\C$\temp\DONUT\apply.log', 0)
            $r.Found           | Should -BeTrue
            $r.Code            | Should -Be 0
            $service.TailCalls | Should -Be 2
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
            
            $result = $service.CopyRemoteArtifacts("WORKSTATION01", 'C:\temp\DONUT\scan.log')

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

        It "Fallback: an all-null CIM result (DCOM up, WMI empty) uses the psexec probe" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.GatherResult = @{ model = $null; serviceTag = $null; biosVersion = $null; totalSpaceBytes = $null; lastBootTime = $null; probedAt = 'x' }
            $device = [DeviceContext]::new("InvHost")

            $result = $service.RunInventoryPhase($device, @{ ScriptText = "Write-Output 'probe'" })

            $result.InventoryPath | Should -Be "C:\Fake\InvHost-inventory.json"
            $service.LastInventoryScript | Should -Be "Write-Output 'probe'"
        }

        It "Fallback: a CIM exception falls back to the psexec probe" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.ThrowOnGather = $true
            $device = [DeviceContext]::new("InvHost")

            $result = $service.RunInventoryPhase($device, @{ ScriptText = "Write-Output 'probe'" })

            $result.InventoryPath | Should -Be "C:\Fake\InvHost-inventory.json"
            $service.LastInventoryScript | Should -Be "Write-Output 'probe'"
        }

        It "Fails fast (no CIM / psexec) when RPC (135) is unreachable" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $probe.IsRpcAvailableResult = $false   # offline / RPC blocked
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.GatherResult = @{ model = 'ShouldNotBeReached' }   # would succeed past the gate
            $device = [DeviceContext]::new("DeadHost")

            { $service.RunInventoryPhase($device, @{ ScriptText = 'probe' }) } | Should -Throw "*offline*"
            $service.LastInventoryScript | Should -BeNullOrEmpty   # CIM + psexec fallback never reached
        }
    }

    Context "IsUsableInventory" {
        It "is false for a null result" {
            [ExecutionService]::IsUsableInventory($null) | Should -BeFalse
        }
        It "is false when every identifying field is null" {
            $inv = @{ model = $null; serviceTag = $null; biosVersion = $null; totalSpaceBytes = $null; lastBootTime = $null; hasBattery = $false }
            [ExecutionService]::IsUsableInventory($inv) | Should -BeFalse
        }
        It "is true when any identifying field is populated" {
            [ExecutionService]::IsUsableInventory(@{ model = 'Latitude 5440' }) | Should -BeTrue
            [ExecutionService]::IsUsableInventory(@{ totalSpaceBytes = 512000000000 }) | Should -BeTrue
        }
    }

    Context "BuildDeleteCommand" {
        It "clears contents (not the folder) and injection-proofs paths" {
            $s = [ExecutionService]::BuildDeleteCommand(@("C:\temp\a", "C:\o'brien"))
            $s | Should -Match "Get-ChildItem -LiteralPath"       # clears contents...
            $s | Should -Match "Remove-Item -Recurse -Force"
            $s | Should -Not -Match "Remove-Item -LiteralPath"    # ...never removes the folder itself
            $s | Should -Match "o''brien"                         # embedded single quote doubled
        }
        It "carries the safety guards: logged-on profiles, blocklist, allowlist" {
            $s = [ExecutionService]::BuildDeleteCommand(@("C:\temp"))
            $s | Should -Match "Win32_UserProfile"                # skip currently logged-on profiles
            $s | Should -Match "Loaded"
            $s | Should -Match "ccmcache"                         # allowlist
            $s | Should -Match "system volume information"        # blocklist
        }
    }
}
