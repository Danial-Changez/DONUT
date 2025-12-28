using namespace System.Windows.Controls
using namespace System.Windows.Threading
using namespace System.Collections.Generic
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Services\RemoteServices.psm1"
using module "..\..\Services\DriverMatchingService.psm1"
using module ".\DialogPresenter.psm1"
using module "..\..\Services\ResourceService.psm1"

class HomePresenter {
    [AppConfig] $Config
    [System.Windows.FrameworkElement] $ViewContent
    [TextBox] $SearchBar
    [Button] $SearchButton
    [TabControl] $TerminalTabs
    [ScanService] $ScanService
    [RemoteUpdateService] $UpdateService
    [DialogPresenter] $DialogPresenter
    [NetworkProbe] $NetworkProbe
    [DriverMatchingService] $DriverMatcher
    
    # Async State
    [System.Collections.Generic.List[AsyncJob]] $ActiveJobs
    [DispatcherTimer] $Timer
    
    # Manual Reboot Queue - hosts that require manual reboot after update
    [System.Collections.Generic.List[string]] $ManualRebootQueue
    [int] $TotalJobsInBatch

    HomePresenter([AppConfig] $config, [System.Windows.FrameworkElement] $view, [NetworkProbe] $networkProbe, [ResourceService] $resources) {
        $this.Config = $config
        $this.ViewContent = $view
        
        $this.NetworkProbe = $networkProbe
        $this.ScanService = [ScanService]::new($config, $this.NetworkProbe)
        $this.DriverMatcher = [DriverMatchingService]::new()
        $this.UpdateService = [RemoteUpdateService]::new($config, $this.NetworkProbe, $this.DriverMatcher)
        $this.DialogPresenter = [DialogPresenter]::new($resources)
        
        $this.ActiveJobs = [List[AsyncJob]]::new()
        $this.ManualRebootQueue = [List[string]]::new()
        $this.TotalJobsInBatch = 0
        
        # Initialize Timer
        $presenter = $this
        $this.Timer = [DispatcherTimer]::new()
        $this.Timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $this.Timer.Add_Tick({ $presenter.OnTimerTick($this, $null) }.GetNewClosure())
        $this.Timer.Start()

        $this.Initialize()
    }

    [void] Initialize() {
        $this.SearchBar = $this.ViewContent.FindName('GoogleSearchBar')
        $this.SearchButton = $this.ViewContent.FindName('btnSearch')
        $this.TerminalTabs = $this.ViewContent.FindName('TerminalTabs')

        $presenter = $this
        if ($this.SearchButton) {
            $this.SearchButton.Add_Click({ $presenter.OnSearch() }.GetNewClosure())
        }

        $this.LoadHostList()
        $this.UpdateSearchButtonLabel()
    }

    [void] UpdateSearchButtonLabel() {
        if (-not $this.SearchButton) { return }
        
        $command = $this.Config.GetActiveCommand()
        $this.SearchButton.Content = if ($command -eq 'applyUpdates') { "Apply Updates" } else { "Scan" }
    }

    [void] LoadHostList() {
        if (-not $this.SearchBar) { return }
        
        $wsidPaths = @(
            (Join-Path $env:LOCALAPPDATA "DONUT\config\WSID.txt"),
            (Join-Path (Split-Path $this.Config.SourceRoot -Parent) "res\WSID.txt")
        )
        
        $path = $wsidPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $path) { return }
        
