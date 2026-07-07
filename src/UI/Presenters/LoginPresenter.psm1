using namespace System.Windows
using namespace System.Windows.Threading
using namespace Donut.Mvvm
using module '..\..\Services\SelfUpdateService.psm1'
using module '..\..\Services\ResourceService.psm1'
using module '..\..\Core\LogService.psm1'
using module '..\..\Models\DeviceFlowDecision.psm1'
using module '..\ViewModels\LoginViewModel.psm1'

<#
.SYNOPSIS
    Drives the GitHub device-flow sign-in window.

.DESCRIPTION
    Shows the login window, starts the device flow (SelfUpdateService), displays
    the user code, and polls for the token on a DispatcherTimer — applying the
    pure DeviceFlowDecision (authorize / keep polling / slow down / fail) to the
    real UI and timer.
#>
class LoginPresenter {
    [SelfUpdateService]$Service
    [ResourceService]$Resources
    [LogService]$Logger
    [Window]$LoginWindow
    [LoginViewModel]$LoginVm
    [DispatcherTimer]$PollTimer
    [string]$DeviceCode
    [int]$Interval
    [bool]$LoginSuccess = $false

    LoginPresenter([SelfUpdateService]$service, [ResourceService]$resources) {
        $this.Service = $service
        $this.Resources = $resources
        $this.Logger = $resources.Logger
    }

    [bool] ShowLogin() {
        $this.LoginWindow = $this.LoadXaml('LoginWindow.xaml')

        # Content VM: the output panel binds OutputText; the GitHub button binds
        # AuthCommand. Window chrome (close/minimize/drag) stays event-wired.
        $this.LoginVm = [LoginViewModel]::new()
        $presenter = $this
        $auth = { param($p) $presenter.StartAuthFlow() }.GetNewClosure()
        $this.LoginVm.AuthCommand = [RelayCommand]::new([System.Action[object]]$auth)
        $this.LoginWindow.DataContext = $this.LoginVm

        $btnClose = $this.LoginWindow.FindName('btnClose')
        $btnMinimize = $this.LoginWindow.FindName('btnMinimize')
        $panelControlBar = $this.LoginWindow.FindName('panelControlBar')

        if ($btnClose) { $btnClose.Add_Click({ $presenter.LoginWindow.Close() }.GetNewClosure()) }
        if ($btnMinimize) {
            $btnMinimize.Add_Click({ $presenter.LoginWindow.WindowState = 'Minimized' }.GetNewClosure())
        }
        if ($panelControlBar) {
            $panelControlBar.Add_MouseLeftButtonDown({
                    if ($_.ButtonState -eq 'Pressed') { $presenter.LoginWindow.DragMove() }
                }.GetNewClosure())
        }

        $this.LoginSuccess = $false

        $this.LoadImages()

        # Shown from the worker STA thread; force it to the front once rendered so it does
        # not open hidden behind other windows (see MainPresenter for the same pattern).
        $this.LoginWindow.Add_ContentRendered({
                $lw = $presenter.LoginWindow
                $lw.Activate()
                $lw.Topmost = $true
                $lw.Topmost = $false
                $lw.Focus()
            }.GetNewClosure())

        $this.LoginWindow.ShowDialog() | Out-Null
        return $this.LoginSuccess
    }

    [void] LoadImages() {
        $assetsPath = Join-Path (Split-Path $this.Resources.SourceRoot -Parent) "assets\Images"

        $bgPath = Join-Path $assetsPath "background.jpeg"
        if (Test-Path $bgPath) {
            $bgBrush = $this.LoginWindow.FindName("Background")
            if ($bgBrush) {
                $uri = [Uri]::new($bgPath)
                $image = [System.Windows.Media.Imaging.BitmapImage]::new($uri)
                $bgBrush.ImageSource = $image
            }
        }

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
        # Re-entry guard: a second click starts a fresh device flow, so stop the old
        # poll first or its dead-code failure would overwrite the new code display.
        if ($this.PollTimer -and $this.PollTimer.IsEnabled) { $this.PollTimer.Stop() }
        try {
            $response = $this.Service.InitiateDeviceFlow()
            $this.DeviceCode = $response.device_code
            $this.Interval = $response.interval

            $this.LoginVm.SetOutput("Please visit:`n$($response.verification_uri)`n`nAnd enter code:`n$($response.user_code)")

            Start-Process $response.verification_uri

            $presenter = $this
            $this.PollTimer = [DispatcherTimer]::new()
            $this.PollTimer.Interval = [TimeSpan]::FromSeconds($this.Interval)
            $this.PollTimer.Add_Tick({ $presenter.PollToken() }.GetNewClosure())
            $this.PollTimer.Start()
        }
        catch {
            $this.LoginVm.SetOutput("Error starting flow: $_")
        }
    }

    [void] PollToken() {
        $result = $this.Service.PollForToken($this.DeviceCode)
        $decision = [DeviceFlowDecision]::FromPollResult($result)

        switch ($decision.Outcome) {
            ([PollOutcome]::Authorized) {
                $this.Service.SaveToken($decision.TokenData)
                $this.PollTimer.Stop()
                $this.LoginSuccess = $true
                $this.LoginWindow.Close()
            }
            ([PollOutcome]::KeepPolling) {
                # Keep polling at the current interval.
            }
            ([PollOutcome]::SlowDown) {
                $this.PollTimer.Interval = $this.PollTimer.Interval.Add([TimeSpan]::FromSeconds(5))
            }
            ([PollOutcome]::Failed) {
                $this.LoginVm.SetOutput($decision.Message)
                $this.PollTimer.Stop()
            }
        }
    }

    [Window] LoadXaml([string]$FileName) {
        $xamlPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Views\$FileName"
        if (-not (Test-Path $xamlPath)) {
            $this.Logger.LogError("XAML file not found: $xamlPath")
            return $null
        }

        try {
            $reader = [System.Xml.XmlReader]::Create($xamlPath)
            $window = [System.Windows.Markup.XamlReader]::Load($reader)
            $reader.Close()

            $this.Resources.ApplyResourcesToWindow($window)

            return $window
        }
        catch {
            $this.Logger.LogException("Failed to load XAML $FileName", $_)
            return $null
        }
    }
}
