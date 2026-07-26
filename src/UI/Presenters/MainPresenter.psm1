using namespace System.Windows
using namespace System.Windows.Threading
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Models\HotkeyGesture.psm1"
using module "..\..\Models\TempPassword.psm1"
using module "..\..\Core\ConfigManager.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\DispatcherWatchdog.psm1"
using module "..\..\Core\RunspaceManager.psm1"
using module "..\..\Core\PoolScriptJob.psm1"
using module "..\..\Core\ViewLoader.psm1"
using module "..\..\Services\ResourceService.psm1"
using namespace Donut.Mvvm
using namespace Donut.Interop
using module ".\SettingsPresenter.psm1"
using module ".\HomePresenter.psm1"
using module ".\TourPresenter.psm1"
using module ".\TrayPresenter.psm1"
using module ".\ToastService.psm1"
using module "..\ViewModels\MainViewModel.psm1"
using module "..\ViewModels\ResetPasswordViewModel.psm1"

<#
.SYNOPSIS
    Owns the main window, its child presenters, and the settings overlay.

.DESCRIPTION
    Builds and shows MainWindow, hosts the Home page, opens the settings view in its
    overlay on demand, and constructs the Home / Settings presenters plus the shared
    ToastService. Applies the merged XAML resources to the window. Also owns the
    shell overlays: QR (BitLocker keys + temp passwords) and reset-password.
#>
class MainPresenter {
    [AppConfig] $Config
    [ConfigManager] $ConfigManager
    [System.Windows.Window] $Window
    [hashtable] $Controls
    [hashtable] $Views
    [SettingsPresenter] $SettingsPresenter
    [HomePresenter] $HomePresenter
    [TrayPresenter] $TrayPresenter
    [object] $Tour                   # TourPresenter (guided first-run tour)
    [NetworkProbe] $NetworkProbe
    [LogService] $Logger
    [DispatcherWatchdog] $Watchdog   # diagnostic: logs UI-thread stalls (loader-lock freeze)
    [ResourceService] $Resources
    [ToastService] $ToastService
    [MainViewModel] $MainVm
    [ResetPasswordViewModel] $ResetVm

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

