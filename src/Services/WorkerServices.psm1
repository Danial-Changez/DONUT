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
    # Per-job resolved IP: seeded from HostResolver's prefetch when supplied, else
    # filled by the first ResolvedIpFor() call - a job resolves the host at most once.
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
        # Init Services (share one logger across the worker's collaborators)
        $localLogger = [LogService]::new($LogsDir)
        $localProbe = [NetworkProbe]::new($localLogger)
        $localMatcher = [DriverMatchingService]::new($localLogger)
        $service = [ExecutionService]::new($localLogger, $localProbe, $localMatcher, $Config, $SourceRoot, $LogsDir, $ReportsDir)

        # The pre-resolved IP (warmed on selection) rides a dedicated argument - never an
        # Options key - so the worker skips DNS yet it can't leak into a dcu-cli line.
        if (-not [string]::IsNullOrWhiteSpace($ResolvedIp)) {
            $service.JobIp = $ResolvedIp
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

    # Pool-side resolution. 'Warm' discovers the live DC list once at startup; 'Host' fresh-
    # resolves one host (changed IPs self-heal) + probes RPC 135 -> { Ip; Online } for HostResolver.
    [hashtable] RunResolvePhase([DeviceContext] $device, [hashtable] $options) {
        $mode = if ($null -ne $options) { [string]$options.Mode } else { 'Host' }

        if ($mode -eq 'Warm') {
            $dc = $this.Probe.GetActiveDomainController()
            $this.Logger.LogInfo("Resolver warm-up: active domain controller = $dc")
            return @{ Mode = 'Warm'; ActiveDc = [string]$dc; DomainControllers = @($this.Probe.GetDomainControllers()) }
        }

        # This job already forced RemoteWorker.ps1's module graph into the runspace; warming
        # the runtime assemblies too means later jobs never cold-load under the loader lock.
        if ($mode -eq 'WarmRunspace') {
            $this.WarmRuntimeAssemblies()
            return @{ Mode = 'WarmRunspace' }
        }

        # Identity check: ask the box at $ip for its own name. Its own pool job, parallel
        # to - and never touching - the dcu-cli scan, so it adds no latency there.
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

    # Cold-loads the heavy runtime assemblies (DNS, TCP, CIM/DCOM, LDAP) against localhost so
    # the FIRST real probe never loads them under the CLR loader lock (a UI freeze). Best-effort.
    [void] WarmRuntimeAssemblies() {
        try { Resolve-DnsName -Name 'localhost' -QuickTimeout -ErrorAction SilentlyContinue | Out-Null } catch { }
        try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Close() } catch { }
        try { Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue } catch { }
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
            # Job starts are supposed to thread the prefetched IP through (AttachResolvedIp):
            # landing here means the SLOW full AD resolve - allowed, but a routing bug upstream.
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

        # Build scan arguments from config with remote path overrides
        $remoteOverrides = @{
            report    = 'C:\temp\DONUT'
            outputLog = 'C:\temp\DONUT\scan.log'
        }
        $scanArgs = $this.Config.BuildDcuArgs('scan', $remoteOverrides)
        
        # Default to all categories. Single-quote the comma list so it survives the remote
        # `pwsh -c` wrapper (a bare comma is PowerShell's array operator); pwsh strips the quotes.
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

        # Merge ONLY keys that are real dcu-cli options for this command: the Options bag
        # also carries control data (e.g. ResolvedIp) that dcu-cli rejects with 105.
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
        # dcu-cli 1/5 => the apply landed but the box needs a reboot to finish. Surface it
        # so the presenter flags a manual reboot (the card + the reboot toast).
        $artifact['RebootRequired'] = [DcuLog]::NeedsReboot($applyCode)
        return $artifact
    }

    # Inventory. Fast path: query WMI over a remote DCOM CIM session (no psexec deploy,
    # no SMB copy); if that can't connect, fall back to the proven psexec+pwsh probe.
    [hashtable] RunInventoryPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting inventory probe.")
        $ip = $this.ResolvedIpFor($device.HostName)

        # Bounded RPC gate (TCP 135, ~2s) so an offline host fails in seconds instead of
        # hanging minutes on the unbounded CIM/psexec connect.
        if (-not $this.Probe.IsRpcAvailable($ip)) {
            throw [RemoteJobService]::Fail($this.Logger, [HostOfflineException]::new($device.HostName))
        }

        # Fast path: a null result (no session), an all-null result (WMI gave nothing),
        # or a throw all count as failure and fall through to the psexec probe.
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

    # A CIM gather "succeeded" only if it produced at least one identifying fact; all-null
    # means WMI handed back nothing useful. Pure + static, so unit-tested without a host.
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

    # Queries the host's WMI over a DCOM CIM session, mirroring the probe script's
    # projected queries. Each query is guarded; returns $null only when the session won't open.
    [hashtable] GatherRemoteInventory([string]$ip) {
        if ([string]::IsNullOrWhiteSpace($ip)) { return $null }
        $session = $null
        try {
            # -OperationTimeoutSec bounds the session ops so a box that died mid-open
            # (e.g. rebooting) can't hang the worker on DCOM's multi-minute defaults.
            $session = New-CimSession -ComputerName $ip -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 15 -ErrorAction Stop
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

    # Launches psexec.exe headless and returns the Process for the caller's watchdog loop.
    # CreateNoWindow gives psexec a HIDDEN console: no window ever appears, so concurrent
    # runs never allocate the visible consoles that (from this window-subsystem GUI) would
    # sit in front of the WPF UI for the whole run and read as a frozen app. UseShellExecute
    # off with NO stdout redirect keeps psexec a real console - a file-redirect removed it
    # and is the suspected cause of remote 0xC0000142 init failures. The args are space-
    # joined exactly as the logged command line, so the delicate psexec/DCU quoting is
    # unchanged (this mirrors the old branch's known-good CreateNoWindow launch).
    hidden static [System.Diagnostics.Process] StartPsExecHidden([string[]]$psexecArgs) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'psexec.exe'
        $psi.Arguments = ($psexecArgs -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        return [System.Diagnostics.Process]::Start($psi)
    }

    # Runs a pwsh script on the remote as SYSTEM, passed base64 via -EncodedCommand (no
    # psexec quoting hazards). $serviceName isolates its PSEXESVC; $maxMinutes = watchdog.
    [void] InvokeRemotePwsh([string]$target, [string]$scriptText, [string]$serviceName, [int]$maxMinutes) {
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
        $deadline = [datetime]::UtcNow.AddMinutes($maxMinutes)
        while (-not $p.HasExited) {
            if ([datetime]::UtcNow -gt $deadline) {
                try { $p.Kill($true) } catch { }
                throw [RemoteTimeoutException]::new($target, 'Remote probe', $maxMinutes)
            }
            Start-Sleep -Milliseconds 1500
        }
        $p.WaitForExit()
        $exitCode = [int]$p.ExitCode

        # Classify like InvokePsExec: negative = process-launch fault, Win32 transport code
        # = psexec's pipe dropped mid-probe - neither means "the probe script failed".
        if ($exitCode -lt 0) {
            throw [RemoteProcessStartException]::new($target, 'Remote probe', $exitCode)
        }
        if ([RemoteConnectionLostException]::IsConnectionLost($exitCode)) {
            throw [RemoteConnectionLostException]::new($target, 'Remote probe', $exitCode)
        }
        if ($exitCode -ne 0) {
            throw [RemoteExecutionException]::new($target, 'Remote probe', $exitCode)
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

    # Deploys the bundled WizTree, runs a fast MFT folder scan as SYSTEM, copies the CSV
    # back. The only place DONUT pushes a file TO the target; the exe stays for reuse.
    [hashtable] RunDiskScanPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting disk-usage scan.")

        $ip = $this.ResolvedIpFor($device.HostName)
        # Gate SMB (445) first: DeployWizTree copies over the admin share, and a blocked 445
        # (which RPC/135 reachability does NOT rule out) makes that UNC copy hang forever.
        if (-not $this.Probe.IsSmbAvailable($ip)) {
            $this.Logger.LogWarning("[$ip] Admin share (SMB/445) not reachable - cannot deploy WizTree for the disk scan.")
            throw [RpcUnavailableException]::new($ip)
        }
        $this.DeployWizTree($ip)
        $this.InvokeRemotePwsh($ip, [ExecutionService]::BuildScanCommand(), 'DonutDisk', 20)
        $csvPath = $this.CopyDiskUsageArtifact($device.HostName)
        $jsonPath = $this.ParseAndCacheFolders($device.HostName, $csvPath, $options)
        return @{ FoldersPath = $csvPath; FoldersJson = $jsonPath }
    }

    # Parses the (potentially large) WizTree CSV on the pool thread and writes a compact
    # top-N JSON, so the UI thread only reads a tiny file (a raw parse there froze the UI ~1s).
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

    # The headless WizTree command: fast MFT scan of C:, folders only, size-sorted CSV.
    # Isolated here so a pure-PowerShell fallback would be a single-method swap.
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

    [hashtable] CopyRemoteArtifacts([string] $hostName, [string] $outputLog) {
        $ip = $this.ResolvedIpFor($hostName)
        $remoteDir = "\\$ip\C$\temp\DONUT"
        # Copy the command's OWN outputLog (scan.log for a scan, apply.log for an
        # apply), so the local <host>.log always holds the LAST run's log.
        $logLeaf = if ([string]::IsNullOrWhiteSpace($outputLog)) { 'scan.log' } else { Split-Path $outputLog -Leaf }
        $remoteLog = Join-Path $remoteDir $logLeaf

        $localLog = Join-Path $this.LocalLogsDir "$hostName.log"
        # Must match RemoteUpdateService.ParseUpdateReport's "<host>-Updates.xml", or the
        # scan's report is never read and the pending-updates count stays 0.
        $localReport = Join-Path $this.LocalReportsDir "$hostName-Updates.xml"

        # An applied NIC driver may have just reset the adapter: wait briefly (bounded probes)
        # for the share. Non-fatal - a completed apply must not fail over a lost log copy.
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

        # DCU names its report inconsistently across versions, so copy the NEWEST top-level
        # *.xml instead of guessing a name (recursive UNC enumeration can stall).
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

    # Tails the run's outputLog into the Information stream, whole lines only (a mid-write
    # tail line waits for the next poll). Best-effort: read errors return the old offset.
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

    # Clears the run's outputLog BEFORE psexec starts, so a previous run's log can never
    # "confirm" a run that never happened. Returns the freshness baseline (see .NOTES).
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

    # Recovers dcu-cli's authoritative return code from its outputLog after psexec drops
    # mid-command; retries briefly, returns { Found; Code }, trusts only logs newer than $baseline.
    [hashtable] ReadDcuReturnCode([string]$ip, [string]$outputLog, [object]$baseline) {
        if ([string]::IsNullOrWhiteSpace($outputLog)) { return @{ Found = $false; Code = 0 } }

        $remote = [ExecutionService]::ToAdminShare($ip, $outputLog)
        if (-not $remote) { return @{ Found = $false; Code = 0 } }
        $localCopy = Join-Path $this.LocalLogsDir ("{0}-{1}" -f $ip, (Split-Path $outputLog -Leaf))

        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                # Gate SMB (445, ~2s) first: touching a UNC path while the share is still
                # down (NIC re-initialising) blocks with no timeout.
                if (($this.Probe.IsSmbAvailable($ip)) -and (Test-Path -LiteralPath $remote)) {
                    # Trust only a log written AFTER the pre-run clear's baseline: an older
                    # file is the previous run's leftover - keep waiting, never confirm from it.
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
                        # Present but no return-code line yet: dcu-cli may still be
                        # writing - wait and retry.
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

        # DCU CLI syntax: dcu-cli.exe /<command> -option1=value1 -option2=value2
        # Stop any existing DCU process first to avoid conflicts.
        $outputLog = [string]$parameters.OutputLog

        # Clear the outputLog from the CONTROLLER side too (the remote-side clear only runs
        # if the remote command does) and capture the freshness baseline (see .NOTES).
        $logBaseline = $this.ClearRemoteOutputLog($ip, $outputLog)

        $stopCmd = "Stop-Process -Name 'DellCommandUpdate' -Force -ErrorAction SilentlyContinue"
        $mkdirCmd = "New-Item -Path 'C:\temp\DONUT' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null"
        # Remote-side clear too, so whatever the outputLog holds afterward is THIS run's
        # output (Dell doesn't document whether dcu-cli appends or overwrites).
        $clearCmd = if (-not [string]::IsNullOrWhiteSpace($outputLog)) {
            "Remove-Item -LiteralPath '$outputLog' -Force -ErrorAction SilentlyContinue"
        } else { '' }
        $dcuCmd = "& '$dcuPath' /$command $argsString"
        $remoteCmd = if ($clearCmd) { "$stopCmd; $mkdirCmd; $clearCmd; $dcuCmd" } else { "$stopCmd; $mkdirCmd; $dcuCmd" }

        # -r gives this job family its own remote service name, so concurrent job kinds
        # never share (and tear down) each other's PSEXESVC (see .NOTES).
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

        # Log the EXACT argument list to both the app log and the detail panel, so a CLI
        # failure (e.g. DCU 105) can be read - and the command re-run by hand - straight from it.
        $cmdLine = "psexec.exe $($psexecArgs -join ' ')"
        $this.Logger.LogInfo("Executing: $cmdLine")
        Write-Information "Executing: $cmdLine"

        # Headless launch (hidden console, no stdout redirect): no window means concurrent
        # runs never steal foreground from the WPF UI, while psexec keeps a real console
        # (a file-redirect removed it and is a suspected cause of remote 0xC0000142).
        # Progress is tailed from the outputLog instead. See StartPsExecHidden.
        $remoteLogUnc = [ExecutionService]::ToAdminShare($ip, $outputLog)
        $p = [ExecutionService]::StartPsExecHidden($psexecArgs)
        # Watchdog: a psexec session can hang forever (dead pipes, wedged remote process);
        # past the deadline, kill the client so the job fails with a typed cause.
        $maxMinutes = if ($command -eq 'applyUpdates') { 120 } else { 30 }
        $deadline = [datetime]::UtcNow.AddMinutes($maxMinutes)
        $seenChars = 0
        while (-not $p.HasExited) {
            if ([datetime]::UtcNow -gt $deadline) {
                try { $p.Kill($true) } catch { }
                throw [RemoteTimeoutException]::new($computer, "DCU /$command", $maxMinutes)
            }
            Start-Sleep -Milliseconds 1500
            $seenChars = $this.EmitNewDcuLogLines($remoteLogUnc, $seenChars)
        }
        $p.WaitForExit()   # flush the exit code after HasExited flips
        $exitCode = [int]$p.ExitCode
        # Final flush so the tail (e.g. "The program exited with return code: N") reaches
        # the detail terminal even when it landed between the last poll and exit.
        $seenChars = $this.EmitNewDcuLogLines($remoteLogUnc, $seenChars)

        # Negative = Windows process-launch fault (NTSTATUS, e.g. 0xC0000142): the remote
        # pwsh never ran dcu-cli, so it is NOT a DCU exit code.
        if ($exitCode -lt 0) {
            throw [RemoteProcessStartException]::new($computer, "DCU /$command", $exitCode)
        }

        # Win32 transport codes (233, 64, ...) mean the connection dropped mid-command while
        # dcu-cli finishes on the host - recover its authoritative code instead (see .NOTES).
        if ([RemoteConnectionLostException]::IsConnectionLost($exitCode)) {
            $dcu = $this.ReadDcuReturnCode($ip, $outputLog, $logBaseline)
            if ($dcu.Found) {
                # dcu-cli finished and recorded its verdict: trust that, not the dropped pipe.
                if ([DcuLog]::IsSuccess($dcu.Code)) {
                    $this.Logger.LogWarning("[$computer] psexec lost its connection ($([RemoteConnectionLostException]::Describe($exitCode))), but dcu-cli's log confirms return code $($dcu.Code) - treating DCU /$command as completed.")
                    if ([DcuLog]::NeedsReboot($dcu.Code)) { $this.Logger.LogInfo("[$computer] Reboot required to complete updates (dcu-cli code $($dcu.Code)).") }
                    return $dcu.Code
                }
                # dcu-cli itself reported a real error code: surface THAT, not the transport code.
                throw [RemoteExecutionException]::new($computer, "DCU /$command $argsString", $dcu.Code, [DcuLog]::DescribeReturnCode($dcu.Code))
            }
            # Couldn't read a verdict (log absent/unreadable, or dcu-cli never finished) - can't
            # confirm, so report the connection loss (the operator can re-scan to check).
            throw [RemoteConnectionLostException]::new($computer, "DCU /$command", $exitCode)
        }

        # ONLY 0 is success; 1/5 mean done-but-reboot. The other small codes (2/3/4/6/7/8)
        # are REAL failures, not benign (see the reference in .NOTES).
        if (-not [DcuLog]::IsSuccess($exitCode)) {
            # Carry the full argument string (a syntax error, DCU 105, needs the exact
            # command) plus the decoded meaning so the error reads as its actual cause.
            throw [RemoteExecutionException]::new($computer, "DCU /$command $argsString", $exitCode, [DcuLog]::DescribeReturnCode($exitCode))
        }

        if ([DcuLog]::NeedsReboot($exitCode)) {
            $this.Logger.LogInfo("[$computer] Reboot required to complete updates (dcu-cli code $exitCode).")
        }
        return $exitCode
    }

    [string] FindDcuCli([string]$ip) {
        # Gate SMB (445) first: Test-Path against the admin share blocks with no timeout
        # when 445 is filtered - which RPC/135 reachability does NOT rule out.
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
