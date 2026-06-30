using module "..\Core\LogService.psm1"
using module "..\Core\NetworkProbe.psm1"
using module ".\DriverMatchingService.psm1"
using module ".\RemoteServices.psm1"
using module "..\Models\DeviceContext.psm1"
using module "..\Models\AppConfig.psm1"
using module "..\Models\DiskUsage.psm1"
using module "..\Models\RemoteError.psm1"

<#
.SYNOPSIS
    The runspace-pool worker engine: runs one remote phase end-to-end.

.DESCRIPTION
    Entry point (StartWorker) for the RemoteWorker.ps1 script. Asserts the target
    is reachable on the pool thread, then dispatches by job kind to a phase —
    resolve, scan, apply, inventory, or disk — invoking dcu-cli / CIM probes /
    WizTree via PsExec as SYSTEM and copying the resulting artifacts back to the
    local logs/reports folders for the services to parse.

.NOTES
    Runs entirely off the WPF dispatcher, in a pool runspace. Holds the
    NetworkProbe + DriverMatchingService + LogService it needs to do the work.
#>
class ExecutionService {
    [LogService] $Logger
    [NetworkProbe] $Probe
    [DriverMatchingService] $Matcher
    [AppConfig] $Config
    [string] $RemoteScriptPath
    [string] $ToolsDir
    [string] $LocalLogsDir
    [string] $LocalReportsDir
    # Per-job resolved IP. Seeded from a pre-resolved IP (HostResolver) when one is
    # supplied, else filled in by the first ResolvedIpFor() call - so a job resolves
    # the host 0 or 1 times, never on the hot path when it was prefetched.
    [string] $JobIp = ''

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

