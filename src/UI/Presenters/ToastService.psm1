using namespace Donut.Mvvm
using namespace System.Collections.ObjectModel
using namespace System.Windows.Controls
using namespace System.Windows.Media
using namespace System.Windows.Threading
using module "..\ViewModels\ToastViewModel.psm1"

<#
.SYNOPSIS
    Enqueues non-modal, auto-dismissing toast notifications.

.DESCRIPTION
    Shows informational feedback in the top-right overlay - e.g. "manual reboot
    required", "no updates found" - without stealing focus or blocking the pump;
    decision dialogs go through DialogPresenter. The service owns an
    ObservableCollection of ToastViewModels bound to the toastHost ItemsControl; the
    card chrome and the slide/fade in/out animations live in the DataTemplate
    (MainWindow.xaml). The service keeps the orchestration: per-toast auto-dismiss
    timers, and the flip-IsClosing-then-remove dance that lets the exit storyboard
    play before the item disappears.
#>
class ToastService {
    hidden [ItemsControl] $HostControl
    hidden [ObservableCollection[object]] $Items
    hidden [int] $DefaultDurationMs = 5000
    hidden [int] $ExitAnimationMs = 220   # slightly past the 180ms exit storyboard

    ToastService([ItemsControl] $toastHost) {
        $this.HostControl = $toastHost
        $this.Items = [ObservableCollection[object]]::new()
        if ($toastHost) { $toastHost.ItemsSource = $this.Items }
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

    # Builds and enqueues a toast. colorKey is a UIColors resource key used for the
    # accent bar, border, title and glow, and durationMs is the auto-dismiss delay.
    [void] Show([string]$title, [string]$message, [string]$colorKey, [int]$durationMs) {
        if ($null -eq $this.HostControl) { return }

        $accent = $this.ResolveBrush($colorKey, [Colors]::White)
        $accentColor = if ($accent -is [SolidColorBrush]) { $accent.Color } else { [Colors]::White }

        $toast = [ToastViewModel]::new($title, $message, $accent, $accentColor)

        $svc = $this
        $dismiss = { param($p) $svc.Dismiss($toast) }.GetNewClosure()
        $toast.DismissCommand = [RelayCommand]::new([System.Action[object]]$dismiss)

        $this.Items.Add($toast)

        $timer = [DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds($durationMs)
        $timer.Add_Tick({
                $timer.Stop()
                $svc.Dismiss($toast)
            }.GetNewClosure())
        $timer.Start()
    }

    # Plays the exit animation (IsClosing DataTrigger), then removes the item.
    [void] Dismiss([object]$toast) {
        if ($null -eq $toast -or -not $this.Items.Contains($toast)) { return }
        if ($toast.IsClosing) { return }   # already on its way out
        $toast.Close()

        $svc = $this
        $reaper = [DispatcherTimer]::new()
        $reaper.Interval = [TimeSpan]::FromMilliseconds($this.ExitAnimationMs)
        $reaper.Add_Tick({
                $reaper.Stop()
                if ($svc.Items.Contains($toast)) { [void]$svc.Items.Remove($toast) }
            }.GetNewClosure())
        $reaper.Start()
    }

    # Resolves a brush from the host's merged dictionaries, or a solid fallback colour.
    hidden [Brush] ResolveBrush([string]$key, [Color]$fallback) {
        $res = $null
        if ($this.HostControl) { $res = $this.HostControl.TryFindResource($key) }
        if ($res -is [Brush]) { return $res }
        return [SolidColorBrush]::new($fallback)
    }
}
