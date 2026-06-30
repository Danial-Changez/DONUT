using namespace System.Windows
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\ConfigManager.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Services\ResourceService.psm1"
using module ".\ConfigPresenter.psm1"
using module ".\LogsPresenter.psm1"
using module ".\HomePresenter.psm1"
using module ".\ToastService.psm1"

<#
.SYNOPSIS
    Owns the main window, the navigation rail, and the child presenters.

.DESCRIPTION
    Builds and shows MainWindow, loads each page's view on demand, switches the
    active page from the rail, and constructs the Home / Config / Logs presenters
    plus the shared ToastService. Applies the merged XAML resources to the window.
#>
class MainPresenter {
    [AppConfig] $Config
    [ConfigManager] $ConfigManager
    [System.Windows.Window] $Window
    [hashtable] $Controls
    [hashtable] $Views
    [hashtable] $Headers
    [ConfigPresenter] $ConfigPresenter
    [LogsPresenter] $LogsPresenter
    [HomePresenter] $HomePresenter
    [NetworkProbe] $NetworkProbe
    [LogService] $Logger
    [ResourceService] $Resources
    [ToastService] $ToastService
    [bool] $RailCollapsed

    # Toggle-button graphics: full DONUT wordmark when expanded, donut icon when collapsed.
    hidden [System.Windows.Media.Imaging.BitmapImage] $LogoImage
    hidden [System.Windows.Media.Imaging.BitmapImage] $DonutIcon

    # Rail (sidebar) widths for the collapse/expand animation.
    hidden static [double] $RailExpandedWidth = 250
    hidden static [double] $RailCollapsedWidth = 72

    MainPresenter([AppConfig] $config, [ConfigManager] $configManager, [NetworkProbe] $networkProbe, [ResourceService] $resources) {
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

        # Load XAML. Read through a stream we explicitly dispose so the view file
        # isn't left locked for the app's lifetime (an XmlReader/XamlReader holds
        # the handle otherwise, blocking edits to the .xaml on disk).
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
            [System.Windows.Forms.MessageBox]::Show($msg, "XAML Load Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            throw $msg
        }

        $this.Resources.ApplyResourcesToWindow($this.Window)
        $this.Logger.LogDebug("MainWindow merged resource dictionaries: $($this.Window.Resources.MergedDictionaries.Count)")
        if ($this.Window.Resources.MergedDictionaries.Count -eq 0) {
            $this.Logger.LogWarning("No resources merged into MainWindow.")
        }

        # Find Controls
        $this.Controls = @{}
        $this.Controls['contentMain'] = $this.Window.FindName("contentMain")
        
        $this.LoadImages()
        
        # Navigation Buttons
        $this.Controls['btnHome'] = $this.Window.FindName("btnHome")
        $this.Controls['btnConfig'] = $this.Window.FindName("btnConfig")
        $this.Controls['btnLogs'] = $this.Window.FindName("btnLogs")

        # Collapsible rail
        $this.Controls['sidebar'] = $this.Window.FindName("sidebar")
        $this.Controls['btnRailToggle'] = $this.Window.FindName("btnRailToggle")
        # The logo is now the toggle button itself (its image swaps on collapse),
        # so it is NOT part of the fading label set.
        $this.Controls['railLabels'] = @(
            $this.Window.FindName("lblHome"),
            $this.Window.FindName("lblConfig"),
            $this.Window.FindName("lblLogs")
        ) | Where-Object { $_ }

        # Toast overlay service (shared with sub-presenters that need notifications)
        $toastHost = $this.Window.FindName("toastHost")
        if ($toastHost) {
            $this.ToastService = [ToastService]::new($toastHost)
        }
        
        # Headers
        $this.Headers = @{}
        $this.Headers['Home'] = $this.Window.FindName("headerHome")
        $this.Headers['Config'] = $this.Window.FindName("headerConfig")
        $this.Headers['Logs'] = $this.Window.FindName("headerLogs")

        $this.Views = @{}
        
        # Home View & Presenter
        $homeView = $this.LoadView("HomeView.xaml")
        $this.Views['Home'] = $homeView
        if ($homeView) {
            $this.HomePresenter = [HomePresenter]::new($this.Config, $homeView, $this.NetworkProbe, $this.Resources, $this.ToastService, $this.ConfigManager)
        }
        
        # Config View & Presenter
        $configView = $this.LoadView("ConfigView.xaml")
        $this.Views['Config'] = $configView
        if ($configView) {
            $this.ConfigPresenter = [ConfigPresenter]::new($this.Config, $this.ConfigManager, $configView)
        }

        # Logs
        $logsView = $this.LoadView("LogsView.xaml")
        $this.Views['Logs'] = $logsView
        if ($logsView) {
            $this.LogsPresenter = [LogsPresenter]::new($this.Config, $logsView)
        }

        # Bind Navigation Events
        $presenter = $this
        $this.Controls['btnHome'].Add_Click({ $presenter.NavigateTo('Home') }.GetNewClosure())
        $this.Controls['btnConfig'].Add_Click({ $presenter.NavigateTo('Config') }.GetNewClosure())
        $this.Controls['btnLogs'].Add_Click({ $presenter.NavigateTo('Logs') }.GetNewClosure())

        # Rail collapse / expand
        if ($this.Controls['btnRailToggle']) {
            $this.Controls['btnRailToggle'].Add_Click({ $presenter.ToggleRail() }.GetNewClosure())
        }
        
        # Window Control Events
        $btnClose = $this.Window.FindName("btnClose")
        if ($btnClose) { $btnClose.Add_Click({ $presenter.Window.Close() }.GetNewClosure()) }
        
        $btnMinimize = $this.Window.FindName("btnMinimize")
        if ($btnMinimize) { $btnMinimize.Add_Click({ $presenter.Window.WindowState = 'Minimized' }.GetNewClosure()) }
        
        $btnMaximize = $this.Window.FindName("btnMaximize")
        if ($btnMaximize) { 
            $btnMaximize.Add_Click({ 
                if ($presenter.Window.WindowState -eq 'Maximized') {
                    $presenter.Window.WindowState = 'Normal'
                } else {
                    $presenter.Window.WindowState = 'Maximized'
                }
            }.GetNewClosure()) 
        }

        # Drag Move
        $this.Window.Add_MouseLeftButtonDown({ 
            if ($_.ButtonState -eq 'Pressed') { $presenter.Window.DragMove() } 
        }.GetNewClosure())

        # Shutdown on Close
        $this.Window.Add_Closed({ 
            if ([System.Windows.Application]::Current) {
                [System.Windows.Application]::Current.Shutdown() 
            }
        }.GetNewClosure())

        # Default Navigation
        $this.NavigateTo('Home')
    }

