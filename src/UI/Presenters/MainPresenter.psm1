using namespace System.Windows
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\ConfigManager.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Services\ResourceService.psm1"
using module ".\ConfigPresenter.psm1"
using module ".\LogsPresenter.psm1"
using module ".\HomePresenter.psm1"
using module ".\BatteryPresenter.psm1"

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
    [BatteryPresenter] $BatteryPresenter
    [NetworkProbe] $NetworkProbe
    [ResourceService] $Resources

    MainPresenter([AppConfig] $config, [ConfigManager] $configManager, [NetworkProbe] $networkProbe, [ResourceService] $resources) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.NetworkProbe = $networkProbe
        $this.Resources = $resources
        $this.Initialize()
    }

    [void] Initialize() {
        $xamlPath = Join-Path $this.Config.SourceRoot "UI\Views\MainWindow.xaml"
        
        if (-not (Test-Path $xamlPath)) {
            throw "MainWindow.xaml not found at $xamlPath"
        }

        # Load XAML
        try {
            $reader = [System.Xml.XmlReader]::Create($xamlPath)
            $this.Window = [System.Windows.Markup.XamlReader]::Load($reader)
            $reader.Close()
            
            # Set as Main Window
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

        # Load Resources (Styles)
        $this.Resources.ApplyResourcesToWindow($this.Window)
        Write-Host "MainWindow Resources MergedDictionaries Count: $($this.Window.Resources.MergedDictionaries.Count)"
        if ($this.Window.Resources.MergedDictionaries.Count -eq 0) {
             [System.Windows.Forms.MessageBox]::Show("Warning: No resources merged into MainWindow", "Debug")
        }

        # Find Controls
        $this.Controls = @{}
        $this.Controls['contentMain'] = $this.Window.FindName("contentMain")
        
        # Load Images
        $this.LoadImages()
        
        # Navigation Buttons
        $this.Controls['btnHome'] = $this.Window.FindName("btnHome")
        $this.Controls['btnConfig'] = $this.Window.FindName("btnConfig")
        $this.Controls['btnLogs'] = $this.Window.FindName("btnLogs")
        $this.Controls['btnBattery'] = $this.Window.FindName("btnBattery")
        
        # Headers
        $this.Headers = @{}
        $this.Headers['Home'] = $this.Window.FindName("headerHome")
        $this.Headers['Config'] = $this.Window.FindName("headerConfig")
        $this.Headers['Logs'] = $this.Window.FindName("headerLogs")
        $this.Headers['Battery'] = $this.Window.FindName("headerBattery")

        # Load Sub-Views
        $this.Views = @{}
        
        # Home View & Presenter
        $homeView = $this.LoadView("HomeView.xaml")
        $this.Views['Home'] = $homeView
        if ($homeView) {
            $this.HomePresenter = [HomePresenter]::new($this.Config, $homeView, $this.NetworkProbe, $this.Resources)
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

        # Battery View & Presenter
        $batteryView = $this.LoadView("BatteryView.xaml")
        $this.Views['Battery'] = $batteryView
        if ($batteryView) {
            $this.BatteryPresenter = [BatteryPresenter]::new($this.Config, $batteryView, $this.NetworkProbe, $this.Resources)
        }

        # Bind Navigation Events
        $presenter = $this
        $this.Controls['btnHome'].Add_Click({ $presenter.NavigateTo('Home') }.GetNewClosure())
        $this.Controls['btnConfig'].Add_Click({ $presenter.NavigateTo('Config') }.GetNewClosure())
        $this.Controls['btnLogs'].Add_Click({ $presenter.NavigateTo('Logs') }.GetNewClosure())
        if ($this.Controls['btnBattery']) {
            $this.Controls['btnBattery'].Add_Click({ $presenter.NavigateTo('Battery') }.GetNewClosure())
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
        
        if (Test-Path $logoPath) {
            $logo = $this.Window.FindName("Logo")
            if ($logo) {
                $uri = [Uri]::new($logoPath)
                $image = [System.Windows.Media.Imaging.BitmapImage]::new($uri)
                $logo.Source = $image
            }
        }
    }

    [object] LoadView([string]$fileName) {
        $path = Join-Path $this.Config.SourceRoot "UI\Views\$fileName"
        if (Test-Path $path) {
            try {
                $reader = [System.Xml.XmlReader]::Create($path)
                return [System.Windows.Markup.XamlReader]::Load($reader)
            } catch {
                Write-Error "Failed to load view $fileName : $_"
            }
        }
        return $null
    }

    [void] NavigateTo([string]$viewName) {
        # Set main content
        if ($this.Views.ContainsKey($viewName) -and $this.Views[$viewName]) {
            $this.Controls['contentMain'].Content = $this.Views[$viewName]
            
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

    [void] Show() {
        if ($this.Window) {
            try {
                if ([System.Windows.Application]::Current) {
                    [System.Windows.Application]::Current.Run($this.Window)
                } else {
                    $this.Window.ShowDialog() | Out-Null
                }
            } catch {
                Write-Error "Show failed: $_"
                if ($_.Exception.InnerException) {
                    Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
                }
                throw
            }
        } else {
            Write-Error "MainWindow is null!"
        }
    }
}
