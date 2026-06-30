<#
.SYNOPSIS
    Pure DTO + formatting for the per-machine detail panel.

.DESCRIPTION
    The laptop-troubleshooting facts gathered by a remote inventory probe (model,
    Dell service tag, battery health, disk, uptime). MachineInventory is the
    DTO/round-trip; InventoryFormat derives the card labels. WPF-free so the
    calc/format logic is unit-tested and the presenter just renders it. Mirrors
    the FleetStatus / DcuProgress pure-helper pattern.
#>
class MachineInventory {
    [string] $Model = ''
    [string] $ServiceTag = ''
    [string] $BiosVersion = ''
    [bool]   $HasBattery = $false
    [long]   $DesignCapacity = 0
    [long]   $FullChargeCapacity = 0
    [int]    $ChargePercent = -1
    [bool]   $Charging = $false
    [long]   $FreeSpaceBytes = 0
    [long]   $TotalSpaceBytes = 0
    [string] $LastBootTime = ''          # ISO8601, or '' when unknown
    [string] $ProbedAt = ''              # ISO8601 UTC when the probe ran

    # Builds a typed inventory from the raw hashtable parsed out of the probe's
    # JSON (or a cached recent-connection entry). Tolerates missing/null keys.
    static [MachineInventory] FromHashtable([hashtable]$h) {
        $mi = [MachineInventory]::new()
        if ($null -eq $h) { return $mi }
        $mi.Model              = [string]$h['model']
        $mi.ServiceTag         = [string]$h['serviceTag']
        $mi.BiosVersion        = [string]$h['biosVersion']
        $mi.HasBattery         = [bool]$h['hasBattery']
        $mi.DesignCapacity     = [MachineInventory]::AsLong($h['designCapacity'])
        $mi.FullChargeCapacity = [MachineInventory]::AsLong($h['fullChargeCapacity'])
        $mi.ChargePercent      = [MachineInventory]::AsInt($h['chargePercent'], -1)
        $mi.Charging           = [bool]$h['charging']
        $mi.FreeSpaceBytes     = [MachineInventory]::AsLong($h['freeSpaceBytes'])
        $mi.TotalSpaceBytes    = [MachineInventory]::AsLong($h['totalSpaceBytes'])
        $mi.LastBootTime       = [string]$h['lastBootTime']
        $mi.ProbedAt           = [string]$h['probedAt']
        return $mi
    }

    # Flattens to a plain hashtable (the same shape as the probe JSON) so it can
    # be cached in the recents store and round-trip through ConvertTo/FromJson.
    [hashtable] ToHashtable() {
        return @{
            model              = $this.Model
            serviceTag         = $this.ServiceTag
            biosVersion        = $this.BiosVersion
            hasBattery         = $this.HasBattery
            designCapacity     = $this.DesignCapacity
            fullChargeCapacity = $this.FullChargeCapacity
            chargePercent      = $this.ChargePercent
            charging           = $this.Charging
            freeSpaceBytes     = $this.FreeSpaceBytes
            totalSpaceBytes    = $this.TotalSpaceBytes
            lastBootTime       = $this.LastBootTime
            probedAt           = $this.ProbedAt
        }
    }

    hidden static [long] AsLong([object]$v) {
        if ($null -eq $v) { return 0 }
        $out = [long]0
        if ([long]::TryParse([string]$v, [ref]$out)) { return $out }
        return 0
    }

    hidden static [int] AsInt([object]$v, [int]$default) {
        if ($null -eq $v) { return $default }
        $out = [int]0
        if ([int]::TryParse([string]$v, [ref]$out)) { return $out }
        return $default
    }
}

# Pure formatting/derivation for the detail-panel cards. Static, WPF-free, tested.
class InventoryFormat {
    # Battery health as a percentage of original design capacity: how much the
    # battery still holds at full charge vs. when new. Returns -1 ("no data") when
    # either capacity is missing/zero. Clamped to 0..100.
    static [int] BatteryHealthPercent([double]$design, [double]$fullCharge) {
        if ($design -le 0 -or $fullCharge -le 0) { return -1 }
        $pct = [int][Math]::Round(($fullCharge / $design) * 100.0)
        if ($pct -lt 0) { return 0 }
        if ($pct -gt 100) { return 100 }
        return $pct
    }

    # One-line battery-health summary for the card.
    static [string] BatteryHealthLabel([bool]$hasBattery, [int]$healthPct) {
        if (-not $hasBattery) { return 'No battery (desktop / AC)' }
        if ($healthPct -lt 0) { return '— (no battery data)' }
        return "$healthPct% health"
    }

    # Free / total disk on C: as GB. '—' when total is unknown.
    static [string] DiskFreeLabel([double]$freeBytes, [double]$totalBytes) {
        if ($totalBytes -le 0) { return '—' }
        $gb = 1073741824.0   # 1024^3
        $free = [Math]::Round($freeBytes / $gb, 1)
        $total = [Math]::Round($totalBytes / $gb, 1)
        $ci = [System.Globalization.CultureInfo]::InvariantCulture
        return "$($free.ToString($ci)) GB free of $($total.ToString($ci)) GB"
    }

    # Uptime phrased from the last boot time. '—' for an unknown (MinValue) boot.
    static [string] UptimeLabel([datetime]$lastBoot) {
        if ($lastBoot -eq [datetime]::MinValue) { return '—' }
        $bootUtc = if ($lastBoot.Kind -eq [System.DateTimeKind]::Utc) { $lastBoot } else { $lastBoot.ToUniversalTime() }
        $span = [datetime]::UtcNow - $bootUtc
        if ($span.TotalSeconds -lt 0) { return 'just booted' }
        if ($span.TotalMinutes -lt 60) { return "up $([int]$span.TotalMinutes) min" }
        if ($span.TotalHours -lt 24) { return "up $([int]$span.TotalHours) hr" }
        $days = [int]$span.TotalDays
        return "up $days day$(if ($days -ne 1) { 's' })"
    }
}
