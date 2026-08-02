using module "..\Models\AppConfig.psm1"
using module "..\Models\DiskUsage.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\LogService.psm1"
using module ".\RemoteServices.psm1"

<#
.SYNOPSIS
    Prepares and parses the on-demand "biggest folders on C:" scan.

.DESCRIPTION
    A WizTree MFT scan that runs on the remote host (deployed and executed by the
    worker's RunDiskScanPhase), exports a size-ranked folder CSV that is trimmed
    to the top rows on the target before the copy-back, then parsed into a
    [DiskUsageReport]. Mirrors InventoryService - subclasses RemoteJobService,
    reusing BuildWorkerArgs. Heavier than the inventory probe, so it is triggered
    on demand rather than on every scan/apply.
#>
class DiskUsageService : RemoteJobService {

    DiskUsageService([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    DiskUsageService([AppConfig] $config, [NetworkProbe] $probe,
        [LogService] $logger) : base($config, $probe, $logger) {}

    # Returns worker args for the "DiskScan" job (no network here - the worker gates
    # reachability itself and resolves wiztree64.exe); Options carries the configurable row cap.
    [hashtable] PrepareDiskScan([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "DiskScan", @{ TopN = $this.Config.GetFolderScanCount() })
    }

    # Worker args for the destructive "DeleteFolders" job. The operator-selected paths (already
    # filtered to deletable) ride in Options and cross the boundary as JSON, never a command line.
    [hashtable] PrepareDeleteFolders([string]$hostName, [string[]]$paths) {
        return $this.BuildWorkerArgs($hostName, "DeleteFolders", @{ Paths = $paths })
    }

    # Reads the compact top-N JSON the worker wrote (the heavy CSV parse already ran on
    # the pool thread), so this is cheap on the dispatcher. $null when missing/unparseable.
    [DiskUsageReport] ParseDiskUsage([string]$hostName) {
        $reportPath = Join-Path $this.Config.ReportsPath "$hostName-folders.json"
        if (-not (Test-Path $reportPath)) { return $null }

        try {
            $raw = Get-Content -Path $reportPath -Raw
            $h = $raw | ConvertFrom-Json -AsHashtable
            return [DiskUsageReport]::FromHashtable([hashtable]$h)
        }
        catch {
            $this.Logger.LogException("Failed to parse disk-usage report for $hostName", $_)
            return $null
        }
    }
}
