using module "..\Models\AppConfig.psm1"
using module "..\Models\MachineInventory.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\LogService.psm1"
using module ".\RemoteServices.psm1"

<#
.SYNOPSIS
    Prepares and parses the per-machine inventory probe.

.DESCRIPTION
    The worker gathers laptop-troubleshooting facts over a remote CIM session and
    writes them as JSON, which is parsed here into a [MachineInventory]. Mirrors
    RemoteUpdateService - subclasses RemoteJobService, reusing BuildWorkerArgs.
#>
class InventoryService : RemoteJobService {

    InventoryService([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    InventoryService([AppConfig] $config, [NetworkProbe] $probe,
        [LogService] $logger) : base($config, $probe, $logger) {}

    # Worker args only. No network here: the worker gates reachability.
    # "Inventory" is the worker token, distinct from [JobKind]::Inventory.
    [hashtable] PrepareInventory([string]$hostName) {
        return $this.BuildWorkerArgs($hostName, "Inventory", @{})
    }

    # Reads the copied-back inventory JSON into a typed MachineInventory. Returns $null
    # when missing or unparseable, mirroring RemoteUpdateService.ParseUpdateReport.
    [MachineInventory] ParseInventory([string]$hostName) {
        $reportPath = Join-Path $this.Config.ReportsPath "$hostName-inventory.json"
        if (-not (Test-Path $reportPath)) { return $null }

        try {
            $raw = Get-Content -Path $reportPath -Raw
            $h = $raw | ConvertFrom-Json -AsHashtable
            return [MachineInventory]::FromHashtable([hashtable]$h)
        }
        catch {
            $this.Logger.LogException("Failed to parse inventory report for $hostName", $_)
            return $null
        }
    }

}
