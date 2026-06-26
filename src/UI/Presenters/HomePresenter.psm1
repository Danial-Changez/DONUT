using namespace System.Windows.Controls
using namespace System.Windows.Threading
using namespace System.Collections.Generic
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Models\FleetStatus.psm1"
using module "..\..\Models\DcuProgress.psm1"
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Services\RemoteServices.psm1"
using module "..\..\Services\DriverMatchingService.psm1"
using module ".\DialogPresenter.psm1"
using module ".\ToastService.psm1"
using module ".\FleetCard.psm1"
using module "..\..\Services\ResourceService.psm1"

class HomePresenter {
    [AppConfig] $Config
    [System.Windows.FrameworkElement] $ViewContent
    [TextBox] $SearchBar
    [Button] $SearchButton
    [ItemsControl] $FleetCards
    [System.Windows.UIElement] $FleetEmptyHint
    [Button] $ClearButton
    [ScanService] $ScanService
    [RemoteUpdateService] $UpdateService
    [DialogPresenter] $DialogPresenter
    [ToastService] $Toasts
    [NetworkProbe] $NetworkProbe
    [DriverMatchingService] $DriverMatcher

    # Async State
    [System.Collections.Generic.List[AsyncJob]] $ActiveJobs
    [DispatcherTimer] $Timer

    # Host name -> FleetCard
    [hashtable] $Cards

    # Manual Reboot Queue - hosts that require manual reboot after update
    [System.Collections.Generic.List[string]] $ManualRebootQueue
    [int] $TotalJobsInBatch

    HomePresenter([AppConfig] $config, [System.Windows.FrameworkElement] $view, [NetworkProbe] $networkProbe, [ResourceService] $resources, [ToastService] $toasts) {
        $this.Config = $config
        $this.ViewContent = $view
        $this.Toasts = $toasts

        $this.NetworkProbe = $networkProbe
        # Reuse the shared app logger that travels with the probe so scan/update
        # services log into the same sink as the rest of the app.
        $logger = $this.NetworkProbe.Logger
        $this.ScanService = [ScanService]::new($config, $this.NetworkProbe, $logger)
        $this.DriverMatcher = [DriverMatchingService]::new($logger)
        $this.UpdateService = [RemoteUpdateService]::new($config, $this.NetworkProbe, $this.DriverMatcher, $logger)
        $this.DialogPresenter = [DialogPresenter]::new($resources)

        $this.ActiveJobs = [List[AsyncJob]]::new()
        $this.Cards = @{}
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
        $this.FleetCards = $this.ViewContent.FindName('FleetCards')
        $this.FleetEmptyHint = $this.ViewContent.FindName('FleetEmptyHint')
        $this.ClearButton = $this.ViewContent.FindName('btnClearTabs')

        $presenter = $this
        if ($this.SearchButton) {
            $this.SearchButton.Add_Click({ $presenter.OnSearch() }.GetNewClosure())
        }
        if ($this.ClearButton) {
            $this.ClearButton.Add_Click({ $presenter.ClearCompleted() }.GetNewClosure())
        }

        $this.LoadHostList()
        $this.UpdateSearchButtonLabel()
        $this.UpdateEmptyHint()
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
        $card = $this.AddCard($hostName)

        $command = $this.Config.GetActiveCommand()
        $card.AppendLog("Starting $command for $hostName...")

        try {
            $jobParams = switch ($command) {
                'scan' {
                    @{ Type = 'Scan'; Prep = $this.ScanService.PrepareScan($hostName) }
                }
                'applyUpdates' {
                    $card.AppendLog("Phase 1: Scanning for updates...")
                    @{ Type = 'UpdateScan'; Prep = $this.UpdateService.PrepareScanForUpdates($hostName) }
                }
                default {
                    $card.AppendLog("Command '$command' not implemented yet.")
                    $null
                }
            }

            if ($jobParams) {
                $job = [AsyncJob]::new($hostName, $jobParams.Type)
                $job.Start($jobParams.Prep.ScriptPath, $jobParams.Prep.Arguments, $jobParams.Prep.TempConfigPath)
                $this.ActiveJobs.Add($job)
                $this.RefreshCardStatus($job)
            }
        }
        catch {
            $card.AppendLog("Error starting process: $_")
            $card.SetStatus([FleetStatus]::FromJob('Scan', 'Failed', $false))
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Failed to start: $_") }
        }
    }

