using module "..\Models\AppConfig.psm1"
using module "..\Models\DcuUpdate.psm1"
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
    prepares an update scan/apply and parses the resulting update report into
    typed DcuUpdate rows (driver-matched, urgency-sorted) for the detail pane.
    The subclasses only PREPARE and PARSE off the UI thread — the worker
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
            throw [System.IO.FileNotFoundException]::new('RemoteWorker script not found.', $scriptPath)
        }

        return @{
            ScriptPath     = $scriptPath
            TempConfigPath = $null
            Arguments      = @{
                HostName   = $hostName
                JobType    = $jobType
                # Snapshot, same rule as Settings below: no live hashtable may
                # cross the runspace boundary.
                Options    = if ($null -ne $options) { [AppConfig]::DeepClone($options) }
                else { @{} }
                # Seeded by the presenter (AttachResolvedIp) before Start. A dedicated
                # arg, never an Options key, so it can't leak onto a dcu-cli command line.
                ResolvedIp = ''
                SourceRoot = $this.Config.SourceRoot
                LogsDir    = $this.Config.LogsPath
                ReportsDir = $this.Config.ReportsPath
                # UI-thread deep clone of the live config: a worker enumerating a
                # table the UI mutates can spin forever on a corrupted bucket chain.
                Settings   = [AppConfig]::DeepClone($this.Config.Settings)
                # The EFFECTIVE debug state (setting OR -DebugLog session override).
                DebugLog   = $this.Logger.DebugEnabled
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

    # $null = no report on disk; @() = a report with zero updates; else typed rows.
    [array] GetUpdateRows([string]$hostName) {
        $report = $this.ParseUpdateReport($hostName)
        if (-not $report) { return $null }
        if ($report.SelectNodes("//update").Count -eq 0) { return @() }
        return $this.BuildUpdateRows($report)
    }

    # Parses each <update>'s child elements into typed DcuUpdate rows (read explicitly - the
    # fields are child elements, so $node.InnerText would mash them). See NodeText.
    hidden [array] BuildUpdateRows([xml]$report) {
        $installedDrivers = $this.GetInstalledDriversFromReport($report)
        $updateRows = @()
        foreach ($node in $report.SelectNodes("//update")) {
            $name = $this.NodeText($node, 'name')
            $newVersion = $this.NodeText($node, 'version')
            $category = $this.NodeText($node, 'category')
            $bytesText = $this.NodeText($node, 'bytes')
            [long]$bytes = 0
            [void][long]::TryParse($bytesText, [ref]$bytes)

            $match = $this.DriverMatcher.FindBestDriverMatch($name, $installedDrivers)
            $currentVersion = ''
            $isNewer = $false
            $hasMatch = $false
            if ($match) {
                $hasMatch = $true
                $currentVersion = $match.Driver.DriverVersion
                $isNewer = $this.DriverMatcher.CompareVersions($currentVersion, $newVersion).IsNewer
                if ([string]::IsNullOrWhiteSpace($category)) { $category = $match.Category }
            }
            $updateRows += [DcuUpdate]::Create($name, $newVersion, $currentVersion, $hasMatch, $isNewer,
                $this.NodeText($node, 'urgency'), $this.NodeText($node, 'type'), $category, $bytes)
        }
        # Show most-urgent first (Urgent -> Recommended -> Optional -> unknown), then by name.
        return @($updateRows | Sort-Object @{ Expression = { [DcuUpdate]::UrgencyRank($_.Urgency) } }, Name)
    }

    # First child element's trimmed text (empty when absent). SelectSingleNode('name'), never
    # $node.name - the latter collides with XmlElement.Name and returns the tag ("update").
    hidden [string] NodeText([System.Xml.XmlNode]$node, [string]$child) {
        $c = $node.SelectSingleNode($child)
        if ($null -eq $c) { return '' }
        return $c.InnerText.Trim()
    }

    hidden [array] GetInstalledDriversFromReport([xml]$report) {
        $driverNodes = $report.SelectNodes("//drivers/driver")
        if (-not $driverNodes) { return @() }
        return $driverNodes | ForEach-Object {
            @{
                DriverName    = $_.GetAttribute("name")
                ProviderName  = $_.GetAttribute("provider")
                DriverVersion = $_.GetAttribute("version")
                DriverDate    = $_.GetAttribute("date")
            }
        }
    }
}
