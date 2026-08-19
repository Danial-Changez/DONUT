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

    SetOwner shortens to first name + surname initial: a full display name would crowd the
    hostname it sits beside, while a bare first name cannot tell two Daniels apart. It
    handles both directory shapes ("Jane Doe" and "Doe, Jane"). The card renders it in
    brackets and tooltips the full name only when it adds something the short form lacks.
#>
class HostViewModel : ObservableObject {
    [string] $HostName = ''
    [string] $OwnerName = ''           # short owner form, e.g. "Danial C", '' collapses the chip
    [string] $OwnerTip = ''            # full display name, only when it says more than OwnerName
    [string] $Subtitle = 'never run'   # a freshly-added host (not yet in recents) reads this
    [string] $ChipText = ''
    [string] $StatusGlyph = ''   # chip symbol so status reads by shape, not colour alone
    [bool]   $ChipVisible = $false
    [double] $Percent = 0
    [bool]   $ProgressVisible = $false
    [bool]   $ProgressIndeterminate = $false
    [Brush]  $DotBrush
    [Brush]  $ChipForeground
    [Brush]  $ChipBackground
    [Brush]  $ChipBorderBrush
    [object] $RunCommand      # RelayCommand, assigned by the coordinator
    [object] $GatherCommand   # RelayCommand, assigned by the coordinator
    [object] $RemoveCommand   # RelayCommand, assigned by the coordinator (card's X)

    # Sort key: the list's CollectionView sorts on it so attention-worthy machines rise.
    [int]    $SortStatusRank = 4

    # Detail-header and overview bindables, mirrored via SelectedMachine.* from inventory.
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

    # Largest-folders tree: FolderNodeViewModel roots plus an emptiness flag for the hint.
    [object] $Folders = @()
    [bool]   $HasFolders = $false
    hidden [object] $FoldersSource = $null   # last-applied report, to skip no-op rebuilds

    # Available-updates list (DcuUpdate[]), display-only since apply needs a confirm dialog.
    [object] $Updates = @()
    [bool]   $HasUpdates = $false
    [string] $UpdatesIdentityText = ''   # full verdict sentence (identity pill's tooltip)
    [string] $IdentityState = 'Unknown'  # Match / Mismatch / Unknown, which drives the pill

    # The chip and subtitle are rebuilt from these on any status or reachability change.
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
        } else {
            $this.Set('ProgressVisible', $false)
            $this.Set('ProgressIndeterminate', $false)
            $this.Set('Percent', [double]0)
        }
        $this.RefreshShape()
    }

    # Feeds a parsed DCU percentage (0-100) into the bar. The param name avoids the
    # [Percent] property, since a same-name param breaks assignment in PS classes.
    [void] SetPercent([double]$pct) {
        if ($pct -lt 0) { return }
        if ($pct -gt 100) { $pct = 100 }
        $this.Set('ProgressIndeterminate', $false)
        $this.Set('ProgressVisible', $true)
        $this.Set('Percent', $pct)
    }

    # Switches the bar to indeterminate for a phase that reports activity but no
    # sub-percentage, instead of leaving it frozen at the last percent.
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
        } else {
            [TimeFormat]::Relative([TimeFormat]::ParseIso($rc.LastSeen))
        }
        $plural = if ($rc.UpdateCount -ne 1) { 's' } else { '' }
        $this.BaseSubtitle = if ($rc.UpdateCount -gt 0) { "$when - $($rc.UpdateCount) update$plural" } else { $when }

        $this.RenderDot()
        $this.ApplyChip()
        $this.ApplySubtitle()
        $this.RefreshShape()
    }

    # Fills the overview bindables from an inventory probe via the InventoryFormat mappers.
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
                } else { '' }))

        $this.Set('OvDisk', [InventoryFormat]::DiskFreeLabel($inv.FreeSpaceBytes, $inv.TotalSpaceBytes))
        $this.Set('OvDiskSub', [InventoryFormat]::UptimeLabel([TimeFormat]::ParseIso($inv.LastBootTime)))
    }

    # Sets the header subtitle to the resolved IP, since the card already shows freshness.
    [void] SetResolvedIp([string]$ip) {
        if (-not [string]::IsNullOrWhiteSpace($ip)) { $this.CachedIp = $ip }
        $this.Set('DetailIp', $this.CachedIp)
    }

    # Recomputes the sort rank so the CollectionView re-sorts with attention first.
    hidden [void] RefreshShape() {
        $cat = [MachineListShaper]::Categorize($this.ProgressVisible, $this.Reachability, $this.IdleStatus)
        $this.Set('SortStatusRank', [MachineListShaper]::StatusRank($cat))
    }

    # Rebuilds the largest-folders tree from a disk report. A re-applied same instance is
    # skipped so the TreeView keeps its expansion state, and null clears to the hint.
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

    # The dot has two writers (ApplyIdle's tick and SetReachability), so both flow through
    # the list-sort mapper's precedence: attention, offline, online, idle.
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

    # First name plus surname initial ("Danial C"). OwnerTip holds the full name only when
    # it says more than the short form (a bare SAM does not). See .NOTES.
    [void] SetOwner([string]$displayName) {
        $full = ([string]$displayName).Trim()
        # "Doe, Jane" -> first "Jane", surname "Doe". "Jane [M.] Doe" -> first + last token.
        $tokens = if ($full.Contains(',')) {
            $half = $full -split ',\s*', 2
            @(@($half[1] -split '\s+')[0], @($half[0] -split '\s+')[-1])
        } else { @($full -split '\s+') }
        $tokens = @($tokens | Where-Object { $_ })
        $shortForm = [string]$tokens[0]
        if ($tokens.Count -gt 1 -and $tokens[-1].Length -gt 0) {
            $shortForm = "$shortForm $($tokens[-1].Substring(0, 1))"
        }
        $this.Set('OwnerName', $shortForm)
        $this.Set('OwnerTip', $(if ($full -ne $shortForm) { $full } else { '' }))
    }

    hidden [void] ApplySubtitle() {
        if ($this.Reachability -eq 'Offline') {
            $sub = if ([string]::IsNullOrWhiteSpace($this.BaseSubtitle)) { 'offline' }
            else { "$($this.BaseSubtitle)  ·  offline" }
            $this.Set('Subtitle', $sub)
        } else {
            $this.Set('Subtitle', $this.BaseSubtitle)
        }
    }

    # Rebuild only when the key changes, since SolidColorBrush has no value-equality.
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

    # Status symbol so the chip reads by shape, not colour alone (mirrors FleetCardStatus).
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

    # Seeded once from UIColors.xaml so the accents have exactly one source.
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
