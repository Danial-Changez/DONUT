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
    worker's RunDiskScanPhase), exports a folder CSV whose N largest rows are
    selected on the target before the copy-back, then parsed into a
    [DiskUsageReport]. Mirrors InventoryService - subclasses RemoteJobService,
    reusing BuildWorkerArgs. Heavier than the inventory probe, so it is triggered
    on demand rather than on every scan/apply.
#>
class DiskUsageService : RemoteJobService {

    DiskUsageService([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    DiskUsageService([AppConfig] $config, [NetworkProbe] $probe,
        [LogService] $logger) : base($config, $probe, $logger) {}

    # Worker args for the "DiskScan" job. No network here: the worker gates reachability
    # itself and resolves wiztree64.exe. Options carries the configurable row cap.
    [hashtable] PrepareDiskScan([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "DiskScan", @{ TopN = $this.Config.GetFolderScanCount() })
    }

    # Worker args for the destructive "DeleteFolders" job. Operator-selected paths ride
    # in Options and cross the boundary as JSON, never as a command line.
    [hashtable] PrepareDeleteFolders([string]$hostName, [string[]]$paths) {
        return $this.BuildWorkerArgs($hostName, "DeleteFolders", @{ Paths = $paths })
    }

    # Clearing a machine deletes its report, so reports\ never needs a manual sweep.
    [void] DeleteReport([string]$hostName) {
        $csvPath = Join-Path $this.Config.ReportsPath "$hostName-folders.csv"
        Remove-Item -LiteralPath $csvPath -Force -ErrorAction SilentlyContinue
    }

    # Parses the top-rows CSV the worker copied back into a typed report. Returns $null
    # when no scan has run, and a corrupt file parses to an empty report.
    [DiskUsageReport] ParseDiskUsage([string]$hostName) {
        $csvPath = Join-Path $this.Config.ReportsPath "$hostName-folders.csv"
        if (-not (Test-Path $csvPath)) { return $null }
        return [WizTreeCsv]::ParseTopFoldersFromFile($csvPath, $this.Config.GetFolderScanCount())
    }
}
