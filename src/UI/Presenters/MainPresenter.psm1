using namespace System.Windows
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\ConfigManager.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\DispatcherWatchdog.psm1"
using module "..\..\Services\ResourceService.psm1"
using namespace Donut.Mvvm
using namespace Donut.Interop
using module ".\ConfigPresenter.psm1"
using module ".\HomePresenter.psm1"
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
    [NetworkProbe] $NetworkProbe
    [LogService] $Logger
    [DispatcherWatchdog] $Watchdog   # diagnostic: logs UI-thread stalls (loader-lock freeze)
    [ResourceService] $Resources
    [ToastService] $ToastService
    [MainViewModel] $MainVm

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
                if ([System.Windows.Application]::Current) {
                    [System.Windows.Application]::Current.Shutdown()
                }
                [System.Environment]::Exit(0)
            }.GetNewClosure())

        # Shown from the worker STA thread, so Windows won't foreground it. Once rendered,
        # the brief Topmost toggle forces it to the front (needs no foreground-activation right).
        $this.Window.Add_ContentRendered({
                $w = $presenter.Window
                if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
                $w.Activate()
                $w.Topmost = $true
                $w.Topmost = $false
                $w.Focus()
            }.GetNewClosure())

        # Constrain maximize to the monitor work area - a WindowChrome window otherwise
        # overflows the screen edges and covers the taskbar. Needs the HWND, so wait.
        $this.Window.Add_SourceInitialized({
                try {
                    $hwnd = [Interop.WindowInteropHelper]::new($presenter.Window).Handle
                    if ($hwnd -ne [IntPtr]::Zero) {
                        [WindowChromeHelper]::ConstrainMaximize($hwnd)
                    }
                }
                catch { $presenter.Logger.LogException("Maximize constraint hook failed", $_) }
            }.GetNewClosure())

        # Diagnostic (remove once pinned): logs UI-thread stalls over 1 s - the freeze.
        $this.Watchdog = [DispatcherWatchdog]::new($this.Logger, 1000)
        $this.Watchdog.Start()

        $this.ShowHome()
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
            $onSaved = { $presenter.CloseSettings() }.GetNewClosure()
            $this.ConfigPresenter = [ConfigPresenter]::new(
                $this.Config, $this.ConfigManager, $configView, $this.ToastService, $onSaved)
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

    [void] Show() {
        if ($this.Window) {
            try {
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
}
