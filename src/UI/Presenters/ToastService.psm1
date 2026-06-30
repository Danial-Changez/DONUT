using namespace System.Windows
using namespace System.Windows.Controls
using namespace System.Windows.Media
using namespace System.Windows.Media.Animation
using namespace System.Windows.Threading

<#
.SYNOPSIS
    Renders non-modal, auto-dismissing toast notifications.

.DESCRIPTION
    Shows informational feedback in a host ItemsControl (the top-right overlay in
    MainWindow) — e.g. "manual reboot required", "no updates found" — that
    previously surfaced as modal alert dialogs. Decision dialogs still go through
    DialogPresenter. Toasts slide + fade in, sit for a few seconds, then slide +
    fade out; clicking one dismisses it early.
#>
class ToastService {
    hidden [ItemsControl] $HostControl
    hidden [int] $DefaultDurationMs = 5000

    ToastService([ItemsControl] $toastHost) {
        $this.HostControl = $toastHost
    }

    [void] ShowSuccess([string]$title, [string]$message) {
        $this.Show($title, $message, 'AccentGreen', $this.DefaultDurationMs)
    }

    [void] ShowInfo([string]$title, [string]$message) {
        $this.Show($title, $message, 'AccentCyan', $this.DefaultDurationMs)
    }

    [void] ShowWarning([string]$title, [string]$message) {
        # Warnings linger a little longer since they usually need follow-up.
        $this.Show($title, $message, 'AccentYellow', 8000)
    }

    [void] ShowError([string]$title, [string]$message) {
        $this.Show($title, $message, 'AccentRed', 8000)
    }

    # Builds and presents a toast. colorKey is a UIColors resource key used for
    # the accent bar / title; durationMs is how long before auto-dismiss.
    [void] Show([string]$title, [string]$message, [string]$colorKey, [int]$durationMs) {
        if ($null -eq $this.HostControl) { return }

        $accent = $this.ResolveBrush($colorKey, [Colors]::White)

        # Card background: translucent zinc-900 for a subtle acrylic feel.
        $bg = [SolidColorBrush]::new([Color]::FromArgb(235, 0x18, 0x18, 0x1B))

        $card = [Border]::new()
        $card.Background = $bg
        $card.BorderBrush = $accent
        $card.BorderThickness = [Thickness]::new(1)
        $card.CornerRadius = [CornerRadius]::new(10)
        $card.Margin = [Thickness]::new(0, 0, 0, 10)
        $card.Padding = [Thickness]::new(0)
        $card.Cursor = [System.Windows.Input.Cursors]::Hand
        $card.Effect = $this.MakeGlow($accent)

        $grid = [Grid]::new()
        $col0 = [ColumnDefinition]::new(); $col0.Width = [GridLength]::new(4)
        $col1 = [ColumnDefinition]::new(); $col1.Width = [GridLength]::new(1, [GridUnitType]::Star)
        $grid.ColumnDefinitions.Add($col0)
        $grid.ColumnDefinitions.Add($col1)

        # Accent bar down the left edge.
        $bar = [Border]::new()
        $bar.Background = $accent
        $bar.CornerRadius = [CornerRadius]::new(10, 0, 0, 10)
        [Grid]::SetColumn($bar, 0)
        $grid.Children.Add($bar)

        $stack = [StackPanel]::new()
        $stack.Margin = [Thickness]::new(14, 12, 14, 12)
        [Grid]::SetColumn($stack, 1)

        $titleBlock = [TextBlock]::new()
        $titleBlock.Text = $title
        $titleBlock.Foreground = $accent
        $titleBlock.FontFamily = [FontFamily]::new('Montserrat')
        $titleBlock.FontWeight = [FontWeights]::SemiBold
        $titleBlock.FontSize = 14
        $titleBlock.TextWrapping = [TextWrapping]::Wrap
        $stack.Children.Add($titleBlock)

        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $msgBlock = [TextBlock]::new()
            $msgBlock.Text = $message
            $msgBlock.Foreground = $this.ResolveBrush('TitleTextTertiary', [Colors]::Gainsboro)
            $msgBlock.FontFamily = [FontFamily]::new('Montserrat')
            $msgBlock.FontSize = 12.5
            $msgBlock.TextWrapping = [TextWrapping]::Wrap
            $msgBlock.Margin = [Thickness]::new(0, 4, 0, 0)
            $stack.Children.Add($msgBlock)
        }

        $grid.Children.Add($stack)
        $card.Child = $grid

        # Slide-in transform.
        $transform = [TranslateTransform]::new(40, 0)
        $card.RenderTransform = $transform
        $card.Opacity = 0

        $this.HostControl.Items.Add($card) | Out-Null

        # Animate in.
        $easeOut = [QuadraticEase]::new(); $easeOut.EasingMode = [EasingMode]::EaseOut
        $fadeIn = [DoubleAnimation]::new(0, 1, [Duration]::new([TimeSpan]::FromMilliseconds(200)))
        $slideIn = [DoubleAnimation]::new(40, 0, [Duration]::new([TimeSpan]::FromMilliseconds(220)))
        $slideIn.EasingFunction = $easeOut
        $card.BeginAnimation([UIElement]::OpacityProperty, $fadeIn)
        $transform.BeginAnimation([TranslateTransform]::XProperty, $slideIn)

        # Click dismisses early.
        $svc = $this
        $card.Add_MouseLeftButtonUp({ $svc.Dismiss($card) }.GetNewClosure())

        # Auto-dismiss timer.
        $timer = [DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds($durationMs)
        $timer.Add_Tick({
            $timer.Stop()
            $svc.Dismiss($card)
        }.GetNewClosure())
        $timer.Start()
    }

    # Animates a toast out and removes it from the host once finished.
    [void] Dismiss([Border]$card) {
        if ($null -eq $card -or -not $this.HostControl.Items.Contains($card)) { return }

        $transform = $card.RenderTransform
        $fadeOut = [DoubleAnimation]::new($card.Opacity, 0, [Duration]::new([TimeSpan]::FromMilliseconds(180)))

        $panel = $this.HostControl
        $fadeOut.Add_Completed({
            if ($panel.Items.Contains($card)) { $panel.Items.Remove($card) }
        }.GetNewClosure())

        if ($transform -is [TranslateTransform]) {
            $slideOut = [DoubleAnimation]::new(0, 40, [Duration]::new([TimeSpan]::FromMilliseconds(180)))
            $transform.BeginAnimation([TranslateTransform]::XProperty, $slideOut)
        }
        $card.BeginAnimation([UIElement]::OpacityProperty, $fadeOut)
    }

    # Resolves a brush from the host's merged resource dictionaries, falling back
    # to a solid colour if the key is missing.
    hidden [Brush] ResolveBrush([string]$key, [Color]$fallback) {
        $res = $null
        if ($this.HostControl) { $res = $this.HostControl.TryFindResource($key) }
        if ($res -is [Brush]) { return $res }
        return [SolidColorBrush]::new($fallback)
    }

    # A soft outer glow in the accent colour for the synthwave look.
    hidden [System.Windows.Media.Effects.DropShadowEffect] MakeGlow([Brush]$accent) {
        $glow = [System.Windows.Media.Effects.DropShadowEffect]::new()
        $glow.BlurRadius = 18
        $glow.ShadowDepth = 0
        $glow.Opacity = 0.55
        if ($accent -is [SolidColorBrush]) { $glow.Color = $accent.Color }
        return $glow
    }
}
