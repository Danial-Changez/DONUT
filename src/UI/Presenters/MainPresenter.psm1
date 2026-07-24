using namespace System.Windows
using namespace System.Windows.Threading
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Models\HotkeyGesture.psm1"
using module "..\..\Core\ConfigManager.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\DispatcherWatchdog.psm1"
using module "..\..\Core\RunspaceManager.psm1"
using module "..\..\Services\ResourceService.psm1"
using namespace Donut.Mvvm
using namespace Donut.Interop
using module ".\ConfigPresenter.psm1"
using module ".\HomePresenter.psm1"
using module ".\TourPresenter.psm1"
using module ".\TrayPresenter.psm1"
using module ".\ToastService.psm1"
using module "..\ViewModels\MainViewModel.psm1"

<#
.SYNOPSIS
    Owns the main window, its child presenters, and the settings overlay.

.DESCRIPTION
    Builds and shows MainWindow, hosts the Home page, opens the Config view in the
    settings overlay on demand, and constructs the Home / Config presenters plus the
    shared ToastService. Applies the merged XAML resources to the window.
#>
class MainPresenter {
    [AppConfig] $Config
    [ConfigManager] $ConfigManager
    [System.Windows.Window] $Window
    [hashtable] $Controls
    [hashtable] $Views
    [ConfigPresenter] $ConfigPresenter
    [HomePresenter] $HomePresenter
    [TrayPresenter] $TrayPresenter
    [object] $Tour                   # TourPresenter (guided first-run tour)
    [NetworkProbe] $NetworkProbe
    [LogService] $Logger
    [DispatcherWatchdog] $Watchdog   # diagnostic: logs UI-thread stalls (loader-lock freeze)
    [ResourceService] $Resources
    [ToastService] $ToastService
    [MainViewModel] $MainVm

    # Set true before a real exit (tray "Exit") so the close-to-tray Closing hook
    # doesn't cancel it; a hidden boot parks the deferred sign-in/update check here.
    [bool] $ExitRequested
    [object] $PendingUpdateCheck

    # Global-hotkey interop (Donut.Interop.HotkeyManager) and the HWND it binds to.
    hidden [object] $Hotkey
    hidden [IntPtr] $Hwnd = [IntPtr]::Zero

    # The window-level Open-Settings KeyBinding, rebuilt from config (removed on re-apply).
    hidden [object] $SettingsKeyBinding

    # Fire-and-forget pool jobs (e.g. the scheduled-task Apply) reaped on the UI thread.
    hidden [System.Collections.Generic.List[object]] $PoolJobs
    hidden [DispatcherTimer] $PoolReapTimer

    # The DONUT wordmark shown in the branding bar.
    hidden [System.Windows.Media.Imaging.BitmapImage] $LogoImage

