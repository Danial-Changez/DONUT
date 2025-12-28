using module "..\Models\AppConfig.psm1"
using module "..\Core\NetworkProbe.psm1"
using module ".\DriverMatchingService.psm1"

# Base class for remote host operations
class RemoteJobService {
    [AppConfig] $Config
    [NetworkProbe] $Probe

    RemoteJobService([AppConfig] $config, [NetworkProbe] $probe) {
        $this.Config = $config
        $this.Probe = $probe
    }

    hidden [void] ValidateHostConnectivity([string]$hostName) {
        if (-not $this.Probe.IsOnline($hostName)) {
            throw "Host '$hostName' is offline or unreachable."
        }
        
        $ip = $this.Probe.ResolveHost($hostName)
        if (-not $ip) {
            throw "Could not resolve IP for '$hostName'."
        }

        if (-not $this.Probe.IsRpcAvailable($hostName)) {
            throw "RPC (Port 135) is not available on '$hostName'. Check firewall rules."
        }
    }

    hidden [hashtable] BuildWorkerArgs([string]$hostName, [string]$jobType, [hashtable]$options) {
        $scriptPath = Join-Path $this.Config.SourceRoot "Scripts\RemoteWorker.ps1"
        
        if (-not (Test-Path $scriptPath)) {
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
            }
        }
    }
}

# Handles remote host scanning
class ScanService : RemoteJobService {
    
    ScanService([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    [hashtable] PrepareScan([string]$hostName) {
        $this.ValidateHostConnectivity($hostName)
        
        # Check Reverse DNS (warning only)
        $ip = $this.Probe.ResolveHost($hostName)
        if (-not $this.Probe.CheckReverseDNS($ip, $hostName)) {
            Write-Warning "Reverse DNS mismatch for '$hostName' ($ip). Proceeding anyway..."
        }

        return $this.BuildWorkerArgs($hostName, "Scan", @{})
    }
}

# Handles scanning for and applying updates on remote hosts
class RemoteUpdateService : RemoteJobService {
    [DriverMatchingService] $DriverMatcher

    RemoteUpdateService([AppConfig] $config, [NetworkProbe] $probe, [DriverMatchingService] $matcher) : base($config, $probe) {
        $this.DriverMatcher = $matcher
    }

    [hashtable] PrepareScanForUpdates([string]$hostName) {
        $this.ValidateHostConnectivity($hostName)
        return $this.BuildWorkerArgs($hostName, "Scan", @{})
    }

    [xml] ParseUpdateReport([string]$hostName) {
        $reportPath = Join-Path $this.Config.ReportsPath "$hostName-Updates.xml"
        if (-not (Test-Path $reportPath)) { return $null }
        
        try {
            return [xml](Get-Content $reportPath)
        } catch {
            Write-Warning "Failed to parse update report for $hostName"
            return $null
        }
    }

    [hashtable] PrepareApplyUpdates([string]$hostName, [hashtable]$selectedUpdates) {
        return $this.BuildWorkerArgs($hostName, "Apply", $selectedUpdates)
    }
}