        # Home is built eagerly; Settings builds lazily on first open, so
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
        # Reset-password overlay: built once; the finder's Reset action arms + opens it.
        $this.ResetVm = [ResetPasswordViewModel]::new()
        $this.MainVm.ResetVm = $this.ResetVm
        $closeReset = { param($p) $presenter.CloseReset() }.GetNewClosure()
        $this.MainVm.CloseResetCommand = [RelayCommand]::new([System.Action[object]]$closeReset)
        $generate = { param($p) $presenter.OnGeneratePassword() }.GetNewClosure()
        $this.ResetVm.GenerateCommand = [RelayCommand]::new([System.Action[object]]$generate)
        $copyPw = { param($p) $presenter.OnCopyPassword() }.GetNewClosure()
        $this.ResetVm.CopyCommand = [RelayCommand]::new([System.Action[object]]$copyPw)
        $pwQr = { param($p) $presenter.OnShowPasswordQr() }.GetNewClosure()
        $this.ResetVm.ShowQrCommand = [RelayCommand]::new([System.Action[object]]$pwQr)
        $applyReset = { param($p) $presenter.OnApplyReset() }.GetNewClosure()
        $canApply = { param($p) -not $presenter.ResetVm.IsBusy }.GetNewClosure()
        $this.ResetVm.ApplyCommand = [RelayCommand]::new(
            [System.Action[object]]$applyReset, [System.Func[object, bool]]$canApply)
        $showReset = { param($r) $presenter.ShowReset($r) }.GetNewClosure()
        if ($this.HomePresenter -and $this.HomePresenter.Finder) {
            $this.HomePresenter.Finder.OnShowReset = $showReset
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

        # Permanent diagnostic: logs UI-thread stalls over 1 s with GC-delta fingerprints.
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

    # Applies the debug-logging toggle to the live logger; workers pick the effective
    # state up per job (BuildWorkerArgs ships Logger.DebugEnabled). -DebugLog wins.
    [void] ApplyDebugLogging() {
        $effective = $this.Config.GetDebugLogging() -or [bool]$global:DebugLogStart
        $this.Logger.DebugEnabled = $effective
        $this.Logger.LogInfo("Debug logging " + $(if ($effective) { 'enabled' } else { 'disabled' }) + " (settings toggle).")
    }

    # Runs a pool worker script (a .ps1 whose using-module class types resolve in the
    # runspace) and reaps it on the UI thread - no runspace-less callback (see repo notes).
    hidden [void] RunOnPool([string]$scriptPath, [hashtable]$params, [object]$onDone) {
        try {
            $job = [PoolScriptJob]::Start($scriptPath, $params)
            $job.OnDone = $onDone

            if ($null -eq $this.PoolJobs) {
                $this.PoolJobs = [System.Collections.Generic.List[object]]::new()
            }
            $this.PoolJobs.Add($job)

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
        foreach ($job in @($this.PoolJobs | Where-Object { $_.Handle.IsCompleted })) {
            $result = [PoolScriptJob]::Complete($job, $this.Logger)
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

    # Page-level load: missing/broken views log and return null (the shell copes);
    # region composition inside HomePresenter uses ViewLoader directly and fails loud.
    [object] LoadView([string]$fileName) {
        try {
            return [ViewLoader]::Load($this.Config.SourceRoot, "UI\Views\$fileName")
        }
        catch {
            $this.Logger.LogException("Failed to load view $fileName", $_)
        }
        return $null
    }

    # Builds the settings view + presenter once, on first open, and hosts it in
    # the overlay card. SettingsPresenter persists edits live (no Save button).
    hidden [void] EnsureSettingsView() {
        if ($this.Views.ContainsKey('Settings') -and $this.Views['Settings']) { return }

        $settingsView = $this.LoadView("SettingsView.xaml")
        $this.Views['Settings'] = $settingsView
        if ($settingsView) {
            $presenter = $this
            # Real-time settings re-apply the bits that live outside the config file, each
            # when its own control changes (the overlay closes via its X / Esc / backdrop).
            $sideEffects = @{
                Hotkey         = { $presenter.ApplyHotkey() }.GetNewClosure()
                WindowShortcut = { $presenter.ApplyWindowShortcuts() }.GetNewClosure()
                StartupTask    = { $presenter.ApplyStartupTask() }.GetNewClosure()
                DebugLog       = { $presenter.ApplyDebugLogging() }.GetNewClosure()
            }
            $this.SettingsPresenter = [SettingsPresenter]::new(
                $this.Config, $this.ConfigManager, $settingsView, $this.ToastService, $sideEffects)
            if ($this.Controls['settingsContent']) {
                $this.Controls['settingsContent'].Content = $settingsView
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

    # Opens the settings overlay, building the settings view lazily on first use. A
    # visibility toggle (not ShowDialog), so background jobs keep pumping behind it.
    [void] OpenSettings() {
        $this.EnsureSettingsView()
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

    # Pops the QR overlay for a BitLocker recovery key (the Lens path keeps this
    # 2-arg shape; the caption prefix and hint stay its own).
    [void] ShowQr([string]$payload, [string]$caption) {
        $this.ShowQr($payload, "BitLocker recovery key - $caption",
            'Scan to read the recovery key, then close this.')
    }

    # Pops the QR overlay for any secret, rendered to an in-memory image only (never
    # written to disk). A render failure toasts instead of opening an empty card.
    [void] ShowQr([string]$payload, [string]$caption, [string]$hint) {
        if ([string]::IsNullOrWhiteSpace($payload)) { return }
        $img = $this.BuildQrImage($payload)
        if ($null -eq $img) {
            if ($this.ToastService) {
                $this.ToastService.ShowError($caption, "Couldn't render the QR code.")
            }
            return
        }
        $this.MainVm.Set('QrImage', $img)
        $this.MainVm.Set('QrCaption', $caption)
        $this.MainVm.Set('QrHint', $hint)
        $this.MainVm.Set('IsQrOpen', $true)
        # Focus the card so the overlay's Esc key binding is in scope (settings idiom).
        $qrCard = $this.Window.FindName('qrCard')
        if ($qrCard) { [void]$qrCard.Focus() }
    }

    [void] CloseQr() {
        if ($this.MainVm) { $this.MainVm.Set('IsQrOpen', $false) }
        # Hand Esc scope back to the reset card when the QR was popped over it.
        if ($this.MainVm -and $this.MainVm.IsResetOpen) {
            $card = $this.Window.FindName('resetCard')
            if ($card) { [void]$card.Focus() }
        }
    }

    # Arms and opens the reset overlay for a finder user row (the Reset action).
    [void] ShowReset([object]$target) {
        if ($null -eq $target -or $null -eq $this.ResetVm) { return }
        $this.ResetVm.SetTarget($target)
        $this.ClearResetError()
        $this.MainVm.Set('IsResetOpen', $true)
        # Focus the card so the overlay's Esc key binding is in scope (settings idiom).
        $card = $this.Window.FindName('resetCard')
        if ($card) { [void]$card.Focus() }
    }

    # Closing wipes the secret - the temp password lives only while the card is up.
    [void] CloseReset() {
        if ($this.ResetVm) { $this.ResetVm.ClearSecrets() }
        $this.ClearResetError()
        if ($this.MainVm) { $this.MainVm.Set('IsResetOpen', $false) }
    }

    hidden [void] ClearResetError() {
        $box = $this.Window.FindName('resetPasswordBox')
        if ($box) { $box.Tag = $null }
    }

    hidden [void] OnGeneratePassword() {
        $this.ResetVm.Set('Password', [TempPassword]::Generate())
        $this.ClearResetError()
    }

    hidden [void] OnCopyPassword() {
        $vm = $this.ResetVm
        if ([string]::IsNullOrWhiteSpace($vm.Password)) { return }
        try {
            Set-Clipboard -Value $vm.Password
            if ($this.ToastService) {
                $this.ToastService.ShowInfo('Reset password', 'Temporary password copied.')
            }
        }
        catch { $this.Logger.LogWarning("Clipboard copy failed: $($_.Exception.Message)") }
    }

    hidden [void] OnShowPasswordQr() {
        $vm = $this.ResetVm
        if ([string]::IsNullOrWhiteSpace($vm.Password)) { return }
        $this.ShowQr($vm.Password, "Temporary password - $($vm.DisplayName)",
            'Scan to read the temporary password, then close this.')
    }

    # Validates, then runs the reset worker on the pool. The password crosses the
    # boundary as a SecureString and is never logged or written anywhere.
    hidden [void] OnApplyReset() {
        $vm = $this.ResetVm
        if ($null -eq $vm -or $vm.IsBusy) { return }
        $plain = ([string]$vm.Password).Trim()
        if ($plain.Length -lt 8) {
            $box = $this.Window.FindName('resetPasswordBox')
            if ($box) { $box.Tag = 'error' }
            if ($this.ToastService) {
                $this.ToastService.ShowWarning('Reset password',
                    'Use at least 8 characters (or Generate one).')
            }
            return
        }
        $this.ClearResetError()
        $vm.Set('IsBusy', $true)
        if ($vm.ApplyCommand) { $vm.ApplyCommand.RaiseCanExecuteChanged() }

        $workerPath = Join-Path $this.Config.SourceRoot 'Scripts\AdResetPasswordWorker.ps1'
        $presenter = $this
        $onDone = { param($result) $presenter.OnResetDone($result) }.GetNewClosure()
        $this.RunOnPool($workerPath, @{
                Sam           = $vm.TargetSam
                Domain        = $vm.TargetDomain
                Password      = [TempPassword]::ToSecure($plain)
                ChangeAtLogon = [bool]$vm.ChangeAtLogon
            }, $onDone)
        if ($this.ToastService) {
            $this.ToastService.ShowInfo('Reset password', "Resetting $($vm.TargetSam)...")
        }
    }

    # Success keeps the overlay open - the operator still has to hand the password
    # over (copy / QR / read out); closing it is what wipes the secret.
    hidden [void] OnResetDone([object]$result) {
        $vm = $this.ResetVm
        $vm.Set('IsBusy', $false)
        if ($vm.ApplyCommand) { $vm.ApplyCommand.RaiseCanExecuteChanged() }
        $last = @($result)[-1]
        if ($null -ne $last -and [bool]$last) {
            $flag = $(if ($vm.ChangeAtLogon) { ' Change required at next logon.' } else { '' })
            $this.ToastService.ShowSuccess('Reset password',
                "Password reset for $($vm.TargetSam).$flag")
        }
        else {
            $this.ToastService.ShowError('Reset password',
                "Could not reset $($vm.TargetSam) - see the log for details.")
        }
    }

    # Resolves a UIColors Color key to RGBA bytes for the QR encoder ($fallback when absent).
    hidden [byte[]] QrColorBytes([string]$key, [byte[]]$fallback) {
        $c = $this.Window.TryFindResource($key)
        if ($c -is [System.Windows.Media.Color]) { return [byte[]]($c.R, $c.G, $c.B, $c.A) }
        return $fallback
    }

    # Encodes text to a QR PNG (in memory) via the bundled QR helper, returned as a frozen,
    # cross-thread-safe BitmapImage (ECC level Q for glare tolerance). $null on any failure.
    hidden [System.Windows.Media.ImageSource] BuildQrImage([string]$payload) {
        try {
            # INVERTED by choice (see UIColors QrModule* for the revert recipe): violet-300
            # modules on a transparent back so the code blends into the dark card.
            $modules = $this.QrColorBytes('QrModuleColor', [byte[]](0xC4, 0xB5, 0xFD, 0xFF))
            $back = $this.QrColorBytes('QrModuleBackColor', [byte[]](0x00, 0x00, 0x00, 0x00))
            $png = [Donut.Qr.QrCode]::EncodePng($payload, 20, $modules, $back)
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