    [void] OnTimerTick($sender, $e) {
        if (-not $this.ActiveJobs -or $this.ActiveJobs.Count -eq 0) { return }

        try {
            # Iterate backwards to safely remove completed jobs
            for ($i = $this.ActiveJobs.Count - 1; $i -ge 0; $i--) {
                $job = $this.ActiveJobs[$i]
                if (-not $job) { continue }

                $card = $this.GetCard($job.HostName)
                $job.Poll()

                # Flush log queue to the card terminal, picking up the latest
                # DCU download/install percentage as we go.
                $logEntry = $null
                $latestPct = -1
                while ($job.Logs.TryDequeue([ref]$logEntry)) {
                    if ($card) { $card.AppendLog($logEntry) }
                    $pct = [DcuProgress]::ParsePercent($logEntry)
                    if ($pct -ge 0) { $latestPct = $pct }
                }
                if ($card -and $latestPct -ge 0) { $card.SetPercent($latestPct) }

                # Keep the chip in sync with the running job
                $this.RefreshCardStatus($job)

                # Handle job completion
                if ($job.Status -in @('Completed', 'Failed')) {
                    if ($card) {
                        $card.AppendLog("Job $($job.JobType) finished: $($job.Status)")
                        $this.AppendHostLogs($job.HostName, $card)
                    }

                    # Transition to apply phase after successful scan
                    if ($job.Status -eq 'Completed' -and $job.JobType -eq 'UpdateScan') {
                        $this.HandleUpdateScanCompletion($job, $card)
                    }

                    # Check if host needs manual reboot after UpdateApply
                    if ($job.JobType -eq 'UpdateApply' -and $job.Status -eq 'Completed') {
                        $this.CheckForManualReboot($job)
                        if ($this.Toasts) {
                            if ($this.ManualRebootQueue.Contains($job.HostName)) {
                                $this.Toasts.ShowWarning($job.HostName, "Updates applied - manual reboot required.")
                            } else {
                                $this.Toasts.ShowSuccess($job.HostName, "Updates applied successfully.")
                            }
                        }
                    }

                    if ($job.Status -eq 'Failed' -and $this.Toasts) {
                        $this.Toasts.ShowError($job.HostName, "$($job.JobType) failed. Expand the card for details.")
                    }

                    # Settle the card's final status before dropping the job
                    $this.RefreshCardStatus($job)

                    # Cleanup and Remove
                    $job.Cleanup()
                    $this.ActiveJobs.RemoveAt($i)

                    # Check if all jobs in batch are complete - notify reboot queue
                    if ($this.ActiveJobs.Count -eq 0 -and $this.ManualRebootQueue.Count -gt 0) {
                        $this.ShowManualRebootNotice()
                    }
                }
            }
        }
        catch {
            Write-Error "Error in OnTimerTick: $_"
        }
    }

    # Recomputes a host card's chip/progress from its job's current coordinates.
    [void] RefreshCardStatus([AsyncJob]$job) {
        $card = $this.GetCard($job.HostName)
        if (-not $card) { return }
        $rebootRequired = $this.ManualRebootQueue.Contains($job.HostName)
        $card.SetStatus([FleetStatus]::FromJob($job.JobType, $job.Status, $rebootRequired))
    }

