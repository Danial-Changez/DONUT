using namespace System.Windows
using namespace System.Windows.Controls
using namespace System.Windows.Media
using namespace System.Windows.Media.Animation
using namespace System.Windows.Shapes
using module "..\..\Models\FleetStatus.psm1"
using module "..\..\Models\RecentConnection.psm1"
using module "..\..\Core\TimeFormat.psm1"

<#
.SYNOPSIS
    A full-width machine row in the Home list (TeamViewer-style).

.DESCRIPTION
    One row per machine; it serves double duty as both a persisted "recent
    connection" (idle state, via SetIdleFrom) and a live run (SetStatus/SetPercent
    while a job is in flight). Built in code, consistent with the passive-view
    pattern. Pure status semantics (label/colour/busy) come from [FleetStatus].

.NOTES
    Interaction: single-clicking the row body selects it (the presenter opens the
    detail panel from cache; no network); double-clicking gathers fresh inventory;
    the Run button is the ONLY way to execute a scan/update, so a stray click
    never kicks off a remote run. The live job log/output lives in the detail
    panel, not in the row.
#>
class ConnectionRow {
    [string]      $HostName
    [Border]      $Root          # element added to the machine list
    [scriptblock] $RunAction     # set by presenter; runs the active config (Run button only)
    [scriptblock] $SelectAction  # set by presenter; opens the detail panel (single click)
    [scriptblock] $GatherAction  # set by presenter; gathers inventory (double click)

    hidden [Ellipse]     $Dot
    hidden [TextBlock]   $Subtitle
    hidden [Border]      $ChipBg
    hidden [TextBlock]   $ChipText
    hidden [ProgressBar] $Progress
    hidden [Button]      $RunButton
    hidden [bool]        $Selected
    hidden [double]      $LastPercent = -1   # last % parsed from DCU output (-1 = unknown)
    hidden [string]      $BaseSubtitle = ''  # idle subtitle before the reachability suffix
    hidden [string]      $Reachability = 'Unknown'  # 'Online' | 'Offline' | 'Unknown'
    hidden [string]      $IdleStatus = ''           # last job status, to restore the chip after offline

    ConnectionRow([string]$hostName) {
        $this.HostName = $hostName
        $this.Build()
    }

