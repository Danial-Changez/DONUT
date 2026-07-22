using module "..\Core\LogService.psm1"
using module "..\Core\NetworkProbe.psm1"
using module ".\DriverMatchingService.psm1"
using module ".\RemoteServices.psm1"
using module "..\Models\DeviceContext.psm1"
using module "..\Models\AppConfig.psm1"
using module "..\Models\DiskUsage.psm1"
using module "..\Models\RemoteError.psm1"
using module "..\Models\DcuLog.psm1"
using module "..\Models\DcuProgress.psm1"

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
      thread forever. An OPEN 445 still doesn't guarantee the C$ share responds, so
      the psexec path does NO controller-side UNC before launch: dcu-cli discovery
      and the pre-run log clear both run ON the target (BuildRemoteDcuScript), and a
      missing dcu-cli comes back as the $DcuNotFoundExit sentinel, not a hung path.
    - Concurrent psexec sessions sharing one PSEXESVC hang when the first ends and
      deletes the service, so each job family runs under its own -r service name
      (DonutDcu / DonutDisk / DonutProbe).
    - psexec exit codes are classified: negative = Windows process-launch fault
      (NTSTATUS); Win32 transport codes = the connection dropped mid-command, at
      EITHER end - the target's NIC reset (a NETWORK driver install), or the operator's
      own laptop lost Wi-Fi (59/1232/...). On a drop the run does NOT fail: dcu-cli keeps
      going on the target, so RecoverByResumeTail reconnects (waiting out a local outage
      too), resumes the outputLog tail from the last-seen offset, and recovers dcu-cli's
      authoritative code - bounded by AppConfig.GetRecoveryWindowMinutes, after which the
      run settles Unconfirmed. The target-side clear runs before dcu-cli, so a recovered
      code is always this run's.
    - dcu-cli return codes: only 0 is success, 1/5 mean done-but-reboot, and the
      other small codes are real failures (see DcuLog). Reference:
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

    # Exit code the remote script returns when dcu-cli.exe isn't on the target. Chosen
    # to sit outside every documented dcu-cli code (0-8, 1xx, 5xx, 1000s, 2000s) and every
    # psexec transport code (64, 233, ...), so InvokePsExec can map it back to
    # DcuNotInstalledException without a bounded-side path check that would hang on a
    # wedged admin share (see BuildRemoteDcuScript).
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
            # Entry marker: if this logs but "Cached N domain controller(s)" never
            # follows, the hang is inside the AD discovery itself; if even this line is
            # missing, the worker never started (script/pipeline bring-up wedged).
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
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $this.WarmRuntimeAssemblies()
            $runtimeMs = $sw.ElapsedMilliseconds
            $sw.Restart()
            $this.WarmScanLaunchPath()
            # One line per pool runspace at startup: proof this runspace ran the real
            # worker pipeline before any real job landed on it. The timings say where
            # a slow warm spent its barrier budget.
            $this.Logger.LogDebug(
                "Runspace warmed: worker pipeline up; runtime assemblies $runtimeMs ms; " +
                "scan path $($sw.ElapsedMilliseconds) ms.")
            return @{ Mode = 'WarmRunspace' }
        }

        # Identity check: ask the box at $ip for its own name (parallel to the scan).
        if ($mode -eq 'Name') {
            $ip = if ($null -ne $options) { [string]$options.Ip } else { '' }
            $actual = $this.Probe.ResolveComputerName($ip)
            return @{ Mode = 'Name'; HostName = $device.HostName; ActualName = [string]$actual }
        }

        # Step breadcrumbs (DEBUG): a host resolve that never completes must name its
        # last step - DNS via the DC, then the RPC-135 probe. TTL re-validations are
        # minutes apart per host, so the volume stays low.
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

    # Exercises the heavy runtime stacks (DNS, TCP, CIM/DCOM, LDAP) against localhost
    # so a live job's FIRST resolve/socket/CIM call is never also this runspace's
    # first: assembly loads, winsock/DNS-client bring-up, and DCOM plumbing all get
    # paid here. This is the recipe every known-good build ran (64dbec8 through
    # 36c7536: resolve, disk scan, and DC discovery all worked for weeks). A
    # loads-only variant that skipped the exercises shipped once, and the first live
    # resolve-IP and disk-scan jobs - whose opening act is exactly a first
    # DNS/socket connect - stopped completing.
    #
    # Wedge risk is accepted BY DESIGN: this runs under WarmPool's barrier, which
    # can no longer hang or kill anything - a warm that overruns is parked running,
    # capacity is compensated, and the reaper harvests it whenever it lands. The
    # one op that stays banned here is anything unproven: the loopback port-445
    # probe added in 2292abe was in no known-good build and coincided with the
    # no-window startup incident; WarmScanLaunchPath stays pure CPU.
    [void] WarmRuntimeAssemblies() {
        # Each exercise logs BEFORE it runs: a warm that wedges leaves the name of
        # the exact stack it wedged in as the runspace's last log line.
        $this.Logger.LogDebug("Warm: exercising DNS (localhost lookup)...")
        try {
            Resolve-DnsName -Name 'localhost' -QuickTimeout -ErrorAction Stop | Out-Null
        }
        catch {
            $this.Logger.LogDebug("DNS warm-up skipped: $($_.Exception.Message)")
        }
        $this.Logger.LogDebug("Warm: exercising TCP (socket construct)...")
        try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Close() }
        catch {
            $this.Logger.LogDebug("TCP warm-up skipped: $($_.Exception.Message)")
        }
        $this.Logger.LogDebug("Warm: loading DirectoryServices (LDAP)...")
        try { Add-Type -AssemblyName System.DirectoryServices -ErrorAction Stop }
        catch {
            $this.Logger.LogDebug("DirectoryServices warm-up skipped: $($_.Exception.Message)")
        }
        $this.Logger.LogDebug("Warm: exercising CIM (loopback DCOM session)...")
        try {
            $opt = New-CimSessionOption -Protocol Dcom
            $s = New-CimSession -SessionOption $opt -ErrorAction Stop
            try {
                Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystem `
                    -Property Name -ErrorAction Stop | Out-Null
            }
            catch {
                $this.Logger.LogDebug("CIM query warm-up skipped: $($_.Exception.Message)")
            }
            Remove-CimSession -CimSession $s -ErrorAction SilentlyContinue
        }
        catch {
            $this.Logger.LogDebug("CIM session warm-up skipped: $($_.Exception.Message)")
        }
        $this.Logger.LogDebug("Warm: runtime stacks exercised.")
    }

    # Pre-executes the CPU-only half of the DCU launch path - dcu-cli arg build and
    # remote-script build + encode - so a live scan's first InvokePsExec is never also
    # this runspace's first compile of that code. A first-ever execution on a live job
    # is the silent-wedge class the worker warm pass exists to dodge: a real scan
    # wedged forever after "Starting preliminary scan" with every op in that gap
    # bounded at source level, so the block sits below PowerShell.
    #
    # This warm stays PURE CPU. A port-445 loopback probe was added here once "to
    # bind the socket stack" - it was in no known-good build, and it coincided with
    # the no-window startup incident (a hooked connect can block inside BeginConnect,
    # below the probe's own 2 s timeout, which is armed only after the call returns).
    # The proven localhost first-use exercises live in WarmRuntimeAssemblies; nothing
    # unproven gets added to the barrier's workload.
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

        # Breadcrumb pairing with InvokePsExec's gate + "Executing:" lines: a scan once
        # wedged silently between "Starting preliminary scan" and the psexec launch, so
        # the next repro must pin which segment of that gap stopped logging.
        $this.Logger.LogDebug(
            "[$($device.HostName)] Scan arguments built - invoking psexec launcher.")

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
        # Diagnostic (remove once pinned): a "start" with no matching "done" names the
        # step that hung on the loader lock; a long "done" names the slow cold-load.
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
            # Stream the CSV line-by-line: reading a full-drive export with -Raw and
            # splitting it materialized multi-MB strings + a PSObject per row on the
            # pool thread, and the resulting gen-2 GCs suspended the UI mid-scan.
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

    # One SMB-gated read of the run's outputLog: streams any new whole lines to the
    # Information stream and reports @{ Seen (advanced offset); Code (dcu-cli's terminal
    # return code if the log now holds one) }. Shared by the live tail (offset only) and the
    # reconnect-resume recovery (which also needs the code). The 2s SMB gate matters because
    # this runs INSIDE loops that must keep ticking: a read against a wedged/absent share
    # blocks with no timeout, so the gate turns that into a skipped read, not a stall.
    # Best-effort: a missing file / unreachable share / read error returns the old offset and
    # Found=$false. Overridable seam so the worker tests run without a network.
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

    # After a connection drop (at EITHER end), keep trying to reconnect and RESUME tailing
    # the log from $seenChars until dcu-cli's return code appears or the recovery window
    # (AppConfig.GetRecoveryWindowMinutes) elapses. dcu-cli keeps running on the target as
    # SYSTEM, so its outputLog is the source of truth. Bidirectional: it waits out the
    # operator's own offline periods (IsLocalOnline) as well as an unreachable target,
    # emitting DcuProgress.ReconnectMarker status lines the pump turns into a "Reconnecting…"
    # card. Returns @{ Found; Code }; Found=$false means the window elapsed with no verdict
    # (settle Unconfirmed). Overridable seam so the worker tests run without a network.
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

    # Builds the PowerShell that runs on the TARGET (as SYSTEM) for one dcu-cli command:
    # stop any running DCU, ensure the work dir, clear the prior outputLog, then resolve
    # dcu-cli locally and run it. Resolving on the target (not a controller-side UNC
    # Test-Path) is the whole point - a hung admin share can no longer stall the launch.
    # Exits $DcuNotFoundExit when dcu-cli is absent; ends on dcu-cli's own code otherwise.
    # Pure + static, so it's unit-testable without a host.
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

        # Bounded SMB gate (2s) so a down/firewalled host fails fast and typed. dcu-cli
        # discovery + the log clear now run ON the target (BuildRemoteDcuScript), so there
        # is NO controller-side UNC before launch - a wedged admin share (e.g. a host
        # mid-reboot after a BIOS flash) can't stall the worker before psexec is even sent.
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
        $p = [ExecutionService]::StartPsExecHidden($psexecArgs)
        # $tickState is a hashtable holder: GetNewClosure copies locals by value, so
        # only a reference type lets the consumed-chars offset survive across ticks.
        $maxMinutes = if ($command -eq 'applyUpdates') { 120 } else { 30 }
        $svc = $this
        $tickState = @{ Seen = 0 }
        $onTick = {
            $tickState.Seen = $svc.EmitNewDcuLogLines($ip, $remoteLogUnc, [int]$tickState.Seen)
        }.GetNewClosure()
        $exitCode = $this.WaitForRemoteProcess($p, $computer, "DCU /$command", $maxMinutes, $onTick)
        # Final flush for output that landed between the last poll and exit.
        $tickState.Seen = $this.EmitNewDcuLogLines($ip, $remoteLogUnc, [int]$tickState.Seen)

        # The remote script signals "dcu-cli not installed" with a reserved sentinel
        # (discovery moved onto the target), so surface the same typed error as before.
        if ($exitCode -eq [ExecutionService]::DcuNotFoundExit) {
            throw [DcuNotInstalledException]::new($computer)
        }

        # A transport code means the connection dropped mid-command - at EITHER end (the
        # target's NIC reset, or the operator's own laptop lost Wi-Fi). dcu-cli keeps running
        # on the target, so reconnect, resume the tail from where we left off ($tickState.Seen),
        # and recover its authoritative code (bounded by the recovery window - see .NOTES).
        if ([RemoteConnectionLostException]::IsConnectionLost($exitCode)) {
            $dcu = $this.RecoverByResumeTail($ip, $computer, $remoteLogUnc, [int]$tickState.Seen)
            if ($dcu.Found) {
                # dcu-cli recorded its verdict: trust that, not the dropped pipe.
                if ([DcuLog]::IsSuccess($dcu.Code)) {
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

}
