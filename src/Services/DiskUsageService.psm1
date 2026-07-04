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
    worker's RunDiskScanPhase), exports a folder CSV which is copied back and
    parsed into a [DiskUsageReport]. Mirrors InventoryService — subclasses
    RemoteJobService, reusing BuildWorkerArgs. Heavier than
    the inventory probe, so it is triggered on demand rather than on every
    scan/apply.
#>
class DiskUsageService : RemoteJobService {

    # Number of largest folders to keep. Kept small so the cached result stays
    # compact in config.json and the detail panel stays readable.
    static [int] $TopN = 12

    DiskUsageService([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    DiskUsageService([AppConfig] $config, [NetworkProbe] $probe, [LogService] $logger) : base($config, $probe, $logger) {}

    # Returns worker args for the "DiskScan" job (no network here - the worker gates
    # reachability itself and resolves wiztree64.exe); Options only carries the row cap.
    [hashtable] PrepareDiskScan([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "DiskScan", @{ TopN = [DiskUsageService]::TopN })
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
