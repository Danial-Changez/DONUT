using module "..\Models\AppConfig.psm1"
using module "..\Models\MachineInventory.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\LogService.psm1"
using module ".\RemoteServices.psm1"

# InventoryService
#
# Prepares and parses a per-machine "inventory" probe: a small self-contained
# pwsh script that runs on the remote host (via the worker's PsExec path) and
# writes laptop-troubleshooting facts as JSON, which we copy back and parse into
# a [MachineInventory]. Mirrors ScanService (subclasses RemoteJobService, reuses
# ValidateHostConnectivity / BuildWorkerArgs).
class InventoryService : RemoteJobService {

    InventoryService([AppConfig] $config, [NetworkProbe] $probe) : base($config, $probe) {}

    InventoryService([AppConfig] $config, [NetworkProbe] $probe, [LogService] $logger) : base($config, $probe, $logger) {}

    # Validates connectivity and returns worker args carrying the probe script.
    # The worker dispatches on the "Inventory" token (a worker string, distinct
    # from the [JobKind]::Inventory enum the UI tags the AsyncJob with).
    [hashtable] PrepareInventory([string]$hostName) {
        $this.ValidateHostConnectivity($hostName)
        $script = [InventoryService]::BuildProbeScript($hostName)
        return $this.BuildWorkerArgs($hostName, "Inventory", @{ ScriptText = $script })
    }

    # Reads the copied-back inventory JSON into a typed MachineInventory.
    # Returns $null when the file is missing or unparseable (mirrors
    # RemoteUpdateService.ParseUpdateReport).
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

    # Generates the remote probe script. It gathers identity / battery health /
    # disk / uptime (each call independently guarded so one failure never aborts
    # the probe) and writes <host>-inventory.json to C:\temp\DONUT on the target.
    # The host name is substituted into the filename at generation time so the
    # script needs no parameters and can be run via -EncodedCommand.
    static [string] BuildProbeScript([string]$hostName) {
        $template = @'
$ErrorActionPreference = 'SilentlyContinue'
$dir = 'C:\temp\DONUT'
if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

$inv = [ordered]@{
    model              = $null
    serviceTag         = $null
    biosVersion        = $null
    hasBattery         = $false
    designCapacity     = $null
    fullChargeCapacity = $null
    cycleCount         = $null
    chargePercent      = $null
    charging           = $false
    freeSpaceBytes     = $null
    totalSpaceBytes    = $null
    lastBootTime       = $null
    probedAt           = ([datetime]::UtcNow.ToString('o'))
}

try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop; $inv.model = $cs.Model } catch { }
try {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $inv.serviceTag = $bios.SerialNumber
    $inv.biosVersion = $bios.SMBIOSBIOSVersion
} catch { }

# Battery design/health live in root\wmi (not root\cimv2).
try {
    $static = Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1
    if ($static) { $inv.designCapacity = [int64]$static.DesignedCapacity }
} catch { }
try {
    $full = Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
    if ($full) { $inv.fullChargeCapacity = [int64]$full.FullChargedCapacity }
} catch { }
try {
    $cyc = Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryCycleCount -ErrorAction Stop | Select-Object -First 1
    if ($cyc -and $null -ne $cyc.CycleCount) { $inv.cycleCount = [int]$cyc.CycleCount }
} catch { }

# Presence + current charge from Win32_Battery (BatteryStatus 1 = discharging).
try {
    $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
    if ($bat) {
        $inv.hasBattery = $true
        $inv.chargePercent = [int]$bat.EstimatedChargeRemaining
        $inv.charging = ([int]$bat.BatteryStatus -ne 1)
    }
} catch { }

try {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop | Select-Object -First 1
    if ($disk) {
        $inv.freeSpaceBytes = [int64]$disk.FreeSpace
        $inv.totalSpaceBytes = [int64]$disk.Size
    }
} catch { }

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ($os.LastBootUpTime) { $inv.lastBootTime = $os.LastBootUpTime.ToUniversalTime().ToString('o') }
} catch { }

$inv | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $dir '__HOST__-inventory.json') -Encoding UTF8
'@
        return $template.Replace('__HOST__', $hostName)
    }
}
