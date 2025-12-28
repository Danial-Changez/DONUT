using module ".\LogService.psm1"
using module "..\Core\NetworkProbe.psm1"
using module ".\DriverMatchingService.psm1"
using module "..\Models\DeviceContext.psm1"
using module "..\Models\AppConfig.psm1"

class ExecutionService {
    [LogService] $Logger
    [NetworkProbe] $Probe
    [DriverMatchingService] $Matcher
    [AppConfig] $Config
    [string] $RemoteScriptPath
    [string] $LocalLogsDir
    [string] $LocalReportsDir

    ExecutionService(
        [LogService] $logger,
        [NetworkProbe] $probe,
        [DriverMatchingService] $matcher,
        [AppConfig] $config,
        [string] $sourceRoot,
        [string] $logsDir,
        [string] $reportsDir
    ) {
        $this.Logger = $logger
        $this.Probe = $probe
        $this.Matcher = $matcher
        $this.Config = $config
        $this.RemoteScriptPath = Join-Path $sourceRoot "Scripts\RemoteWorker.ps1"
        $this.LocalLogsDir = $logsDir
        $this.LocalReportsDir = $reportsDir
    }

    static [hashtable] StartWorker(
        [string]$HostName,
        [string]$JobType,
        [hashtable]$Options,
        [AppConfig]$Config,
        [string]$SourceRoot,
        [string]$LogsDir,
        [string]$ReportsDir
    ) {
        # Init Services
        $localLogger = [LogService]::new($LogsDir)
        $localProbe = [NetworkProbe]::new()
        $localMatcher = [DriverMatchingService]::new()
        $service = [ExecutionService]::new($localLogger, $localProbe, $localMatcher, $Config, $SourceRoot, $LogsDir, $ReportsDir)

        # Create Device Context
        $device = [DeviceContext]::new($HostName)

        # Execute
        if ($JobType -eq 'Scan') {
            return $service.RunScanPhase($device)
        }
        elseif ($JobType -eq 'Apply') {
            return $service.RunApplyPhase($device, $Options)
        }
        else {
            throw "Unknown JobType: $JobType"
        }
    }

    [hashtable] ExecuteTask([DeviceContext] $device, [hashtable] $options) {
        $this.AssertReachable($device)
        $scanResult = $this.RunScanPhase($device)

        if (-not $scanResult.ContainsKey('Updates') -or $scanResult.Updates.Count -eq 0) {
            $this.Logger.LogInfo("[$($device.HostName)] No updates found; skipping apply.")
            return @{
                Phase   = "ScanOnly"
                Updates = @()
            }
        }

        # Placeholder: caller should confirm before proceeding
        $applyResult = $this.RunApplyPhase($device, $options)
        return @{
            Phase       = "Apply"
            Updates     = $scanResult.Updates
            ApplyResult = $applyResult
        }
    }

    [hashtable] RunScanPhase([DeviceContext] $device) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting preliminary scan.")
        
        # Build scan arguments from config with remote path overrides
        $remoteOverrides = @{
            report    = 'C:\temp\DONUT'
            outputLog = 'C:\temp\DONUT\scan.log'
        }
        $scanArgs = $this.Config.BuildDcuArgs('scan', $remoteOverrides)
        
        # If no updateDeviceCategory specified, default to all categories
        if ($scanArgs -notmatch '-updateDeviceCategory') {
            $scanArgs += ' -updateDeviceCategory=audio,video,network,storage,input,chipset,others'
        }
        
        $params = @{
            ComputerName = $device.HostName
            Command      = 'scan'
            Arguments    = $scanArgs
        }

        $this.InvokePsExec($params)
        $artifact = $this.CopyRemoteArtifacts($device.HostName)
        
        # Parse report (placeholder)
        $updates = $this.Matcher.FindBestDriverMatch('report', @()) 

