using module "..\Models\AppConfig.psm1"
using module "..\Models\RemoteError.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\LogService.psm1"
using module ".\DriverMatchingService.psm1"

<#
.SYNOPSIS
    Base class + concrete services for preparing remote host operations.

.DESCRIPTION
    RemoteJobService is the shared base: it builds the RemoteWorker.ps1 argument
    hashtable (BuildWorkerArgs) and owns the log-then-throw policy for typed
    remote failures (Fail). ScanService prepares a DCU scan; RemoteUpdateService
    prepares an update scan/apply and parses + counts the resulting update
    report. The subclasses only PREPARE and PARSE off the UI thread — the worker
    does the network I/O, gating each phase's transport itself (bounded RPC/SMB
    port probes).

.NOTES
    InventoryService, DiskUsageService and HostResolver also subclass
    RemoteJobService (in their own files) to reuse BuildWorkerArgs.
#>
class RemoteJobService {
    [AppConfig] $Config
    [NetworkProbe] $Probe
    [LogService] $Logger

    RemoteJobService([AppConfig] $config, [NetworkProbe] $probe) {
        $this.Config = $config
        $this.Probe = $probe
        $this.Logger = [NullLogService]::new()
    }

    RemoteJobService([AppConfig] $config, [NetworkProbe] $probe, [LogService] $logger) {
        $this.Config = $config
        $this.Probe = $probe
        $this.Logger = [LogService]::Coalesce($logger)
    }

    # Logs a typed failure at its carried severity and returns it for the caller to
    # throw, so the log entry and the exception can never drift apart.
    hidden static [RemoteOperationException] Fail([LogService]$logger, [RemoteOperationException]$ex) {
        switch ($ex.Level) {
            ([ErrorLevel]::Warning) { $logger.LogWarning($ex.Message); break }
            ([ErrorLevel]::Error) { $logger.LogError($ex.Message); break }
            default { $logger.LogInfo($ex.Message); break }
        }
        return $ex
    }

    hidden [hashtable] BuildWorkerArgs([string]$hostName, [string]$jobType, [hashtable]$options) {
        $scriptPath = Join-Path $this.Config.SourceRoot "Scripts\RemoteWorker.ps1"

        if (-not (Test-Path $scriptPath)) {
            $this.Logger.LogError("RemoteWorker script not found at $scriptPath")
            throw "RemoteWorker script not found at $scriptPath"
        }

        return @{
            ScriptPath     = $scriptPath
            TempConfigPath = $null
            Arguments      = @{
                HostName   = $hostName
                JobType    = $jobType
                Options    = $options
                # Seeded by the presenter (AttachResolvedIp) before Start. A dedicated
                # arg, never an Options key, so it can't leak onto a dcu-cli command line.
                ResolvedIp = ''
                SourceRoot = $this.Config.SourceRoot
                LogsDir    = $this.Config.LogsPath
                ReportsDir = $this.Config.ReportsPath
                # Send the live in-memory config to the worker so the run uses
                # exactly what the UI holds, not whatever config.json contains.
                Settings   = $this.Config.Settings
            }
        }
    }
}

# Handles remote host scanning
class ScanService : RemoteJobService {

    ScanService([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    ScanService([AppConfig] $config, [NetworkProbe] $probe,
        [LogService] $logger) : base($config, $probe, $logger) {}

    # Builds the worker args only (no network) - the worker asserts reachability on the
    # pool thread, so the UI thread never blocks on an offline/slow host.
    [hashtable] PrepareScan([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "Scan", @{})
    }
}

# Handles scanning for and applying updates on remote hosts
class RemoteUpdateService : RemoteJobService {
    [DriverMatchingService] $DriverMatcher
    # Parsed-report cache: host -> @{ Ticks; Xml }, invalidated by the report file's
    # last-write time so a fresh scan re-parses but repeated reads in one flow don't.
    hidden [hashtable] $ReportCache = @{}

    RemoteUpdateService([AppConfig] $config, [NetworkProbe] $probe,
        [DriverMatchingService] $matcher) : base($config, $probe) {
        $this.DriverMatcher = $matcher
    }

    RemoteUpdateService([AppConfig] $config, [NetworkProbe] $probe,
        [DriverMatchingService] $matcher, [LogService] $logger) : base($config, $probe, $logger) {
        $this.DriverMatcher = $matcher
    }

    [hashtable] PrepareScanForUpdates([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "Scan", @{})
    }

    [xml] ParseUpdateReport([string]$hostName) {
        $reportPath = Join-Path $this.Config.ReportsPath "$hostName-Updates.xml"
        if (-not (Test-Path $reportPath)) { return $null }

        try {
            # Cache the parsed doc keyed by last-write time: repeated calls in one flow
            # don't re-parse on the UI thread; a new scan's newer file misses the cache.
            $ticks = (Get-Item -LiteralPath $reportPath).LastWriteTimeUtc.Ticks
            $cached = $this.ReportCache[$hostName]
            if ($null -ne $cached -and $cached.Ticks -eq $ticks) { return $cached.Xml }

            $xml = [xml](Get-Content -LiteralPath $reportPath)
            $this.ReportCache[$hostName] = @{ Ticks = $ticks; Xml = $xml }
            return $xml
        }
        catch {
            $this.Logger.LogException("Failed to parse update report for $hostName", $_)
            return $null
        }
    }

    [hashtable] PrepareApplyUpdates([string]$hostName, [hashtable]$selectedUpdates) {
        return $this.BuildWorkerArgs($hostName, "Apply", $selectedUpdates)
    }

    # Counts the available updates in a parsed report (0 when null/empty).
    # Used to record how many updates a scan found on a host.
    [int] CountUpdates([xml]$report) {
        if ($null -eq $report) { return 0 }
        $nodes = $report.SelectNodes("//update")
        if ($null -eq $nodes) { return 0 }
        return $nodes.Count
    }
}
