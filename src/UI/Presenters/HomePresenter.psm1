using namespace System.Windows.Controls
using namespace System.Windows.Shapes
using namespace System.Windows.Threading
using namespace System.Collections.Generic
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Models\FleetStatus.psm1"
using module "..\..\Models\DcuProgress.psm1"
using module "..\..\Models\RecentConnection.psm1"
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Core\NetworkProbe.psm1"
using module "..\..\Core\HostListSource.psm1"
using module "..\..\Services\RemoteServices.psm1"
using module "..\..\Services\DriverMatchingService.psm1"
using module "..\..\Services\SystemInfoService.psm1"
using module ".\DialogPresenter.psm1"
using module ".\ToastService.psm1"
using module ".\ConnectionRow.psm1"
using module ".\AsyncJobPresenter.psm1"
using module "..\..\Services\ResourceService.psm1"

class HomePresenter : AsyncJobPresenter {
    [AppConfig] $Config
    [object] $ConfigManager           # duck-typed; used to persist recents
    [System.Windows.FrameworkElement] $ViewContent
    [TextBox] $SearchBar
    [Button] $SearchButton
    [Button] $ClearButton
    [Button] $RefreshButton
    [ItemsControl] $MachineList
    [System.Windows.UIElement] $EmptyHint
    [TextBlock] $ModePill
    [ScanService] $ScanService
    [RemoteUpdateService] $UpdateService
    [DialogPresenter] $DialogPresenter
    [ToastService] $Toasts
    [NetworkProbe] $NetworkProbe
    [DriverMatchingService] $DriverMatcher
    [SystemInfoService] $SysInfo
    [RecentConnectionsStore] $Store
    [HostListSource] $HostListSource

    # Overview tile controls
    [TextBlock] $TileCtrlHost
    [TextBlock] $TileCtrlIp
    [TextBlock] $TileDc
    [TextBlock] $TileDcSub
    [Ellipse]   $TileDcDot
    [TextBlock] $TileBattery
    [TextBlock] $TileFleet
    [TextBlock] $TileFleetSub

    # Async state ($ActiveJobs is inherited from AsyncJobPresenter)
    [DispatcherTimer] $Timer

    # Host name -> ConnectionRow
    [hashtable] $Rows

    # Manual reboot queue - hosts that require manual reboot after update
    [System.Collections.Generic.List[string]] $ManualRebootQueue
    [int] $TotalJobsInBatch

    HomePresenter([AppConfig] $config, [System.Windows.FrameworkElement] $view, [NetworkProbe] $networkProbe, [ResourceService] $resources, [ToastService] $toasts, [object] $configManager) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.ViewContent = $view
        $this.Toasts = $toasts

        $this.NetworkProbe = $networkProbe
        $logger = $this.NetworkProbe.Logger
        $this.ScanService = [ScanService]::new($config, $this.NetworkProbe, $logger)
        $this.DriverMatcher = [DriverMatchingService]::new($logger)
        $this.UpdateService = [RemoteUpdateService]::new($config, $this.NetworkProbe, $this.DriverMatcher, $logger)
        $this.DialogPresenter = [DialogPresenter]::new($resources)
        $this.SysInfo = [SystemInfoService]::new($this.NetworkProbe, $logger)
        $this.Store = [RecentConnectionsStore]::new($config, $configManager)
        $this.HostListSource = [HostListSource]::new($config.SourceRoot)

        # $this.ActiveJobs is initialized by the AsyncJobPresenter base constructor.
        $this.Rows = @{}
        $this.ManualRebootQueue = [List[string]]::new()
        $this.TotalJobsInBatch = 0

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
        $this.ClearButton = $this.ViewContent.FindName('btnClearTabs')
        $this.RefreshButton = $this.ViewContent.FindName('btnRefresh')
        $this.MachineList = $this.ViewContent.FindName('MachineList')
        $this.EmptyHint = $this.ViewContent.FindName('FleetEmptyHint')
        $this.ModePill = $this.ViewContent.FindName('txtMode')

