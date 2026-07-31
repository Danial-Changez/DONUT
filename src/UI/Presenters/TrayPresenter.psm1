using namespace System.Windows.Forms
using namespace System.Windows.Threading
using module "..\..\Core\LogService.psm1"

<#
.SYNOPSIS
    Owns DONUT's system-tray icon and the single-instance "show me" listener.

.DESCRIPTION
    Creates the tray NotifyIcon on the WPF UI thread (whose dispatcher pumps its
    messages), surfaces the main window on left-click or the "Open" menu item, and
    exits the app via "Exit". Also polls a cross-instance event so a second launch
    foregrounds the running instance instead of starting a rival window.

.NOTES
    Holds the MainPresenter as [object] (not [MainPresenter]) so MainPresenter can
    import this module without a circular using-module. Every WinForms/DispatcherTimer
    callback runs on the UI thread, so the scriptblocks are runspace-safe (same model
    as the app's WPF handlers); the show-request event is POLLED with WaitOne(0) on a
    DispatcherTimer, never a wait-callback (a threadpool callback has no runspace and
    would crash - see the repo's async-callback notes).
#>
class TrayPresenter {
    hidden [object] $Main            # MainPresenter (duck-typed to avoid a circular import)
    hidden [LogService] $Logger
    hidden [NotifyIcon] $Icon
    hidden [ContextMenuStrip] $Menu
    hidden [DispatcherTimer] $ShowRequestTimer
    hidden [System.Threading.EventWaitHandle] $ShowRequestEvent
    hidden [bool] $HintShown         # close-to-tray balloon is shown at most once

    TrayPresenter([object]$main, [LogService]$logger) {
        $this.Main = $main
        $this.Logger = $logger
        $this.BuildIcon()
        $this.StartShowRequestListener()
    }

    hidden [void] BuildIcon() {
        $this.Icon = [NotifyIcon]::new()
        $this.Icon.Text = 'DONUT'
        $this.Icon.Icon = $this.LoadTrayIcon()

        $this.Menu = [ContextMenuStrip]::new()
        $presenter = $this
        [void]$this.Menu.Items.Add('Open', $null,
            { param($s, $e) $presenter.ShowMainWindow() }.GetNewClosure())
        [void]$this.Menu.Items.Add([ToolStripSeparator]::new())
        [void]$this.Menu.Items.Add('Exit', $null,
            { param($s, $e) $presenter.ExitApp() }.GetNewClosure())
        $this.Icon.ContextMenuStrip = $this.Menu

        # Left-click restores; right-click opens the menu (WinForms default).
        $this.Icon.Add_MouseClick({
                param($s, $e)
                if ($e.Button -eq [MouseButtons]::Left) { $presenter.ShowMainWindow() }
            }.GetNewClosure())

        $this.Icon.Visible = $true
    }

    # Loads the bundled donut icon through a disposed stream (so the .ico isn't left
    # locked), falling back to the generic application icon on any failure.
    hidden [System.Drawing.Icon] LoadTrayIcon() {
        try {
            $iconPath = Join-Path (Split-Path $this.Main.Config.SourceRoot -Parent) `
                'assets\Images\donut icon48x48.ico'
            if (Test-Path $iconPath) {
                $fs = [System.IO.File]::OpenRead($iconPath)
                try { return [System.Drawing.Icon]::new($fs) }
                finally { $fs.Dispose() }
            }
        }
        catch { $this.Logger.LogException("Tray icon load failed", $_) }
        return [System.Drawing.SystemIcons]::Application
    }

    # Create-or-open the AutoReset event a second launch Set()s, and poll it on the UI
    # thread. WaitOne(0) is a non-blocking check (never a blocking wait-callback).
    hidden [void] StartShowRequestListener() {
        try {
            $this.ShowRequestEvent = [System.Threading.EventWaitHandle]::new(
                $false, [System.Threading.EventResetMode]::AutoReset, 'Local\DONUT.ShowRequest')
        }
        catch {
            $this.Logger.LogException("Show-request event unavailable", $_)
            return
        }
        $presenter = $this
        $this.ShowRequestTimer = [DispatcherTimer]::new()
        $this.ShowRequestTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $this.ShowRequestTimer.Add_Tick({
                if ($presenter.ShowRequestEvent.WaitOne(0)) { $presenter.ShowMainWindow() }
            }.GetNewClosure())
        $this.ShowRequestTimer.Start()
    }

    # Surfaces (and foregrounds) the main window; on the first show after a hidden
    # start, runs the sign-in/update check that the hidden boot deferred.
    [void] ShowMainWindow() {
        $w = $this.Main.Window
        if ($null -eq $w) { return }
        try {
            $w.Show()
            if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
            $this.Main.BringToFront()
        }
        catch { $this.Logger.LogException("Show main window failed", $_) }

        $pending = $this.Main.PendingUpdateCheck
        if ($null -ne $pending) {
            $this.Main.PendingUpdateCheck = $null
            try { $pending.CheckAndPrompt() }
            catch { $this.Logger.LogException("Deferred update check failed", $_) }
        }

        # Once per launch: the actions are elsewhere (any fleet action prompts, and the
        # Settings toggle restarts elevated), so this only has to name the state.
        if ($this.Main.PendingLimitedNotice) {
            $this.Main.PendingLimitedNotice = $false
            if ($this.Main.ToastService) {
                $this.Main.ToastService.ShowWarning('Limited capability',
                    'DONUT started with Windows, so it is running without administrator rights. ' +
                    'Remote actions will ask for them, and granting one restarts DONUT elevated for the rest of the session.')
            }
        }
    }

    # Hotkey toggle: minimise DONUT when it's already up front, otherwise surface it (so
    # a not-focused or minimised/hidden window is brought forward, not sent down).
    [void] ToggleMainWindow() {
        $w = $this.Main.Window
        if ($null -eq $w) { return }
        if ($w.IsVisible -and $w.WindowState -ne 'Minimized' -and $w.IsActive) {
            $w.WindowState = 'Minimized'
        }
        else {
            $this.ShowMainWindow()
        }
    }

    # Requests a real exit (vs. close-to-tray hide): flags it so the window's Closing
    # handler won't cancel, then closes - the existing Closed teardown is the exit path.
    [void] ExitApp() {
        $this.Main.ExitRequested = $true
        if ($this.Main.Window) { $this.Main.Window.Close() }
    }

    # One-time balloon after the X hides the window to the tray, so the app doesn't
    # look like it vanished.
    [void] ShowCloseToTrayHint() {
        if ($this.HintShown -or $null -eq $this.Icon) { return }
        $this.HintShown = $true
        try {
            $this.Icon.BalloonTipTitle = 'DONUT'
            $this.Icon.BalloonTipText = 'DONUT is still running here - right-click to exit.'
            $this.Icon.ShowBalloonTip(3000)
        }
        catch { }
    }

    # Removes the icon and releases handles. Called from the window's Closed handler
    # before the process exits, else the icon ghosts in the tray until hovered.
    [void] Dispose() {
        try { if ($this.ShowRequestTimer) { $this.ShowRequestTimer.Stop() } } catch { }
        try {
            if ($this.Icon) {
                $this.Icon.Visible = $false
                $this.Icon.Dispose()
            }
        }
        catch { }
        try { if ($this.Menu) { $this.Menu.Dispose() } } catch { }
        try { if ($this.ShowRequestEvent) { $this.ShowRequestEvent.Dispose() } } catch { }
    }
}
