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
    remote failures (Fail). RemoteUpdateService prepares a DCU scan or apply and
    parses the resulting update report into typed DcuUpdate rows
    (driver-matched, urgency-sorted) for the detail pane. The subclasses only
    prepare and parse off the UI thread - the worker does the network I/O,
    gating each phase's transport itself (bounded RPC/SMB port probes).

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
                # No live hashtable may cross the runspace boundary.
                Options    = if ($null -ne $options) { [AppConfig]::DeepClone($options) }
                else { @{} }
                # Seeded by AttachResolvedIp, never an Options key on a dcu-cli command line.
                ResolvedIp = ''
                SourceRoot = $this.Config.SourceRoot
                LogsDir    = $this.Config.LogsPath
                ReportsDir = $this.Config.ReportsPath
                # Only the keys workers read, since the worker's AppConfig defaults the rest.
                Settings   = @{
                    commands              = [AppConfig]::DeepClone($this.Config.Settings['commands'])
                    debugLogging          = $this.Config.GetDebugLogging()
                    recoveryWindowMinutes = $this.Config.GetRecoveryWindowMinutes()
                }
                # The effective debug state (the setting or the -DebugLog session override).
                DebugLog   = $this.Logger.DebugEnabled
            }
        }
    }
}

# Handles scanning for and applying updates on remote hosts.
class RemoteUpdateService : RemoteJobService {
    [DriverMatchingService] $DriverMatcher
    # Keyed on the report's last-write time, so a fresh scan re-parses but reads do not.
    hidden [hashtable] $ReportCache = @{}

    RemoteUpdateService([AppConfig] $config, [NetworkProbe] $probe,
        [DriverMatchingService] $matcher) : base($config, $probe) {
        $this.DriverMatcher = $matcher
    }

    RemoteUpdateService([AppConfig] $config, [NetworkProbe] $probe,
        [DriverMatchingService] $matcher, [LogService] $logger) : base($config, $probe, $logger) {
        $this.DriverMatcher = $matcher
    }

    # Builds the worker args only, with no network. The worker asserts reachability on
    # the pool thread, so the UI thread never blocks on an offline host.
    [hashtable] PrepareScanForUpdates([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "Scan", @{})
    }

    [xml] ParseUpdateReport([string]$hostName) {
        $reportPath = Join-Path $this.Config.ReportsPath "$hostName-Updates.xml"
        if (-not (Test-Path $reportPath)) { return $null }

        try {
            # Keyed on last-write time, so a new scan's newer file misses the cache.
            $ticks = (Get-Item -LiteralPath $reportPath).LastWriteTimeUtc.Ticks
            $cached = $this.ReportCache[$hostName]
            if ($null -ne $cached -and $cached.Ticks -eq $ticks) { return $cached.Xml }

            $xml = [xml](Get-Content -LiteralPath $reportPath)
            $this.ReportCache[$hostName] = @{ Ticks = $ticks; Xml = $xml }
            return $xml
        } catch {
            $this.Logger.LogException("Failed to parse update report for $hostName", $_)
            return $null
        }
    }

    # Clearing a machine deletes its report, so reports\ never needs a manual sweep.
    [void] DeleteReport([string]$hostName) {
        $reportPath = Join-Path $this.Config.ReportsPath "$hostName-Updates.xml"
        Remove-Item -LiteralPath $reportPath `
                    -Force `
                    -ErrorAction SilentlyContinue
    }

    [hashtable] PrepareApplyUpdates([string]$hostName, [hashtable]$selectedUpdates) {
        return $this.BuildWorkerArgs($hostName, "Apply", $selectedUpdates)
    }

    # Counts the available updates in a parsed report (0 when null or empty).
    [int] CountUpdates([xml]$report) {
        if ($null -eq $report) { return 0 }
        $nodes = $report.SelectNodes("//update")
        if ($null -eq $nodes) { return 0 }
        return $nodes.Count
    }

    # Returns $null when no report is on disk, and @() when it holds zero updates.
    [array] GetUpdateRows([string]$hostName) {
        $report = $this.ParseUpdateReport($hostName)
        if (-not $report) { return $null }
        if ($report.SelectNodes("//update").Count -eq 0) { return @() }
        return $this.BuildUpdateRows($report)
    }

    # Parses each <update>'s child elements into typed DcuUpdate rows. The fields are
    # child elements, so $node.InnerText would mash them together. See NodeText.
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

            $type = $this.NodeText($node, 'type')
            $match = $this.DriverMatcher.FindBestDriverMatch($name, $type, $category, $installedDrivers)
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
                $this.NodeText($node, 'urgency'), $category, $bytes)
        }
        # Show most-urgent first (Urgent -> Recommended -> Optional -> unknown), then by name.
        return @($updateRows | Sort-Object @{ Expression = { [DcuUpdate]::UrgencyRank($_.Urgency) } }, Name)
    }

    # First child element's trimmed text, empty when absent. SelectSingleNode('name'),
    # never $node.name, which collides with XmlElement.Name and returns the tag.
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
                DeviceClass   = $_.GetAttribute("class")
            }
        }
    }
}