    hidden [void] Build() {
        $this.Root = [Border]::new()
        $this.Root.Margin = [Thickness]::new(0, 0, 0, 8)
        $this.Root.CornerRadius = [CornerRadius]::new(10)
        $this.Root.BorderThickness = [Thickness]::new(1)
        # subtly elevated above the #171717 card; neutral (Arcane) not zinc
        $this.Root.Background = [SolidColorBrush]::new([Color]::FromRgb(0x1F, 0x1F, 0x1F))
        $this.Root.BorderBrush = $this.Brush('PanelBorder', [Color]::FromArgb(0x1A, 0xFF, 0xFF, 0xFF))
        $this.Root.HorizontalAlignment = [HorizontalAlignment]::Stretch

        # ---- Header (clickable body: selects the host) ----
        $header = [Border]::new()
        $header.Background = [Brushes]::Transparent
        $header.Padding = [Thickness]::new(14, 10, 8, 10)
        $header.Cursor = [System.Windows.Input.Cursors]::Hand
        $this.Root.Child = $header

        $grid = [Grid]::new()
        foreach ($w in @(
            [GridLength]::new(0, [GridUnitType]::Auto),   # dot
            [GridLength]::new(1, [GridUnitType]::Star),   # name + subtitle
            [GridLength]::new(0, [GridUnitType]::Auto),   # progress
            [GridLength]::new(0, [GridUnitType]::Auto),   # chip
            [GridLength]::new(0, [GridUnitType]::Auto)    # run button
        )) {
            $col = [ColumnDefinition]::new(); $col.Width = $w
            $grid.ColumnDefinitions.Add($col)
        }
        $header.Child = $grid

        # Status dot
        $this.Dot = [Ellipse]::new()
        $this.Dot.Width = 10
        $this.Dot.Height = 10
        $this.Dot.Margin = [Thickness]::new(0, 0, 12, 0)
        $this.Dot.VerticalAlignment = [VerticalAlignment]::Center
        [Grid]::SetColumn($this.Dot, 0)
        $grid.Children.Add($this.Dot)

        # Name + subtitle
        $info = [StackPanel]::new()
        $info.Orientation = [Orientation]::Vertical
        $info.VerticalAlignment = [VerticalAlignment]::Center
        [Grid]::SetColumn($info, 1)
        $grid.Children.Add($info)

        $nameBlock = [TextBlock]::new()
        $nameBlock.Text = $this.HostName
        $nameBlock.Foreground = $this.Brush('TitleTextPrimary', [Colors]::White)
        $nameBlock.FontFamily = [FontFamily]::new('Montserrat')
        $nameBlock.FontWeight = [FontWeights]::SemiBold
        $nameBlock.FontSize = 14
        $nameBlock.TextTrimming = [TextTrimming]::CharacterEllipsis
        $info.Children.Add($nameBlock)

        $this.Subtitle = [TextBlock]::new()
        $this.Subtitle.Foreground = $this.Brush('BodyTextTertiary', [Colors]::Gray)
        $this.Subtitle.FontFamily = [FontFamily]::new('Montserrat')
        $this.Subtitle.FontSize = 11.5
        $this.Subtitle.TextTrimming = [TextTrimming]::CharacterEllipsis
        $info.Children.Add($this.Subtitle)

        # Live progress (hidden until running)
        $this.Progress = [ProgressBar]::new()
        $this.Progress.Width = 120
        $this.Progress.Height = 4
        $this.Progress.Margin = [Thickness]::new(12, 0, 12, 0)
        $this.Progress.VerticalAlignment = [VerticalAlignment]::Center
        $this.Progress.Minimum = 0
        $this.Progress.Maximum = 100
        $this.Progress.Background = [SolidColorBrush]::new([Color]::FromArgb(120, 0x3F, 0x3F, 0x46))
        $this.Progress.BorderThickness = [Thickness]::new(0)
        $this.Progress.Visibility = [Visibility]::Collapsed
        [Grid]::SetColumn($this.Progress, 2)
        $grid.Children.Add($this.Progress)

        # State chip
        $this.ChipBg = [Border]::new()
        $this.ChipBg.CornerRadius = [CornerRadius]::new(8)
        $this.ChipBg.Padding = [Thickness]::new(10, 3, 10, 3)
        $this.ChipBg.VerticalAlignment = [VerticalAlignment]::Center
        $this.ChipBg.Margin = [Thickness]::new(0, 0, 8, 0)
        [Grid]::SetColumn($this.ChipBg, 3)
        $grid.Children.Add($this.ChipBg)

        $this.ChipText = [TextBlock]::new()
        $this.ChipText.FontFamily = [FontFamily]::new('Montserrat')
        $this.ChipText.FontWeight = [FontWeights]::SemiBold
        $this.ChipText.FontSize = 11
        $this.ChipBg.Child = $this.ChipText

        # Run button (executes the active config for this host)
        $this.RunButton = [Button]::new()
        $this.RunButton.Content = 'Run'
        $this.RunButton.FontFamily = [FontFamily]::new('Montserrat')
        $this.RunButton.FontWeight = [FontWeights]::Medium
        $this.RunButton.FontSize = 11.5
        $this.RunButton.Foreground = $this.Brush('PrimaryForeground', [Color]::FromRgb(0xF5, 0xF3, 0xFF))
        # Arcane "default" (primary) = violet-600, matching ButtonPrimary in ButtonStyles.xaml
        $this.RunButton.Background = $this.Brush('Primary', [Color]::FromRgb(0x7C, 0x3A, 0xED))
        $this.RunButton.Padding = [Thickness]::new(14, 4, 14, 4)
        $this.RunButton.Height = 28
        $this.RunButton.VerticalAlignment = [VerticalAlignment]::Center
        $this.RunButton.Cursor = [System.Windows.Input.Cursors]::Hand
        $this.RunButton.BorderThickness = [Thickness]::new(0)
        $this.RunButton.ToolTip = 'Run the active command on this machine'
        $this.RunButton.Template = $this.MakeFlatButtonTemplate()
        [Grid]::SetColumn($this.RunButton, 4)
        $grid.Children.Add($this.RunButton)

        $row = $this
        # Single click selects (opens detail, cached only); double click gathers
        # fresh inventory. Running a scan/update is reserved for the Run button,
        # which is a Button that swallows its own click (so it won't also select).
        $header.Add_MouseLeftButtonDown({
            if ($_.ClickCount -eq 2) {
                if ($null -ne $row.GatherAction) { & $row.GatherAction $row.HostName }
            }
            else {
                if ($null -ne $row.SelectAction) { & $row.SelectAction $row.HostName }
            }
        }.GetNewClosure())

        $this.RunButton.Add_Click({
            if ($null -ne $row.RunAction) { & $row.RunAction $row.HostName }
        }.GetNewClosure())

        # Hover highlight on the row (background only; selection uses the border).
        # One step above the #1F1F1F base so the lift is visible.
        $hoverBrush = $this.Brush('PanelBackgroundActive', [Color]::FromRgb(0x27, 0x27, 0x2A))
        $baseBrush = $this.Root.Background
        $header.Add_MouseEnter({ $row.Root.Background = $hoverBrush }.GetNewClosure())
        $header.Add_MouseLeave({ $row.Root.Background = $baseBrush }.GetNewClosure())
    }

