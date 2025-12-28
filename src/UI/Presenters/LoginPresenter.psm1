using namespace System.Windows
using namespace System.Windows.Threading
using module '..\..\Services\SelfUpdateService.psm1'
using module '..\..\Services\ResourceService.psm1'

class LoginPresenter {
    [SelfUpdateService]$Service
    [ResourceService]$Resources
    [Window]$LoginWindow
    [DispatcherTimer]$PollTimer
    [string]$DeviceCode
    [int]$Interval
    [bool]$LoginSuccess = $false

    LoginPresenter([SelfUpdateService]$service, [ResourceService]$resources) {
        $this.Service = $service
        $this.Resources = $resources
    }

    [bool] ShowLogin() {
        $this.LoginWindow = $this.LoadXaml('LoginWindow.xaml')
        
        # Find Controls
        $btnGitHubAuth = $this.LoginWindow.FindName('btnGitHubAuth')
        $btnClose = $this.LoginWindow.FindName('btnClose')
        $btnMinimize = $this.LoginWindow.FindName('btnMinimize')
        $panelControlBar = $this.LoginWindow.FindName('panelControlBar')
        
        # Events
        $presenter = $this
        if ($btnGitHubAuth) { $btnGitHubAuth.Add_Click({ $presenter.StartAuthFlow() }.GetNewClosure()) }
        if ($btnClose) { $btnClose.Add_Click({ $presenter.LoginWindow.Close() }.GetNewClosure()) }
        if ($btnMinimize) { $btnMinimize.Add_Click({ $presenter.LoginWindow.WindowState = 'Minimized' }.GetNewClosure()) }
        if ($panelControlBar) { 
            $panelControlBar.Add_MouseLeftButtonDown({ 
                if ($_.ButtonState -eq 'Pressed') { $presenter.LoginWindow.DragMove() } 
            }.GetNewClosure()) 
        }

        $this.LoginSuccess = $false
        
        # Load Images
        $this.LoadImages()
        
        $this.LoginWindow.ShowDialog() | Out-Null
        return $this.LoginSuccess
    }

    [void] LoadImages() {
        $assetsPath = Join-Path (Split-Path $this.Resources.SourceRoot -Parent) "assets\Images"
        
        # Background
        $bgPath = Join-Path $assetsPath "background.jpeg"
        if (Test-Path $bgPath) {
            $bgBrush = $this.LoginWindow.FindName("Background")
            if ($bgBrush) {
                $uri = [Uri]::new($bgPath)
                $image = [System.Windows.Media.Imaging.BitmapImage]::new($uri)
                $bgBrush.ImageSource = $image
            }
        }

        # GitHub Button
        $ghPath = Join-Path $assetsPath "GitHub.png"
        if (Test-Path $ghPath) {
            $btn = $this.LoginWindow.FindName("btnGitHubAuth")
            if ($btn) {
                $uri = [Uri]::new($ghPath)
                $image = [System.Windows.Media.Imaging.BitmapImage]::new($uri)
                $brush = [System.Windows.Media.ImageBrush]::new($image)
                $btn.Background = $brush
            }
        }
    }

    [void] StartAuthFlow() {
        try {
            $response = $this.Service.StartDeviceFlow()
            $this.DeviceCode = $response.device_code
            $this.Interval = $response.interval
            
            $output = $this.LoginWindow.FindName('Output')
            if ($output) {
                $output.Text = "Please visit:`n$($response.verification_uri)`n`nAnd enter code:`n$($response.user_code)"
            }
            
            Start-Process $response.verification_uri

            # Start Polling Timer
            $this.PollTimer = [DispatcherTimer]::new()
            $this.PollTimer.Interval = [TimeSpan]::FromSeconds($this.Interval)
            $this.PollTimer.Add_Tick({ $this.PollToken() })
            $this.PollTimer.Start()
        }
        catch {
            $output = $this.LoginWindow.FindName('Output')
            if ($output) { $output.Text = "Error starting flow: $_" }
        }
    }

    [void] PollToken() {
        $result = $this.Service.PollForToken($this.DeviceCode, $this.Interval)
        
        if ($result.access_token) {
            $this.Service.SaveToken($result)
            $this.PollTimer.Stop()
            $this.LoginSuccess = $true
            $this.LoginWindow.Close()
        }
        elseif ($result.Error -eq 'authorization_pending') {
            # Continue polling
        }
        elseif ($result.Error -eq 'slow_down') {
            $this.PollTimer.Interval = $this.PollTimer.Interval.Add([TimeSpan]::FromSeconds(5))
        }
        else {
            $output = $this.LoginWindow.FindName('Output')
            if ($output) { $output.Text = "Error: $($result.Error)" }
            $this.PollTimer.Stop()
        }
    }

    [Window] LoadXaml([string]$FileName) {
        $xamlPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Views\$FileName"
        if (-not (Test-Path $xamlPath)) {
            Write-Error "XAML file not found: $xamlPath"
            return $null
        }

        try {
            $reader = [System.Xml.XmlReader]::Create($xamlPath)
            $window = [System.Windows.Markup.XamlReader]::Load($reader)
            $reader.Close()
            
            # Apply resources using the service
            $this.Resources.ApplyResourcesToWindow($window)
            
            return $window
        }
        catch {
            Write-Error "Failed to load XAML $FileName : $_"
            return $null
        }
    }
}