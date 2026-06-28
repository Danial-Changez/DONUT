using namespace System.Windows.Controls
using namespace System.Windows.Threading
using namespace System.Collections.Generic
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\HostListSource.psm1"
using module ".\DialogPresenter.psm1"
using module ".\AsyncJobPresenter.psm1"
using module "..\..\Services\ResourceService.psm1"

class BatteryPresenter : AsyncJobPresenter {
    [AppConfig] $Config
    [System.Windows.FrameworkElement] $ViewContent
    [TextBox] $SearchBar
    [Button] $RunButton
    [Button] $ClearButton
    [TabControl] $ReportTabs
    [NetworkProbe] $NetworkProbe
    [LogService] $Logger
    [DialogPresenter] $DialogPresenter
    [HostListSource] $HostListSource

    # Async State ($ActiveJobs is inherited from AsyncJobPresenter)
    [DispatcherTimer] $Timer

    BatteryPresenter([AppConfig] $config, [System.Windows.FrameworkElement] $view, [NetworkProbe] $networkProbe, [ResourceService] $resources) {
        $this.Config = $config
        $this.ViewContent = $view
        $this.NetworkProbe = $networkProbe
        $this.Logger = $networkProbe.Logger
        $this.DialogPresenter = [DialogPresenter]::new($resources)
        $this.HostListSource = [HostListSource]::new($config.SourceRoot)
        # $this.ActiveJobs is initialized by the AsyncJobPresenter base constructor.

        # Initialize Timer for async polling
        $presenter = $this
        $this.Timer = [DispatcherTimer]::new()
        $this.Timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $this.Timer.Add_Tick({ $presenter.OnTimerTick($this, $null) }.GetNewClosure())
        $this.Timer.Start()

        $this.Initialize()
    }

    [void] Initialize() {
        $this.SearchBar = $this.ViewContent.FindName('BatterySearchBar')
        $this.RunButton = $this.ViewContent.FindName('btnRunBatteryReport')
        $this.ClearButton = $this.ViewContent.FindName('btnClearBatteryTabs')
        $this.ReportTabs = $this.ViewContent.FindName('BatteryReportTabs')

        $presenter = $this
        if ($this.RunButton) {
            $this.RunButton.Add_Click({ $presenter.OnRunReport() }.GetNewClosure())
        }
        
        if ($this.ClearButton) {
            $this.ClearButton.Add_Click({ $presenter.OnClearTabs() }.GetNewClosure())
        }

        $this.LoadHostList()
    }

    [void] LoadHostList() {
        if (-not $this.SearchBar) { return }

        $hosts = $this.HostListSource.ReadHosts()
        if ($hosts.Count -gt 0) { $this.SearchBar.Text = $hosts -join "`r`n" }
    }

    [void] OnRunReport() {
        $rawInput = $this.SearchBar.Text
        if ([string]::IsNullOrWhiteSpace($rawInput)) { return }

        $targetHosts = $rawInput -split "[\r\n,]+" | 
            ForEach-Object { $_.Trim() } | 
            Where-Object { $_ }
        
        foreach ($hostName in $targetHosts) {
            $this.StartBatteryReport($hostName)
        }
    }

    [void] StartBatteryReport([string]$hostName) {
        $tab = $this.AddTab($hostName)
        
        # Validate host connectivity
        if (-not $this.NetworkProbe.IsOnline($hostName)) {
            $this.ShowErrorInTab($tab, "Host '$hostName' is offline or unreachable.")
            return
        }
        
        $ip = $this.NetworkProbe.ResolveHost($hostName)
        if (-not $ip) {
            $this.ShowErrorInTab($tab, "Could not resolve IP for '$hostName'.")
            return
        }

        $reportPath = Join-Path $this.Config.ReportsPath "$hostName-battery.html"
        $remoteScript = Join-Path $this.Config.SourceRoot "Scripts\RemoteWorker.ps1"
        
        $job = [AsyncJob]::new($hostName, 'BatteryReport')
        $scriptArgs = @{
            HostName   = $hostName
            IP         = $ip
            OutputPath = $reportPath
            JobType    = 'BatteryReport'
            SourceRoot = $this.Config.SourceRoot
        }
        
        try {
            $job.Start($remoteScript, $scriptArgs, $null)
            $this.ActiveJobs.Add($job)
        }
        catch {
            $this.ShowErrorInTab($tab, "Error starting battery report: $_")
        }
    }

    # Timer Tick handler: drive the shared job-polling lifecycle (AsyncJobPresenter).
    [void] OnTimerTick($sender, $e) {
        try {
            $this.PumpJobs()
        }
        catch {
            $this.Logger.LogException("Error during battery job pump", $_)
        }
    }

    # Terminal hook: render the finished report (WebBrowser navigation).
    [void] OnJobCompleted([AsyncJob]$job) {
        $this.HandleBatteryReportCompletion($job)
    }

    [void] HandleBatteryReportCompletion([AsyncJob]$job) {
        $tab = $this.GetTab($job.HostName)
        if (-not $tab) { return }
        
        $reportPath = Join-Path $this.Config.ReportsPath "$($job.HostName)-battery.html"
        
        if ($job.Status -ne 'Completed' -or -not (Test-Path $reportPath)) {
            $this.ShowErrorInTab($tab, "Battery report generation failed for '$($job.HostName)'.")
            return
        }
        
        $browser = $tab.Content
        if ($browser -is [System.Windows.Controls.WebBrowser]) {
            try {
                $browser.Navigate([Uri]::new($reportPath))
            }
            catch {
                $this.ShowErrorInTab($tab, "Failed to load report: $_")
            }
        }
    }

    [TabItem] AddTab([string]$hostName) {
        # Return existing tab if found
        foreach ($existingTab in $this.ReportTabs.Items) {
            if ($existingTab.Header -eq $hostName) {
                $this.ReportTabs.SelectedItem = $existingTab
                return $existingTab
            }
        }

        # Create new tab with WebBrowser
        $tab = [TabItem]::new()
        $tab.Header = $hostName
        $tab.Content = [System.Windows.Controls.WebBrowser]::new()
        
        $this.ReportTabs.Items.Add($tab)
        $this.ReportTabs.SelectedItem = $tab
        return $tab
    }

    [TabItem] GetTab([string]$hostName) {
        foreach ($tab in $this.ReportTabs.Items) {
            if ($tab.Header -eq $hostName) { return $tab }
        }
        return $null
    }

    [void] ShowErrorInTab([TabItem]$tab, [string]$message) {
        # Replace content with error message TextBlock
        $errorText = [System.Windows.Controls.TextBlock]::new()
        $errorText.Text = $message
        $errorText.Foreground = [System.Windows.Media.Brushes]::Red
        $errorText.FontSize = 14
        $errorText.TextWrapping = 'Wrap'
        $errorText.Margin = [System.Windows.Thickness]::new(10)
        $tab.Content = $errorText
    }

    [void] OnClearTabs() {
        if ($this.ReportTabs) {
            $this.ReportTabs.Items.Clear()
        }
    }
}