        $this.TileCtrlHost = $this.ViewContent.FindName('txtCtrlHost')
        $this.TileCtrlIp = $this.ViewContent.FindName('txtCtrlIp')
        $this.TileDc = $this.ViewContent.FindName('txtDc')
        $this.TileDcSub = $this.ViewContent.FindName('txtDcSub')
        $this.TileDcDot = $this.ViewContent.FindName('dotDc')
        $this.TileBattery = $this.ViewContent.FindName('txtBattery')
        $this.TileFleet = $this.ViewContent.FindName('txtFleet')
        $this.TileFleetSub = $this.ViewContent.FindName('txtFleetSub')

        $presenter = $this
        if ($this.SearchButton) { $this.SearchButton.Add_Click({ $presenter.OnSearch() }.GetNewClosure()) }
        if ($this.ClearButton) { $this.ClearButton.Add_Click({ $presenter.ClearCompleted() }.GetNewClosure()) }
        if ($this.RefreshButton) { $this.RefreshButton.Add_Click({ $presenter.RefreshAll() }.GetNewClosure()) }

        # Seed recents from WSID.txt the first time, then build a row per recent.
        if ($this.Store.Count() -eq 0) {
            $this.Store.SeedFrom($this.ReadWsidHosts())
        }
        $this.BuildRows()

