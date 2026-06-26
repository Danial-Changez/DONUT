using namespace System.Windows
using namespace System.Windows.Controls
using namespace System.Windows.Media
using namespace System.Windows.Media.Animation
using module "..\..\Models\FleetStatus.psm1"

# FleetCard
#
# A single host's status card on the Home view. Built in code (consistent with
# the existing passive-view pattern) rather than via data binding, since the
# presenter drives all state. Shows the host name, a colour-coded state chip and
# a progress bar; clicking the card expands an inline terminal showing that
# host's live DCU/PsExec output.
#
# Pure status semantics (label/colour/busy) come from [FleetStatus]; this class
# only renders and mutates the visuals.

class FleetCard {
    [string]      $HostName
    [Border]      $Root        # the element added to the fleet ItemsControl
    hidden [Border]      $ChipBg
    hidden [TextBlock]   $ChipText
    hidden [ProgressBar] $Progress
    hidden [Border]      $DetailHost
    hidden [TextBox]     $Log
    hidden [bool]        $Expanded
    hidden [double]      $LastPercent = -1   # last % parsed from DCU output (-1 = unknown)

    FleetCard([string]$hostName) {
        $this.HostName = $hostName
        $this.Expanded = $false
        $this.Build()
    }

    hidden [void] Build() {
        $this.Root = [Border]::new()
        $this.Root.Width = 320
        $this.Root.Margin = [Thickness]::new(8)
        $this.Root.CornerRadius = [CornerRadius]::new(10)
        $this.Root.BorderThickness = [Thickness]::new(1)
        $this.Root.Background = [SolidColorBrush]::new([Color]::FromArgb(180, 28, 14, 73))
        $this.Root.BorderBrush = $this.Brush('PanelBorder', [Color]::FromArgb(80, 120, 120, 200))
        $this.Root.VerticalAlignment = [VerticalAlignment]::Top

        $outer = [StackPanel]::new()
        $this.Root.Child = $outer

        # ---- Header (clickable: toggles the log) ----
        $header = [Border]::new()
        $header.Background = [Brushes]::Transparent
        $header.Padding = [Thickness]::new(14, 12, 14, 12)
        $header.Cursor = [System.Windows.Input.Cursors]::Hand
        $outer.Children.Add($header)

        $headerGrid = [Grid]::new()
        $cName = [ColumnDefinition]::new(); $cName.Width = [GridLength]::new(1, [GridUnitType]::Star)
        $cChip = [ColumnDefinition]::new(); $cChip.Width = [GridLength]::new(0, [GridUnitType]::Auto)
        $headerGrid.ColumnDefinitions.Add($cName)
        $headerGrid.ColumnDefinitions.Add($cChip)
        $header.Child = $headerGrid

        $rowTop = [StackPanel]::new()
        $rowTop.Orientation = [Orientation]::Vertical
        [Grid]::SetColumn($rowTop, 0)
        $headerGrid.Children.Add($rowTop)

        $nameBlock = [TextBlock]::new()
        $nameBlock.Text = $this.HostName
        $nameBlock.Foreground = $this.Brush('TitleTextPrimary', [Colors]::White)
        $nameBlock.FontFamily = [FontFamily]::new('Montserrat')
        $nameBlock.FontWeight = [FontWeights]::SemiBold
        $nameBlock.FontSize = 15
        $nameBlock.TextTrimming = [TextTrimming]::CharacterEllipsis
        $rowTop.Children.Add($nameBlock)

        # State chip
        $this.ChipBg = [Border]::new()
        $this.ChipBg.CornerRadius = [CornerRadius]::new(8)
        $this.ChipBg.Padding = [Thickness]::new(10, 3, 10, 3)
        $this.ChipBg.VerticalAlignment = [VerticalAlignment]::Center
        [Grid]::SetColumn($this.ChipBg, 1)
        $headerGrid.Children.Add($this.ChipBg)

        $this.ChipText = [TextBlock]::new()
        $this.ChipText.FontFamily = [FontFamily]::new('Montserrat')
        $this.ChipText.FontWeight = [FontWeights]::SemiBold
        $this.ChipText.FontSize = 11.5
        $this.ChipBg.Child = $this.ChipText

        # ---- Progress bar ----
        $this.Progress = [ProgressBar]::new()
        $this.Progress.Height = 4
        $this.Progress.Margin = [Thickness]::new(14, 0, 14, 12)
        $this.Progress.Minimum = 0
        $this.Progress.Maximum = 100
        $this.Progress.Background = [SolidColorBrush]::new([Color]::FromArgb(60, 120, 120, 200))
        $this.Progress.BorderThickness = [Thickness]::new(0)
        $outer.Children.Add($this.Progress)

        # ---- Collapsible log detail ----
        $this.DetailHost = [Border]::new()
        $this.DetailHost.Visibility = [Visibility]::Collapsed
        $this.DetailHost.Margin = [Thickness]::new(10, 0, 10, 10)
        $this.DetailHost.CornerRadius = [CornerRadius]::new(6)
        $this.DetailHost.Background = [SolidColorBrush]::new([Color]::FromArgb(235, 8, 4, 28))
        $outer.Children.Add($this.DetailHost)

        $this.Log = [TextBox]::new()
        $this.Log.IsReadOnly = $true
        $this.Log.MaxHeight = 180
        $this.Log.Margin = [Thickness]::new(2)
        $this.Log.BorderThickness = [Thickness]::new(0)
        $this.Log.Background = [Brushes]::Transparent
        $this.Log.Foreground = [SolidColorBrush]::new([Color]::FromRgb(0xC8, 0xCC, 0xF0))
        $this.Log.FontFamily = [FontFamily]::new('Consolas')
        $this.Log.FontSize = 12
        $this.Log.TextWrapping = [TextWrapping]::NoWrap
        $this.Log.VerticalScrollBarVisibility = [ScrollBarVisibility]::Auto
        $this.Log.HorizontalScrollBarVisibility = [ScrollBarVisibility]::Auto
        $this.DetailHost.Child = $this.Log

        # Toggle expansion on header click.
        $card = $this
        $header.Add_MouseLeftButtonUp({ $card.ToggleExpand() }.GetNewClosure())

        # Start in the queued state.
        $this.SetStatus([FleetStatus]::FromJob('Scan', 'Created', $false))
    }

