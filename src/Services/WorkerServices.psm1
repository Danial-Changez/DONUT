using module "..\Core\LogService.psm1"
using module "..\Core\NetworkProbe.psm1"
using module ".\DriverMatchingService.psm1"
using module ".\RemoteServices.psm1"
using module "..\Models\DeviceContext.psm1"
using module "..\Models\AppConfig.psm1"
using module "..\Models\DiskUsage.psm1"
using module "..\Models\RemoteError.psm1"
using module "..\Models\DcuLog.psm1"

<#
.SYNOPSIS
    The runspace-pool worker engine: runs one remote phase end-to-end.

.DESCRIPTION
    Entry point (StartWorker) for the RemoteWorker.ps1 script. Dispatches by job
    kind to a phase — resolve, scan, apply, inventory, or disk — invoking dcu-cli /
    CIM probes / WizTree via PsExec as SYSTEM and copying the resulting artifacts
    back to the local logs/reports folders for the services to parse. Each phase
    gates its own transport first (bounded RPC-135 / SMB-445 probes), so an
    unreachable target fails in seconds instead of hanging the pool thread.

.NOTES
    Runs entirely off the WPF dispatcher, in a pool runspace. Holds the
    NetworkProbe + DriverMatchingService + LogService it needs to do the work.

    Transport rules this file is built around:
    - UNC and CIM operations have no usable timeout, so every share/WMI touch is
      gated by a bounded port probe first (RPC 135 for psexec/CIM, SMB 445 for
      admin-share I/O) - otherwise an offline or firewalled host hangs the pool
      thread forever.
    - Concurrent psexec sessions sharing one PSEXESVC hang when the first ends and
      deletes the service, so each job family runs under its own -r service name
      (DonutDcu / DonutDisk / DonutProbe).
    - psexec exit codes are classified: negative = Windows process-launch fault
      (NTSTATUS); Win32 transport codes = the connection dropped mid-command (the
      classic trigger is applying a NETWORK driver, which resets the NIC psexec
      rides over). On a drop, dcu-cli's authoritative return code is recovered from
      its outputLog, trusted only if written strictly after the pre-run clear's
      freshness baseline ($null = log was cleared, a LastWriteTimeUtc = locked
      leftover so only strictly-newer counts, [datetime]::MaxValue = never trust).
    - dcu-cli return codes: only 0 is success, 1/5 mean done-but-reboot, and the
      other small codes are real failures (see DcuLog). Reference:
      https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes
    - Live progress rides dcu-cli's -outputLog, tailed over the admin share into
      the Information stream while psexec runs.
    - GatherRemoteInventory, ReadDcuReturnCode and WarmRuntimeAssemblies are
      overridable seams so unit tests run without a network.
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
    # Per-job resolved IP; a job resolves its host at most once (see ResolvedIpFor).
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
        [string]$ResolvedIp,
        [AppConfig]$Config,
        [string]$SourceRoot,
        [string]$LogsDir,
        [string]$ReportsDir
    ) {
        # One logger shared across the worker's collaborators.
        $localLogger = [LogService]::new($LogsDir)
        $localProbe = [NetworkProbe]::new($localLogger)
        $localMatcher = [DriverMatchingService]::new($localLogger)
        $service = [ExecutionService]::new($localLogger, $localProbe, $localMatcher,
            $Config, $SourceRoot, $LogsDir, $ReportsDir)

        # The pre-resolved IP rides a dedicated argument - never an Options key - so
        # the worker skips DNS yet it can't leak into a dcu-cli line.
        if (-not [string]::IsNullOrWhiteSpace($ResolvedIp)) {
            $service.JobIp = $ResolvedIp
        }

        $device = [DeviceContext]::new($HostName)

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

    # Pool-side resolution. 'Warm' discovers the live DC list once at startup; 'Host'
    # fresh-resolves one host + probes RPC 135 -> { Ip; Online } for HostResolver.
    [hashtable] RunResolvePhase([DeviceContext] $device, [hashtable] $options) {
        $mode = if ($null -ne $options) { [string]$options.Mode } else { 'Host' }

        if ($mode -eq 'Warm') {
            $dc = $this.Probe.GetActiveDomainController()
            $this.Logger.LogInfo("Resolver warm-up: active domain controller = $dc")
            return @{
                Mode              = 'Warm'
                ActiveDc          = [string]$dc
                DomainControllers = @($this.Probe.GetDomainControllers())
            }
        }

        # This job already loaded the module graph; warming the runtime assemblies too
        # means later jobs never cold-load under the loader lock.
        if ($mode -eq 'WarmRunspace') {
            $this.WarmRuntimeAssemblies()
            return @{ Mode = 'WarmRunspace' }
        }

        # Identity check: ask the box at $ip for its own name (parallel to the scan).
        if ($mode -eq 'Name') {
            $ip = if ($null -ne $options) { [string]$options.Ip } else { '' }
            $actual = $this.Probe.ResolveComputerName($ip)
            return @{ Mode = 'Name'; HostName = $device.HostName; ActualName = [string]$actual }
        }

        $dc = if ($null -ne $options) { [string]$options.Dc } else { '' }
        $ip = $this.Probe.ResolveWith($device.HostName, $dc)
        $ipStr = if ($null -ne $ip) { $ip.ToString() } else { '' }
        $online = if (-not [string]::IsNullOrWhiteSpace($ipStr)) { $this.Probe.IsRpcAvailable($ipStr) }
        else { $false }
        # No log: routine TTL re-validations would spam it; the presenter logs changes.
        return @{ Mode = 'Host'; HostName = $device.HostName; Ip = $ipStr; Online = $online }
    }

    # Cold-loads the heavy runtime assemblies (DNS, TCP, CIM/DCOM, LDAP) against
    # localhost so the first real probe never loads them under the CLR loader lock.
    [void] WarmRuntimeAssemblies() {
        try { Resolve-DnsName -Name 'localhost' -QuickTimeout -ErrorAction SilentlyContinue | Out-Null } catch { }
        try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Close() } catch { }
        try { Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue } catch { }
        try {
            $opt = New-CimSessionOption -Protocol Dcom
            $s = New-CimSession -SessionOption $opt -ErrorAction Stop
            try { Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystem -Property Name -ErrorAction Stop | Out-Null } catch { }
            Remove-CimSession -CimSession $s -ErrorAction SilentlyContinue
        }
        catch { }
    }

    # The job's target IP, resolved at most once: returns the seeded IP if present,
    # else resolves via the AD-authoritative path and memoizes it.
    hidden [string] ResolvedIpFor([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($this.JobIp)) {
            # Job starts should thread the prefetched IP through (AttachResolvedIp);
            # landing here means the slow full AD resolve - a routing bug upstream.
            $this.Logger.LogWarning("[$hostName] No pre-resolved IP was threaded to this job - falling back to a full AD resolve on the worker (slow path).")
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

        $remoteOverrides = @{
            report    = 'C:\temp\DONUT'
            outputLog = 'C:\temp\DONUT\scan.log'
        }
        $scanArgs = $this.Config.BuildDcuArgs('scan', $remoteOverrides)

        # Default to all categories. Single-quote the comma list so it survives the
        # remote `pwsh -c` wrapper (a bare comma is PowerShell's array operator).
        if ($scanArgs -notmatch '-updateDeviceCategory') {
            $scanArgs += " -updateDeviceCategory='audio,video,network,storage,input,chipset,others'"
        }

        $params = @{
            ComputerName = $device.HostName
            Command      = 'scan'
            Arguments    = $scanArgs
            OutputLog    = 'C:\temp\DONUT\scan.log'
        }

        $this.InvokePsExec($params)
        $artifact = $this.CopyRemoteArtifacts($device.HostName, [string]$params.OutputLog)

        return @{
            ReportPath = $artifact.Report
            LogPath    = $artifact.Log
            Updates    = @()
        }
    }

    [hashtable] RunApplyPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting apply updates.")

        # Merge only keys that are real dcu-cli options: the Options bag also carries
        # control data (e.g. ResolvedIp) that dcu-cli rejects with 105.
        $remoteOverrides = @{
            outputLog = 'C:\temp\DONUT\apply.log'
        }
        $validOptionKeys = @($this.Config.GetCommandArgs('applyUpdates').Keys)
        if ($null -ne $options) {
            foreach ($key in $options.Keys) {
                if ($validOptionKeys -contains $key) {
                    $remoteOverrides[$key] = $options[$key]
                }
            }
        }

        $applyArgs = $this.Config.BuildDcuArgs('applyUpdates', $remoteOverrides)

        $params = @{
            ComputerName = $device.HostName
            Command      = 'applyUpdates'
            Arguments    = $applyArgs
            OutputLog    = 'C:\temp\DONUT\apply.log'
        }

        $applyCode = $this.InvokePsExec($params)
        $artifact = $this.CopyRemoteArtifacts($device.HostName, [string]$params.OutputLog)
        # dcu-cli 1/5 = the apply landed but needs a reboot; the presenter flags it.
        $artifact['RebootRequired'] = [DcuLog]::NeedsReboot($applyCode)
        return $artifact
    }

    # Inventory. Fast path: query WMI over a remote DCOM CIM session (no psexec deploy,
    # no SMB copy); if that can't connect, fall back to the proven psexec+pwsh probe.
    [hashtable] RunInventoryPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting inventory probe.")
        $ip = $this.ResolvedIpFor($device.HostName)

        # Bounded RPC gate (TCP 135, ~2s) so an offline host fails in seconds instead
        # of hanging minutes on the unbounded CIM/psexec connect.
        if (-not $this.Probe.IsRpcAvailable($ip)) {
            throw [RemoteJobService]::Fail($this.Logger, [HostOfflineException]::new($device.HostName))
        }

        # Null, all-null, or a throw all count as failure and fall to the psexec probe.
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
        $this.InvokeRemotePwsh($ip, $scriptText, 'DonutProbe', 10)
        $localPath = $this.CopyInventoryArtifact($device.HostName)
        return @{ InventoryPath = $localPath }
    }

    # A CIM gather "succeeded" only if it produced at least one identifying fact.
    # Pure + static, so unit-tested without a host.
    static [bool] IsUsableInventory([hashtable]$inv) {
        if ($null -eq $inv) { return $false }
        foreach ($key in @('model', 'serviceTag', 'biosVersion',
                'totalSpaceBytes', 'lastBootTime')) {
            if ($inv.ContainsKey($key)) {
                $v = $inv[$key]
                if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return $true }
            }
        }
        return $false
    }

    # Queries the host's WMI over a DCOM CIM session. Each query is guarded; returns
    # $null only when the session won't open.
    [hashtable] GatherRemoteInventory([string]$ip) {
        if ([string]::IsNullOrWhiteSpace($ip)) { return $null }
        $session = $null
        try {
            # -OperationTimeoutSec bounds the session ops so a box that died mid-open
            # (e.g. rebooting) can't hang the worker on DCOM's multi-minute defaults.
            $open = @{
                ComputerName        = $ip
                SessionOption       = (New-CimSessionOption -Protocol Dcom)
                OperationTimeoutSec = 15
                ErrorAction         = 'Stop'
            }
            $session = New-CimSession @open
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
        # Each CIM field is independently best-effort: a class that's absent (e.g. no battery
        # on a desktop) or blocked leaves that field null rather than failing the whole probe.
        try {
            try { $cs = Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -Property Model -ErrorAction Stop; $inv.model = $cs.Model } catch { }
            try {
                $bios = Get-CimInstance -CimSession $session -ClassName Win32_BIOS -Property SerialNumber, SMBIOSBIOSVersion -ErrorAction Stop
                $inv.serviceTag = $bios.SerialNumber; $inv.biosVersion = $bios.SMBIOSBIOSVersion
            }
            catch { }
            try {
                $static = Get-CimInstance -CimSession $session -Namespace 'root\wmi' -ClassName BatteryStaticData -Property DesignedCapacity -ErrorAction Stop | Select-Object -First 1
                if ($static) { $inv.designCapacity = [int64]$static.DesignedCapacity }
            }
            catch { }
            try {
                $full = Get-CimInstance -CimSession $session -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -Property FullChargedCapacity -ErrorAction Stop | Select-Object -First 1
                if ($full) { $inv.fullChargeCapacity = [int64]$full.FullChargedCapacity }
            }
            catch { }
            try {
                $bat = Get-CimInstance -CimSession $session -ClassName Win32_Battery -Property EstimatedChargeRemaining, BatteryStatus -ErrorAction Stop | Select-Object -First 1
                if ($bat) {
                    $inv.hasBattery = $true
                    $inv.chargePercent = [int]$bat.EstimatedChargeRemaining
                    $inv.charging = ([int]$bat.BatteryStatus -ne 1)
                }
            }
            catch { }
            try {
                $disk = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -Property FreeSpace, Size -ErrorAction Stop | Select-Object -First 1
                if ($disk) { $inv.freeSpaceBytes = [int64]$disk.FreeSpace; $inv.totalSpaceBytes = [int64]$disk.Size }
            }
            catch { }
            try {
                $os = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop
                if ($os.LastBootUpTime) { $inv.lastBootTime = $os.LastBootUpTime.ToUniversalTime().ToString('o') }
            }
            catch { }
        }
        finally {
            Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
        }
        return $inv
    }

    # Launches psexec.exe headless and returns the Process for the caller's watchdog.
    # CreateNoWindow hides the console so concurrent runs never sit in front of the
    # WPF UI; stdout stays unredirected so psexec keeps a real console (a file
    # redirect removed it - the suspected cause of remote 0xC0000142 init failures).
    # Args are space-joined exactly as logged, preserving the delicate DCU quoting.
    hidden static [System.Diagnostics.Process] StartPsExecHidden([string[]]$psexecArgs) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'psexec.exe'
        $psi.Arguments = ($psexecArgs -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        return [System.Diagnostics.Process]::Start($psi)
    }

    # Shared psexec watchdog: polls HasExited on a 1500ms tick (running $onTick, e.g.
    # the DCU log tail), kills + throws past the deadline, throws on a negative
    # (NTSTATUS) exit, and returns the raw code - classification stays with the caller.
    hidden [int] WaitForRemoteProcess(
        [System.Diagnostics.Process]$p,
        [string]$target,
        [string]$operation,
        [int]$maxMinutes,
        [scriptblock]$onTick
    ) {
        $deadline = [datetime]::UtcNow.AddMinutes($maxMinutes)
        while (-not $p.HasExited) {
            if ([datetime]::UtcNow -gt $deadline) {
                # Best-effort: it may already be exiting, or we may lack rights to kill it.
                try { $p.Kill($true) } catch { }
                throw [RemoteTimeoutException]::new($target, $operation, $maxMinutes)
            }
            Start-Sleep -Milliseconds 1500
            if ($null -ne $onTick) { & $onTick }
        }
        $p.WaitForExit()   # flush the exit code after HasExited flips
        $exitCode = [int]$p.ExitCode
        if ($exitCode -lt 0) {
            throw [RemoteProcessStartException]::new($target, $operation, $exitCode)
        }
        return $exitCode
    }

    # Runs a pwsh script on the remote as SYSTEM, passed base64 via -EncodedCommand
    # (no psexec quoting hazards). $serviceName isolates its PSEXESVC.
    [void] InvokeRemotePwsh([string]$target, [string]$scriptText,
        [string]$serviceName, [int]$maxMinutes) {
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($scriptText)
        $encoded = [Convert]::ToBase64String($bytes)

        $psexecArgs = @(
            '-accepteula',
            '-nobanner',
            '-r', $serviceName,
            '-n', '60',     # connect timeout (s): give up instead of hanging on a dead host
            '-s',           # Run as SYSTEM
            '-h',           # Elevated token
            "\\$target",
            'pwsh',
            '-NoProfile',
            '-NonInteractive',
            '-EncodedCommand',
            $encoded
        )

        $this.Logger.LogInfo("Executing remote probe on \\$target (service $serviceName, limit ${maxMinutes}m)")
        $p = [ExecutionService]::StartPsExecHidden($psexecArgs)
        $exitCode = $this.WaitForRemoteProcess($p, $target, 'Remote probe', $maxMinutes, $null)

        # Negative codes threw in the watchdog; a Win32 transport code means psexec's
        # pipe dropped mid-probe - neither means "the probe script failed".
        if ([RemoteConnectionLostException]::IsConnectionLost($exitCode)) {
            throw [RemoteConnectionLostException]::new($target, 'Remote probe', $exitCode)
        }
        if ($exitCode -ne 0) {
            throw [RemoteExecutionException]::new($target, 'Remote probe', $exitCode)
        }
    }

    # Copies an artifact from the remote working dir back to the local reports dir;
    # returns the local path.
    hidden [string] CopyBackArtifact([string]$hostName, [string]$remoteLeaf, [string]$localLeaf) {
        $ip = $this.ResolvedIpFor($hostName)
        $remote = "\\$ip\C$\temp\DONUT\$remoteLeaf"
        $local = Join-Path $this.LocalReportsDir $localLeaf
        if (Test-Path $remote) {
            Copy-Item -Path $remote -Destination $local -Force
        }
        return $local
    }

    # Copies the inventory JSON the probe wrote on the remote back locally.
    [string] CopyInventoryArtifact([string] $hostName) {
        return $this.CopyBackArtifact($hostName, "$hostName-inventory.json",
            "$hostName-inventory.json")
    }

    # Deploys the bundled WizTree, runs a fast MFT folder scan as SYSTEM, copies the CSV
    # back. The only place DONUT pushes a file TO the target; the exe stays for reuse.
    [hashtable] RunDiskScanPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting disk-usage scan.")

        $ip = $this.ResolvedIpFor($device.HostName)
        # Gate SMB (445) first: DeployWizTree copies over the admin share, and a
        # blocked 445 (not ruled out by RPC/135) makes the UNC copy hang forever.
        if (-not $this.Probe.IsSmbAvailable($ip)) {
            $this.Logger.LogWarning("[$ip] Admin share (SMB/445) not reachable - cannot deploy WizTree for the disk scan.")
            throw [RpcUnavailableException]::new($ip)
        }
        # Diagnostic: the first disk scan of a session cold-loads the SMB-write + PsExec
        # paths, which can stall the STA thread on the process-wide loader lock (the
        # freeze reproduced by starting a storage scan mid dcu-scan). These logs run on
        # the pool thread, so they survive a UI freeze: a "start" with no matching "done"
        # means that step hung; an anomalously long "done" names the slow cold-load.
        # Remove once the freeze is pinned.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $this.Logger.LogInfo("[$ip] DiskScan: DeployWizTree start.")
        $this.DeployWizTree($ip)
        $this.Logger.LogInfo("[$ip] DiskScan: DeployWizTree done in $($sw.ElapsedMilliseconds) ms.")

        $sw.Restart()
        $this.Logger.LogInfo("[$ip] DiskScan: WizTree run (PsExec) start.")
        $this.InvokeRemotePwsh($ip, [ExecutionService]::BuildScanCommand(), 'DonutDisk', 20)
        $this.Logger.LogInfo("[$ip] DiskScan: WizTree run (PsExec) done in $($sw.ElapsedMilliseconds) ms.")

        $csvPath = $this.CopyDiskUsageArtifact($device.HostName)
        $jsonPath = $this.ParseAndCacheFolders($device.HostName, $csvPath, $options)
        return @{ FoldersPath = $csvPath; FoldersJson = $jsonPath }
    }

    # Parses the (large) WizTree CSV on the pool thread and writes a compact top-N
    # JSON, so the UI thread only reads a tiny file (a raw parse there froze the UI).
    [string] ParseAndCacheFolders([string]$hostName, [string]$csvPath, [hashtable]$options) {
        $topN = 12
        if ($null -ne $options -and $options.TopN) { $topN = [int]$options.TopN }

        $jsonPath = Join-Path $this.LocalReportsDir "$hostName-folders.json"
        if (-not (Test-Path $csvPath)) { return $jsonPath }

        try {
            $raw = Get-Content -Path $csvPath -Raw
            $report = [WizTreeCsv]::ParseTopFolders($raw, $topN)
            $report.ToHashtable() | ConvertTo-Json -Depth 5 |
                Set-Content -Path $jsonPath -Encoding UTF8
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
            throw [System.IO.FileNotFoundException]::new(
                'Bundled wiztree64.exe not found. Drop the binary into src\Tools\.', $localExe)
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

    # The headless WizTree command: fast MFT scan of C:, folders only, size-sorted CSV.
    # Isolated here so a pure-PowerShell fallback would be a single-method swap.
    static [string] BuildScanCommand() {
        return @'
& 'C:\temp\DONUT\wiztree64.exe' "C:" /export="C:\temp\DONUT\folders.csv" /admin=1 /exportfolders=1 /exportfiles=0 /sortby=1 /exportmaxdepth=4 | Out-Null
'@
    }

    # WizTree always exports the fixed name folders.csv; only the local copy is
    # host-qualified.
    [string] CopyDiskUsageArtifact([string] $hostName) {
        return $this.CopyBackArtifact($hostName, 'folders.csv', "$hostName-folders.csv")
    }

    [hashtable] CopyRemoteArtifacts([string] $hostName, [string] $outputLog) {
        $ip = $this.ResolvedIpFor($hostName)
        $remoteDir = "\\$ip\C$\temp\DONUT"
        # Copy the command's own outputLog so the local <host>.log holds the last run.
        $logLeaf = if ([string]::IsNullOrWhiteSpace($outputLog)) { 'scan.log' }
        else { Split-Path $outputLog -Leaf }
        $remoteLog = Join-Path $remoteDir $logLeaf

        $localLog = Join-Path $this.LocalLogsDir "$hostName.log"
        # Must match RemoteUpdateService.ParseUpdateReport's "<host>-Updates.xml", or
        # the report is never read and the pending-updates count stays 0.
        $localReport = Join-Path $this.LocalReportsDir "$hostName-Updates.xml"

        # An applied NIC driver may have just reset the adapter: wait briefly for the
        # share. Non-fatal - a completed apply must not fail over a lost log copy.
        $smbUp = $false
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            if ($this.Probe.IsSmbAvailable($ip)) { $smbUp = $true; break }
            if ($attempt -lt 4) { Start-Sleep -Seconds 3 }
        }
        if (-not $smbUp) {
            $this.Logger.LogWarning("[$hostName] Admin share (SMB/445) not reachable after the run - log/report not copied; the pending-update count may be stale until the next scan.")
            return @{ Log = $localLog; Report = $localReport }
        }

        if (Test-Path $remoteLog) {
            Copy-Item -Path $remoteLog -Destination $localLog -Force
        }

        # DCU names its report inconsistently across versions: copy the newest
        # top-level *.xml instead of guessing (recursive UNC enumeration can stall).
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
            # Log what DCU left behind so a missing/renamed report can be diagnosed.
            $contents = try {
                (Get-ChildItem -Path $remoteDir -File -ErrorAction Stop |
                    ForEach-Object { $_.Name }) -join ', '
            }
            catch { '<unreadable>' }
            $this.Logger.LogWarning("[$hostName] No scan report (*.xml) found in $remoteDir - the apply/count will see no updates. Folder contains: $contents")
        }

        return @{ Log = $localLog; Report = $localReport }
    }

    # Tails the run's outputLog into the Information stream, whole lines only.
    # Best-effort: read errors return the old offset.
    hidden [int] EmitNewDcuLogLines([string]$remoteLog, [int]$seenChars) {
        if ([string]::IsNullOrWhiteSpace($remoteLog)) { return $seenChars }
        try {
            if (-not (Test-Path -LiteralPath $remoteLog)) { return $seenChars }
            $text = Get-Content -LiteralPath $remoteLog -Raw -ErrorAction Stop
            if ([string]::IsNullOrEmpty($text)) { return $seenChars }
            if ($text.Length -lt $seenChars) { $seenChars = 0 }   # file was rewritten, restart
            # Consume only up to the last newline: the final line may still be mid-write.
            $upto = $text.LastIndexOf("`n")
            if ($upto -lt $seenChars) { return $seenChars }
            $chunk = $text.Substring($seenChars, $upto - $seenChars + 1)
            foreach ($line in ($chunk -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Information $line }
            }
            return $upto + 1
        }
        catch {
            return $seenChars
        }
    }

    # Maps a target-local drive path (C:\temp\DONUT\apply.log) to its admin-share UNC
    # (\\ip\C$\temp\DONUT\apply.log). Returns '' when the path isn't drive-rooted.
    hidden static [string] ToAdminShare([string]$ip, [string]$localPath) {
        if ([string]::IsNullOrWhiteSpace($localPath)) { return '' }
        if ($localPath -notmatch '^[A-Za-z]:\\') { return '' }
        $drive = $localPath.Substring(0, 1)          # 'C'
        $rest  = $localPath.Substring(3)             # 'temp\DONUT\apply.log'
        return "\\$ip\$drive`$\$rest"                # \\ip\C$\temp\DONUT\apply.log
    }

    # Clears the run's outputLog before psexec starts, so a previous run's log can
    # never "confirm" a run that never happened. Returns the freshness baseline (.NOTES).
    hidden [object] ClearRemoteOutputLog([string]$ip, [string]$outputLog) {
        $remote = [ExecutionService]::ToAdminShare($ip, $outputLog)
        if (-not $remote) { return $null }
        try {
            if (-not (Test-Path -LiteralPath $remote)) { return $null }
            Remove-Item -LiteralPath $remote -Force -ErrorAction Stop
            return $null
        }
        catch {
            try {
                $stamp = (Get-Item -LiteralPath $remote -ErrorAction Stop).LastWriteTimeUtc
                $this.Logger.LogWarning("[$ip] Could not clear $outputLog before the run (locked?) - only output newer than $($stamp.ToString('o')) will be trusted.")
                return $stamp
            }
            catch {
                $this.Logger.LogWarning("[$ip] Could not clear or stat $outputLog before the run - its content will not be trusted for confirmation.")
                return [datetime]::MaxValue
            }
        }
    }

    # Recovers dcu-cli's authoritative return code from its outputLog after psexec
    # drops mid-command; returns { Found; Code }, trusting only logs newer than $baseline.
    [hashtable] ReadDcuReturnCode([string]$ip, [string]$outputLog, [object]$baseline) {
        if ([string]::IsNullOrWhiteSpace($outputLog)) { return @{ Found = $false; Code = 0 } }

        $remote = [ExecutionService]::ToAdminShare($ip, $outputLog)
        if (-not $remote) { return @{ Found = $false; Code = 0 } }
        $localCopy = Join-Path $this.LocalLogsDir ("{0}-{1}" -f $ip, (Split-Path $outputLog -Leaf))

        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                # Gate SMB first: touching a UNC path while the share is still down
                # (NIC re-initialising) blocks with no timeout.
                if (($this.Probe.IsSmbAvailable($ip)) -and (Test-Path -LiteralPath $remote)) {
                    # Trust only a log written after the pre-run clear's baseline; an
                    # older file is the previous run's leftover.
                    $stale = $false
                    if ($null -ne $baseline) {
                        $item = Get-Item -LiteralPath $remote -ErrorAction Stop
                        $stale = ($item.LastWriteTimeUtc -le [datetime]$baseline)
                    }
                    if (-not $stale) {
                        $text = Get-Content -LiteralPath $remote -Raw -ErrorAction Stop
                        try { Set-Content -LiteralPath $localCopy -Value $text -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
                        $parsed = [DcuLog]::ParseReturnCode($text)
                        if ($parsed.Found) {
                            $this.Logger.LogInfo("[$ip] Recovered dcu-cli return code $($parsed.Code) from $outputLog after a dropped connection.")
                            return $parsed
                        }
                        # No return-code line yet: dcu-cli may still be writing - retry.
                    }
                }
            }
            catch {
                $this.Logger.LogDebug("[$ip] Reading $remote (attempt $attempt) failed: $($_.Exception.Message)")
            }
            if ($attempt -lt 5) { Start-Sleep -Seconds 3 }
        }

        $this.Logger.LogWarning("[$ip] Could not read a dcu-cli return code from $outputLog after the connection dropped.")
        return @{ Found = $false; Code = 0 }
    }

    # Runs dcu-cli via psexec and returns the effective dcu-cli return code (0 = done,
    # 1/5 = done + reboot needed, used by RunApplyPhase). Throws on any real failure.
    [int] InvokePsExec([hashtable] $parameters) {
        $computer = $parameters.ComputerName
        $command = $parameters.Command
        $argsString = $parameters.Arguments

        # Reuse the job's resolved/prefetched IP (resolves at most once).
        $ip = $this.ResolvedIpFor($computer)

        $dcuPath = $this.FindDcuCli($ip)
        $this.Logger.LogInfo("Found dcu-cli at $dcuPath on $computer")

        $outputLog = [string]$parameters.OutputLog

        # Clear from the controller side too (the remote-side clear only runs if the
        # remote command does) and capture the freshness baseline (see .NOTES).
        $logBaseline = $this.ClearRemoteOutputLog($ip, $outputLog)

        $stopCmd = "Stop-Process -Name 'DellCommandUpdate' -Force -ErrorAction SilentlyContinue"
        $mkdirCmd = "New-Item -Path 'C:\temp\DONUT' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null"
        # Remote-side clear too, so whatever the outputLog holds afterward is this
        # run's output (Dell doesn't document whether dcu-cli appends or overwrites).
        $clearCmd = if (-not [string]::IsNullOrWhiteSpace($outputLog)) {
            "Remove-Item -LiteralPath '$outputLog' -Force -ErrorAction SilentlyContinue"
        }
        else { '' }
        $dcuCmd = "& '$dcuPath' /$command $argsString"
        $remoteCmd = if ($clearCmd) { "$stopCmd; $mkdirCmd; $clearCmd; $dcuCmd" }
        else { "$stopCmd; $mkdirCmd; $dcuCmd" }

        # -r gives each job family its own PSEXESVC (see .NOTES).
        $psexecArgs = @(
            '-accepteula',
            '-nobanner',
            '-r', 'DonutDcu',
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

        # Log the exact argument list so a CLI failure (e.g. DCU 105) can be read -
        # and the command re-run by hand - straight from the log.
        $cmdLine = "psexec.exe $($psexecArgs -join ' ')"
        $this.Logger.LogInfo("Executing: $cmdLine")
        Write-Information "Executing: $cmdLine"

        # Headless launch; progress is tailed from the outputLog (see StartPsExecHidden).
        $remoteLogUnc = [ExecutionService]::ToAdminShare($ip, $outputLog)
        $p = [ExecutionService]::StartPsExecHidden($psexecArgs)
        # $tickState is a hashtable holder: GetNewClosure copies locals by value, so
        # only a reference type lets the consumed-chars offset survive across ticks.
        $maxMinutes = if ($command -eq 'applyUpdates') { 120 } else { 30 }
        $svc = $this
        $tickState = @{ Seen = 0 }
        $onTick = {
            $tickState.Seen = $svc.EmitNewDcuLogLines($remoteLogUnc, [int]$tickState.Seen)
        }.GetNewClosure()
        $exitCode = $this.WaitForRemoteProcess($p, $computer, "DCU /$command", $maxMinutes, $onTick)
        # Final flush for output that landed between the last poll and exit.
        $tickState.Seen = $this.EmitNewDcuLogLines($remoteLogUnc, [int]$tickState.Seen)

        # Win32 transport codes mean the connection dropped mid-command while dcu-cli
        # finishes on the host - recover its authoritative code instead (see .NOTES).
        if ([RemoteConnectionLostException]::IsConnectionLost($exitCode)) {
            $dcu = $this.ReadDcuReturnCode($ip, $outputLog, $logBaseline)
            if ($dcu.Found) {
                # dcu-cli recorded its verdict: trust that, not the dropped pipe.
                if ([DcuLog]::IsSuccess($dcu.Code)) {
                    $this.Logger.LogWarning("[$computer] psexec lost its connection ($([RemoteConnectionLostException]::Describe($exitCode))), but dcu-cli's log confirms return code $($dcu.Code) - treating DCU /$command as completed.")
                    if ([DcuLog]::NeedsReboot($dcu.Code)) { $this.Logger.LogInfo("[$computer] Reboot required to complete updates (dcu-cli code $($dcu.Code)).") }
                    return $dcu.Code
                }
                # dcu-cli reported a real error: surface that, not the transport code.
                throw [RemoteExecutionException]::new($computer, "DCU /$command $argsString", $dcu.Code, [DcuLog]::DescribeReturnCode($dcu.Code))
            }
            # No verdict readable - can't confirm, so report the connection loss.
            throw [RemoteConnectionLostException]::new($computer, "DCU /$command", $exitCode)
        }

        # Only 0 is success; 1/5 mean done-but-reboot. The other small codes are real
        # failures (see the reference in .NOTES).
        if (-not [DcuLog]::IsSuccess($exitCode)) {
            # Carry the full argument string + decoded meaning so the error reads as
            # its actual cause (a syntax error like DCU 105 needs the exact command).
            throw [RemoteExecutionException]::new($computer, "DCU /$command $argsString", $exitCode, [DcuLog]::DescribeReturnCode($exitCode))
        }

        if ([DcuLog]::NeedsReboot($exitCode)) {
            $this.Logger.LogInfo("[$computer] Reboot required to complete updates (dcu-cli code $exitCode).")
        }
        return $exitCode
    }

    [string] FindDcuCli([string]$ip) {
        # Gate SMB (445) first: Test-Path against the admin share blocks with no
        # timeout when 445 is filtered - which RPC/135 reachability does not rule out.
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

}
