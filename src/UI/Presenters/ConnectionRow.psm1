using namespace System.Windows
using namespace System.Windows.Controls
using namespace System.Windows.Media
using namespace System.Windows.Media.Animation
using namespace System.Windows.Shapes
using module "..\..\Models\FleetStatus.psm1"
using module "..\..\Models\RecentConnection.psm1"
using module "..\..\Core\TimeFormat.psm1"

# ConnectionRow
#
# A full-width row in the Home machine list (TeamViewer-style). One row per
# machine; it serves double duty as both a persisted "recent connection" (idle
# state, via SetIdleFrom) and a live run (SetStatus/SetPercent/AppendLog while a
# job is in flight). Built in code, consistent with the passive-view pattern.
#
# Interaction:
#   - clicking the row body invokes RunAction(hostname) (presenter runs the
#     active config, confirming first when the mode is destructive)
#   - the chevron toggles an inline terminal showing live DCU/PsExec output
#
# Pure status semantics (label/colour/busy) come from [FleetStatus].

class ConnectionRow {
    [string]      $HostName
    [Border]      $Root          # element added to the machine list
    [scriptblock] $RunAction     # set by presenter; called with hostname on click

    hidden [Ellipse]     $Dot
    hidden [TextBlock]   $Subtitle
    hidden [Border]      $ChipBg
    hidden [TextBlock]   $ChipText
    hidden [ProgressBar] $Progress
    hidden [Button]      $Chevron
    hidden [Border]      $DetailHost
    hidden [TextBox]     $Log
    hidden [bool]        $Expanded
    hidden [double]      $LastPercent = -1   # last % parsed from DCU output (-1 = unknown)

    ConnectionRow([string]$hostName) {
        $this.HostName = $hostName
        $this.Expanded = $false
        $this.Build()
    }

