using module "..\Models\AppConfig.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\LogService.psm1"
using module ".\DriverMatchingService.psm1"

# Base class for remote host operations
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

    # Shared connectivity policy: IsOnline -> ResolveHost -> IsRpcAvailable,
    # logging and throwing on the first failure. Returns the resolved IP (as a
    # string) so callers can record it. Static so collaborators that hold a
    # NetworkProbe + LogService (ExecutionService) can reuse the exact policy
    # without duplicating it.
    static [string] AssertHostReachable([NetworkProbe]$probe, [LogService]$logger, [string]$hostName) {
        if (-not $probe.IsOnline($hostName)) {
            $logger.LogError("Connectivity check failed: host '$hostName' is offline or unreachable.")
            throw "Host '$hostName' is offline or unreachable."
        }

        $ip = $probe.ResolveHost($hostName)
        if (-not $ip) {
            $logger.LogError("Connectivity check failed: could not resolve IP for '$hostName'.")
            throw "Could not resolve IP for '$hostName'."
        }

        if (-not $probe.IsRpcAvailable($hostName)) {
            $logger.LogError("Connectivity check failed: RPC (Port 135) not available on '$hostName'.")
            throw "RPC (Port 135) is not available on '$hostName'. Check firewall rules."
        }

        $logger.LogDebug("Host '$hostName' passed connectivity checks ($ip).")
        return $ip.ToString()
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

    ScanService([AppConfig] $config, [NetworkProbe] $probe, [LogService] $logger) : base($config, $probe, $logger) {}

    # Builds the worker args only (no network). Reachability + reverse-DNS are
    # asserted by the worker on the runspace-pool thread (RunScanPhase), so the UI
    # thread never blocks on an offline/slow host.
    [hashtable] PrepareScan([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "Scan", @{})
    }
}

# Handles scanning for and applying updates on remote hosts
class RemoteUpdateService : RemoteJobService {
    [DriverMatchingService] $DriverMatcher

    RemoteUpdateService([AppConfig] $config, [NetworkProbe] $probe, [DriverMatchingService] $matcher) : base($config, $probe) {
        $this.DriverMatcher = $matcher
    }

    RemoteUpdateService([AppConfig] $config, [NetworkProbe] $probe, [DriverMatchingService] $matcher, [LogService] $logger) : base($config, $probe, $logger) {
        $this.DriverMatcher = $matcher
    }

    [hashtable] PrepareScanForUpdates([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "Scan", @{})
    }

    [xml] ParseUpdateReport([string]$hostName) {
        $reportPath = Join-Path $this.Config.ReportsPath "$hostName-Updates.xml"
        if (-not (Test-Path $reportPath)) { return $null }

        try {
            return [xml](Get-Content $reportPath)
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
