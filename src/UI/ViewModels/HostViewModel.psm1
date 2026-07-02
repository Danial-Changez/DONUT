using namespace Donut.Mvvm
using namespace System.Windows.Media
using module "..\..\Models\FleetStatus.psm1"
using module "..\..\Models\RecentConnection.psm1"
using module "..\..\Models\MachineInventory.psm1"
using module "..\..\Core\TimeFormat.psm1"

<#
.SYNOPSIS
    View-model for one machine row in the Home list (MVVM replacement for ConnectionRow).

.DESCRIPTION
    Inherits the C# ObservableObject base so WPF binds to it and updates live when the
    coordinator (HomePresenter) sets its properties on the UI thread. Exposes ready-to-bind
    values (labels, visibility bools, and Brushes) so the DataTemplate stays plain; the
    status/colour DECISIONS reuse the tested pure mappers ([FleetStatus] for running, the
    idle mappers below - carried over from ConnectionRow).

.NOTES
    Brushes are built from the accent hexes in UIColors.xaml (kept in sync here; the app
    runs without a WPF Application, so a converter can't resolve resource keys). RunCommand
    / GatherCommand are assigned by the coordinator after construction.
#>
class HostViewModel : ObservableObject {
    [string] $HostName = ''
    [string] $Subtitle = 'never run'   # a freshly-added host (not yet in recents) reads this
    [string] $ChipText = ''
    [bool]   $ChipVisible = $false
    [double] $Percent = 0
    [bool]   $ProgressVisible = $false
    [bool]   $ProgressIndeterminate = $false
    [Brush]  $DotBrush
    [Brush]  $ChipForeground
    [Brush]  $ChipBackground
    [Brush]  $ProgressBrush
    [object] $RunCommand      # RelayCommand, assigned by the coordinator
    [object] $GatherCommand   # RelayCommand, assigned by the coordinator

    # Detail-header + overview-strip bindables (the detail pane / overview mirror the
    # SELECTED machine, so they bind to SelectedMachine.* - populated from cached/gathered
    # inventory via ApplyInventory, reusing the pure InventoryFormat mappers).
    [string] $DetailTitle = ''
    [string] $ProbedText = ''
    [string] $OvModel = '—'
    [string] $OvModelSub = 'double-click to gather inventory'
    [string] $OvBattery = '—'
    [string] $OvBatterySub = ''
    [string] $OvDisk = '—'
    [string] $OvDiskSub = ''
    [string] $OvUpdates = '0'
    [string] $OvUpdatesSub = 'pending update(s)'
    hidden [string] $CachedIp = ''   # last resolved IP, for ProbedText recomposition

    # Backing state for idle/reachability recomposition (mirrors ConnectionRow).
    hidden [string] $BaseSubtitle = 'never run'
    hidden [string] $IdleStatus = ''
    hidden [string] $Reachability = 'Unknown'
    hidden [string] $DotKey = 'BodyTextTertiary'
    hidden [string] $ChipKey = 'BodyTextTertiary'

    HostViewModel([string]$hostName) {
        $this.HostName = $hostName
        $this.DetailTitle = $hostName
        $this.DotBrush = [HostViewModel]::BrushFor('BodyTextTertiary')
    }

    # ---- Live job status (running / terminal), from a pure FleetStatus ----
    [void] ApplyStatus([FleetStatus]$status) {
        $this.SetDotKey($status.ColorKey)
        $this.SetChipKey($status.ColorKey)
        $this.Set('ChipText', $status.Label)
        $this.Set('ChipVisible', $true)

        if ($status.IsBusy) {
            $this.Set('Subtitle', 'running now')
            $this.Set('ProgressVisible', $true)
            # Indeterminate until a percentage arrives (SetPercent flips it off).
            if ($this.Percent -le 0) { $this.Set('ProgressIndeterminate', $true) }
        }
        else {
            $this.Set('ProgressVisible', $false)
            $this.Set('ProgressIndeterminate', $false)
            $this.Set('Percent', [double]0)
        }
    }

    # Feeds a parsed DCU percentage (0-100) into the bar. (Param name avoids colliding
    # with the [Percent] property - a same-name param breaks assignment in PS classes.)
    [void] SetPercent([double]$pct) {
        if ($pct -lt 0) { return }
        if ($pct -gt 100) { $pct = 100 }
        $this.Set('ProgressIndeterminate', $false)
        $this.Set('ProgressVisible', $true)
        $this.Set('Percent', $pct)
    }

    # ---- Idle (persisted) state, from a stored RecentConnection ----
    [void] ApplyIdle([RecentConnection]$rc) {
        $this.IdleStatus = $rc.LastStatus
        $this.Set('ProgressVisible', $false)
        $this.Set('ProgressIndeterminate', $false)
        $this.Set('Percent', [double]0)

        $when = if ([string]::IsNullOrWhiteSpace($rc.LastSeen)) {
            'never run'
        } else {
            [TimeFormat]::Relative([RecentConnectionsStore]::ParseSeen($rc.LastSeen))
        }
        $this.BaseSubtitle = if ($rc.UpdateCount -gt 0) { "$when - $($rc.UpdateCount) update(s)" } else { $when }

        $this.SetDotKey([HostViewModel]::IdleColorKey($rc.LastStatus))
        $this.ApplyChip()
        $this.ApplySubtitle()

        # Populate the overview strip from the cached record so selecting the row shows its
        # facts immediately (no re-probe needed).
        $this.SetPendingUpdates($rc.UpdateCount)
        if ($null -ne $rc.Inventory) { $this.ApplyInventory($rc.Inventory) }
    }

    # Fills the overview-strip / probed bindables from an inventory probe (cached or fresh),
    # reusing the pure InventoryFormat mappers. The overview binds to SelectedMachine.*, so
    # this updates the UI whenever the selected host's inventory changes.
    [void] ApplyInventory([MachineInventory]$inv) {
        if ($null -eq $inv) { return }
        $this.Set('OvModel', $(if ($inv.Model) { $inv.Model } else { '—' }))
        $this.Set('OvModelSub', $(if ($inv.ServiceTag) { "Tag $($inv.ServiceTag)" } else { $this.HostName }))

        $health = [InventoryFormat]::BatteryHealthPercent($inv.DesignCapacity, $inv.FullChargeCapacity)
        $this.Set('OvBattery', [InventoryFormat]::BatteryHealthLabel($inv.HasBattery, $health))
        $this.Set('OvBatterySub', $(
            if ($inv.HasBattery -and $inv.ChargePercent -ge 0) {
                $state = if ($inv.Charging) { 'charging' } else { 'on battery' }
                "$($inv.ChargePercent)% - $state"
            } else { '' }))

        $this.Set('OvDisk', [InventoryFormat]::DiskFreeLabel($inv.FreeSpaceBytes, $inv.TotalSpaceBytes))
        $this.Set('OvDiskSub', [InventoryFormat]::UptimeLabel([RecentConnectionsStore]::ParseSeen($inv.LastBootTime)))

        $this.SetProbed($this.CachedIp, $inv.ProbedAt)
    }

    # Sets the detail-header subtitle: the resolved IP plus the probe freshness (either part
    # omitted when unknown). $ip is remembered so a later probe keeps showing it.
    [void] SetProbed([string]$ip, [string]$probedIso) {
        if (-not [string]::IsNullOrWhiteSpace($ip)) { $this.CachedIp = $ip }
        $probed = if ([string]::IsNullOrWhiteSpace($probedIso)) { '' } else {
            "probed " + [TimeFormat]::Relative([RecentConnectionsStore]::ParseSeen($probedIso))
        }
        $this.Set('ProbedText', $(
            if (-not [string]::IsNullOrWhiteSpace($this.CachedIp)) {
                if ($probed) { "$($this.CachedIp)  ·  $probed" } else { $this.CachedIp }
            } else { $probed }))
    }

    [void] SetPendingUpdates([int]$count) {
        $this.Set('OvUpdates', "$count")
    }

    # Reflects the background reachability verdict on an idle row (offline => red dot +
    # "Offline" chip + subtitle tag). Online/Unknown restores the idle rendering.
    [void] SetReachability([string]$state) {
        $this.Reachability = $state
        switch ($state) {
            'Online'  { $this.SetDotKey('AccentGreen') }
            'Offline' { $this.SetDotKey('AccentRed') }
            default   { }
        }
        $this.ApplyChip()
        $this.ApplySubtitle()
        $this.Set('DetailTitle', $(if ($state -eq 'Offline') { "$($this.HostName)  -  offline" } else { $this.HostName }))
    }

    # ---- internal composition helpers ----

    hidden [void] ApplyChip() {
        $status = if ($this.Reachability -eq 'Offline') { 'Offline' } else { $this.IdleStatus }
        if ([string]::IsNullOrWhiteSpace($status)) {
            $this.Set('ChipVisible', $false)
            return
        }
        $this.SetChipKey([HostViewModel]::IdleColorKey($status))
        $this.Set('ChipText', [HostViewModel]::HumanStatus($status))
        $this.Set('ChipVisible', $true)
    }

    hidden [void] ApplySubtitle() {
        if ($this.Reachability -eq 'Offline') {
            $this.Set('Subtitle', $(if ([string]::IsNullOrWhiteSpace($this.BaseSubtitle)) { 'offline' } else { "$($this.BaseSubtitle)  ·  offline" }))
        } else {
            $this.Set('Subtitle', $this.BaseSubtitle)
        }
    }

    # Only rebuild the dot brush when the key actually changes (avoids brush churn, since
    # SolidColorBrush has no value-equality).
    hidden [void] SetDotKey([string]$key) {
        if ($this.DotKey -eq $key) { return }
        $this.DotKey = $key
        $this.Set('DotBrush', [HostViewModel]::BrushFor($key))
    }

    hidden [void] SetChipKey([string]$key) {
        if ($this.ChipKey -eq $key) { return }
        $this.ChipKey = $key
        $this.Set('ChipForeground', [HostViewModel]::BrushFor($key))
        $this.Set('ChipBackground', [HostViewModel]::TintFor($key))
        $this.Set('ProgressBrush', [HostViewModel]::BrushFor($key))
    }

    # --- Pure status mapping (carried over verbatim from ConnectionRow) ---------------

    static [string] IdleColorKey([string]$lastStatus) {
        switch ($lastStatus) {
            'Completed'      { return 'AccentGreen' }
            'Failed'         { return 'AccentRed' }
            'RebootRequired' { return 'AccentYellow' }
            'ConnectionLost' { return 'AccentOrange' }
            'Offline'        { return 'AccentRed' }
            default          { return 'BodyTextTertiary' }
        }
        return 'BodyTextTertiary'
    }

    static [string] HumanStatus([string]$lastStatus) {
        switch ($lastStatus) {
            'RebootRequired' { return 'Reboot required' }
            'ConnectionLost' { return 'Unconfirmed' }
            default          { return $lastStatus }
        }
        return $lastStatus
    }

    # Accent hexes mirror UIColors.xaml. Kept here because the app has no WPF Application,
    # so resource-key lookup isn't available to a value-less view-model.
    static [hashtable] $Accents = @{
        AccentGreen      = '#22C55E'
        AccentRed        = '#EF4444'
        AccentYellow     = '#FBBF24'
        AccentOrange     = '#FB923C'
        AccentCyan       = '#38BDF8'
        AccentPurple     = '#8B5CF6'
        BodyTextTertiary = '#525252'
    }

    static [Brush] BrushFor([string]$key) {
        $hex = [HostViewModel]::Accents[$key]
        if (-not $hex) { $hex = [HostViewModel]::Accents['BodyTextTertiary'] }
        $b = [SolidColorBrush]::new([Color]([ColorConverter]::ConvertFromString($hex)))
        $b.Freeze()
        return $b
    }

    # Chip background = accent at ~15% alpha (matches ConnectionRow's runtime tint).
    static [Brush] TintFor([string]$key) {
        $hex = [HostViewModel]::Accents[$key]
        if (-not $hex) { $hex = [HostViewModel]::Accents['BodyTextTertiary'] }
        $c = [Color]([ColorConverter]::ConvertFromString($hex))
        $b = [SolidColorBrush]::new([Color]::FromArgb(38, $c.R, $c.G, $c.B))
        $b.Freeze()
        return $b
    }
}