    hidden [void] Build() {
        $this.Root = [Border]::new()
        $this.Root.Margin = [Thickness]::new(0, 0, 0, 8)
        $this.Root.CornerRadius = [CornerRadius]::new(10)
        $this.Root.BorderThickness = [Thickness]::new(1)
        $this.Root.Background = [SolidColorBrush]::new([Color]::FromArgb(220, 0x18, 0x18, 0x1B))
        $this.Root.BorderBrush = $this.Brush('PanelBorder', [Color]::FromArgb(255, 0x27, 0x27, 0x2A))
        $this.Root.HorizontalAlignment = [HorizontalAlignment]::Stretch

        $outer = [StackPanel]::new()
        $this.Root.Child = $outer

        # ---- Header (clickable body: runs the active config) ----
        $header = [Border]::new()
        $header.Background = [Brushes]::Transparent
        $header.Padding = [Thickness]::new(14, 10, 8, 10)
        $header.Cursor = [System.Windows.Input.Cursors]::Hand
        $outer.Children.Add($header)

        $grid = [Grid]::new()
        foreach ($w in @(
            [GridLength]::new(0, [GridUnitType]::Auto),   # dot
            [GridLength]::new(1, [GridUnitType]::Star),   # name + subtitle
            [GridLength]::new(0, [GridUnitType]::Auto),   # progress
            [GridLength]::new(0, [GridUnitType]::Auto),   # chip
            [GridLength]::new(0, [GridUnitType]::Auto)    # chevron
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
        $this.ChipBg.Margin = [Thickness]::new(0, 0, 4, 0)
        [Grid]::SetColumn($this.ChipBg, 3)
        $grid.Children.Add($this.ChipBg)

        $this.ChipText = [TextBlock]::new()
        $this.ChipText.FontFamily = [FontFamily]::new('Montserrat')
        $this.ChipText.FontWeight = [FontWeights]::SemiBold
        $this.ChipText.FontSize = 11
        $this.ChipBg.Child = $this.ChipText

        # Chevron (expand log)
        $this.Chevron = [Button]::new()
        $this.Chevron.Width = 32
        $this.Chevron.Height = 32
        $this.Chevron.Background = [Brushes]::Transparent
        $this.Chevron.BorderThickness = [Thickness]::new(0)
        $this.Chevron.Cursor = [System.Windows.Input.Cursors]::Hand
        $this.Chevron.Foreground = $this.Brush('BodyTextTertiary', [Colors]::Gray)
        $this.Chevron.Content = [char]0x2304   # downwards chevron-ish glyph
        $this.Chevron.FontSize = 14
        $this.Chevron.ToolTip = 'Show / hide log'
        $this.Chevron.Template = $this.MakeFlatButtonTemplate()
        [Grid]::SetColumn($this.Chevron, 4)
        $grid.Children.Add($this.Chevron)

        # ---- Collapsible log detail ----
        $this.DetailHost = [Border]::new()
        $this.DetailHost.Visibility = [Visibility]::Collapsed
        $this.DetailHost.Margin = [Thickness]::new(14, 0, 14, 12)
        $this.DetailHost.CornerRadius = [CornerRadius]::new(6)
        $this.DetailHost.Background = [SolidColorBrush]::new([Color]::FromArgb(235, 0x09, 0x09, 0x0B))
        $outer.Children.Add($this.DetailHost)

        $this.Log = [TextBox]::new()
        $this.Log.IsReadOnly = $true
        $this.Log.MaxHeight = 200
        $this.Log.Margin = [Thickness]::new(2)
        $this.Log.BorderThickness = [Thickness]::new(0)
        $this.Log.Background = [Brushes]::Transparent
        $this.Log.Foreground = [SolidColorBrush]::new([Color]::FromRgb(0xD4, 0xD4, 0xD8))
        $this.Log.FontFamily = [FontFamily]::new('Consolas')
        $this.Log.FontSize = 12
        $this.Log.TextWrapping = [TextWrapping]::NoWrap
        $this.Log.VerticalScrollBarVisibility = [ScrollBarVisibility]::Auto
        $this.Log.HorizontalScrollBarVisibility = [ScrollBarVisibility]::Auto
        $this.DetailHost.Child = $this.Log

        $row = $this
        # Row body click -> run the active config. The chevron is a Button, which
        # swallows its own click, so it won't trigger a run.
        $header.Add_MouseLeftButtonUp({
            if ($null -ne $row.RunAction) { & $row.RunAction $row.HostName }
        }.GetNewClosure())
        $this.Chevron.Add_Click({ $row.ToggleExpand() }.GetNewClosure())

        # Hover highlight on the row.
        $hoverBrush = $this.Brush('PanelBackgroundHover', [Color]::FromRgb(0x23, 0x23, 0x27))
        $baseBrush = $this.Root.Background
        $header.Add_MouseEnter({ $row.Root.Background = $hoverBrush }.GetNewClosure())
        $header.Add_MouseLeave({ $row.Root.Background = $baseBrush }.GetNewClosure())
    }

    # Renders the persisted/idle state from a stored RecentConnection record.
    [void] SetIdleFrom([RecentConnection]$rc) {
        $colorKey = [ConnectionRow]::IdleColorKey($rc.LastStatus)
        $accent = $this.Brush($colorKey, [Colors]::Gray)
        $this.Dot.Fill = $accent

        $this.Progress.Visibility = [Visibility]::Collapsed
        $this.LastPercent = -1

        if ([string]::IsNullOrWhiteSpace($rc.LastStatus)) {
            $this.ChipBg.Visibility = [Visibility]::Collapsed
        } else {
            $this.ChipBg.Visibility = [Visibility]::Visible
            $this.ChipText.Text = [ConnectionRow]::HumanStatus($rc.LastStatus)
            $this.ChipText.Foreground = $accent
            $this.ChipBg.Background = $this.Tint($accent, 38)
        }

        $when = if ([string]::IsNullOrWhiteSpace($rc.LastSeen)) {
            'never run'
        } else {
            [TimeFormat]::Relative([RecentConnectionsStore]::ParseSeen($rc.LastSeen))
        }
        $detail = if ($rc.UpdateCount -gt 0) { "$when - $($rc.UpdateCount) update(s)" } else { $when }
        $this.Subtitle.Text = $detail
    }

    # Applies a live job status: recolours the dot/chip and drives the bar.
    [void] SetStatus([FleetStatus]$status) {
        $accent = $this.Brush($status.ColorKey, [Colors]::Gray)

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

    [void] AppendLog([string]$text) {
        $this.Log.AppendText("$text`n")
        $this.Log.ScrollToEnd()
    }

    [void] ToggleExpand() {
        $this.Expanded = -not $this.Expanded
        $this.DetailHost.Visibility = if ($this.Expanded) { [Visibility]::Visible } else { [Visibility]::Collapsed }
        if ($this.Expanded) {
            $fade = [DoubleAnimation]::new(0, 1, [Duration]::new([TimeSpan]::FromMilliseconds(160)))
            $this.DetailHost.BeginAnimation([UIElement]::OpacityProperty, $fade)
            $this.Log.ScrollToEnd()
        }
    }

    # --- Pure status mapping for idle rows -------------------------------------------

    static [string] IdleColorKey([string]$lastStatus) {
        switch ($lastStatus) {
            'Completed'      { return 'AccentGreen' }
            'Failed'         { return 'AccentRed' }
            'RebootRequired' { return 'AccentYellow' }
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

    # Flat, borderless template for the chevron button (no default chrome).
    hidden [System.Windows.Controls.ControlTemplate] MakeFlatButtonTemplate() {
        $xaml = @'
<ControlTemplate TargetType="Button" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
    <Border Background="{TemplateBinding Background}" CornerRadius="6">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
    </Border>
</ControlTemplate>
'@
        return [System.Windows.Markup.XamlReader]::Parse($xaml)
    }
}
