using module "..\Core\LogService.psm1"
using module "..\Core\NetworkProbe.psm1"
using module ".\DriverMatchingService.psm1"
using module ".\RemoteServices.psm1"
using module "..\Models\DeviceContext.psm1"
using module "..\Models\AppConfig.psm1"
using module "..\Models\DiskUsage.psm1"
using module "..\Models\FolderDeletionPolicy.psm1"
using module "..\Models\RemoteError.psm1"
using module "..\Models\DcuLog.psm1"
using module "..\Models\DcuProgress.psm1"

<#
.SYNOPSIS
    The runspace-pool worker engine: runs one remote phase end-to-end.

.DESCRIPTION
    Entry point (StartWorker) for the RemoteWorker.ps1 script. Dispatches by job
    kind to a phase (resolve, scan, apply, inventory, or disk), invoking dcu-cli /
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
      thread forever. An open 445 still doesn't guarantee the C$ share responds, so
      the psexec path does NO controller-side UNC before launch: dcu-cli discovery
      and the pre-run log clear both run ON the target (BuildRemoteDcuScript), and a
      missing dcu-cli comes back as the $DcuNotFoundExit sentinel, not a hung path.
    - Concurrent psexec sessions sharing one PSEXESVC hang when the first ends and
      deletes the service, so each job family runs under its own -r service name
      (DonutDcu / DonutDisk / DonutProbe).
    - psexec exit codes are classified: negative = Windows process-launch fault
      (NTSTATUS); Win32 transport codes = the connection dropped mid-command, at
      either end - the target's NIC reset (a network driver install), or the operator's
      own laptop lost Wi-Fi (59/1232/...). On a drop the run does not fail: dcu-cli keeps
      going on the target, so RecoverByResumeTail reconnects (waiting out a local outage
      too), resumes the outputLog tail from the last-seen offset, and recovers dcu-cli's
      authoritative code - bounded by AppConfig.GetRecoveryWindowMinutes, after which the
      run settles Unconfirmed. The target-side clear runs before dcu-cli, so a recovered
      code is always this run's.
    - dcu-cli return codes are classified per command (DcuLog.Classify): 0/1/5 pass
      for any command, a scan's 500 is a clean no-updates result (carried on the
      artifact as NoUpdatesFound), and everything else is a real failure. Reference:
      https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes
    - Live progress rides dcu-cli's -outputLog, tailed over the admin share into
      the Information stream while psexec runs.
    - GatherRemoteInventory, TailAndScanLog, RecoverByResumeTail and
      WarmRuntimeAssemblies are overridable seams so unit tests run without a network.
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
    # Warm-shell tag ("warm-3", rides in HostName) prefixing the warm breadcrumbs so
    # 8 concurrent warm passes stay distinguishable in Donut.log.
    hidden [string] $WarmTag = ''

    # dcu-cli-missing exit code, outside all dcu-cli and psexec code ranges so
    # InvokePsExec maps it without a UNC path check (see BuildRemoteDcuScript).
    static [int] $DcuNotFoundExit = 2600

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
        # Shared logger; the two breadcrumbs bracket the constructor chain so a
        # wedged bring-up names its segment (ctors vs dispatch vs phase entry).
        $localLogger = [LogService]::new($LogsDir)
        $localLogger.DebugEnabled = $Config.GetDebugLogging()
        $localLogger.LogDebug("[$HostName] Worker service: constructing collaborators...")
        $localProbe = [NetworkProbe]::new($localLogger)
        $localMatcher = [DriverMatchingService]::new($localLogger)
        $service = [ExecutionService]::new($localLogger, $localProbe, $localMatcher,
            $Config, $SourceRoot, $LogsDir, $ReportsDir)
        $localLogger.LogDebug("[$HostName] Worker service: dispatching JobType=$JobType...")

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
        elseif ($JobType -eq 'DeleteFolders') {
            return $service.RunDeleteFoldersPhase($device, $Options)
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
            # Entry marker: absent = bring-up wedged; present with no "Cached N
            # domain controller(s)" after it = the AD discovery itself hung.
            $this.Logger.LogInfo("DC discovery running on the pool (worker pipeline is up).")
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
            $this.WarmTag = [string]$device.HostName
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $this.WarmRuntimeAssemblies()
            $runtimeMs = $sw.ElapsedMilliseconds
            $sw.Restart()
            $this.WarmScanLaunchPath()
            # One line per warmed runspace; the timings say where a slow warm spent
            # its barrier budget.
            $this.Logger.LogDebug(
                "[$($this.WarmTag)] Runspace warmed: worker pipeline up; runtime assemblies $runtimeMs ms; " +
                "scan path $($sw.ElapsedMilliseconds) ms.")
            return @{ Mode = 'WarmRunspace' }
        }

        # Identity check: ask the box at $ip for its own name (parallel to the scan).
        if ($mode -eq 'Name') {
            $ip = if ($null -ne $options) { [string]$options.Ip } else { '' }
            $actual = $this.Probe.ResolveComputerName($ip)
            return @{ Mode = 'Name'; HostName = $device.HostName; ActualName = [string]$actual }
        }

        # Step breadcrumbs (DEBUG): a stalled host resolve must name its last step;
        # TTL re-validations are minutes apart per host, so the volume stays low.
        $dc = if ($null -ne $options) { [string]$options.Dc } else { '' }
        $this.Logger.LogDebug("[$($device.HostName)] Host resolve: DC='$dc' - DNS lookup...")
        $ip = $this.Probe.ResolveWith($device.HostName, $dc)
        $ipStr = if ($null -ne $ip) { $ip.ToString() } else { '' }
        $online = $false
        if (-not [string]::IsNullOrWhiteSpace($ipStr)) {
            $this.Logger.LogDebug(
                "[$($device.HostName)] Host resolve: ip='$ipStr' - probing RPC 135...")
            $online = $this.Probe.IsRpcAvailable($ipStr)
        }
        $this.Logger.LogDebug(
            "[$($device.HostName)] Host resolve verdict: ip='$ipStr', online=$online.")
        return @{ Mode = 'Host'; HostName = $device.HostName; Ip = $ipStr; Online = $online }
    }

    # Exercises the heavy stacks (DNS/TCP/CIM/LDAP) against localhost so a live job's
    # first such call is never a runspace's first (architecture/runspaces-and-workers: pool warm).
    [void] WarmRuntimeAssemblies() {
        # Each exercise logs before it runs: a warm that wedges leaves the name of
        # the exact stack it wedged in as the runspace's last log line.
        $t = $this.WarmTag
        $this.Logger.LogDebug("[$t] Warm: exercising DNS (localhost lookup)...")
        try {
            Resolve-DnsName -Name 'localhost' -QuickTimeout -ErrorAction Stop | Out-Null
        }
        catch {
            $this.Logger.LogDebug("[$t] DNS warm-up skipped: $($_.Exception.Message)")
        }
        $this.Logger.LogDebug("[$t] Warm: exercising TCP (socket construct)...")
        try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Close() }
        catch {
            $this.Logger.LogDebug("[$t] TCP warm-up skipped: $($_.Exception.Message)")
        }
        $this.Logger.LogDebug("[$t] Warm: loading DirectoryServices (LDAP)...")
        try { Add-Type -AssemblyName System.DirectoryServices -ErrorAction Stop }
        catch {
            $this.Logger.LogDebug("[$t] DirectoryServices warm-up skipped: $($_.Exception.Message)")
        }
        $this.Logger.LogDebug("[$t] Warm: exercising CIM (loopback DCOM session)...")
        try {
            $opt = New-CimSessionOption -Protocol Dcom
            $s = New-CimSession -SessionOption $opt -ErrorAction Stop
            try {
                Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystem `
                    -Property Name -ErrorAction Stop | Out-Null
            }
            catch {
                $this.Logger.LogDebug("[$t] CIM query warm-up skipped: $($_.Exception.Message)")
            }
            Remove-CimSession -CimSession $s -ErrorAction SilentlyContinue
        }
        catch {
            $this.Logger.LogDebug("[$t] CIM session warm-up skipped: $($_.Exception.Message)")
        }
        $this.Logger.LogDebug("[$t] Warm: runtime stacks exercised.")
    }

    # Pre-executes the CPU-only half of the DCU launch path so a live scan's first
    # InvokePsExec is never a first compile. Pure CPU only (architecture/runspaces-and-workers).
    [void] WarmScanLaunchPath() {
        try {
            $overrides = @{
                report    = 'C:\temp\DONUT'
                outputLog = 'C:\temp\DONUT\scan.log'
            }
            $scanArgs = $this.Config.BuildDcuArgs('scan', $overrides)
            $remoteScript = [ExecutionService]::BuildRemoteDcuScript(
                'scan', $scanArgs, [string]$overrides.outputLog)
            [void][Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($remoteScript))
        }
        catch {
            $this.Logger.LogWarning(
                "Scan launch-path warm failed - the first live scan pays its first-use costs: " +
                $_.Exception.Message)
        }
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

        # Pairs with the gate + "Executing:" lines: a scan repro must pin which
        # segment between "Starting preliminary scan" and psexec stopped logging.
        $this.Logger.LogDebug(
            "[$($device.HostName)] Scan arguments built - invoking psexec launcher.")

        $params = @{
            ComputerName = $device.HostName
            Command      = 'scan'
            Arguments    = $scanArgs
            OutputLog    = 'C:\temp\DONUT\scan.log'
        }

        # Start/done pair around the launch (mirrors RunDiskScanPhase): a "start" with
        # no "done" pins the hang to the psexec/dcu wait, not to argument-building.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $this.Logger.LogInfo("[$($device.HostName)] Scan: psexec launch start.")
        $exit = $this.InvokePsExec($params)
        $this.Logger.LogInfo(
            "[$($device.HostName)] Scan: psexec launch done in $($sw.ElapsedMilliseconds) ms (exit $exit).")

        # DCU 500 = clean no-updates: skip the report copy so a stale previous-run
        # XML cannot masquerade as this scan's result (the local copy is dropped too).
        $noUpdates = ([DcuLog]::Classify('scan', $exit) -eq [DcuCommandOutcome]::NoUpdates)
        $artifact = $this.CopyRemoteArtifacts($device.HostName, [string]$params.OutputLog, (-not $noUpdates))
        if ($noUpdates) {
            $this.Logger.LogInfo("[$($device.HostName)] Scan clean (DCU $exit): no updates found.")
        }

        return @{
            ReportPath     = $artifact.Report
            LogPath        = $artifact.Log
            Updates        = @()
            DcuCode        = [int]$exit
            NoUpdatesFound = $noUpdates
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

    # CreateNoWindow keeps concurrent psexec consoles off the WPF UI; stdout stays
    # unredirected so psexec keeps a real console (redirecting it caused remote 0xC0000142).
    hidden static [System.Diagnostics.Process] StartPsExecHidden([string[]]$psexecArgs) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'psexec.exe'
        $psi.Arguments = ($psexecArgs -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        return [System.Diagnostics.Process]::Start($psi)
    }

    # Polls HasExited on a 1500ms tick running $onTick; kills + throws past the deadline,
    # and returns the raw code - classification stays with the caller.
    hidden [int] WaitForRemoteProcess(
        [System.Diagnostics.Process]$p,
        [string]$target,
        [string]$operation,
        [int]$maxMinutes,
        [scriptblock]$onTick
    ) {
        $deadline = [datetime]::UtcNow.AddMinutes($maxMinutes)
        $startedUtc = [datetime]::UtcNow
        $nextReportUtc = $startedUtc.AddSeconds(30)
        # WaitForExit(ms) sleeps AND returns the instant the process exits, so a job
        # never pays up to 1.5 s of dead latency the old sleep-then-recheck loop cost.
        while (-not $p.WaitForExit(1500)) {
            if ([datetime]::UtcNow -gt $deadline) {
                # Best-effort: it may already be exiting, or we may lack rights to kill it.
                try { $p.Kill($true) } catch { }
                throw [RemoteTimeoutException]::new($target, $operation, $maxMinutes)
            }
            if ($null -ne $onTick) { & $onTick }
            # Heartbeat: the remote process is still alive - the wait isn't the wedge.
            if ([datetime]::UtcNow -ge $nextReportUtc) {
                $waited = [long]([datetime]::UtcNow - $startedUtc).TotalSeconds
                $this.Logger.LogDebug("[$target] $operation still waiting after $waited s (remote process running).")
                $nextReportUtc = [datetime]::UtcNow.AddSeconds(30)
            }
        }
        $p.WaitForExit()   # flush async output/exit code after the timed wait returns true
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

    # Deploys the bundled WizTree, runs a fast MFT folder scan as SYSTEM, copies the
    # remotely-trimmed top-rows CSV back. The only place DONUT pushes a file TO the
    # target; the exe stays for reuse.
    [hashtable] RunDiskScanPhase([DeviceContext] $device, [hashtable] $options) {
        $this.Logger.LogInfo("[$($device.HostName)] Starting disk-usage scan.")

        $ip = $this.ResolvedIpFor($device.HostName)
        # Gate SMB (445) first: DeployWizTree copies over the admin share, and a
        # blocked 445 (not ruled out by RPC/135) makes the UNC copy hang forever.
        if (-not $this.Probe.IsSmbAvailable($ip)) {
            $this.Logger.LogWarning("[$ip] Admin share (SMB/445) not reachable - cannot deploy WizTree for the disk scan.")
            throw [RpcUnavailableException]::new($ip)
        }
        # Diagnostic (remove once pinned): a "start" with no matching "done" names the
        # step that hung on the loader lock; a long "done" names the slow cold-load.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $this.Logger.LogInfo("[$ip] DiskScan: DeployWizTree start.")
        $this.DeployWizTree($ip)
        $this.Logger.LogInfo("[$ip] DiskScan: DeployWizTree done in $($sw.ElapsedMilliseconds) ms.")

        $topN = 12
        if ($null -ne $options -and $options.TopN) { $topN = [int]$options.TopN }

        $sw.Restart()
        $this.Logger.LogInfo("[$ip] DiskScan: WizTree run (PsExec) start.")
        $this.InvokeRemotePwsh($ip, [ExecutionService]::BuildScanCommand($topN), 'DonutDisk', 20)
        $this.Logger.LogInfo("[$ip] DiskScan: WizTree run (PsExec) done in $($sw.ElapsedMilliseconds) ms.")

        $csvPath = $this.CopyDiskUsageArtifact($device.HostName)
        $jsonPath = $this.ParseAndCacheFolders($device.HostName, $csvPath, $topN)
        return @{ FoldersPath = $csvPath; FoldersJson = $jsonPath }
    }

    # Clears the contents of the operator-selected folders on the target as SYSTEM (psexec),
    # keeping the folders. Each path is re-validated here and again in the remote script.
    [hashtable] RunDeleteFoldersPhase([DeviceContext] $device, [hashtable] $options) {
        $paths = @()
        if ($null -ne $options -and $options.Paths) { $paths = @($options.Paths) }
        # Canonical form only past this point, so what the remote script re-checks is what it deletes.
        $paths = @($paths |
                Where-Object { [FolderDeletionPolicy]::IsDeletable($_) } |
                ForEach-Object { [FolderDeletionPolicy]::Canonicalize($_) })
        if ($paths.Count -eq 0) {
            $this.Logger.LogWarning("[$($device.HostName)] ClearFolders: no deletable paths after the safety filter.")
            return @{ Deleted = 0 }
        }
        $this.Logger.LogInfo("[$($device.HostName)] Clearing $($paths.Count) folder(s).")

        $ip = $this.ResolvedIpFor($device.HostName)
        if (-not $this.Probe.IsSmbAvailable($ip)) {
            $this.Logger.LogWarning("[$ip] Admin share (SMB/445) not reachable - cannot delete folders.")
            throw [RpcUnavailableException]::new($ip)
        }
        $this.InvokeRemotePwsh($ip, [ExecutionService]::BuildDeleteCommand($paths), 'DonutDelete', 15)
        return @{ Deleted = $paths.Count }
    }

    # The remote clear script: each path is a single-quoted literal (quotes doubled to block
    # injection), re-checked against the safety rules, then its contents removed (folder kept).
    static [string] BuildDeleteCommand([string[]]$paths) {
        $literals = @($paths | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" })
        $arr = $literals -join ', '
        return @"
`$ErrorActionPreference = 'Continue'
`$targets = @($arr)
`$allowed = @('windows\ccmcache','windows\temp','windows\softwaredistribution\download','windows\prefetch','windows\logs','windows\downloaded program files')
`$blocked = @('windows','program files','program files (x86)','programdata','system volume information','`$recycle.bin','recovery','perflogs','`$winreagent','boot','msocache','`$sysreset')
`$profiles = @()
try {
    `$profiles = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { `$_.Loaded -and -not `$_.Special -and `$_.LocalPath } |
        ForEach-Object { `$_.LocalPath.ToLowerInvariant().TrimEnd('\') })
} catch {
    Write-Output "profile enumeration failed, no logged-on profile is protected: `$(`$_.Exception.Message)"
    return
}
# Empties `$dir without ever descending through a junction: Remove-Item -Recurse follows directory
# reparse points on 5.1, so a link planted under an allowed root would clear the system dir it names.
function Clear-Tree([string]`$dir) {
    foreach (`$c in @(Get-ChildItem -LiteralPath `$dir -Force -ErrorAction SilentlyContinue)) {
        if (`$c.PSIsContainer -and (`$c.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            try { [IO.Directory]::Delete(`$c.FullName, `$false) }
            catch { Write-Output "left link `$(`$c.FullName): `$(`$_.Exception.Message)" }
            continue
        }
        if (`$c.PSIsContainer) { Clear-Tree `$c.FullName }
        Remove-Item -LiteralPath `$c.FullName -Force -ErrorAction SilentlyContinue
    }
}
foreach (`$t in `$targets) {
    `$p = "`$t".Trim().TrimEnd('\')
    if (`$p -notmatch '^[A-Za-z]:\\.+') { continue }
    # Mirrors FolderDeletionPolicy.Canonicalize: the checks below are string compares, so ".."
    # and 8.3 aliases have to be resolved out before they are applied.
    if (`$p -match '~\d') { continue }
    try { `$p = [IO.Path]::GetFullPath(`$p).TrimEnd('\') }
    catch { Write-Output "skipped unresolvable path `$p"; continue }
    if (`$p -notmatch '^[A-Za-z]:\\.+') { continue }
    `$pl = `$p.ToLowerInvariant()
    `$inUse = `$false
    foreach (`$u in `$profiles) { if (`$pl -eq `$u -or `$pl.StartsWith("`$u\")) { `$inUse = `$true; break } }
    if (`$inUse) { continue }
    `$rest = `$p.Substring(3).ToLowerInvariant()
    `$ok = `$false
    foreach (`$c in `$allowed) { if (`$rest -eq `$c -or `$rest.StartsWith("`$c\")) { `$ok = `$true; break } }
    if (-not `$ok) {
        if (`$rest -eq 'users') { continue }
        if (`$blocked -contains `$rest.Split('\')[0]) { continue }
    }
    `$item = Get-Item -LiteralPath `$p -Force -ErrorAction SilentlyContinue
    if (-not `$item) { continue }
    # The selected folder being a junction means the name that passed the checks is not the target.
    if (`$item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Output "skipped reparse point `$p"
        continue
    }
    Clear-Tree `$p
}
"@
    }

    # Parses the copied-back top-rows CSV on the pool thread and writes a compact
    # top-N JSON, so the UI thread only reads a tiny file (a raw parse there froze
    # the UI, back when the full export crossed SMB).
    [string] ParseAndCacheFolders([string]$hostName, [string]$csvPath, [int]$topN) {
        $jsonPath = Join-Path $this.LocalReportsDir "$hostName-folders.json"
        if (-not (Test-Path $csvPath)) { return $jsonPath }

        try {
            # Stream line-by-line: a -Raw read of a full-drive export caused gen-2
            # GCs that suspended the UI mid-scan (see DiskUsage.psm1).
            $report = [WizTreeCsv]::ParseTopFoldersFromFile($csvPath, $topN)
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

    # The headless WizTree command: fast MFT scan of C:, folders only, size-sorted
    # CSV. /sortby=1 is size DESCENDING, so the export's first rows are the top N;
    # the trim keeps them (plus a margin for the banner/header/volume-root lines the
    # parser skips) and only that small file ever crosses SMB - the full export ran
    # ~40 MB per scan. TotalCount never reads past the kept lines, so the trim is
    # instant on the target, and the big export is deleted rather than left behind.
    # Isolated here so a pure-PowerShell fallback would be a single-method swap.
    static [string] BuildScanCommand([int]$topN) {
        $keep = [Math]::Max($topN, 1) + 8
        return @"
& 'C:\temp\DONUT\wiztree64.exe' "C:" /export="C:\temp\DONUT\folders.csv" /admin=1 /exportfolders=1 /exportfiles=0 /sortby=1 /exportmaxdepth=4 | Out-Null
Get-Content 'C:\temp\DONUT\folders.csv' -TotalCount $keep | Set-Content 'C:\temp\DONUT\folders-top.csv'
Remove-Item 'C:\temp\DONUT\folders.csv' -Force -ErrorAction SilentlyContinue
"@
    }

    # The remote script trims the size-ranked export to folders-top.csv; only the
    # local copy is host-qualified. A missing remote file (failed scan) surfaces
    # here, same as it did when the full export was the artifact.
    [string] CopyDiskUsageArtifact([string] $hostName) {
        return $this.CopyBackArtifact($hostName, 'folders-top.csv', "$hostName-folders.csv")
    }

    [hashtable] CopyRemoteArtifacts([string] $hostName, [string] $outputLog) {
        return $this.CopyRemoteArtifacts($hostName, $outputLog, $true)
    }

    [hashtable] CopyRemoteArtifacts([string] $hostName, [string] $outputLog, [bool] $copyReport) {
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

        # A no-updates scan produced no fresh report: drop the previous run's local
        # copy so the UI cannot re-render stale updates for this host.
        if (-not $copyReport) {
            Remove-Item -LiteralPath $localReport -Force -ErrorAction SilentlyContinue
        }

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

        if (-not $copyReport) {
            return @{ Log = $localLog; Report = $localReport }
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

    # One SMB-gated outputLog read -> @{ Seen; Code }; shared by the live tail and
    # reconnect recovery. Best-effort + 2s-gated so tick loops never stall (.NOTES).
    [hashtable] TailAndScanLog([string]$ip, [string]$remoteLog, [int]$seenChars) {
        $result = @{ Seen = $seenChars; Code = @{ Found = $false; Code = 0 } }
        if ([string]::IsNullOrWhiteSpace($remoteLog)) { return $result }
        # Quiet gate: this runs every tick, so a down host must not spam a DEBUG line per tick.
        if (-not $this.Probe.IsSmbReachableQuiet($ip)) { return $result }
        try {
            if (-not (Test-Path -LiteralPath $remoteLog)) { return $result }
            $text = Get-Content -LiteralPath $remoteLog -Raw -ErrorAction Stop
            if ([string]::IsNullOrEmpty($text)) { return $result }
            if ($text.Length -lt $seenChars) { $seenChars = 0 }   # file was rewritten, restart
            # Consume only up to the last newline: the final line may still be mid-write.
            $upto = $text.LastIndexOf("`n")
            if ($upto -ge $seenChars) {
                $chunk = $text.Substring($seenChars, $upto - $seenChars + 1)
                foreach ($line in ($chunk -split "`r?`n")) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Information $line }
                }
                $seenChars = $upto + 1
            }
            $result.Seen = $seenChars
            $result.Code = [DcuLog]::ParseReturnCode($text)
            return $result
        }
        catch {
            return $result
        }
    }

    # Thin wrapper for the live tick, which only needs the advanced offset.
    hidden [int] EmitNewDcuLogLines([string]$ip, [string]$remoteLog, [int]$seenChars) {
        return [int]($this.TailAndScanLog($ip, $remoteLog, $seenChars)).Seen
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

    # Reconnect-and-resume tail after a drop at either end, bounded by the recovery
    # window; dcu-cli's outputLog is the truth. Overridable test seam (.NOTES).
    [hashtable] RecoverByResumeTail([string]$ip, [string]$computer, [string]$remoteLog, [int]$seenChars) {
        $marker = [DcuProgress]::ReconnectMarker
        $deadline = [datetime]::UtcNow.AddMinutes($this.Config.GetRecoveryWindowMinutes())
        $backoff = 5
        $announced = ''   # de-dupe: only re-announce when the reason changes
        while ([datetime]::UtcNow -lt $deadline) {
            # My own laptop is offline: wait it out, don't probe the target.
            if (-not $this.Probe.IsLocalOnline()) {
                if ($announced -ne 'offline') {
                    Write-Information "${marker}Connection lost - this machine is offline. Waiting to reconnect, then resuming $computer…"
                    $announced = 'offline'
                }
                Start-Sleep -Seconds $backoff
                $backoff = [Math]::Min($backoff * 2, 60)
                continue
            }
            # Online, but the target's admin share isn't reachable yet.
            if (-not $this.Probe.IsSmbAvailable($ip)) {
                if ($announced -ne 'target') {
                    Write-Information "${marker}Reconnecting to $computer to resume…"
                    $announced = 'target'
                }
                Start-Sleep -Seconds $backoff
                $backoff = [Math]::Min($backoff * 2, 60)
                continue
            }
            # Reachable: resume the tail from where we left off and look for the verdict.
            $r = $this.TailAndScanLog($ip, $remoteLog, $seenChars)
            $seenChars = [int]$r.Seen
            if ($r.Code.Found) {
                $this.Logger.LogInfo("[$computer] Reconnected and recovered dcu-cli return code $($r.Code.Code) from the resumed log.")
                return $r.Code
            }
            # Connected but dcu-cli hasn't written its code yet: reset backoff and poll
            # steadily while we have a link so the resumed lines stream in near-live.
            $announced = ''
            $backoff = 5
            Start-Sleep -Seconds 3
        }

        $this.Logger.LogWarning("[$computer] Reconnect window elapsed without a dcu-cli return code; the run is unconfirmed.")
        return @{ Found = $false; Code = 0 }
    }

    # Builds the on-target launcher for one dcu-cli command; resolving dcu-cli on the
    # target keeps hung admin shares out of the launch. Pure + static (unit-tested).
    static [string] BuildRemoteDcuScript([string]$command, [string]$argsString, [string]$outputLog) {
        $clearLine = if (-not [string]::IsNullOrWhiteSpace($outputLog)) {
            "Remove-Item -LiteralPath '$outputLog' -Force -ErrorAction SilentlyContinue"
        }
        else { '' }
        $notFound = [ExecutionService]::DcuNotFoundExit
        # A double-quoted here-string: $command/$argsString/$clearLine/$notFound interpolate
        # here on the controller; `$dcu / `$_ / `$LASTEXITCODE stay literal for the target.
        return @"
Stop-Process -Name 'DellCommandUpdate' -Force -ErrorAction SilentlyContinue
New-Item -Path 'C:\temp\DONUT' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$clearLine
`$dcu = @('C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe', 'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe') | Where-Object { Test-Path -LiteralPath `$_ } | Select-Object -First 1
if (-not `$dcu) { exit $notFound }
& `$dcu /$command $argsString
exit `$LASTEXITCODE
"@
    }

    # Runs dcu-cli via psexec and returns the effective dcu-cli return code (0 = done,
    # 1/5 = done + reboot needed, used by RunApplyPhase). Throws on any real failure.
    [int] InvokePsExec([hashtable] $parameters) {
        $computer = $parameters.ComputerName
        $command = $parameters.Command
        $argsString = $parameters.Arguments

        # Reuse the job's resolved/prefetched IP (resolves at most once).
        $ip = $this.ResolvedIpFor($computer)

        # Bounded SMB gate (2s): a down/firewalled host fails fast and typed, and no
        # controller-side UNC runs before launch (see BuildRemoteDcuScript).
        if (-not $this.Probe.IsSmbAvailable($ip)) {
            $this.Logger.LogWarning("[$ip] Admin share (SMB/445) not reachable - cannot run psexec.")
            throw [RpcUnavailableException]::new($ip)
        }

        # Breadcrumb: SMB gate passed; only pure string/encode work remains before the
        # "Executing:" line, so a gap ending here points at the probe/socket layer.
        $this.Logger.LogDebug("[$ip] SMB gate passed - building remote DCU command.")

        $outputLog = [string]$parameters.OutputLog
        $remoteScript = [ExecutionService]::BuildRemoteDcuScript($command, $argsString, $outputLog)

        # -EncodedCommand (base64, like InvokeRemotePwsh) carries the multi-line discovery
        # script with no psexec quoting hazards; -r gives each job family its own PSEXESVC.
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($remoteScript))
        $psexecFlags = @(
            '-accepteula',
            '-nobanner',
            '-r', 'DonutDcu',
            '-n', '60',     # connect timeout (s): give up instead of hanging on a dead host
            '-s',           # Run as SYSTEM
            '-h',           # Elevated token
            "\\$ip"
        )
        $psexecArgs = $psexecFlags + @('pwsh', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)

        # Log a readable rendering (not the base64 blob) so a CLI failure (e.g. DCU 105)
        # can be read - and the command re-run by hand - straight from the log.
        $readableRemote = (($remoteScript -split "`r?`n" | Where-Object { $_.Trim() }) -join '; ')
        $cmdLine = "psexec.exe $($psexecFlags -join ' ') pwsh -NoProfile -NonInteractive -Command `"$readableRemote`""
        $this.Logger.LogInfo("Executing: $cmdLine")
        Write-Information "Executing: $cmdLine"

        # Headless launch; progress is tailed from the outputLog (see StartPsExecHidden).
        $remoteLogUnc = [ExecutionService]::ToAdminShare($ip, $outputLog)
        # Clear the previous run's log over the share before tailing: psexec takes seconds
        # to connect, so the tail would otherwise replay the last scan (bar jumps to 5/5).
        try { Remove-Item -LiteralPath $remoteLogUnc -Force -ErrorAction Stop }
        catch { $this.Logger.LogDebug("[$ip] Could not pre-clear $remoteLogUnc (may not exist yet): $($_.Exception.Message)") }
        $p = [ExecutionService]::StartPsExecHidden($psexecArgs)
        # $tickState is a hashtable holder: GetNewClosure copies locals by value, so
        # only a reference type lets the consumed-chars offset survive across ticks.
        $maxMinutes = if ($command -eq 'applyUpdates') { 120 } else { 30 }
        $svc = $this
        $tickState = @{ Seen = 0; Ticks = 0; LastReportedSeen = 0 }
        $onTick = {
            $tickState.Seen = $svc.EmitNewDcuLogLines($ip, $remoteLogUnc, [int]$tickState.Seen)
            $tickState.Ticks++
            # Every ~30 s say whether the remote log grew: no growth while SMB is
            # reachable = dcu-cli is running but producing nothing (the wedge to chase).
            if ($tickState.Ticks % 20 -eq 0) {
                $delta = [int]$tickState.Seen - [int]$tickState.LastReportedSeen
                $reach = $svc.Probe.IsSmbReachableQuiet($ip)
                $svc.Logger.LogDebug(
                    "[$ip] DCU /$command tail: +$delta log chars in last ~30 s (total $($tickState.Seen), SMB reachable=$reach).")
                $tickState.LastReportedSeen = $tickState.Seen
            }
        }.GetNewClosure()
        $exitCode = $this.WaitForRemoteProcess($p, $computer, "DCU /$command", $maxMinutes, $onTick)
        # Final flush for output that landed between the last poll and exit.
        $tickState.Seen = $this.EmitNewDcuLogLines($ip, $remoteLogUnc, [int]$tickState.Seen)

        # The remote script signals "dcu-cli not installed" with a reserved sentinel
        # (discovery moved onto the target), so surface the same typed error as before.
        if ($exitCode -eq [ExecutionService]::DcuNotFoundExit) {
            throw [DcuNotInstalledException]::new($computer)
        }

        # Transport code = the connection dropped mid-command at either end; dcu-cli
        # keeps running, so resume the tail and recover its code (.NOTES).
        if ([RemoteConnectionLostException]::IsConnectionLost($exitCode)) {
            $dcu = $this.RecoverByResumeTail($ip, $computer, $remoteLogUnc, [int]$tickState.Seen)
            if ($dcu.Found) {
                # dcu-cli recorded its verdict: trust that, not the dropped pipe.
                if ([DcuLog]::Classify($command, $dcu.Code) -ne [DcuCommandOutcome]::Failed) {
                    $this.Logger.LogWarning("[$computer] Connection dropped ($([RemoteConnectionLostException]::Describe($exitCode))); reconnected and dcu-cli's log confirms return code $($dcu.Code) - treating DCU /$command as completed.")
                    if ([DcuLog]::NeedsReboot($dcu.Code)) { $this.Logger.LogInfo("[$computer] Reboot required to complete updates (dcu-cli code $($dcu.Code)).") }
                    return $dcu.Code
                }
                # dcu-cli reported a real error: surface that, not the transport code.
                throw [RemoteExecutionException]::new($computer, "DCU /$command $argsString", $dcu.Code, [DcuLog]::DescribeReturnCode($dcu.Code))
            }
            # Window elapsed with no verdict (interrupted mid-install, or never got back
            # online) - report the drop so the card settles Unconfirmed (re-scan to confirm).
            throw [RemoteConnectionLostException]::new($computer, "DCU /$command", $exitCode)
        }

        # Per-command verdict: 0/1/5 pass for any command, a scan's 500 is a clean
        # no-updates result; everything else is a real failure (reference in .NOTES).
        if ([DcuLog]::Classify($command, $exitCode) -eq [DcuCommandOutcome]::Failed) {
            # Carry the full argument string + decoded meaning so the error reads as
            # its actual cause (a syntax error like DCU 105 needs the exact command).
            throw [RemoteExecutionException]::new($computer, "DCU /$command $argsString", $exitCode, [DcuLog]::DescribeReturnCode($exitCode))
        }

        if ([DcuLog]::NeedsReboot($exitCode)) {
            $this.Logger.LogInfo("[$computer] Reboot required to complete updates (dcu-cli code $exitCode).")
        }
        return $exitCode
    }

}
