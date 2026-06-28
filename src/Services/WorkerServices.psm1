using module "..\Core\LogService.psm1"
using module "..\Core\NetworkProbe.psm1"
using module ".\DriverMatchingService.psm1"
using module ".\RemoteServices.psm1"
using module "..\Models\DeviceContext.psm1"
using module "..\Models\AppConfig.psm1"
using module "..\Models\DiskUsage.psm1"

class ExecutionService {
    [LogService] $Logger
    [NetworkProbe] $Probe
    [DriverMatchingService] $Matcher
    [AppConfig] $Config
    [string] $RemoteScriptPath
    [string] $ToolsDir
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
        $this.ToolsDir = Join-Path $sourceRoot "Tools"
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
        # Init Services (share one logger across the worker's collaborators)
        $localLogger = [LogService]::new($LogsDir)
        $localProbe = [NetworkProbe]::new($localLogger)
        $localMatcher = [DriverMatchingService]::new($localLogger)
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
        elseif ($JobType -eq 'Inventory') {
            return $service.RunInventoryPhase($device, $Options)
        }
        elseif ($JobType -eq 'DiskScan') {
            return $service.RunDiskScanPhase($device, $Options)
        }
        else {
            throw "Unknown JobType: $JobType"
        }
    }

    [hashtable] RunScanPhase([DeviceContext] $device) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting preliminary scan.")

        # Reachability is asserted here on the runspace-pool thread (moved off the
        # UI thread, which used to block when probing an offline host).
        $this.AssertReachable($device)
        if ($device.IPAddress -and -not $this.Probe.CheckReverseDNS($device.IPAddress, $device.HostName)) {
            $this.Logger.LogWarning("Reverse DNS mismatch for '$($device.HostName)' ($($device.IPAddress)). Proceeding anyway.")
        }

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

        return @{
            ReportPath = $artifact.Report
            LogPath    = $artifact.Log
            Updates    = @()
        }
    }

    [hashtable] RunApplyPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting apply updates.")
        $this.AssertReachable($device)

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

    # Runs the inventory probe script on the remote and copies its JSON back.
    [hashtable] RunInventoryPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting inventory probe.")
        $this.AssertReachable($device)

        $ip = $this.Probe.ResolveHost($device.HostName)
        if (-not $ip) {
            $this.Logger.LogError("[$($device.HostName)] Could not resolve IP; aborting inventory.")
            throw "Could not resolve IP for $($device.HostName)"
        }

        $scriptText = if ($null -ne $options) { [string]$options.ScriptText } else { '' }
        if ([string]::IsNullOrWhiteSpace($scriptText)) {
            throw "No inventory script supplied for $($device.HostName)."
        }

        $this.InvokeRemotePwsh($ip, $scriptText)
        $localPath = $this.CopyInventoryArtifact($device.HostName)
        return @{ InventoryPath = $localPath }
    }

    # Runs an arbitrary pwsh script on the remote as SYSTEM. The script is passed
    # base64-encoded (UTF-16LE) via -EncodedCommand, which removes all psexec
    # command-line quoting hazards (unlike the dcu-cli '-c "..."' path).
    [void] InvokeRemotePwsh([string]$ip, [string]$scriptText) {
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($scriptText)
        $encoded = [Convert]::ToBase64String($bytes)

        $psexecArgs = @(
            '-accepteula',
            '-nobanner',
            '-s',           # Run as SYSTEM
            '-h',           # Elevated token
            "\\$ip",
            'pwsh',
            '-NoProfile',
            '-NonInteractive',
            '-EncodedCommand',
            $encoded
        )

        $this.Logger.LogInfo("Executing inventory probe on \\$ip")
        $p = Start-Process -FilePath 'psexec.exe' -ArgumentList $psexecArgs -Wait -NoNewWindow -PassThru

        if ($p.ExitCode -ne 0) {
            throw "Remote inventory probe failed on $ip (exit code $($p.ExitCode))."
        }
    }

    # Copies the inventory JSON the probe wrote on the remote back to the local
    # reports dir; returns the local path. Mirrors CopyRemoteArtifacts.
    [string] CopyInventoryArtifact([string] $hostName) {
        $ip = $this.Probe.ResolveHost($hostName)
        $remote = "\\$ip\C$\temp\DONUT\$hostName-inventory.json"
        $local = Join-Path $this.LocalReportsDir "$hostName-inventory.json"
        if (Test-Path $remote) {
            Copy-Item -Path $remote -Destination $local -Force
        }
        return $local
    }

    # Deploys the bundled WizTree binary to the target, runs a fast MFT folder
    # scan as SYSTEM (exporting a size-sorted CSV), and copies the CSV back. This
    # is the only place DONUT pushes a file TO the target (every other probe only
    # copies artifacts back); the exe is left in C:\temp\DONUT for reuse.
    [hashtable] RunDiskScanPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting disk-usage scan.")
        $this.AssertReachable($device)

        $ip = $this.Probe.ResolveHost($device.HostName)
        if (-not $ip) {
            $this.Logger.LogError("[$($device.HostName)] Could not resolve IP; aborting disk scan.")
            throw "Could not resolve IP for $($device.HostName)"
        }

        $this.DeployWizTree($ip)
        $this.InvokeRemotePwsh($ip, [ExecutionService]::BuildScanCommand())
        $csvPath = $this.CopyDiskUsageArtifact($device.HostName)
        $jsonPath = $this.ParseAndCacheFolders($device.HostName, $csvPath, $options)
        return @{ FoldersPath = $csvPath; FoldersJson = $jsonPath }
    }

    # Parses the (potentially large) WizTree CSV here on the worker/pool thread and
    # writes a compact top-N JSON, so the UI thread only ever reads a tiny file.
    # (Parsing the raw CSV with ConvertFrom-Csv on the dispatcher thread froze the
    # UI for ~1s; the heavy work belongs off the STA thread.)
    [string] ParseAndCacheFolders([string]$hostName, [string]$csvPath, [hashtable]$options) {
        $topN = 12
        if ($null -ne $options -and $options.TopN) { $topN = [int]$options.TopN }

        $jsonPath = Join-Path $this.LocalReportsDir "$hostName-folders.json"
        if (-not (Test-Path $csvPath)) { return $jsonPath }

        try {
            $raw = Get-Content -Path $csvPath -Raw
            $report = [WizTreeCsv]::ParseTopFolders($raw, $topN)
            $report.ToHashtable() | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
        }
        catch {
            $this.Logger.LogException("[$hostName] Failed to parse WizTree CSV", $_)
        }
        return $jsonPath
    }

    # Copies wiztree64.exe to the target's working dir (only when not already
    # present, so repeat scans skip the ~2 MB transfer).
    [void] DeployWizTree([string]$ip) {
        $localExe = Join-Path $this.ToolsDir 'wiztree64.exe'
        if (-not (Test-Path $localExe)) {
            throw "Bundled wiztree64.exe not found at $localExe. Drop the binary into src\Tools\."
        }

        $remoteDir = "\\$ip\C$\temp\DONUT"
        if (-not (Test-Path $remoteDir)) {
            New-Item -Path $remoteDir -ItemType Directory -Force | Out-Null
        }

        $remoteExe = Join-Path $remoteDir 'wiztree64.exe'
        if (-not (Test-Path $remoteExe)) {
            $this.Logger.LogInfo("Deploying wiztree64.exe to \\$ip")
            Copy-Item -Path $localExe -Destination $remoteExe -Force
        }
    }

    # The remote command that runs WizTree headlessly: a fast MFT scan of C:,
    # folders only, sorted by size, exported to CSV. Isolated in one place so a
    # pure-PowerShell fallback (if session-0 GUI invocation proves unreliable) is
    # a single-method swap with no change to the parser/cache/UI.
    static [string] BuildScanCommand() {
        return @'
& 'C:\temp\DONUT\wiztree64.exe' "C:" /export="C:\temp\DONUT\folders.csv" /admin=1 /exportfolders=1 /exportfiles=0 /sortby=1 /exportmaxdepth=4 | Out-Null
'@
    }

    # Copies the WizTree CSV the scan wrote on the remote back to the local
    # reports dir; returns the local path. Mirrors CopyInventoryArtifact.
    [string] CopyDiskUsageArtifact([string] $hostName) {
        $ip = $this.Probe.ResolveHost($hostName)
        $remote = "\\$ip\C$\temp\DONUT\folders.csv"
        $local = Join-Path $this.LocalReportsDir "$hostName-folders.csv"
        if (Test-Path $remote) {
            Copy-Item -Path $remote -Destination $local -Force
        }
        return $local
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

    [void] InvokePsExec([hashtable] $parameters) {
        $computer = $parameters.ComputerName
        $command = $parameters.Command
        $argsString = $parameters.Arguments

        # Resolve IP (should be done, but verify)
        $ip = $this.Probe.ResolveHost($computer)
        if (-not $ip) {
            $this.Logger.LogError("[$computer] Could not resolve IP; aborting PsExec.")
            throw "Could not resolve IP for $computer"
        }

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
        # Reuse the shared connectivity policy (IsOnline -> ResolveHost ->
        # IsRpcAvailable) and record the resolved IP on the device context.
        $device.IPAddress = [RemoteJobService]::AssertHostReachable($this.Probe, $this.Logger, $device.HostName)
    }
}
