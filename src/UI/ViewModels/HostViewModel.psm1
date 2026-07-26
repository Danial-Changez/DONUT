using namespace Donut.Mvvm
using namespace System.Windows.Media
using module "..\..\Models\FleetCardStatus.psm1"
using module "..\..\Models\MachineListShaper.psm1"
using module "..\..\Models\RecentConnection.psm1"
using module "..\..\Models\MachineInventory.psm1"
using module "..\..\Models\DiskUsage.psm1"
using module "..\..\Core\TimeFormat.psm1"
using module ".\FolderNodeViewModel.psm1"

<#
.SYNOPSIS
    View-model for one machine row in the Home list, plus the detail pane it mirrors.

.DESCRIPTION
    Inherits the C# ObservableObject base so WPF binds to it and updates live when the
    coordinator (HomePresenter) sets its properties on the UI thread. Exposes ready-to-bind
    values (labels, visibility bools, and Brushes) so the DataTemplate stays plain; the
    status/colour DECISIONS reuse the tested pure mappers ([FleetCardStatus] while a job runs,
    the idle mappers below when one isn't).

.NOTES
    Row brushes come from the static Palette that HomePresenter seeds out of
    UIColors.xaml (presenter resolves, VM holds, view binds - no duplicated hexes).
    RunCommand / GatherCommand are assigned by the coordinator after construction.
#>
class HostViewModel : ObservableObject {
    [string] $HostName = ''
    [string] $Subtitle = 'never run'   # a freshly-added host (not yet in recents) reads this
    [string] $ChipText = ''
    [string] $StatusGlyph = ''   # chip symbol so status reads by shape, not colour alone
    [bool]   $ChipVisible = $false
    [double] $Percent = 0
    [bool]   $ProgressVisible = $false
    [bool]   $ProgressIndeterminate = $false
    [string] $StepText = ''   # live milestone beside the bar, e.g. "2/5 scanning devices"
    [Brush]  $DotBrush
    [Brush]  $ChipForeground
    [Brush]  $ChipBackground
    [Brush]  $ChipBorderBrush
    [Brush]  $ProgressBrush
    [object] $RunCommand      # RelayCommand, assigned by the coordinator
    [object] $GatherCommand   # RelayCommand, assigned by the coordinator

    # Machine-list sort key (maintained by RefreshShape): the Home list's CollectionView sorts
    # on SortStatusRank (then HostName), so attention-worthy machines rise to the top.
    [int]    $SortStatusRank = 4

    # Detail-header + overview-strip bindables: both mirror the selected machine via
    # SelectedMachine.*, populated from inventory by ApplyInventory.
    [string] $DetailTitle = ''
    [string] $DetailIp = ''   # resolved IP under the hostname (freshness lives on the card)
    [string] $OvModel = '—'
    [string] $OvModelSub = 'double-click to gather inventory'
    [string] $OvBattery = '—'
    [string] $OvBatterySub = ''
    [string] $OvDisk = '—'
    [string] $OvDiskSub = ''
    [string] $OvBios = '—'   # current system BIOS/firmware version (from the inventory probe)
    hidden [string] $CachedIp = ''   # last resolved IP, kept across re-renders

    # Largest-folders tree (bound by the detail pane's TreeView via SelectedMachine.Folders):
    # display-ready FolderNodeViewModel roots + an emptiness flag for the hint text.
    [object] $Folders = @()
    [bool]   $HasFolders = $false
    hidden [object] $FoldersSource = $null   # last-applied report, to skip no-op rebuilds

    # Available-updates list (DcuUpdate[]) shown in the detail pane after an apply-updates scan.
    # Display-only (apply is gated by a confirm dialog); HasUpdates gates the section + folders.
    [object] $Updates = @()
    [bool]   $HasUpdates = $false
    [string] $UpdatesIdentityText = ''   # full verdict sentence (identity pill's tooltip)
    [string] $IdentityState = 'Unknown'  # Match / Mismatch / Unknown - drives the pill

    # Backing state for idle/reachability recomposition: the chip/subtitle are rebuilt
    # from these whenever either the stored status or the live reachability changes.
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

    # --- Live job status (running / terminal), from a pure FleetCardStatus ---
    [void] ApplyStatus([FleetCardStatus]$status) {
        $this.SetDotKey($status.ColorKey)
        $this.SetChipKey($status.ColorKey)
        $this.Set('ChipText', $status.Label)
        $this.Set('StatusGlyph', $status.Glyph)
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
            $this.Set('StepText', '')
        }
        $this.RefreshShape()
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

    # Shows a scan milestone beside the bar ("2/5 scanning devices"); $pct also drives the
    # bar for percent-less jobs (a scan), or -1 leaves it alone (an apply owns its bar).
    [void] SetScanStep([string]$text, [double]$pct) {
        $this.Set('StepText', $text)
        if ($pct -ge 0) { $this.SetPercent($pct) }
    }

    # Switches the bar to an animated indeterminate state for a phase that reports activity but
    # no sub-percentage (a dcu-cli install), instead of leaving it frozen at the last percent.
    [void] SetIndeterminate() {
        $this.Set('ProgressVisible', $true)
        $this.Set('ProgressIndeterminate', $true)
    }

    # --- Idle (persisted) state, from a stored RecentConnection ---
    [void] ApplyIdle([RecentConnection]$rc) {
        $this.IdleStatus = $rc.LastStatus
        $this.Set('ProgressVisible', $false)
        $this.Set('ProgressIndeterminate', $false)
        $this.Set('Percent', [double]0)

        $when = if ([string]::IsNullOrWhiteSpace($rc.LastSeen)) {
            'never run'
        }
        else {
            [TimeFormat]::Relative([TimeFormat]::ParseIso($rc.LastSeen))
        }
        $this.BaseSubtitle = if ($rc.UpdateCount -gt 0) { "$when - $($rc.UpdateCount) update(s)" } else { $when }

        $this.RenderDot()
        $this.ApplyChip()
        $this.ApplySubtitle()

        # Populate the overview strip from the cached record so selecting the row shows its
        # facts immediately (no re-probe needed).
        if ($null -ne $rc.Inventory) { $this.ApplyInventory($rc.Inventory) }
        $this.RefreshShape()
    }

    # Fills the overview-strip / probed bindables from an inventory probe (cached or
    # fresh), reusing the pure InventoryFormat mappers.
    [void] ApplyInventory([MachineInventory]$inv) {
        if ($null -eq $inv) { return }
        $this.Set('OvModel', $(if ($inv.Model) { $inv.Model } else { '—' }))
        $this.Set('OvModelSub', $(if ($inv.ServiceTag) { "Tag $($inv.ServiceTag)" } else { $this.HostName }))
        $this.Set('OvBios', $(if ($inv.BiosVersion) { $inv.BiosVersion } else { '—' }))

        $health = [InventoryFormat]::BatteryHealthPercent($inv.DesignCapacity, $inv.FullChargeCapacity)
        $this.Set('OvBattery', [InventoryFormat]::BatteryHealthLabel($inv.HasBattery, $health))
        $this.Set('OvBatterySub', $(
                if ($inv.HasBattery -and $inv.ChargePercent -ge 0) {
                    $state = if ($inv.Charging) { 'charging' } else { 'on battery' }
                    "$($inv.ChargePercent)% - $state"
                }
                else { '' }))

        $this.Set('OvDisk', [InventoryFormat]::DiskFreeLabel($inv.FreeSpaceBytes, $inv.TotalSpaceBytes))
        $this.Set('OvDiskSub', [InventoryFormat]::UptimeLabel([TimeFormat]::ParseIso($inv.LastBootTime)))
    }

    # Sets the detail-header subtitle to the resolved IP (Reduction: probe freshness
    # already shows on the machine card, so the pane doesn't repeat it).
    [void] SetResolvedIp([string]$ip) {
        if (-not [string]::IsNullOrWhiteSpace($ip)) { $this.CachedIp = $ip }
        $this.Set('DetailIp', $this.CachedIp)
    }

    # Recompute the list sort rank from the current running/reachability/idle state; called
    # whenever any of those change so the CollectionView re-sorts (attention first).
    hidden [void] RefreshShape() {
        $cat = [MachineListShaper]::Categorize($this.ProgressVisible, $this.Reachability, $this.IdleStatus)
        $this.Set('SortStatusRank', [MachineListShaper]::StatusRank($cat))
    }

    # Rebuilds the largest-folders tree from a disk report; a re-applied same instance
    # is skipped (TreeView keeps its expansion state), and null/empty clears to the hint.
    [void] ApplyFolders([DiskUsageReport]$report) {
        if ($null -ne $report -and [object]::ReferenceEquals($this.FoldersSource, $report)) { return }
        $this.FoldersSource = $report
        $roots = [FolderNodeViewModel]::FromReport($report)
        $this.Set('Folders', $roots)
        $this.Set('HasFolders', ($roots.Count -gt 0))
    }

    # Reflects the background reachability verdict on an idle row (offline => red dot +
    # "Offline" chip + subtitle tag). Online/Unknown restores the idle rendering.
    [void] SetReachability([string]$state) {
        $this.Reachability = $state
        $this.RenderDot()
        $this.ApplyChip()
        $this.ApplySubtitle()
        $title = if ($state -eq 'Offline') { "$($this.HostName)  -  offline" }
        else { $this.HostName }
        $this.Set('DetailTitle', $title)
        $this.RefreshShape()
    }

    # --- Internal composition helpers ---

    # The dot has TWO writers (ApplyIdle every 30s tick, SetReachability on verdicts);
    # both flow through this one precedence so neither can clobber the other. It derives
    # from the same pure mapper as the list sort: attention > offline > online > idle.
    hidden [void] RenderDot() {
        $cat = [MachineListShaper]::Categorize($false, $this.Reachability, $this.IdleStatus)
        $key = switch ($cat) {
            'Offline' { 'AccentRed' }
            'Online' { 'AccentGreen' }
            default { [HostViewModel]::IdleColorKey($this.IdleStatus) }
        }
        $this.SetDotKey($key)
    }

    hidden [void] ApplyChip() {
        $status = if ($this.Reachability -eq 'Offline') { 'Offline' } else { $this.IdleStatus }
        if ([string]::IsNullOrWhiteSpace($status)) {
            $this.Set('ChipVisible', $false)
            return
        }
        $this.SetChipKey([HostViewModel]::IdleColorKey($status))
        $this.Set('ChipText', [HostViewModel]::HumanStatus($status))
        $this.Set('StatusGlyph', [HostViewModel]::StatusGlyph($status))
        $this.Set('ChipVisible', $true)
    }

    hidden [void] ApplySubtitle() {
        if ($this.Reachability -eq 'Offline') {
            $sub = if ([string]::IsNullOrWhiteSpace($this.BaseSubtitle)) { 'offline' }
            else { "$($this.BaseSubtitle)  ·  offline" }
            $this.Set('Subtitle', $sub)
        }
        else {
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
        $this.Set('ChipBorderBrush', [HostViewModel]::TintBorderFor($key))
        $this.Set('ProgressBrush', [HostViewModel]::BrushFor($key))
    }

    # --- Pure status mapping (idle rows; running rows go through FleetCardStatus) ---------

    static [string] IdleColorKey([string]$lastStatus) {
        switch ($lastStatus) {
            'Completed' { return 'AccentGreen' }
            'Failed' { return 'AccentRed' }
            'RebootRequired' { return 'AccentYellow' }
            'ConnectionLost' { return 'AccentOrange' }
            'Offline' { return 'AccentRed' }
            default { return 'BodyTextTertiary' }
        }
        return 'BodyTextTertiary'
    }

    static [string] HumanStatus([string]$lastStatus) {
        switch ($lastStatus) {
            'RebootRequired' { return 'Reboot required' }
            'ConnectionLost' { return 'Unconfirmed' }
            default { return $lastStatus }
        }
        return $lastStatus
    }

    # Status symbol for idle rows so the chip reads by shape, not colour alone (mirrors
    # the glyphs FleetCardStatus assigns to running rows).
    static [string] StatusGlyph([string]$lastStatus) {
        switch ($lastStatus) {
            'Completed' { return '✓' }
            'Failed' { return '✕' }
            'Offline' { return '✕' }
            'RebootRequired' { return '⚠' }
            'ConnectionLost' { return '?' }
            default { return '' }
        }
        return ''
    }

    # Palette seeded once by HomePresenter.SeedRowPalette from UIColors.xaml so the
    # accents have exactly one source; key -> @{ Brush; Tint; TintBorder }, all frozen.
    static [hashtable] $Palette = @{}

    static [void] SetPalette([hashtable]$palette) {
        [HostViewModel]::Palette = if ($null -ne $palette) { $palette } else { @{} }
    }

    static [Brush] BrushFor([string]$key) {
        $entry = [HostViewModel]::Palette[$key]
        if ($entry) { return $entry.Brush }
        return [Brushes]::Gray   # unseeded palette / unknown key: visible but neutral
    }

    # Chip background = the accent at 10% alpha (Arcane's status-badge fill).
    static [Brush] TintFor([string]$key) {
        $entry = [HostViewModel]::Palette[$key]
        if ($entry) { return $entry.Tint }
        return [Brushes]::Transparent
    }

    # Chip border = the accent at 30% alpha (the badge's hairline edge).
    static [Brush] TintBorderFor([string]$key) {
        $entry = [HostViewModel]::Palette[$key]
        if ($entry) { return $entry.TintBorder }
        return [Brushes]::Transparent
    }
}
