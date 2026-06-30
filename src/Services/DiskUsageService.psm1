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
    RemoteJobService, reusing AssertHostReachable / BuildWorkerArgs. Heavier than
    the inventory probe, so it is triggered on demand rather than on every
    scan/apply.
#>
class DiskUsageService : RemoteJobService {

    # Number of largest folders to keep. Kept small so the cached result stays
    # compact in config.json and the detail panel stays readable.
    static [int] $TopN = 12

    DiskUsageService([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    DiskUsageService([AppConfig] $config, [NetworkProbe] $probe, [LogService] $logger) : base($config, $probe, $logger) {}

    # Returns worker args for the disk-usage scan (no network — the worker asserts
    # reachability on the pool thread). The worker resolves the bundled
    # wiztree64.exe from SourceRoot, so Options only carries the row cap.
    # Dispatches on the "DiskScan" worker token.
    [hashtable] PrepareDiskScan([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "DiskScan", @{ TopN = [DiskUsageService]::TopN })
    }

    # Reads the compact top-N JSON the worker wrote (the heavy CSV parse already
    # ran off the UI thread in ExecutionService.ParseAndCacheFolders, so this stays
    # cheap on the dispatcher thread). Returns $null when missing/unparseable.
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