    # Applies a status: recolours the chip + accent border and updates the bar.
    [void] SetStatus([FleetStatus]$status) {
        $accent = $this.Brush($status.ColorKey, [Colors]::Gray)

        $this.ChipText.Text = $status.Label
        $this.ChipText.Foreground = $accent
        $this.ChipBg.Background = $this.Tint($accent, 38)
        $this.Root.BorderBrush = $this.Tint($accent, 150)
        $this.Progress.Foreground = $accent

        if ($status.IsBusy) {
            # Show a real bar once DCU has reported a percentage; until then
            # (checking / determining / installing) fall back to indeterminate.
            if ($this.LastPercent -ge 0) {
                $this.Progress.IsIndeterminate = $false
                $this.Progress.Value = $this.LastPercent
            }
            else {
                $this.Progress.IsIndeterminate = $true
            }
        }
        else {
            $this.Progress.IsIndeterminate = $false
            # Failed leaves the bar empty; any settled state fills it.
            $this.Progress.Value = if ($status.State -eq [FleetState]::Failed) { 0 } else { 100 }
            # Reset so the next run for this host starts fresh.
            $this.LastPercent = -1
        }
    }

    # Feeds a parsed DCU percentage (0-100) into the bar. Switches it to a
    # determinate display immediately; SetStatus keeps it consistent thereafter.
    [void] SetPercent([double]$percent) {
        if ($percent -lt 0) { return }
        if ($percent -gt 100) { $percent = 100 }
        $this.LastPercent = $percent
        $this.Progress.IsIndeterminate = $false
        $this.Progress.Value = $percent
    }

    # Fades + slides the card in when it first joins the fleet grid.
    [void] AnimateIn() {
        $transform = [TranslateTransform]::new(0, 12)
        $this.Root.RenderTransform = $transform
        $this.Root.Opacity = 0

        $ease = [QuadraticEase]::new(); $ease.EasingMode = [EasingMode]::EaseOut
        $fade = [DoubleAnimation]::new(0, 1, [Duration]::new([TimeSpan]::FromMilliseconds(220)))
        $rise = [DoubleAnimation]::new(12, 0, [Duration]::new([TimeSpan]::FromMilliseconds(240)))
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

    # Resolves a brush resource by key, falling back to a solid colour.
    hidden [Brush] Brush([string]$key, [Color]$fallback) {
        $res = $null
        if ($this.Root) { $res = $this.Root.TryFindResource($key) }
        if ($res -is [Brush]) { return $res }
        return [SolidColorBrush]::new($fallback)
    }

    # Returns a translucent copy of a solid brush's colour at the given alpha.
    hidden [Brush] Tint([Brush]$brush, [byte]$alpha) {
        if ($brush -is [SolidColorBrush]) {
            $c = $brush.Color
            return [SolidColorBrush]::new([Color]::FromArgb($alpha, $c.R, $c.G, $c.B))
        }
        return $brush
    }
}