        $this.UpdateModePill()
        $this.RefreshAll()
    }

    [void] UpdateModePill() {
        $command = $this.Config.GetActiveCommand()
        $label = if ($command -eq 'applyUpdates') { "Apply Updates" } else { "Scan" }
        if ($this.SearchButton) { $this.SearchButton.Content = $label }
        if ($this.ModePill) { $this.ModePill.Text = "Mode: $label" }
    }

    # Backwards-compatible name used by MainPresenter on navigation.
    [void] UpdateSearchButtonLabel() {
        $this.UpdateModePill()
    }

    [string[]] ReadWsidHosts() {
        return $this.HostListSource.ReadHosts()
    }

    # Builds an idle row for every persisted recent connection (newest first).
    [void] BuildRows() {
        foreach ($rc in $this.Store.GetAll()) {
            $row = $this.EnsureRow($rc.Hostname)
            $row.SetIdleFrom($rc)
        }
        $this.UpdateEmptyHint()
    }

    [void] OnSearch() {
        $rawInput = $this.SearchBar.Text
        if ([string]::IsNullOrWhiteSpace($rawInput)) { return }

        $targetHosts = $rawInput -split "[\r\n,]+" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }

        if ($targetHosts.Count -eq 0) { return }

        # One confirmation for a destructive batch; single rows confirm in RunHost.
        $command = $this.Config.GetActiveCommand()
        if ($command -eq 'applyUpdates' -and $targetHosts.Count -gt 1) {
            $confirmed = $this.DialogPresenter.ShowConfirmation(
                "Confirm Apply Updates",
                "You are about to apply updates to $($targetHosts.Count) computers.",
                $targetHosts
            )
            if (-not $confirmed) { return }
        }

        $this.ManualRebootQueue.Clear()
        $this.TotalJobsInBatch = $targetHosts.Count

        foreach ($hostName in $targetHosts) {
            $this.StartProcess($hostName)
        }

        $this.SearchBar.Text = ""
    }

    # Runs a single host from a row click; confirms first when destructive.
    [void] RunHost([string]$hostName) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        if ($this.IsRunning($hostName)) { return }

        if ($this.Config.GetActiveCommand() -eq 'applyUpdates') {
            $confirmed = $this.DialogPresenter.ShowConfirmation(
                "Confirm Apply Updates",
                "Apply updates to $hostName now?",
                @($hostName)
            )
            if (-not $confirmed) { return }
        }
        $this.StartProcess($hostName)
    }

    [bool] IsRunning([string]$hostName) {
        foreach ($job in $this.ActiveJobs) {
            if ($job -and $job.HostName -eq $hostName) { return $true }
        }
        return $false
    }

    [void] StartProcess([string]$hostName) {
        $row = $this.EnsureRow($hostName)

        $command = $this.Config.GetActiveCommand()
        $row.AppendLog("Starting $command for $hostName...")

        try {
            $jobParams = switch ($command) {
                'scan' {
                    @{ Type = 'Scan'; Prep = $this.ScanService.PrepareScan($hostName) }
                }
                'applyUpdates' {
                    $row.AppendLog("Phase 1: Scanning for updates...")
                    @{ Type = 'UpdateScan'; Prep = $this.UpdateService.PrepareScanForUpdates($hostName) }
                }
                default {
                    $row.AppendLog("Command '$command' not implemented yet.")
                    $null
                }
            }

            if ($jobParams) {
                $job = [AsyncJob]::new($hostName, $jobParams.Type)
                $job.Start($jobParams.Prep.ScriptPath, $jobParams.Prep.Arguments, $jobParams.Prep.TempConfigPath)
                $this.ActiveJobs.Add($job)
                $this.RefreshCardStatus($job)
                $this.RefreshOverview()
            }
        }
        catch {
            $row.AppendLog("Error starting process: $_")
            $row.SetStatus([FleetStatus]::FromJob('Scan', 'Failed', $false))
            if ($this.Toasts) { $this.Toasts.ShowError($hostName, "Failed to start: $_") }
        }
    }

    # Timer Tick handler: drive the shared job-polling lifecycle (AsyncJobPresenter).
    [void] OnTimerTick($sender, $e) {
        try {
            $this.PumpJobs()
        }
        catch {
            Write-Error "Error in OnTimerTick: $_"
        }
    }

    # Per-tick: stream the job's queued output into its row and keep the card live.
    [void] OnJobPolled([AsyncJob]$job) {
        $row = $this.GetRow($job.HostName)

        $logEntry = $null
        $latestPct = -1
        while ($job.Logs.TryDequeue([ref]$logEntry)) {
            if ($row) { $row.AppendLog($logEntry) }
            $pct = [DcuProgress]::ParsePercent($logEntry)
            if ($pct -ge 0) { $latestPct = $pct }
        }
        if ($row -and $latestPct -ge 0) { $row.SetPercent($latestPct) }

        $this.RefreshCardStatus($job)
    }

    # Terminal: driver-match analysis / apply-phase transition / recents persistence.
    [void] OnJobCompleted([AsyncJob]$job) {
        $row = $this.GetRow($job.HostName)
        if ($row) {
            $row.AppendLog("Job $($job.JobType) finished: $($job.Status)")
            $this.AppendHostLogs($job.HostName, $row)
        }

        # Transition to apply phase after a successful update scan.
        $transitioned = $false
        if ($job.Status -eq 'Completed' -and $job.JobType -eq 'UpdateScan') {
            $transitioned = $this.HandleUpdateScanCompletion($job, $row)
        }

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
            $this.Toasts.ShowError($job.HostName, "$($job.JobType) failed. Open the log for details.")
        }

        # Persist + settle the row unless we just kicked off an apply.
        if (-not $transitioned) {
            $this.SettleHost($job)
        }
    }

    # End of tick: refresh fleet counts and, once the batch is fully drained,
    # surface any pending manual-reboot notice.
    [void] AfterPump() {
        $this.RefreshOverview()
        if ($this.ActiveJobs.Count -eq 0 -and $this.ManualRebootQueue.Count -gt 0) {
            $this.ShowManualRebootNotice()
        }
    }

    # Records the host's final state into the recent store and renders the row idle.
    [void] SettleHost([AsyncJob]$job) {
        $reboot = $this.ManualRebootQueue.Contains($job.HostName)
        $status = if ($job.Status -eq 'Failed') {
            'Failed'
        } elseif ($reboot) {
            'RebootRequired'
        } else {
            'Completed'
        }

        $report = $this.UpdateService.ParseUpdateReport($job.HostName)
        $updateCount = $this.UpdateService.CountUpdates($report)

        $this.Store.Upsert($job.HostName, $status, $job.JobType, $updateCount, $reboot)

        $row = $this.GetRow($job.HostName)
        if ($row) {
            $rc = $this.GetRecord($job.HostName)
            if ($rc) { $row.SetIdleFrom($rc) }
        }
    }

    [RecentConnection] GetRecord([string]$hostName) {
        foreach ($rc in $this.Store.GetAll()) {
            if ($rc.Hostname -eq $hostName) { return $rc }
        }
        return $null
    }

    [void] RefreshCardStatus([AsyncJob]$job) {
        $row = $this.GetRow($job.HostName)
        if (-not $row) { return }
        $rebootRequired = $this.ManualRebootQueue.Contains($job.HostName)
        $row.SetStatus([FleetStatus]::FromJob($job.JobType, $job.Status, $rebootRequired))
    }

    # Returns $true when an apply job was started (so the caller defers settling).
    [bool] HandleUpdateScanCompletion([AsyncJob]$job, [ConnectionRow]$row) {
        $hostName = $job.HostName
        $report = $this.UpdateService.ParseUpdateReport($hostName)

        if (-not $report) {
            if ($row) { $row.AppendLog("No report generated or scan failed.") }
            return $false
        }

        $updateNodes = $report.SelectNodes("//update")
        if ($updateNodes.Count -eq 0) {
            if ($row) { $row.AppendLog("No updates found.") }
            if ($this.Toasts) { $this.Toasts.ShowInfo($hostName, "No updates found.") }
            return $false
        }

        if ($row) { $row.AppendLog("Found $($updateNodes.Count) updates. Analyzing driver matches...") }

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

        if ($row) { $row.AppendLog("Driver analysis complete. Waiting for confirmation...") }
        $confirmed = $this.DialogPresenter.ShowConfirmation("Updates Available", "Updates found for $hostName", $displayList)

        if (-not $confirmed) {
            if ($row) { $row.AppendLog("Cancelled by user.") }
            return $false
        }

        if ($row) { $row.AppendLog("Confirmed. Phase 2: Applying updates...") }
        $this.CopyUpdatesToClipboard($hostName, $clipboardList)
        if ($row) { $row.AppendLog("Updates list copied to clipboard.") }

        try {
            $prep = $this.UpdateService.PrepareApplyUpdates($hostName, @{})
            $applyJob = [AsyncJob]::new($hostName, 'UpdateApply')
            $applyJob.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
            $this.ActiveJobs.Add($applyJob)
            $this.RefreshCardStatus($applyJob)
            return $true
        }
        catch {
            if ($row) { $row.AppendLog("Error starting apply phase: $_") }
            return $false
        }
    }

    # Returns the existing row for a host, or builds and inserts a new one.
    [ConnectionRow] EnsureRow([string]$hostName) {
        if ($this.Rows.ContainsKey($hostName)) {
            return $this.Rows[$hostName]
        }

        $row = [ConnectionRow]::new($hostName)
        $presenter = $this
        $row.RunAction = { param($h) $presenter.RunHost($h) }.GetNewClosure()
        $this.Rows[$hostName] = $row
        if ($this.MachineList) {
            $this.MachineList.Items.Add($row.Root) | Out-Null
            $row.AnimateIn()
        }
        $this.UpdateEmptyHint()
        return $row
    }

    [ConnectionRow] GetRow([string]$hostName) {
        if ($this.Rows.ContainsKey($hostName)) { return $this.Rows[$hostName] }
        return $null
    }

    # Removes idle (not currently running) machines from the list and recents.
    [void] ClearCompleted() {
        $toRemove = @($this.Rows.Keys | Where-Object { -not $this.IsRunning($_) })

        foreach ($hostName in $toRemove) {
            $row = $this.Rows[$hostName]
            if ($this.MachineList -and $row) { $this.MachineList.Items.Remove($row.Root) }
            $this.Rows.Remove($hostName)
            $this.Store.Remove($hostName)
        }
        $this.UpdateEmptyHint()
        $this.RefreshOverview()
    }

    [void] UpdateEmptyHint() {
        if (-not $this.EmptyHint) { return }
        $this.EmptyHint.Visibility = if ($this.Rows.Count -eq 0) {
            [System.Windows.Visibility]::Visible
        } else {
            [System.Windows.Visibility]::Collapsed
        }
    }

    # Refreshes overview tiles (system info) and the fleet counts.
    [void] RefreshAll() {
        $this.GatherSystemInfo()
        $this.RefreshOverview()
        # Re-render idle rows so their relative times stay current.
        foreach ($rc in $this.Store.GetAll()) {
            if (-not $this.IsRunning($rc.Hostname)) {
                $row = $this.GetRow($rc.Hostname)
                if ($row) { $row.SetIdleFrom($rc) }
            }
        }
    }

    [void] GatherSystemInfo() {
        $info = $this.SysInfo.Gather()

        if ($this.TileCtrlHost) { $this.TileCtrlHost.Text = if ($info.Hostname) { $info.Hostname } else { '—' } }
        if ($this.TileCtrlIp) { $this.TileCtrlIp.Text = $info.IPv4 }

        if ($this.TileDc) {
            $this.TileDc.Text = if ($info.DomainController) { $info.DomainController } elseif ($info.Domain) { $info.Domain } else { '—' }
        }
        if ($this.TileDcSub) {
            $this.TileDcSub.Text = if ($info.DcReachable) { 'reachable' } elseif ($info.DomainJoined) { 'DC unreachable' } else { 'not domain-joined' }
        }
        if ($this.TileDcDot) {
            $key = if ($info.DcReachable) { 'AccentGreen' } elseif ($info.DomainJoined) { 'AccentRed' } else { 'BodyTextTertiary' }
            $this.TileDcDot.Fill = $this.ResBrush($key)
        }
        if ($this.TileBattery) {
            $this.TileBattery.Text = [SystemInfoService]::BatteryLabel($info.HasBattery, $info.BatteryPercent, $info.Charging)
        }
    }

    [void] RefreshOverview() {
        $recents = @($this.Store.GetAll())
        $active = @($this.ActiveJobs | ForEach-Object { $_.HostName } | Select-Object -Unique)
        $attention = @($recents | Where-Object { $_.LastStatus -eq 'Failed' -or $_.LastStatus -eq 'RebootRequired' })

        if ($this.TileFleet) { $this.TileFleet.Text = "$($recents.Count)" }
        if ($this.TileFleetSub) {
            $sub = "$($active.Count) active"
            if ($attention.Count -gt 0) { $sub += " · $($attention.Count) need attention" }
            $this.TileFleetSub.Text = $sub
        }
    }

    [System.Windows.Media.Brush] ResBrush([string]$key) {
        $res = $null
        if ($this.MachineList) { $res = $this.MachineList.TryFindResource($key) }
        if ($res -is [System.Windows.Media.Brush]) { return $res }
        return [System.Windows.Media.Brushes]::Gray
    }

    [void] AppendHostLogs([string]$hostName, [ConnectionRow]$row) {
        $logsDir = Join-Path $env:LOCALAPPDATA "DONUT\logs"
        $logFiles = @(
            (Join-Path $logsDir "$hostName.log"),
            (Join-Path $logsDir "default.log")
        )
        foreach ($logPath in $logFiles) {
            if (Test-Path $logPath) {
                try {
                    Get-Content -Path $logPath -ErrorAction Stop | ForEach-Object {
                        $row.AppendLog($_)
                    }
                } catch { }
            }
        }
    }

    [void] CheckForManualReboot([AsyncJob]$job) {
        $appData = Join-Path $env:LOCALAPPDATA "DONUT"
        $rebootFlagPath = Join-Path $appData "reports\$($job.HostName)-reboot-required.flag"

        if (Test-Path $rebootFlagPath) {
            if (-not $this.ManualRebootQueue.Contains($job.HostName)) {
                $this.ManualRebootQueue.Add($job.HostName)
            }
            Remove-Item -Path $rebootFlagPath -Force -ErrorAction SilentlyContinue
        }

        if ($job.Result -and $job.Result -match 'reboot\s*required|needs\s*reboot|pending\s*reboot') {
            if (-not $this.ManualRebootQueue.Contains($job.HostName)) {
                $this.ManualRebootQueue.Add($job.HostName)
            }
        }
    }

    [void] ShowManualRebootNotice() {
        if ($this.ManualRebootQueue.Count -eq 0) { return }
        $hostList = $this.ManualRebootQueue.ToArray() -join ", "
        if ($this.Toasts) {
            $this.Toasts.ShowWarning(
                "Manual reboot required",
                "These machines need a manual reboot to finish updating: $hostList"
            )
        }
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