    # Highlights (or clears) the row to mark the selected machine.
    [void] SetSelected([bool]$selected) {
        $this.Selected = $selected
        if ($selected) {
            $this.Root.BorderBrush = $this.Brush('AccentPurple', [Color]::FromRgb(0x8B, 0x5C, 0xF6))
            $this.Root.BorderThickness = [Thickness]::new(1.5)
        } else {
            $this.Root.BorderBrush = $this.Brush('PanelBorder', [Color]::FromArgb(255, 0x27, 0x27, 0x2A))
            $this.Root.BorderThickness = [Thickness]::new(1)
        }
    }

    # Renders the persisted/idle state from a stored RecentConnection record.
    [void] SetIdleFrom([RecentConnection]$rc) {
        $this.IdleStatus = $rc.LastStatus
        $this.Dot.Fill = $this.Brush([ConnectionRow]::IdleColorKey($rc.LastStatus), [Colors]::Gray)

        $this.Progress.Visibility = [Visibility]::Collapsed
        $this.LastPercent = -1

        $this.ApplyChip()

        $when = if ([string]::IsNullOrWhiteSpace($rc.LastSeen)) {
            'never run'
        } else {
            [TimeFormat]::Relative([RecentConnectionsStore]::ParseSeen($rc.LastSeen))
        }
        $detail = if ($rc.UpdateCount -gt 0) { "$when - $($rc.UpdateCount) update(s)" } else { $when }
        $this.BaseSubtitle = $detail
        $this.ApplySubtitle()
    }

    # Reflects the background reachability verdict on an idle row: an offline host
    # gets an "offline" subtitle tag and a dimmed dot. Online/Unknown clears it.
    # (The presenter only calls this when no job is running on the host.)
    [void] SetReachability([string]$state) {
        $this.Reachability = $state
        # The dot is a presence light: green = online, red = offline. 'Unknown' (not yet
        # resolved) leaves the existing colour. A running job owns the dot, so the
        # presenter only calls this on an idle row.
        switch ($state) {
            'Online'  { $this.Dot.Fill = $this.Brush('AccentGreen', [Colors]::Green) }
            'Offline' { $this.Dot.Fill = $this.Brush('AccentRed', [Colors]::Red) }
            default   { }
        }
        $this.Dot.Opacity = 1.0
        $this.ApplyChip()
        $this.ApplySubtitle()
    }

    # Renders the status chip: "Offline" (grey) when the host is unreachable, otherwise
    # its last job status (hidden when it has never run).
    hidden [void] ApplyChip() {
        $status = if ($this.Reachability -eq 'Offline') { 'Offline' } else { $this.IdleStatus }
        if ([string]::IsNullOrWhiteSpace($status)) {
            $this.ChipBg.Visibility = [Visibility]::Collapsed
            return
        }
        $accent = $this.Brush([ConnectionRow]::IdleColorKey($status), [Colors]::Gray)
        $this.ChipBg.Visibility = [Visibility]::Visible
        $this.ChipText.Text = [ConnectionRow]::HumanStatus($status)
        $this.ChipText.Foreground = $accent
        $this.ChipBg.Background = $this.Tint($accent, 38)
    }

    # Composes the idle subtitle from its base text plus the reachability tag.
    hidden [void] ApplySubtitle() {
        if ($this.Reachability -eq 'Offline') {
            $this.Subtitle.Text = if ([string]::IsNullOrWhiteSpace($this.BaseSubtitle)) { 'offline' } else { "$($this.BaseSubtitle)  ·  offline" }
        } else {
            $this.Subtitle.Text = $this.BaseSubtitle
        }
    }

