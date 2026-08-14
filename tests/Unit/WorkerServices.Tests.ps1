using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Services\DriverMatchingService.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\DiskUsage.psm1"
using module "..\..\src\Services\WorkerServices.psm1"
using module "..\Helpers\CapturingLogService.psm1"
using namespace System.Net

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

# Partial mock of ExecutionService so no test ever launches a real PsExec.
class TestExecutionService : ExecutionService {
    [hashtable] $LastPsExecParams = @{}
    [hashtable] $ApplyResult = @{ Status = "Success" }

    TestExecutionService($l, $p, $m, $c, $s, $ld, $rd) : base($l, $p, $m, $c, $s, $ld, $rd) {}

    [int] $PsExecReturnCode = 0   # dcu-cli code the mock reports back (0 = clean, 1/5 = reboot)
    [int] InvokePsExec([hashtable]$params) {
        $this.LastPsExecParams = $params
        return $this.PsExecReturnCode
    }

    # Canned TailAndScanLog results so RecoverByResumeTail can be driven without a network.
    [System.Collections.Generic.Queue[hashtable]] $TailResults = [System.Collections.Generic.Queue[hashtable]]::new()
    [int] $TailCalls = 0
    [hashtable] TailAndScanLog([string]$ip, [string]$remoteLog, [int]$seenChars) {
        $this.TailCalls++
        if ($this.TailResults.Count -gt 0) { return $this.TailResults.Dequeue() }
        return @{ Seen = $seenChars; Code = @{ Found = $false; Code = 0 } }
    }

    [string] $LastCopiedOutputLog = $null
    [bool] $LastCopyReport = $true
    [hashtable] CopyRemoteArtifacts([string]$hostName, [string]$outputLog) {
        return $this.CopyRemoteArtifacts($hostName, $outputLog, $true)
    }
    [hashtable] CopyRemoteArtifacts([string]$hostName, [string]$outputLog, [bool]$copyReport) {
        $this.LastCopiedOutputLog = $outputLog
        $this.LastCopyReport = $copyReport
        return @{ Report = "C:\Fake\Report.xml"; Log = "C:\Fake\Scan.log" }
    }

    # GatherResult $null simulates a failed CIM session, and ThrowOnGather blows the gather up.
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
        $script:tempDir = Join-Path $TestDrive "DonutTests_Worker"
        $script:logsDir = Join-Path $script:tempDir "Logs"
        $script:reportsDir = Join-Path $script:tempDir "Reports"
        $script:sourceRoot = $script:tempDir

        New-Item -Path $script:logsDir -ItemType Directory -Force | Out-Null
        New-Item -Path $script:reportsDir -ItemType Directory -Force | Out-Null
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
            $device = "TestHost"

            $result = $service.RunScanPhase($device)
            