        # Use the pre-resolved IP (warmed in the background on selection) when the
        # presenter threaded one through, so the worker skips DNS on the hot path.
        if ($null -ne $Options -and $Options.ResolvedIp -and -not [string]::IsNullOrWhiteSpace([string]$Options.ResolvedIp)) {
            $service.JobIp = [string]$Options.ResolvedIp
        }

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
        elseif ($JobType -eq 'Resolve') {
            return $service.RunResolvePhase($device, $Options)
        }
        else {
            throw "Unknown JobType: $JobType"
        }
    }

    # Background resolution run on the pool (not the UI thread). 'Warm' discovers a
    # live domain controller (+ list) once at startup; 'Host' freshly resolves a
    # single host against that already-known DC (cheap, no AD module) AND probes
    # reachability, returning a verdict { Ip; Online }. A fresh forward-resolve is
    # authoritative, so it self-heals a changed/reassigned IP; RPC (TCP 135) is
    # exactly what psexec needs, so it doubles as the online check. The result
    # rides back on the AsyncJob's Result and is cached by HostResolver.
    [hashtable] RunResolvePhase([DeviceContext] $device, [hashtable] $options) {
        $mode = if ($null -ne $options) { [string]$options.Mode } else { 'Host' }

        if ($mode -eq 'Warm') {
            $dc = $this.Probe.GetActiveDomainController()
            $this.Logger.LogInfo("Resolver warm-up: active domain controller = $dc")
            return @{ Mode = 'Warm'; ActiveDc = [string]$dc; DomainControllers = @($this.Probe.GetDomainControllers()) }
        }

        # Running this job forced RemoteWorker.ps1 to load the full worker module graph
        # into its pool runspace; WarmRuntimeAssemblies then cold-loads the heavy runtime
        # assemblies (DNS, CIM/DCOM, TCP). Both happen here during the synchronous
        # pre-warm so a later scan/inventory never cold-loads them under the loader lock
        # (which freezes the UI).
        if ($mode -eq 'WarmRunspace') {
            $this.WarmRuntimeAssemblies()
            return @{ Mode = 'WarmRunspace' }
        }

        # Identity check: ask the box at $ip for its own name. Runs as its own pool
        # job (its own thread), in parallel with - and never touching - the dcu-cli
        # scan, so it adds no latency to the bottleneck.
        if ($mode -eq 'Name') {
            $ip = if ($null -ne $options) { [string]$options.Ip } else { '' }
            $actual = $this.Probe.ResolveComputerName($ip)
            return @{ Mode = 'Name'; HostName = $device.HostName; ActualName = [string]$actual }
        }

        $dc = if ($null -ne $options) { [string]$options.Dc } else { '' }
        $ip = $this.Probe.ResolveWith($device.HostName, $dc)
        $ipStr = if ($null -ne $ip) { $ip.ToString() } else { '' }
        $online = if (-not [string]::IsNullOrWhiteSpace($ipStr)) { $this.Probe.IsRpcAvailable($ipStr) } else { $false }
        # No log here: routine TTL re-validations would spam it. The presenter logs
        # only a first find or an actual IP change (CompleteResolve).
        return @{ Mode = 'Host'; HostName = $device.HostName; Ip = $ipStr; Online = $online }
    }

    # Cold-loads the heavy runtime assemblies the worker uses - DNS resolution, CIM/DCOM
    # and TCP sockets - against localhost, so the FIRST real probe doesn't load them under
    # the process-wide CLR loader lock and freeze the UI. Best-effort: only the load
    # matters, not the results. Overridable so unit tests skip the local I/O.
    [void] WarmRuntimeAssemblies() {
        try { Resolve-DnsName -Name 'localhost' -QuickTimeout -ErrorAction SilentlyContinue | Out-Null } catch { }
        try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Close() } catch { }
        try {
            $opt = New-CimSessionOption -Protocol Dcom
            $s = New-CimSession -SessionOption $opt -ErrorAction Stop
            try { Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystem -Property Name -ErrorAction Stop | Out-Null } catch { }
            Remove-CimSession -CimSession $s -ErrorAction SilentlyContinue
        } catch { }
    }

    # The job's target IP, resolved at most once: returns the pre-resolved/seeded IP
    # if present, otherwise resolves via the AD-authoritative path and memoizes it.
    hidden [string] ResolvedIpFor([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($this.JobIp)) {
            $ip = $this.Probe.ResolveHost($hostName)
            if (-not $ip) {
                throw [RemoteJobService]::Fail($this.Logger, [HostUnresolvableException]::new($hostName))
            }
            $this.JobIp = [string]$ip
        }
        return $this.JobIp
    }

    [hashtable] RunScanPhase([DeviceContext] $device) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting preliminary scan.")

        # Build scan arguments from config with remote path overrides
        $remoteOverrides = @{
            report    = 'C:\temp\DONUT'
            outputLog = 'C:\temp\DONUT\scan.log'
        }
        $scanArgs = $this.Config.BuildDcuArgs('scan', $remoteOverrides)
        
        # If no updateDeviceCategory specified, default to all categories.
        # Single-quote the comma list so it survives the remote `pwsh -c` wrapper
        # (a bare comma is PowerShell's array operator and breaks parsing); the
        # remote PowerShell strips the quotes, so dcu-cli gets the plain list.
        if ($scanArgs -notmatch '-updateDeviceCategory') {
            $scanArgs += " -updateDeviceCategory='audio,video,network,storage,input,chipset,others'"
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

        # Pass only runtime options to /applyUpdates; let config supply the rest. We do
        # NOT add -outputLog here: the pending-update count comes from the scan report
        # (not apply.log), and some DCU builds reject -outputLog on /applyUpdates with a
        # 105 (invalid command-line syntax) even though /scan accepts it.
        $remoteOverrides = @{}
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

    # Gathers a machine's inventory. Fast path: query WMI directly over a remote DCOM
    # CIM session (no psexec deploy, no pwsh cold-start, no SMB copy) and write the
    # JSON locally. If that can't connect, fall back to the proven psexec+pwsh probe.
    [hashtable] RunInventoryPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting inventory probe.")
        $ip = $this.ResolvedIpFor($device.HostName)

        # Bounded reachability gate (TCP 135, ~2s) so an offline host fails in seconds
        # instead of hanging minutes on the unbounded CIM/psexec connect. This is only
        # IsRpcAvailable - NOT the Test-Connection/ResolveHost combo that stalled a cold
        # runspace - and the socket/CIM assemblies are pre-warmed, so it can't cold-load.
        if (-not $this.Probe.IsRpcAvailable($ip)) {
            throw [RemoteJobService]::Fail($this.Logger, [HostOfflineException]::new($device.HostName))
        }

        # Fast path: gather over a remote CIM/DCOM session. A null result (session
        # wouldn't open), an all-null/unusable result (DCOM answered but WMI gave
        # nothing), or a thrown error all count as failure and fall through to the
        # psexec probe.
        $inv = $null
        try {
            $inv = $this.GatherRemoteInventory($ip)
        }
        catch {
            $this.Logger.LogException("[$($device.HostName)] CIM inventory threw; falling back to the psexec probe", $_)
            $inv = $null
        }

        if ([ExecutionService]::IsUsableInventory($inv)) {
            $local = Join-Path $this.LocalReportsDir "$($device.HostName)-inventory.json"
            $inv | ConvertTo-Json -Depth 4 | Set-Content -Path $local -Encoding UTF8
            return @{ InventoryPath = $local }
        }

        # Fallback: the original psexec probe (e.g. DCOM/WMI blocked on the target).
        $this.Logger.LogWarning("[$($device.HostName)] Remote CIM unavailable or empty; using psexec probe.")
        $scriptText = if ($null -ne $options) { [string]$options.ScriptText } else { '' }
        if ([string]::IsNullOrWhiteSpace($scriptText)) {
            throw "No inventory script supplied for $($device.HostName)."
        }
        $this.InvokeRemotePwsh($ip, $scriptText)
        $localPath = $this.CopyInventoryArtifact($device.HostName)
        return @{ InventoryPath = $localPath }
    }

    # A CIM gather only "succeeded" if it produced at least one identifying fact.
    # An all-null result means DCOM answered but WMI handed back nothing useful, so
    # the caller should fall back to the psexec probe. Pure + static, so it is
    # unit-tested without a live host.
    static [bool] IsUsableInventory([hashtable]$inv) {
        if ($null -eq $inv) { return $false }
        foreach ($key in @('model', 'serviceTag', 'biosVersion', 'totalSpaceBytes', 'lastBootTime')) {
            if ($inv.ContainsKey($key)) {
                $v = $inv[$key]
                if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return $true }
            }
        }
        return $false
    }

    # Queries the host's WMI directly over a DCOM CIM session (same RPC transport
    # psexec uses) and returns the inventory hashtable - mirrors the probe script's
    # projected queries, including the battery -Property serialization bypass. Each
    # query is guarded so one missing field never aborts; returns $null only when the
    # session itself can't open (caller falls back). Overridable so tests fake it.
    [hashtable] GatherRemoteInventory([string]$ip) {
        if ([string]::IsNullOrWhiteSpace($ip)) { return $null }
        $session = $null
        try {
            $session = New-CimSession -ComputerName $ip -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop
        }
        catch {
            $this.Logger.LogException("[$ip] Could not open CIM session for inventory", $_)
            return $null
        }

        $inv = @{
            model = $null; serviceTag = $null; biosVersion = $null
            hasBattery = $false; designCapacity = $null; fullChargeCapacity = $null
            chargePercent = $null; charging = $false
            freeSpaceBytes = $null; totalSpaceBytes = $null
            lastBootTime = $null; probedAt = ([datetime]::UtcNow.ToString('o'))
        }
        try {
            try { $cs = Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -Property Model -ErrorAction Stop; $inv.model = $cs.Model } catch { }
            try {
                $bios = Get-CimInstance -CimSession $session -ClassName Win32_BIOS -Property SerialNumber, SMBIOSBIOSVersion -ErrorAction Stop
                $inv.serviceTag = $bios.SerialNumber; $inv.biosVersion = $bios.SMBIOSBIOSVersion
            } catch { }
            try {
                $static = Get-CimInstance -CimSession $session -Namespace 'root\wmi' -ClassName BatteryStaticData -Property DesignedCapacity -ErrorAction Stop | Select-Object -First 1
                if ($static) { $inv.designCapacity = [int64]$static.DesignedCapacity }
            } catch { }
            try {
                $full = Get-CimInstance -CimSession $session -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -Property FullChargedCapacity -ErrorAction Stop | Select-Object -First 1
                if ($full) { $inv.fullChargeCapacity = [int64]$full.FullChargedCapacity }
            } catch { }
            try {
                $bat = Get-CimInstance -CimSession $session -ClassName Win32_Battery -Property EstimatedChargeRemaining, BatteryStatus -ErrorAction Stop | Select-Object -First 1
                if ($bat) {
                    $inv.hasBattery = $true
                    $inv.chargePercent = [int]$bat.EstimatedChargeRemaining
                    $inv.charging = ([int]$bat.BatteryStatus -ne 1)
                }
            } catch { }
            try {
                $disk = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -Property FreeSpace, Size -ErrorAction Stop | Select-Object -First 1
                if ($disk) { $inv.freeSpaceBytes = [int64]$disk.FreeSpace; $inv.totalSpaceBytes = [int64]$disk.Size }
            } catch { }
            try {
                $os = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop
                if ($os.LastBootUpTime) { $inv.lastBootTime = $os.LastBootUpTime.ToUniversalTime().ToString('o') }
            } catch { }
        }
        finally {
            Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
        }
        return $inv
    }

    # Runs an arbitrary pwsh script on the remote as SYSTEM. The script is passed
    # base64-encoded (UTF-16LE) via -EncodedCommand, which removes all psexec
    # command-line quoting hazards (unlike the dcu-cli '-c "..."' path).
    # $target may be a host name or an IP - psexec accepts either.
    [void] InvokeRemotePwsh([string]$target, [string]$scriptText) {
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($scriptText)
        $encoded = [Convert]::ToBase64String($bytes)

        $psexecArgs = @(
            '-accepteula',
            '-nobanner',
            '-s',           # Run as SYSTEM
            '-h',           # Elevated token
            "\\$target",
            'pwsh',
            '-NoProfile',
            '-NonInteractive',
            '-EncodedCommand',
            $encoded
        )

        $this.Logger.LogInfo("Executing remote probe on \\$target")
        $p = Start-Process -FilePath 'psexec.exe' -ArgumentList $psexecArgs -Wait -NoNewWindow -PassThru

        if ($p.ExitCode -ne 0) {
            throw [RemoteExecutionException]::new($target, 'Remote probe', $p.ExitCode)
        }
    }

    # Copies the inventory JSON the probe wrote on the remote back to the local
    # reports dir; returns the local path. Reuses the job's already-resolved IP.
    [string] CopyInventoryArtifact([string] $hostName) {
        $ip = $this.ResolvedIpFor($hostName)
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

        $ip = $this.ResolvedIpFor($device.HostName)
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
        $ip = $this.ResolvedIpFor($hostName)
        $remote = "\\$ip\C$\temp\DONUT\folders.csv"
        $local = Join-Path $this.LocalReportsDir "$hostName-folders.csv"
        if (Test-Path $remote) {
            Copy-Item -Path $remote -Destination $local -Force
        }
        return $local
    }

    [hashtable] CopyRemoteArtifacts([string] $hostName) {
        $ip = $this.ResolvedIpFor($hostName)
        $remoteDir = "\\$ip\C$\temp\DONUT"
        $remoteLog = Join-Path $remoteDir "scan.log"

        $localLog = Join-Path $this.LocalLogsDir "$hostName.log"
        # Must match RemoteUpdateService.ParseUpdateReport's "<host>-Updates.xml", or the
        # scan's report is never read and the pending-updates count stays 0.
        $localReport = Join-Path $this.LocalReportsDir "$hostName-Updates.xml"

        if (Test-Path $remoteLog) {
            Copy-Item -Path $remoteLog -Destination $localLog -Force
        }

        # DCU names its scan report inconsistently across versions (Report.xml,
        # DCUApplicableUpdates.xml, ...), so don't guess a single name - copy the NEWEST
        # *.xml the scan left at the top of the remote DONUT folder. That is the report.
        # (Top level only: DCU writes it there, and a recursive UNC enumeration can stall.)
        $report = $null
        try {
            $report = Get-ChildItem -Path $remoteDir -Filter '*.xml' -File -ErrorAction Stop |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        catch {
            $this.Logger.LogWarning("[$hostName] Could not list reports in $remoteDir : $($_.Exception.Message)")
        }
        if ($report) {
            Copy-Item -Path $report.FullName -Destination $localReport -Force
            $this.Logger.LogInfo("[$hostName] Copied scan report '$($report.Name)' -> $hostName-Updates.xml")
        }
        else {
            # Log what DCU actually left behind, so we can see whether it wrote the report
            # under a different name - or didn't write one at all.
            $contents = try {
                (Get-ChildItem -Path $remoteDir -File -ErrorAction Stop | ForEach-Object { $_.Name }) -join ', '
            } catch { '<unreadable>' }
            $this.Logger.LogWarning("[$hostName] No scan report (*.xml) found in $remoteDir - the apply/count will see no updates. Folder contains: $contents")
        }

        return @{ Log = $localLog; Report = $localReport }
    }

    [void] InvokePsExec([hashtable] $parameters) {
        $computer = $parameters.ComputerName
        $command = $parameters.Command
        $argsString = $parameters.Arguments

        # Reuse the job's resolved/prefetched IP (resolves at most once).
        $ip = $this.ResolvedIpFor($computer)

        $dcuPath = $this.FindDcuCli($ip)
        $this.Logger.LogInfo("Found dcu-cli at $dcuPath on $computer")

        # DCU CLI syntax: dcu-cli.exe /<command> -option1=value1 -option2=value2
        # Stop any existing DCU process first to avoid conflicts.
        $stopCmd = "Stop-Process -Name 'DellCommandUpdate' -Force -ErrorAction SilentlyContinue"
        $mkdirCmd = "New-Item -Path 'C:\temp\DONUT' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null"
        $dcuCmd = "& '$dcuPath' /$command $argsString"
        $remoteCmd = "$stopCmd; $mkdirCmd; $dcuCmd"

        # PsExec Arguments
        $psexecArgs = @(
            '-accepteula',
            '-nobanner',
            '-n', '60',     # connect timeout (s): give up instead of hanging on a dead host
            '-s',           # Run as SYSTEM
            '-h',           # Elevated token
            "\\$ip",
            'pwsh',
            '-NoProfile',
            '-NonInteractive',
            '-c',
            "`"$remoteCmd`""
        )

        # Log the EXACT command line handed to psexec.exe - psexec flags plus the remote
        # 'pwsh -c "..."' wrapper that actually runs dcu-cli - so a CLI/syntax failure
        # (e.g. DCU 105) can be read straight from the log instead of reconstructed. This
        # is the literal argument list Start-Process receives, in order.
        $this.Logger.LogInfo("Executing: psexec.exe $($psexecArgs -join ' ')")

        $p = Start-Process -FilePath 'psexec.exe' -ArgumentList $psexecArgs -Wait -NoNewWindow -PassThru
        
        # DCU CLI exit codes: 0=success, 1=reboot required, 500+=errors
        # Reference: https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes
        if ($p.ExitCode -notin @(0, 1, 2, 3, 4, 5)) {
            # Carry the full argument string so a syntax error (e.g. DCU 105) surfaces the
            # exact command in the user-visible error, not just the bare command name.
            throw [RemoteExecutionException]::new($computer, "DCU /$command $argsString", $p.ExitCode)
        }
        
        if ($p.ExitCode -eq 1) {
            $this.Logger.LogInfo("[$computer] Reboot required to complete updates.")
        }
    }

    [string] FindDcuCli([string]$ip) {
        # The lookup below probes the admin share over SMB (445). If that port is blocked
        # - which IsHostOnline (RPC/135) does NOT rule out - Test-Path blocks with no
        # timeout and the job spins forever. Check it first and fail fast with a reason.
        if (-not $this.Probe.IsSmbAvailable($ip)) {
            $this.Logger.LogWarning("[$ip] Admin share (SMB/445) not reachable - cannot locate dcu-cli or run psexec.")
            throw [RpcUnavailableException]::new($ip)
        }

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
        throw [DcuNotInstalledException]::new($ip)
    }

    [void] AssertReachable([DeviceContext] $device) {
        # Reuse the shared connectivity policy (IsOnline -> ResolveHost ->
        # IsRpcAvailable) and record the resolved IP on the device context.
        $device.IPAddress = [RemoteJobService]::AssertHostReachable($this.Probe, $this.Logger, $device.HostName)
    }
}