    # Applies a live job status: recolours the dot/chip and drives the bar.
    [void] SetStatus([FleetStatus]$status) {
        $accent = $this.Brush($status.ColorKey, [Colors]::Gray)

        $this.Dot.Opacity = 1.0   # clear any offline dimming while a job runs
        $this.Dot.Fill = $accent
        $this.ChipBg.Visibility = [Visibility]::Visible
        $this.ChipText.Text = $status.Label
        $this.ChipText.Foreground = $accent
        $this.ChipBg.Background = $this.Tint($accent, 38)
        $this.Progress.Foreground = $accent

        if ($status.IsBusy) {
            $this.Subtitle.Text = 'running now'
            $this.Progress.Visibility = [Visibility]::Visible
            if ($this.LastPercent -ge 0) {
                $this.Progress.IsIndeterminate = $false
                $this.Progress.Value = $this.LastPercent
            } else {
                $this.Progress.IsIndeterminate = $true
            }
        } else {
            $this.Progress.IsIndeterminate = $false
            $this.Progress.Visibility = [Visibility]::Collapsed
            $this.LastPercent = -1
        }
    }

    # Feeds a parsed DCU percentage (0-100) into the bar.
    [void] SetPercent([double]$percent) {
        if ($percent -lt 0) { return }
        if ($percent -gt 100) { $percent = 100 }
        $this.LastPercent = $percent
        $this.Progress.Visibility = [Visibility]::Visible
        $this.Progress.IsIndeterminate = $false
        $this.Progress.Value = $percent
    }

    # Fades + slides the row in when it first joins the list.
    [void] AnimateIn() {
        $transform = [TranslateTransform]::new(0, 10)
        $this.Root.RenderTransform = $transform
        $this.Root.Opacity = 0

        $ease = [QuadraticEase]::new(); $ease.EasingMode = [EasingMode]::EaseOut
        $fade = [DoubleAnimation]::new(0, 1, [Duration]::new([TimeSpan]::FromMilliseconds(200)))
        $rise = [DoubleAnimation]::new(10, 0, [Duration]::new([TimeSpan]::FromMilliseconds(220)))
        $rise.EasingFunction = $ease
        $this.Root.BeginAnimation([UIElement]::OpacityProperty, $fade)
        $transform.BeginAnimation([TranslateTransform]::YProperty, $rise)
    }

    # --- Pure status mapping for idle rows -------------------------------------------

    static [string] IdleColorKey([string]$lastStatus) {
        switch ($lastStatus) {
            'Completed'      { return 'AccentGreen' }
            'Failed'         { return 'AccentRed' }
            'RebootRequired' { return 'AccentYellow' }
            'Offline'        { return 'AccentRed' }          # offline shows red (matches the dot)
            default          { return 'BodyTextTertiary' }
        }
        return 'BodyTextTertiary'
    }

    static [string] HumanStatus([string]$lastStatus) {
        switch ($lastStatus) {
            'RebootRequired' { return 'Reboot required' }
            default          { return $lastStatus }
        }
        return $lastStatus
    }

    # --- Helpers ---------------------------------------------------------------------

    hidden [Brush] Brush([string]$key, [Color]$fallback) {
        $res = $null
        if ($this.Root) { $res = $this.Root.TryFindResource($key) }
        if ($res -is [Brush]) { return $res }
        return [SolidColorBrush]::new($fallback)
    }

    hidden [Brush] Tint([Brush]$brush, [byte]$alpha) {
        if ($brush -is [SolidColorBrush]) {
            $c = $brush.Color
            return [SolidColorBrush]::new([Color]::FromArgb($alpha, $c.R, $c.G, $c.B))
        }
        return $brush
    }

    # Flat, borderless template (rounded, background-bound) for the row buttons.
    hidden [System.Windows.Controls.ControlTemplate] MakeFlatButtonTemplate() {
        # hover = primary/90 (violet-700 #6D28D9), hardcoded since a parsed
        # template has no merged-dictionary context for DynamicResource.
        $xaml = @'
<ControlTemplate TargetType="Button" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" />
    </Border>
    <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="bd" Property="Background" Value="#6D28D9" />
        </Trigger>
    </ControlTemplate.Triggers>
</ControlTemplate>
'@
        return [System.Windows.Markup.XamlReader]::Parse($xaml)
    }
}