        return @{
            ReportPath = $artifact.Report
            LogPath    = $artifact.Log
            Updates    = @($updates) | Where-Object { $_ }
        }
    }

    [hashtable] RunApplyPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting apply updates.")
        
        # Build apply arguments from config with runtime overrides
        $remoteOverrides = @{
            outputLog = 'C:\temp\DONUT\apply.log'
        }
        # Merge user-provided options
        if ($null -ne $options) {
            foreach ($key in $options.Keys) {
                $remoteOverrides[$key] = $options[$key]
            }
        }
        
        $applyArgs = $this.Config.BuildDcuArgs('applyUpdates', $remoteOverrides)

        $params = @{
            ComputerName = $device.HostName
            Command      = 'applyUpdates'
            Arguments    = $applyArgs
        }

        $this.InvokePsExec($params)
        $artifact = $this.CopyRemoteArtifacts($device.HostName)
        return $artifact
    }

    [hashtable] CopyRemoteArtifacts([string] $hostName) {
        $ip = $this.Probe.ResolveHost($hostName)
        
        # Remote Paths (UNC)
        $remoteLog = "\\$ip\C$\temp\DONUT\scan.log"
        $remoteReport = "\\$ip\C$\temp\DONUT\Report.xml" # DCU default report name might vary, usually Report.xml in the folder
        
        # If we specified -report C:\temp\DONUT, it creates C:\temp\DONUT\Report.xml (or similar)
        # We need to be sure about the report filename.
        # DCU 4.x+ usually creates "Report.xml" inside the folder.
        
        $localLog = Join-Path $this.LocalLogsDir "$hostName.log"
        $localReport = Join-Path $this.LocalReportsDir "$hostName.xml"
        
        if (Test-Path $remoteLog) {
            Copy-Item -Path $remoteLog -Destination $localLog -Force
        }
        
        # Check for report file (it might be named differently or inside a subfolder)
        # We'll try the standard one.
        if (Test-Path "\\$ip\C$\temp\DONUT\Report.xml") {
            Copy-Item -Path "\\$ip\C$\temp\DONUT\Report.xml" -Destination $localReport -Force
        }
        
        return @{ Log = $localLog; Report = $localReport }
    }

    # BuildTempConfig is deprecated/removed


    [void] InvokePsExec([hashtable] $parameters) {
        $computer = $parameters.ComputerName
        $command = $parameters.Command
        $argsString = $parameters.Arguments

        # Resolve IP (should be done, but verify)
        $ip = $this.Probe.ResolveHost($computer)
        if (-not $ip) { throw "Could not resolve IP for $computer" }

        # Find DCU Path
        $dcuPath = $this.FindDcuCli($ip)
        $this.Logger.LogInfo("Found dcu-cli at $dcuPath on $computer")

        # Build Remote Command
        # DCU CLI syntax: dcu-cli.exe /<command> -option1=value1 -option2=value2
        # Stop existing process first to avoid conflicts
        $stopCmd = "Stop-Process -Name 'DellCommandUpdate' -Force -ErrorAction SilentlyContinue"
        
        # Ensure temp directory exists
        $mkdirCmd = "New-Item -Path 'C:\temp\DONUT' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null"
        
        # Execute DCU CLI with command and arguments
        $dcuCmd = "& '$dcuPath' /$command $argsString"
        $remoteCmd = "$stopCmd; $mkdirCmd; $dcuCmd"

        # PsExec Arguments
        $psexecArgs = @(
            '-accepteula',
            '-nobanner', 
            '-s',           # Run as SYSTEM
            '-h',           # Elevated token
            "\\$ip",
            'pwsh',
            '-NoProfile',
            '-NonInteractive',
            '-c',
            "`"$remoteCmd`""
        )

        $this.Logger.LogInfo("Executing: psexec \\$ip /$command $argsString")

        $p = Start-Process -FilePath 'psexec.exe' -ArgumentList $psexecArgs -Wait -NoNewWindow -PassThru
        
        # DCU CLI exit codes: 0=success, 1=reboot required, 500+=errors
        # Reference: https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes
        if ($p.ExitCode -notin @(0, 1, 2, 3, 4, 5)) {
            throw "PsExec/DCU failed with exit code $($p.ExitCode)"
        }
        
        if ($p.ExitCode -eq 1) {
            $this.Logger.LogInfo("[$computer] Reboot required to complete updates.")
        }
    }

    [string] FindDcuCli([string]$ip) {
        $paths = @(
            "\\$ip\C$\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe",
            "\\$ip\C$\Program Files\Dell\CommandUpdate\dcu-cli.exe"
        )
        foreach ($path in $paths) {
            if (Test-Path $path) {
                if ($path -match "Program Files \(x86\)") {
                    return "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
                }
                else {
                    return "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
                }
            }
        }
        throw "dcu-cli.exe not found on $ip"
    }

    [void] AssertReachable([DeviceContext] $device) {
        if (-not $this.Probe.IsOnline($device.HostName)) {
            throw "Host '$($device.HostName)' is offline or unreachable."
        }
        $ip = $this.Probe.ResolveHost($device.HostName)
        
        if ($ip) { $device.IPAddress = $ip.ToString() }
        if (-not $this.Probe.IsRpcAvailable($device.HostName)) {
            throw "RPC is unavailable on '$($device.HostName)'."
        }
    }
}