    MainPresenter(
        [AppConfig] $config,
        [ConfigManager] $configManager,
        [NetworkProbe] $networkProbe,
        [ResourceService] $resources
    ) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.NetworkProbe = $networkProbe
        $this.Resources = $resources
        $this.Logger = $networkProbe.Logger
        $this.Initialize()
    }

    [void] Initialize() {
        $xamlPath = Join-Path $this.Config.SourceRoot "UI\Views\MainWindow.xaml"

        if (-not (Test-Path $xamlPath)) {
            throw "MainWindow.xaml not found at $xamlPath"
        }

        # Load XAML through a stream we explicitly dispose, so the .xaml file isn't
        # left locked (and uneditable on disk) for the app's lifetime.
        try {
            $stream = [System.IO.File]::OpenRead($xamlPath)
            try {
                $this.Window = [System.Windows.Markup.XamlReader]::Load($stream)
            }
            finally {
                $stream.Dispose()
            }

            if ([System.Windows.Application]::Current) {
                [System.Windows.Application]::Current.MainWindow = $this.Window
            }
        }
        catch {
            $msg = "Failed to load XAML: $_"
            if ($_.Exception -and $_.Exception.InnerException) {
                $msg += "`nInner Exception: $($_.Exception.InnerException.Message)"
                if ($_.Exception.InnerException.InnerException) {
                    $msg += "`nRoot Cause: $($_.Exception.InnerException.InnerException.Message)"
                }
            }
            [System.Windows.Forms.MessageBox]::Show($msg, "XAML Load Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
            throw $msg
        }

        $this.Resources.ApplyResourcesToWindow($this.Window)
        $this.Logger.LogDebug("MainWindow merged resource dictionaries: $($this.Window.Resources.MergedDictionaries.Count)")
        if ($this.Window.Resources.MergedDictionaries.Count -eq 0) {
            $this.Logger.LogWarning("No resources merged into MainWindow.")
        }

        $this.Controls = @{}
        $this.Controls['contentMain'] = $this.Window.FindName("contentMain")
        $this.Controls['settingsContent'] = $this.Window.FindName("settingsContent")
        $this.Controls['settingsCard'] = $this.Window.FindName("settingsCard")

        $this.LoadImages()

        # Toast overlay, shared with sub-presenters that need notifications.
        $toastHost = $this.Window.FindName("toastHost")
        if ($toastHost) {
            $this.ToastService = [ToastService]::new($toastHost)
        }

        $this.Views = @{}

        # Home is built eagerly; Config builds lazily on first settings open, so
        # startup never pays for a view the user may not open.
        $homeView = $this.LoadView("HomeView.xaml")
        $this.Views['Home'] = $homeView
        if ($homeView) {
            $this.HomePresenter = [HomePresenter]::new($this.Config, $homeView,
                $this.NetworkProbe, $this.Resources, $this.ToastService, $this.ConfigManager)
        }

        # Shell view-model: settings overlay + window chrome are bound commands that
        # call back into the presenter for the imperative shell work.
        $presenter = $this
        $this.MainVm = [MainViewModel]::new()
        $openSettings = { param($p) $presenter.OpenSettings() }.GetNewClosure()
        $this.MainVm.OpenSettingsCommand = [RelayCommand]::new([System.Action[object]]$openSettings)
        $closeSettings = { param($p) $presenter.CloseSettings() }.GetNewClosure()
        $this.MainVm.CloseSettingsCommand = [RelayCommand]::new([System.Action[object]]$closeSettings)
        $toggleSettings = { param($p) $presenter.ToggleSettings() }.GetNewClosure()
        $this.MainVm.ToggleSettingsCommand = [RelayCommand]::new([System.Action[object]]$toggleSettings)
        $min = { param($p) $presenter.Window.WindowState = 'Minimized' }.GetNewClosure()
        $this.MainVm.MinimizeCommand = [RelayCommand]::new([System.Action[object]]$min)
        $max = { param($p)
            if ($presenter.Window.WindowState -eq 'Maximized') {
                $presenter.Window.WindowState = 'Normal'
            }
            else { $presenter.Window.WindowState = 'Maximized' }
        }.GetNewClosure()
        $this.MainVm.MaximizeCommand = [RelayCommand]::new([System.Action[object]]$max)
        $close = { param($p) $presenter.Window.Close() }.GetNewClosure()
        $this.MainVm.CloseCommand = [RelayCommand]::new([System.Action[object]]$close)
        $closeQr = { param($p) $presenter.CloseQr() }.GetNewClosure()
        $this.MainVm.CloseQrCommand = [RelayCommand]::new([System.Action[object]]$closeQr)
        # Let the Home finder pop the shell's QR overlay for a Lens device's recovery key.
        $showQr = { param($payload, $caption)
            $presenter.ShowQr($payload, $caption)
        }.GetNewClosure()
        if ($this.HomePresenter -and $this.HomePresenter.Finder) {
            $this.HomePresenter.Finder.OnShowQr = $showQr
        }
        # Guided tour: the ? button replays it; Esc closes it.
        $this.Tour = [TourPresenter]::new(
            $this.Window, $this.MainVm, $this.HomePresenter, $this.Config, $this.ConfigManager, $this.Logger)
        $openTour = { param($p) $presenter.Tour.Start() }.GetNewClosure()
        $this.MainVm.OpenTourCommand = [RelayCommand]::new([System.Action[object]]$openTour)
        $closeTour = { param($p) $presenter.Tour.Finish() }.GetNewClosure()
        $this.MainVm.CloseTourCommand = [RelayCommand]::new([System.Action[object]]$closeTour)
        $openDocs = { param($p)
            try { Start-Process 'https://danial-changez.github.io/DONUT/' }
            catch { $presenter.Logger.LogException('Failed to open documentation', $_) }
        }.GetNewClosure()
        $this.MainVm.OpenDocsCommand = [RelayCommand]::new([System.Action[object]]$openDocs)
        # Pages set their own DataContext, so the shell's context never leaks into them.
        $this.Window.DataContext = $this.MainVm

        # Scope DragMove to the top control bar: wiring it to the whole borderless window made
        # every click-drag move it, so content-area text could never be selected.
        $controlBar = $this.Window.FindName("panelControlBar")
        if ($controlBar) {
            $controlBar.Add_MouseLeftButtonDown({
                    if ($_.ButtonState -eq 'Pressed') { $presenter.Window.DragMove() }
                }.GetNewClosure())
        }

        $this.Window.Add_Closed({
                # Window gone: finish the Lens-agent teardown (bounded, invisible wait), then
                # hard-exit so the tray loop doesn't keep the process alive (locks the exe).
                if ($global:LensTeardownJob) {
                    try {
                        [void]$global:LensTeardownJob.Handle.AsyncWaitHandle.WaitOne(
                            [TimeSpan]::FromSeconds(5))
                    }
                    catch { }
                    try { $global:LensTeardownJob.Ps.Dispose() } catch { }
                    $global:LensTeardownJob = $null
                }
                # Release the global hotkey and remove the tray icon before the hard exit
                # (the icon would otherwise ghost in the tray until hovered).
                if ($presenter.Hotkey) { try { $presenter.Hotkey.Detach() } catch { } }
                if ($presenter.TrayPresenter) { try { $presenter.TrayPresenter.Dispose() } catch { } }
                if ([System.Windows.Application]::Current) {
                    [System.Windows.Application]::Current.Shutdown()
                }
                [System.Environment]::Exit(0)
            }.GetNewClosure())

        # Close-to-tray: the X hides the window instead of exiting, unless a real exit
        # was requested (tray "Exit") or the setting is off. $_ is the CancelEventArgs.
        $this.Window.Add_Closing({
                if ($presenter.Config.GetCloseToTray() -and -not $presenter.ExitRequested) {
                    $_.Cancel = $true
                    $presenter.Window.Hide()
                    if ($presenter.TrayPresenter) { $presenter.TrayPresenter.ShowCloseToTrayHint() }
                }
            }.GetNewClosure())

        # Shown from the worker STA thread, so Windows won't foreground it; the
        # BringToFront Topmost toggle does the front-bringing on first render.
        $this.Window.Add_ContentRendered({ $presenter.BringToFront() }.GetNewClosure())

        # First-run guided tour: fires the first time the window is shown (interactive or
        # tray-surface); hasSeenTour keeps it to once, and MaybeStartFirstRun guards re-entry.
        $this.Window.Add_IsVisibleChanged({
                if ($presenter.Window.IsVisible -and $presenter.Tour) {
                    $presenter.Tour.MaybeStartFirstRun()
                }
            }.GetNewClosure())

        # Constrain maximize to the monitor work area - a WindowChrome window otherwise
        # overflows the screen edges and covers the taskbar. Needs the HWND, so wait.
        $this.Window.Add_SourceInitialized({
                try {
                    $hwnd = [Interop.WindowInteropHelper]::new($presenter.Window).Handle
                    if ($hwnd -ne [IntPtr]::Zero) {
                        [WindowChromeHelper]::ConstrainMaximize($hwnd)
                        # The HWND now exists, so RegisterHotKey can bind to it.
                        $presenter.AttachHotkey($hwnd)
                    }
                }
                catch { $presenter.Logger.LogException("Maximize constraint hook failed", $_) }
            }.GetNewClosure())

        # Diagnostic (remove once pinned): logs UI-thread stalls over 1 s - the freeze.
        $this.Watchdog = [DispatcherWatchdog]::new($this.Logger, 1000)
        $this.Watchdog.Start()

        # Tray icon lives on this (the UI) thread and is present in both show paths.
        $this.TrayPresenter = [TrayPresenter]::new($this, $this.Logger)

        # In-app keyboard shortcuts (config-driven; global hotkey attaches on SourceInitialized).
        $this.ApplyWindowShortcuts()

        $this.ShowHome()
    }

    # Forces the window to the foreground from the worker STA thread (which has no
    # foreground-activation right): restore-if-minimized, then a brief Topmost toggle.
    [void] BringToFront() {
        $w = $this.Window
        if ($null -eq $w) { return }
        if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
        $w.Activate()
        $w.Topmost = $true
        $w.Topmost = $false
        $w.Focus()
    }

    # Stores the window HWND (once it exists) and registers the configured hotkey.
    [void] AttachHotkey([IntPtr]$hwnd) {
        $this.Hwnd = $hwnd
        $this.ApplyHotkey()
    }

    # (Re)registers the global hotkey from the current config on the stored HWND. Detaches
    # first so a Settings change swaps cleanly; a taken combo toasts and the app continues.
    [void] ApplyHotkey() {
        if ($this.Hwnd -eq [IntPtr]::Zero) { return }
        try {
            if ($null -eq $this.Hotkey) {
                $this.Hotkey = [Donut.Interop.HotkeyManager]::new()
                # Pressed fires on the UI thread (WM_HOTKEY -> WndProc), so this is safe.
                # Toggle: surface DONUT, or minimise it when it's already up front.
                $presenter = $this
                $this.Hotkey.add_Pressed(
                    { param($s, $e) $presenter.TrayPresenter.ToggleMainWindow() }.GetNewClosure())
            }
            $this.Hotkey.Detach()

            $gestureText = $this.Config.GetGlobalHotkey()
            if ([string]::IsNullOrWhiteSpace($gestureText)) { return }   # blank = disabled

            $gesture = [HotkeyGesture]::Parse($gestureText)
            if (-not $gesture.Valid) {
                $this.Logger.LogWarning("Global hotkey '$gestureText' invalid: $($gesture.Reason)")
                return
            }
            if ($this.Hotkey.Attach($this.Hwnd, $gesture.Modifiers, $gesture.VirtualKey)) {
                $this.Logger.LogInfo("Global hotkey registered: $($gesture.Normalized)")
            }
            else {
                $msg = "Hotkey $($gesture.Normalized) is unavailable (already in use) - pick another in Settings."
                $this.Logger.LogWarning("$msg (Win32 error $($this.Hotkey.LastError))")
                if ($this.ToastService) { $this.ToastService.ShowError('Global hotkey', $msg) }
            }
        }
        catch { $this.Logger.LogException("Global hotkey setup failed", $_) }
    }

    # (Re)builds the window-level Open-Settings shortcut from config. In-app only (a WPF
    # KeyBinding, not a global RegisterHotKey); a settings change re-applies it.
    [void] ApplyWindowShortcuts() {
        if ($null -eq $this.Window) { return }
        if ($this.SettingsKeyBinding) {
            $this.Window.InputBindings.Remove($this.SettingsKeyBinding)
            $this.SettingsKeyBinding = $null
        }
        $text = $this.Config.GetOpenSettingsShortcut()
        if ([string]::IsNullOrWhiteSpace($text)) { return }   # blank = disabled

        $gesture = [HotkeyGesture]::Parse($text)
        if (-not $gesture.Valid) {
            $this.Logger.LogWarning("Open-Settings shortcut '$text' invalid: $($gesture.Reason)")
            return
        }
        try {
            $key = [System.Windows.Input.Key]$gesture.WpfKey
            $mods = [System.Windows.Input.ModifierKeys]$gesture.Modifiers
            $kb = [System.Windows.Input.KeyBinding]::new($this.MainVm.ToggleSettingsCommand, $key, $mods)
            [void]$this.Window.InputBindings.Add($kb)
            $this.SettingsKeyBinding = $kb
        }
        catch { $this.Logger.LogException("Open-Settings shortcut apply failed", $_) }
    }

    # Registers/unregisters the elevated startup task to match the setting. Runs on the
    # pool (Get/Register-ScheduledTask can stall) and toasts on failure from the reap.
    [void] ApplyStartupTask() {
        $enabled = [bool]$this.Config.GetStartWithWindows()
        $workerPath = Join-Path $this.Config.SourceRoot 'Scripts\Apply-StartupTask.ps1'
        $presenter = $this

        $onDone = {
            param($result)
            $r = @($result)[-1]
            if ($r -is [hashtable] -and -not $r.Ok -and $presenter.ToastService) {
                $presenter.ToastService.ShowError('Startup task',
                    'Could not update the startup task - is DONUT running as administrator?')
            }
        }.GetNewClosure()

        $this.RunOnPool($workerPath, @{
                Enabled    = $enabled
                SourceRoot = $this.Config.SourceRoot
                LogsPath   = $this.ConfigManager.LogsPath
            }, $onDone)
    }

    # Runs a pool worker script (a .ps1 whose using-module class types resolve in the
    # runspace) and reaps it on the UI thread - no runspace-less callback (see repo notes).
    hidden [void] RunOnPool([string]$scriptPath, [hashtable]$params, [object]$onDone) {
        try {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = [RunspaceManager]::GetPool()
            $ps.AddCommand($scriptPath) | Out-Null
            foreach ($k in $params.Keys) { $ps.AddParameter($k, $params[$k]) | Out-Null }
            $async = $ps.BeginInvoke()

            if ($null -eq $this.PoolJobs) {
                $this.PoolJobs = [System.Collections.Generic.List[object]]::new()
            }
            $this.PoolJobs.Add(@{ Ps = $ps; Async = $async; OnDone = $onDone })

            if ($null -eq $this.PoolReapTimer) {
                $presenter = $this
                $this.PoolReapTimer = [DispatcherTimer]::new()
                $this.PoolReapTimer.Interval = [TimeSpan]::FromMilliseconds(300)
                $this.PoolReapTimer.Add_Tick({ $presenter.ReapPoolJobs() }.GetNewClosure())
            }
            if (-not $this.PoolReapTimer.IsEnabled) { $this.PoolReapTimer.Start() }
        }
        catch { $this.Logger.LogException("Pool job start failed", $_) }
    }

    # Completes finished pool jobs, hands each result to its callback, and stops the
    # timer once the queue drains. Polled from a DispatcherTimer (never a wait-callback).
    hidden [void] ReapPoolJobs() {
        if ($null -eq $this.PoolJobs -or $this.PoolJobs.Count -eq 0) {
            if ($this.PoolReapTimer) { $this.PoolReapTimer.Stop() }
            return
        }
        foreach ($job in @($this.PoolJobs | Where-Object { $_.Async.IsCompleted })) {
            $result = $null
            try { $result = $job.Ps.EndInvoke($job.Async) }
            catch { $this.Logger.LogException("Pool job failed", $_) }
            try { $job.Ps.Dispose() } catch { }
            $this.PoolJobs.Remove($job) | Out-Null
            if ($job.OnDone) {
                try { & $job.OnDone $result }
                catch { $this.Logger.LogException("Pool job callback failed", $_) }
            }
        }
        if ($this.PoolJobs.Count -eq 0) { $this.PoolReapTimer.Stop() }
    }

    [void] LoadImages() {
        $assetsPath = Join-Path (Split-Path $this.Config.SourceRoot -Parent) "assets\Images"
        $logoPath = Join-Path $assetsPath "logo yellow arrow.png"

        if (Test-Path $logoPath) {
            $this.LogoImage = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]::new($logoPath))
        }

        $logo = $this.Window.FindName("Logo")
        if ($logo -and $this.LogoImage) { $logo.Source = $this.LogoImage }
    }

    [object] LoadView([string]$fileName) {
        $path = Join-Path $this.Config.SourceRoot "UI\Views\$fileName"
        if (Test-Path $path) {
            try {
                # Stream disposed so the view file isn't left locked (see Initialize).
                $stream = [System.IO.File]::OpenRead($path)
                try {
                    return [System.Windows.Markup.XamlReader]::Load($stream)
                }
                finally {
                    $stream.Dispose()
                }
            }
            catch {
                $this.Logger.LogException("Failed to load view $fileName", $_)
            }
        }
        return $null
    }

    # Builds the Config view + presenter once, on first settings open, and hosts it in
    # the overlay card. ConfigPresenter toasts + closes the overlay on save.
    hidden [void] EnsureConfigView() {
        if ($this.Views.ContainsKey('Config') -and $this.Views['Config']) { return }

        $configView = $this.LoadView("ConfigView.xaml")
        $this.Views['Config'] = $configView
        if ($configView) {
            $presenter = $this
            # Real-time settings re-apply the bits that live outside the config file, each
            # when its own control changes (the overlay closes via its X / Esc / backdrop).
            $sideEffects = @{
                Hotkey         = { $presenter.ApplyHotkey() }.GetNewClosure()
                WindowShortcut = { $presenter.ApplyWindowShortcuts() }.GetNewClosure()
                StartupTask    = { $presenter.ApplyStartupTask() }.GetNewClosure()
            }
            $this.ConfigPresenter = [ConfigPresenter]::new(
                $this.Config, $this.ConfigManager, $configView, $this.ToastService, $sideEffects)
            if ($this.Controls['settingsContent']) {
                $this.Controls['settingsContent'].Content = $configView
            }
        }
    }

    # Home is the shell's only page; shows it with a gentle fade-in.
    [void] ShowHome() {
        if (-not $this.Views['Home']) { return }
        $content = $this.Controls['contentMain']
        $content.Content = $this.Views['Home']
        $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(
            0, 1, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
        $content.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        if ($this.HomePresenter) { $this.HomePresenter.UpdateSearchButtonLabel() }
    }

    # Opens the settings overlay, building the Config view lazily on first use. A
    # visibility toggle (not ShowDialog), so background jobs keep pumping behind it.
    [void] OpenSettings() {
        $this.EnsureConfigView()
        if ($this.MainVm) { $this.MainVm.Set('IsSettingsOpen', $true) }
        # Focus the card so the overlay's Esc key binding is in scope.
        if ($this.Controls['settingsCard']) { $this.Controls['settingsCard'].Focus() }
    }

    [void] CloseSettings() {
        if ($this.MainVm) { $this.MainVm.Set('IsSettingsOpen', $false) }
    }

    # The configurable shortcut opens AND closes the overlay (the gear opens; Esc still closes),
    # mirroring the global hotkey's show/hide toggle instead of only opening.
    [void] ToggleSettings() {
        if ($this.MainVm -and $this.MainVm.IsSettingsOpen) { $this.CloseSettings() }
        else { $this.OpenSettings() }
    }

    # Pops the QR overlay for a BitLocker recovery key, rendered to an in-memory image only
    # (never written to disk). A render failure toasts instead of opening an empty card.
    [void] ShowQr([string]$payload, [string]$caption) {
        if ([string]::IsNullOrWhiteSpace($payload)) { return }
        $img = $this.BuildQrImage($payload)
        if ($null -eq $img) {
            if ($this.ToastService) {
                $this.ToastService.ShowError($caption, "Couldn't render the QR code.")
            }
            return
        }
        $this.MainVm.Set('QrImage', $img)
        $this.MainVm.Set('QrCaption', "BitLocker recovery key - $caption")
        $this.MainVm.Set('IsQrOpen', $true)
    }

    [void] CloseQr() {
        if ($this.MainVm) { $this.MainVm.Set('IsQrOpen', $false) }
    }

    # Encodes text to a QR PNG (in memory) via the bundled QR helper, returned as a frozen,
    # cross-thread-safe BitmapImage (ECC level Q for glare tolerance). $null on any failure.
    hidden [System.Windows.Media.ImageSource] BuildQrImage([string]$payload) {
        try {
            # Themed but still dark-on-light so any reader can scan it: violet-900 modules on a
            # soft violet-50 plate (~9:1 contrast) instead of stark #000 on #FFF. RGBA bytes.
            $dark = [byte[]](0x4C, 0x1D, 0x95, 0xFF)    # violet-900 (brand modules)
            $light = [byte[]](0xF5, 0xF3, 0xFF, 0xFF)   # violet-50 (softened background)
            $png = [Donut.Qr.QrCode]::EncodePng($payload, 20, $dark, $light)
            $ms = [System.IO.MemoryStream]::new($png)
            $img = [System.Windows.Media.Imaging.BitmapImage]::new()
            $img.BeginInit()
            $img.StreamSource = $ms
            $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $img.EndInit()
            $img.Freeze()
            return $img
        }
        catch {
            $this.Logger.LogException("QR render failed", $_)
            return $null
        }
    }

    [void] Show() {
        if ($this.Window) {
            try {
                # The pumpless span since the login dialog closed is dead time; without
                # a reset the watchdog charges it to its first tick as a fake block.
                if ($this.Watchdog) { $this.Watchdog.Reset() }
                if ([System.Windows.Application]::Current) {
                    [System.Windows.Application]::Current.Run($this.Window)
                }
                else {
                    $this.Window.ShowDialog() | Out-Null
                }
            }
            catch {
                $this.Logger.LogException("Show failed", $_)
                if ($_.Exception.InnerException) {
                    $this.Logger.LogError("Inner Exception: $($_.Exception.InnerException.Message)")
                }
                throw
            }
        }
        else {
            $this.Logger.LogError("MainWindow is null.")
        }
    }

    # Hidden (tray) start: runs the WPF message loop WITHOUT showing the window
    # (ShutdownMode is OnExplicitShutdown, so it neither auto-shows nor auto-quits).
    [void] ShowHidden() {
        if (-not $this.Window) {
            $this.Logger.LogError("MainWindow is null.")
            return
        }
        try {
            # Create the native HWND without showing the window (raises SourceInitialized),
            # so the global hotkey registers even when we start straight to the tray.
            [void][System.Windows.Interop.WindowInteropHelper]::new($this.Window).EnsureHandle()
            # Same pumpless-span reset as Show(): don't charge startup to the first tick.
            if ($this.Watchdog) { $this.Watchdog.Reset() }
            if ([System.Windows.Application]::Current) {
                [System.Windows.Application]::Current.Run()
            }
        }
        catch {
            $this.Logger.LogException("ShowHidden failed", $_)
            throw
        }
    }
}