    [void] HandleUpdateScanCompletion([AsyncJob]$job, [FleetCard]$card) {
        $hostName = $job.HostName
        $report = $this.UpdateService.ParseUpdateReport($hostName)

        if (-not $report) {
            $card.AppendLog("No report generated or scan failed.")
            return
        }

        $updateNodes = $report.SelectNodes("//update")
        if ($updateNodes.Count -eq 0) {
            $card.AppendLog("No updates found.")
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "No updates found.") }
            return
        }

        $card.AppendLog("Found $($updateNodes.Count) updates. Analyzing driver matches...")

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

        $card.AppendLog("Driver analysis complete. Waiting for confirmation...")
        $confirmed = $this.DialogPresenter.ShowConfirmation("Updates Available", "Updates found for $hostName", $displayList)

        if (-not $confirmed) {
            $card.AppendLog("Cancelled by user.")
            return
        }

        $card.AppendLog("Confirmed. Phase 2: Applying updates...")
        $this.CopyUpdatesToClipboard($hostName, $clipboardList)
        $card.AppendLog("Updates list copied to clipboard.")

        try {
            $prep = $this.UpdateService.PrepareApplyUpdates($hostName, @{})
            $applyJob = [AsyncJob]::new($hostName, 'UpdateApply')
            $applyJob.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($applyJob)
            $this.RefreshCardStatus($applyJob)
        }
        catch {
            $card.AppendLog("Error starting apply phase: $_")
        }
    }

    # Returns the existing card for a host, or builds and inserts a new one.
    [FleetCard] AddCard([string]$hostName) {
        if ($this.Cards.ContainsKey($hostName)) {
            return $this.Cards[$hostName]
        }

        $card = [FleetCard]::new($hostName)
        $this.Cards[$hostName] = $card
        if ($this.FleetCards) {
            $this.FleetCards.Items.Add($card.Root) | Out-Null
            $card.AnimateIn()
        }
        $this.UpdateEmptyHint()
        return $card
    }

    [FleetCard] GetCard([string]$hostName) {
        if ($this.Cards.ContainsKey($hostName)) { return $this.Cards[$hostName] }
        return $null
    }

    # Removes cards for hosts that are no longer running.
    [void] ClearCompleted() {
        $activeHosts = $this.ActiveJobs | ForEach-Object { $_.HostName }
        $toRemove = @($this.Cards.Keys | Where-Object { $_ -notin $activeHosts })

        foreach ($hostName in $toRemove) {
            $card = $this.Cards[$hostName]
            if ($this.FleetCards -and $card) { $this.FleetCards.Items.Remove($card.Root) }
            $this.Cards.Remove($hostName)
        }
        $this.UpdateEmptyHint()
    }

    # Shows the empty-state hint only when there are no cards.
    [void] UpdateEmptyHint() {
        if (-not $this.FleetEmptyHint) { return }
        $this.FleetEmptyHint.Visibility = if ($this.Cards.Count -eq 0) {
            [System.Windows.Visibility]::Visible
        } else {
            [System.Windows.Visibility]::Collapsed
        }
    }

    [void] AppendHostLogs([string]$hostName, [FleetCard]$card) {
        $logsDir = Join-Path $env:LOCALAPPDATA "DONUT\logs"
        $logFiles = @(
            (Join-Path $logsDir "$hostName.log"),
            (Join-Path $logsDir "default.log")
        )

        foreach ($logPath in $logFiles) {
            if (Test-Path $logPath) {
                try {
                    Get-Content -Path $logPath -ErrorAction Stop | ForEach-Object {
                        $card.AppendLog($_)
                    }
                } catch { }
            }
        }
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

    # Surfaces the batch reboot summary as a toast (was a modal alert).
    [void] ShowManualRebootNotice() {
        if ($this.ManualRebootQueue.Count -eq 0) { return }

        $hostList = $this.ManualRebootQueue.ToArray() -join ", "
        if ($this.Toasts) {
            $this.Toasts.ShowWarning(
                "Manual reboot required",
                "These machines need a manual reboot to finish updating: $hostList"
            )
        }

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