            $result | Should -Not -BeNullOrEmpty
            $result.ReportPath | Should -Be "C:\Fake\Report.xml"
        }

        It "Should return result with LogPath" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = "TestHost"

            $result = $service.RunScanPhase($device)

            $result.LogPath | Should -Be "C:\Fake\Scan.log"
        }

        It "Single-quotes the default updateDeviceCategory so the remote pwsh -c parses it" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.RunScanPhase("TestHost")

            # No configured updateDeviceCategory, so the appended default must be single-quoted.
            $service.LastPsExecParams.Arguments | Should -BeLike "*-updateDeviceCategory='audio,video,network,storage,input,chipset,others'*"
        }

        It "brackets the psexec launch with start/done breadcrumbs carrying the exit code" {
            # A "start" with no "done" pins the scan hang to psexec or dcu, exit code included.
            $logger = [CapturingLogService]::new()
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.PsExecReturnCode = 5

            $service.RunScanPhase("TestHost")

            $logger.Contains("Scan: psexec launch start") | Should -BeTrue
            $logger.Contains("Scan: psexec launch done") | Should -BeTrue
            $logger.Contains("(exit 5)") | Should -BeTrue
        }

        It "flags a DCU 500 scan as NoUpdatesFound and skips the report copy" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.PsExecReturnCode = 500

            $result = $service.RunScanPhase("TestHost")

            $result.NoUpdatesFound | Should -BeTrue
            $result.DcuCode | Should -Be 500
            $service.LastCopyReport | Should -BeFalse -Because "a stale previous-run XML must not masquerade as this scan's result"
        }

        It "carries the dcu code on a clean scan and keeps the report copy" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.PsExecReturnCode = 0

            $result = $service.RunScanPhase("TestHost")

            $result.NoUpdatesFound | Should -BeFalse
            $result.DcuCode | Should -Be 0
            $service.LastCopyReport | Should -BeTrue
        }
    }

    # No worker-level reachability pre-check: one in a fresh runspace stalled the host process.

    Context "RunResolvePhase" {
        It "Warm mode returns the active DC and the DC list" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase("", @{ Mode = 'Warm' })

            $result.Mode                  | Should -Be 'Warm'
            $result.ActiveDc              | Should -Be 'DC1.contoso.local'
            $result.DomainControllers.Count | Should -Be 2
        }

        It "Host mode returns a verdict (fresh IP + online) against the supplied DC" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase("PC-1", @{ Mode = 'Host'; Dc = 'DC1' })

            $result.Mode     | Should -Be 'Host'
            $result.HostName | Should -Be 'PC-1'
            $result.Ip       | Should -Be '10.0.0.7'
            $result.Online   | Should -BeTrue
        }

        It "WarmRunspace mode loads the module graph + runtime assemblies, returns the marker" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            # TestExecutionService no-ops WarmRuntimeAssemblies, so no real DNS or CIM opens.
            $service = [TestExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase("", @{ Mode = 'WarmRunspace' })

            $result.Mode | Should -Be 'WarmRunspace'
        }

        It "Name mode returns the actual computer name at the IP" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $probe.ComputerNameResult = "OTHER-PC"
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase("WS-5330", @{ Mode = 'Name'; Ip = '10.0.0.7' })

            $result.Mode       | Should -Be 'Name'
            $result.HostName   | Should -Be 'WS-5330'
            $result.ActualName | Should -Be 'OTHER-PC'
        }

        It "Host mode reports offline when RPC is unreachable" {
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})
            $probe = [MockNetworkProbeWorker]::new()
            $probe.IsRpcAvailableResult = $false
            $service = [ExecutionService]::new([LogService]::new($script:logsDir), $probe, [DriverMatchingService]::new(), $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)

            $result = $service.RunResolvePhase("PC-1", @{ Mode = 'Host'; Dc = 'DC1' })

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
            $device = "TestHost"

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
            $device = "TestHost"

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
            $device = "TestHost"

            ($service.RunApplyPhase($device, @{})).RebootRequired | Should -BeFalse
        }

        It "Should capture PsExec parameters for applyUpdates command" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = "ApplyTestHost"

            $service.RunApplyPhase($device, @{})

            $service.LastPsExecParams.ComputerName | Should -Be "ApplyTestHost"
            $service.LastPsExecParams.Command | Should -Be "applyUpdates"
        }

        It "Copies the apply's OWN outputLog back (apply.log, not the phase-1 scan.log)" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.RunApplyPhase("ApplyTestHost", @{})

            $service.LastCopiedOutputLog | Should -Be 'C:\temp\DONUT\apply.log'
        }

        It "Should merge runtime options with config" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            
            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = "TestHost"
            
            $options = @{ reboot = $true }
            $service.RunApplyPhase($device, $options)

            $service.LastPsExecParams.Arguments | Should -Not -BeNullOrEmpty
        }

        It "Does not leak control keys (ResolvedIp) into the dcu-cli arguments" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $script:config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $device = "ApplyTestHost"

            # A non-option control key reaching the dcu-cli line makes DCU return 105.
            $service.RunApplyPhase($device, @{ ResolvedIp = '10.124.28.147'; reboot = $true })

            $service.LastPsExecParams.Arguments | Should -Not -Match 'ResolvedIp'
            $service.LastPsExecParams.Arguments | Should -Match 'reboot'
        }
    }

    Context "BuildRemoteDcuScript" {
        It "resolves dcu-cli on the target and clears the prior log (no controller-side UNC)" {
            $s = [ExecutionService]::BuildRemoteDcuScript('applyUpdates',
                '-silent -outputLog=C:\temp\DONUT\apply.log', 'C:\temp\DONUT\apply.log')

            # dcu-cli is discovered on the target with Test-Path, not over a controller UNC.
            $s.Contains('C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe') | Should -BeTrue
            $s.Contains('C:\Program Files\Dell\CommandUpdate\dcu-cli.exe')       | Should -BeTrue
            $s.Contains('Test-Path -LiteralPath')                               | Should -BeTrue
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
            # Past the driver-install range (2000-2007) and clear of the transport codes.
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

            # A local temp file stands in for the admin-share UNC path, SMB gate mocked open.
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

            $result.ContainsKey('Report') | Should -Be $true
            $result.ContainsKey('Log') | Should -Be $true
        }
    }

    Context "RunInventoryPhase" {
        It "Writes the CIM-gathered inventory JSON locally" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.GatherResult = @{ model = 'Latitude 5340'; hasBattery = $true }
            $device = "InvHost"

            $result = $service.RunInventoryPhase($device)

            $expected = Join-Path $script:reportsDir "InvHost-inventory.json"
            $result.InventoryPath | Should -Be $expected
            Test-Path $expected | Should -BeTrue
            (Get-Content $expected -Raw | ConvertFrom-Json).model | Should -Be 'Latitude 5340'
        }

        It "Throws when the CIM session cannot be opened" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.GatherResult = $null   # CIM session failed

            { $service.RunInventoryPhase("InvHost") } | Should -Throw "*CIM inventory unavailable*"
        }

        It "Throws on an all-null CIM result (DCOM up, WMI empty)" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.GatherResult = @{ model = $null; serviceTag = $null; biosVersion = $null; totalSpaceBytes = $null; lastBootTime = $null; probedAt = 'x' }

            { $service.RunInventoryPhase("InvHost") } | Should -Throw "*CIM inventory unavailable*"
        }

        It "Throws when the CIM gather itself throws" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.ThrowOnGather = $true

            { $service.RunInventoryPhase("InvHost") } | Should -Throw "*CIM inventory unavailable*"
        }

        It "Fails fast when RPC (135) is unreachable" {
            $logger = [LogService]::new($script:logsDir)
            $probe = [MockNetworkProbeWorker]::new()
            $probe.IsRpcAvailableResult = $false   # offline / RPC blocked
            $matcher = [DriverMatchingService]::new()
            $config = [AppConfig]::new($script:sourceRoot, $script:logsDir, $script:reportsDir, @{})

            $service = [TestExecutionService]::new($logger, $probe, $matcher, $config, $script:sourceRoot, $script:logsDir, $script:reportsDir)
            $service.GatherResult = @{ model = 'ShouldNotBeReached' }   # would succeed past the gate

            { $service.RunInventoryPhase("DeadHost") } | Should -Throw "*offline*"
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

    Context "BuildScanCommand" {
        BeforeAll {
            # Executes the generated script's filter half (everything after the
            # WizTree invocation) with its hardcoded paths redirected to temp files.
            function Invoke-ScanFilter([string]$fixtureCsv, [int]$topN, [string]$outCsv) {
                $script = [ExecutionService]::BuildScanCommand($topN)
                $body = ($script -split "\r?\n" | Select-Object -Skip 1) -join "`n"
                $body = $body.Replace('C:\temp\DONUT\folders-top.csv', $outCsv)
                $body = $body.Replace('C:\temp\DONUT\folders.csv', $fixtureCsv)
                & ([scriptblock]::Create($body))
            }
        }

        It "selects the N largest rows across the whole export, not a head slice" {
            # Tree-ordered export: a head trim once kept tiny folders and dropped C:\Windows.
            $dir = Join-Path $TestDrive "DonutScanFilter_$(Get-Random)"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $fixture = Join-Path $dir 'folders.csv'
            $out = Join-Path $dir 'folders-top.csv'
            Set-Content -Path $fixture -Value @'
Generated by WizTree 4.x (banner line)
"File Name","Size","Allocated","Modified","Attributes","Files","Folders"
"C:\",1000,1000,2026-08-01,16,0,7
"C:\Users\",900,900,2026-08-01,16,0,3
"C:\Users\a\",30,30,2026-08-01,16,0,0
"C:\Users\b\",20,20,2026-08-01,16,0,0
"C:\Users\c\",10,10,2026-08-01,16,0,0
"C:\Windows\",800,800,2026-08-01,16,0,0
"C:\Program Files, x86\",700,700,2026-08-01,16,0,0
"C:\tiny\",1,1,2026-08-01,16,0,0
'@
            Invoke-ScanFilter $fixture 3 $out

            # The ~40 MB export must not be left on the fleet machine.
            Test-Path $fixture | Should -BeFalse
            # End to end: volume root dropped, quoted comma path intact, no deep small rows.
            $report = [WizTreeCsv]::ParseTopFoldersFromFile($out, 3)
            ($report.Folders | ForEach-Object { $_.Path }) | Should -Be @(
                'C:\Users\', 'C:\Windows\', 'C:\Program Files, x86\')
        }

        It "pins the invocation shape" {
            $s = [ExecutionService]::BuildScanCommand(12)
            $s | Should -Match '/exportfolders=1 /exportfiles=0'
            $s | Should -Match 'folders-top\.csv'
        }
    }

    Context "BuildDeleteCommand" {
        It "clears contents (not the folder) and injection-proofs paths" {
            $s = [ExecutionService]::BuildDeleteCommand(@("C:\temp\a", "C:\o'brien"))
            $s | Should -Match 'Get-ChildItem -LiteralPath'        # walks the contents...
            $s | Should -Match 'Clear-Tree \$p'                    # ...emptying the target in place
            $s | Should -Not -Match 'Remove-Item -LiteralPath \$p' # never removes the folder itself
            $s | Should -Match "o''brien"                          # embedded single quote doubled
        }

        It "empties junction children as links instead of recursing through them" {
            $s = [ExecutionService]::BuildDeleteCommand(@("C:\temp"))
            # The script's own comments name the avoided cmdlet, so strip them before asserting.
            $code = (($s -split "`n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n")
            $code | Should -Not -Match 'Remove-Item -Recurse'      # -Recurse follows reparse points on 5.1
            $code | Should -Match '\[IO\.Directory\]::Delete\(\$c\.FullName, \$false\)'
            $code | Should -Match 'ReparsePoint'
        }

        It "canonicalizes each target and fails closed on profile enumeration" {
            $s = [ExecutionService]::BuildDeleteCommand(@("C:\temp"))
            $s | Should -Match 'GetFullPath'                       # '..' resolved before the checks
            $s | Should -Match 'profile enumeration failed'        # never clears unprotected
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