    [void] LoadImages() {
        $assetsPath = Join-Path (Split-Path $this.Config.SourceRoot -Parent) "assets\Images"
        $logoPath = Join-Path $assetsPath "logo yellow arrow.png"
        $iconPath = Join-Path $assetsPath "donut icon48x48.ico"

        if (Test-Path $logoPath) {
            $this.LogoImage = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]::new($logoPath))
        }
        if (Test-Path $iconPath) {
            $this.DonutIcon = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]::new($iconPath))
        }

        # Starts expanded -> show the full wordmark on the toggle button.
        $logo = $this.Window.FindName("Logo")
        if ($logo -and $this.LogoImage) { $logo.Source = $this.LogoImage }
    }

    [object] LoadView([string]$fileName) {
        $path = Join-Path $this.Config.SourceRoot "UI\Views\$fileName"
        if (Test-Path $path) {
            try {
                # Stream is disposed so the view file isn't left locked while the
                # app runs (see Initialize).
                $stream = [System.IO.File]::OpenRead($path)
                try {
                    return [System.Windows.Markup.XamlReader]::Load($stream)
                }
                finally {
                    $stream.Dispose()
                }
            } catch {
                $this.Logger.LogException("Failed to load view $fileName", $_)
            }
        }
        return $null
    }

    [void] NavigateTo([string]$viewName) {
        if ($this.Views.ContainsKey($viewName) -and $this.Views[$viewName]) {
            $this.Controls['contentMain'].Content = $this.Views[$viewName]

            # Gentle fade-in transition on view switch.
            $content = $this.Controls['contentMain']
            if ($content) {
                $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(0, 1, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
                $content.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
            }

            # Refresh presenter state when navigating
            if ($viewName -eq 'Home' -and $this.HomePresenter) {
                $this.HomePresenter.UpdateSearchButtonLabel()
            }
        }
        
        # Toggle header visibility
        foreach ($headerKey in $this.Headers.Keys) {
            if ($this.Headers[$headerKey]) {
                $this.Headers[$headerKey].Visibility = if ($headerKey -eq $viewName) { 'Visible' } else { 'Collapsed' }
            }
        }
    }

    # Collapses the sidebar to an icon-only rail (or expands it back), animating
    # the width and fading the text labels so only the icons remain when narrow.
    [void] ToggleRail() {
        $sidebar = $this.Controls['sidebar']
        if (-not $sidebar) { return }

        $this.RailCollapsed = -not $this.RailCollapsed

        # Swap the toggle graphic: donut icon when collapsed, full wordmark when expanded.
        $logo = $this.Window.FindName("Logo")
        if ($logo) {
            if ($this.RailCollapsed) {
                if ($this.DonutIcon) { $logo.Source = $this.DonutIcon }
            } elseif ($this.LogoImage) {
                $logo.Source = $this.LogoImage
            }
        }

        $targetWidth = if ($this.RailCollapsed) {
            [MainPresenter]::RailCollapsedWidth
        } else {
            [MainPresenter]::RailExpandedWidth
        }
        $targetOpacity = if ($this.RailCollapsed) { 0.0 } else { 1.0 }

        $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))
        $ease = [System.Windows.Media.Animation.QuadraticEase]::new()
        $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut

        # Animate the rail width.
        $widthAnim = [System.Windows.Media.Animation.DoubleAnimation]::new()
        $widthAnim.To = $targetWidth
        $widthAnim.Duration = $duration
        $widthAnim.EasingFunction = $ease
        $sidebar.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $widthAnim)

        # Fade the text labels. Labels collapse out faster than they fade in so
        # they don't appear before the rail has room for them.
        foreach ($label in $this.Controls['railLabels']) {
            $fade = [System.Windows.Media.Animation.DoubleAnimation]::new()
            $fade.To = $targetOpacity
            $fade.Duration = $duration
            $label.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        }
    }

    [void] Show() {
        if ($this.Window) {
            try {
                if ([System.Windows.Application]::Current) {
                    [System.Windows.Application]::Current.Run($this.Window)
                } else {
                    $this.Window.ShowDialog() | Out-Null
                }
            } catch {
                $this.Logger.LogException("Show failed", $_)
                if ($_.Exception.InnerException) {
                    $this.Logger.LogError("Inner Exception: $($_.Exception.InnerException.Message)")
                }
                throw
            }
        } else {
            $this.Logger.LogError("MainWindow is null.")
        }
    }
}