        try {
            $lines = Get-Content -Path $path | Where-Object { $_ }
            if ($lines) { $this.SearchBar.Text = $lines -join "`r`n" }
        } catch {
            Write-Warning "Failed to load WSID.txt: $_"
        }
    }

    [void] OnSearch() {
        $rawInput = $this.SearchBar.Text
        if ([string]::IsNullOrWhiteSpace($rawInput)) { return }

        $targetHosts = $rawInput -split "[\r\n,]+" | 
            ForEach-Object { $_.Trim() } | 
            Where-Object { $_ }
        
        if ($targetHosts.Count -eq 0) { return }
        
        # Safety confirmation when applying updates to multiple hosts
        $command = $this.Config.GetActiveCommand()
        if ($command -eq 'applyUpdates' -and $targetHosts.Count -gt 1) {
            $confirmed = $this.DialogPresenter.ShowConfirmation(
                "Confirm Apply Updates",
                "You are about to apply updates to $($targetHosts.Count) computers.",
                $targetHosts
            )
            if (-not $confirmed) { return }
        }
        
        # Reset batch tracking
        $this.ManualRebootQueue.Clear()
        $this.TotalJobsInBatch = $targetHosts.Count
        
        foreach ($hostName in $targetHosts) {
            $this.StartProcess($hostName)
        }
        
        $this.SearchBar.Text = ""
    }

    [void] StartProcess([string]$hostName) {
        $tab = $this.AddTab($hostName)
        $terminal = $tab.Content
        
        $command = $this.Config.GetActiveCommand()
        $terminal.AppendText("Starting $command for $hostName...`n")
        
        try {
            $jobParams = switch ($command) {
                'scan' {
                    @{ Type = 'Scan'; Prep = $this.ScanService.PrepareScan($hostName) }
                }
                'applyUpdates' {
                    $terminal.AppendText("Phase 1: Scanning for updates...`n")
                    @{ Type = 'UpdateScan'; Prep = $this.UpdateService.PrepareScanForUpdates($hostName) }
                }
                default {
                    $terminal.AppendText("Command '$command' not implemented yet.`n")
                    $null
                }
            }
            
            if ($jobParams) {
                $job = [AsyncJob]::new($hostName, $jobParams.Type)
                $job.Start($jobParams.Prep.ScriptPath, $jobParams.Prep.Arguments, $jobParams.Prep.TempConfigPath)
                $this.ActiveJobs.Add($job)
            }
        }
        catch {
            $terminal.AppendText("Error starting process: $_`n")
        }
    }

    [void] OnTimerTick($sender, $e) {
        if (-not $this.ActiveJobs -or $this.ActiveJobs.Count -eq 0) { return }
        
        try {
            # Iterate backwards to safely remove completed jobs
            for ($i = $this.ActiveJobs.Count - 1; $i -ge 0; $i--) {
                $job = $this.ActiveJobs[$i]
                if (-not $job) { continue }

                $terminal = $this.GetTerminal($job.HostName)
                $job.Poll()
                
                # Flush log queue to terminal
                $logEntry = $null
                while ($job.Logs.TryDequeue([ref]$logEntry)) {
                    if ($terminal) { 
                        $terminal.AppendText("$logEntry`n") 
                        $terminal.ScrollToEnd()
                    }
                }

                # Handle job completion
                if ($job.Status -in @('Completed', 'Failed')) {
                    if ($terminal) { 
                        $terminal.AppendText("Job $($job.JobType) finished: $($job.Status)`n") 
                        $this.AppendHostLogs($job.HostName, $terminal)
                    }
                    
                    # Transition to apply phase after successful scan
                    if ($job.Status -eq 'Completed' -and $job.JobType -eq 'UpdateScan') {
                        $this.HandleUpdateScanCompletion($job, $terminal)
                    }
                    
                    # Check if host needs manual reboot after UpdateApply
                    if ($job.JobType -eq 'UpdateApply' -and $job.Status -eq 'Completed') {
                        $this.CheckForManualReboot($job)
                    }
                    
                    # Cleanup and Remove
                    $job.Cleanup()
                    $this.ActiveJobs.RemoveAt($i)
                    
                    # Check if all jobs in batch are complete - show ManualRebootQueue popup
                    if ($this.ActiveJobs.Count -eq 0 -and $this.ManualRebootQueue.Count -gt 0) {
                        $this.ShowManualRebootPopup()
                    }
                }
            }
        }
        catch {
            Write-Error "Error in OnTimerTick: $_"
        }
    }

    [void] HandleUpdateScanCompletion([AsyncJob]$job, [TextBox]$terminal) {
        $hostName = $job.HostName
        $report = $this.UpdateService.ParseUpdateReport($hostName)
        
        if (-not $report) {
            $terminal.AppendText("No report generated or scan failed.`n")
            return
        }
        
        $updateNodes = $report.SelectNodes("//update")
        if ($updateNodes.Count -eq 0) {
            $terminal.AppendText("No updates found.`n")
            return
        }
        
        $terminal.AppendText("Found $($updateNodes.Count) updates. Analyzing driver matches...`n")
        
        $installedDrivers = $this.GetInstalledDriversFromReport($report)
        $displayList = @()
        $clipboardList = @()
        
        foreach ($updateNode in $updateNodes) {
            $name = $updateNode.InnerText.Trim()
            $version = $updateNode.GetAttribute("version")
            if ([string]::IsNullOrEmpty($version)) { $version = "N/A" }
                    
            $match = $this.DriverMatcher.FindBestDriverMatch($name, $installedDrivers)
            
            if ($match) {
                $currentVer = $match.Driver.DriverVersion
                $comparison = $this.DriverMatcher.CompareVersions($currentVer, $version)
                $tag = if ($comparison.IsNewer) { "↑NEW" } else { "=" }
                $displayList += $name
                $displayList += "   [$($match.Category)] $currentVer → $version $tag"
                $clipboardList += "$name, $currentVer -> $version"
            }
            else {
                $displayList += "$name ($version)"
                $displayList += "   [No matching driver found]"
                $clipboardList += "$name, $version (latest)"
            }
        }
        
        $terminal.AppendText("Driver analysis complete. Waiting for confirmation...`n")
        $confirmed = $this.DialogPresenter.ShowConfirmation("Updates Available", "Updates found for $hostName", $displayList)
                
        if (-not $confirmed) {
            $terminal.AppendText("Cancelled by user.`n")
            return
        }
        
        $terminal.AppendText("Confirmed. Phase 2: Applying updates...`n")
        $this.CopyUpdatesToClipboard($hostName, $clipboardList)
        $terminal.AppendText("Updates list copied to clipboard.`n")
        
        try {
            $prep = $this.UpdateService.PrepareApplyUpdates($hostName, @{})
            $applyJob = [AsyncJob]::new($hostName, 'UpdateApply')
            $applyJob.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($applyJob)
        }
        catch {
            $terminal.AppendText("Error starting apply phase: $_`n")
        }
    }

    [TabItem] AddTab([string]$hostName) {
        # Return existing tab if found
        foreach ($existingTab in $this.TerminalTabs.Items) {
            if ($existingTab.Header -eq $hostName) {
                $this.TerminalTabs.SelectedItem = $existingTab
                return $existingTab
            }
        }

        # Create new terminal tab
        $tab = [TabItem]::new()
        $tab.Header = $hostName
        
        $terminal = [TextBox]::new()
        $terminal.IsReadOnly = $true
        $terminal.VerticalScrollBarVisibility = 'Auto'
        $terminal.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
        $terminal.Background = [System.Windows.Media.Brushes]::Black
        $terminal.Foreground = [System.Windows.Media.Brushes]::White
        
        $tab.Content = $terminal
        $this.TerminalTabs.Items.Add($tab)
        $this.TerminalTabs.SelectedItem = $tab
        return $tab
    }

    [TextBox] GetTerminal([string]$hostName) {
        foreach ($tab in $this.TerminalTabs.Items) {
            if ($tab.Header -eq $hostName) { return $tab.Content }
        }
        return $null
    }

    [void] AppendHostLogs([string]$hostName, [TextBox]$terminal) {
        $logsDir = Join-Path $env:LOCALAPPDATA "DONUT\logs"
        $logFiles = @(
            (Join-Path $logsDir "$hostName.log"),
            (Join-Path $logsDir "default.log")
        )
        
        foreach ($logPath in $logFiles) {
            if (Test-Path $logPath) {
                try {
                    Get-Content -Path $logPath -ErrorAction Stop | ForEach-Object {
                        $terminal.AppendText("$_`n")
                    }
                } catch { }
            }
        }
        $terminal.ScrollToEnd()
    }

    [void] CheckForManualReboot([AsyncJob]$job) {
        # Check the job result for manual reboot flag
        # The remote worker should write a flag file or return data indicating reboot required
        $appData = Join-Path $env:LOCALAPPDATA "DONUT"
        $rebootFlagPath = Join-Path $appData "reports\$($job.HostName)-reboot-required.flag"
        
        if (Test-Path $rebootFlagPath) {
            if (-not $this.ManualRebootQueue.Contains($job.HostName)) {
                $this.ManualRebootQueue.Add($job.HostName)
            }
            # Clean up the flag file
            Remove-Item -Path $rebootFlagPath -Force -ErrorAction SilentlyContinue
        }
        
        # Also check job output/result for reboot indicators
        if ($job.Result -and $job.Result -match 'reboot\s*required|needs\s*reboot|pending\s*reboot') {
            if (-not $this.ManualRebootQueue.Contains($job.HostName)) {
                $this.ManualRebootQueue.Add($job.HostName)
            }
        }
    }

    [void] ShowManualRebootPopup() {
        if ($this.ManualRebootQueue.Count -eq 0) { return }
        
        $hostList = $this.ManualRebootQueue.ToArray()
        $message = "The following machines require manual reboot to complete updates:"
        
        $this.DialogPresenter.ShowAlert(
            "Manual Reboot Required",
            $message,
            $hostList
        )
        
        # Clear the queue after showing
        $this.ManualRebootQueue.Clear()
    }

    [array] GetInstalledDriversFromReport([xml]$report) {
        $driverNodes = $report.SelectNodes("//drivers/driver")
        if (-not $driverNodes) { return @() }
        
        return $driverNodes | ForEach-Object {
            @{
                DriverName    = $_.GetAttribute("name")
                ProviderName  = $_.GetAttribute("provider")
                DriverVersion = $_.GetAttribute("version")
                DriverDate    = $_.GetAttribute("date")
            }
        }
    }

    [void] CopyUpdatesToClipboard([string]$hostName, [array]$updatesList) {
        try {
            $clipboardText = "Scanned in DONUT, found and installed the following $($updatesList.Count) updates on $hostName`n"
            foreach ($item in $updatesList) {
                $clipboardText += "- $item`n"
            }
            Set-Clipboard -Value $clipboardText
        }
        catch {
            Write-Warning "Failed to copy to clipboard: $($_.Exception.Message)"
        }
    }
}
