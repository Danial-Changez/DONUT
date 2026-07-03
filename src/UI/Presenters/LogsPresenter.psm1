using namespace Donut.Mvvm
using module "..\..\Models\AppConfig.psm1"
using module "..\ViewModels\LogTabViewModel.psm1"
using module "..\ViewModels\LogsViewModel.psm1"

<#
.SYNOPSIS
    Coordinator for the Logs page: file I/O behind a bound LogsViewModel.

.DESCRIPTION
    Reads the log files under the logs directory into LogTabViewModels (the TabControl
    renders them via templates) and clears them on request. Large files are tail-loaded
    (the last TailBytes) with a "Load full file" command, so opening the tab never
    blocks on reading a multi-MB log into a TextBox.
#>
class LogsPresenter {
    [AppConfig] $Config
    [System.Windows.FrameworkElement] $ViewContent
    [LogsViewModel] $LogsVm

    # Files larger than this are tail-loaded (the last TailBytes) with a "Load full"
    # affordance, instead of reading the whole file into the TextBox up front.
    static [int] $FullLoadThresholdBytes = 524288   # 512 KB
    static [int] $TailBytes              = 262144   # 256 KB

    LogsPresenter([AppConfig] $config, [System.Windows.FrameworkElement] $view) {
        $this.Config = $config
        $this.ViewContent = $view
        $this.Initialize()
    }

    [void] Initialize() {
        $this.LogsVm = [LogsViewModel]::new()
        $presenter = $this
        $clear = { param($p) $presenter.ClearLogs() }.GetNewClosure()
        $this.LogsVm.ClearCommand = [RelayCommand]::new([System.Action[object]]$clear)
        $this.ViewContent.DataContext = $this.LogsVm

        $this.LoadLogs()
    }

    # Repopulates the tab collection from the logs directory (newest file first).
    [void] LoadLogs() {
        $this.LogsVm.Tabs.Clear()

        $logsDir = $this.Config.LogsPath
        $logFiles = @()
        if (Test-Path $logsDir) {
            $logFiles = @(Get-ChildItem -Path $logsDir -File | Sort-Object LastWriteTime -Descending)
        }

        if ($logFiles.Count -eq 0) {
            $this.LogsVm.Tabs.Add([LogTabViewModel]::new('No logs found', 'No log files found.'))
            return
        }

        foreach ($file in $logFiles) {
            try {
                $this.LogsVm.Tabs.Add($this.BuildFileTab($file))
            } catch {
                $this.LogsVm.Tabs.Add([LogTabViewModel]::new($file.BaseName, "Error reading file: $_"))
            }
        }
    }

    # Small files load whole; large ones start as a tail with a Load-full command that
    # swaps in the complete text and hides the truncation bar.
    hidden [LogTabViewModel] BuildFileTab([System.IO.FileInfo]$file) {
        if ($file.Length -le [LogsPresenter]::FullLoadThresholdBytes) {
            return [LogTabViewModel]::new($file.BaseName, $this.ReadFull($file.FullName))
        }

        $tab = [LogTabViewModel]::new($file.BaseName, $this.ReadTail($file.FullName, [LogsPresenter]::TailBytes))
        $tab.IsTruncated = $true
        $sizeMb = [Math]::Round($file.Length / 1MB, 1)
        $tab.TruncationNote = "Showing the last $([int]([LogsPresenter]::TailBytes / 1KB)) KB of $sizeMb MB."

        $presenter = $this
        $capturedPath = $file.FullName
        $capturedTab = $tab
        $load = { param($p) $capturedTab.ShowFull($presenter.ReadFull($capturedPath)) }.GetNewClosure()
        $tab.LoadFullCommand = [RelayCommand]::new([System.Action[object]]$load)
        return $tab
    }

    hidden [string] ReadFull([string]$path) {
        try { return [System.IO.File]::ReadAllText($path) }
        catch { return "Error reading file: $($_.Exception.Message)" }
    }

    # Reads the last $maxBytes of a file (shared-read so it works on a live log),
    # dropping the partial first line so the view starts on a clean line boundary.
    hidden [string] ReadTail([string]$path, [int]$maxBytes) {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -gt $maxBytes) {
                [void]$fs.Seek(-$maxBytes, [System.IO.SeekOrigin]::End)
            }
            $sr = [System.IO.StreamReader]::new($fs)
            $text = $sr.ReadToEnd()
            if ($fs.Length -gt $maxBytes) {
                $nl = $text.IndexOf("`n")
                if ($nl -ge 0 -and $nl -lt ($text.Length - 1)) { $text = $text.Substring($nl + 1) }
            }
            return $text
        }
        finally {
            $fs.Dispose()
        }
    }

    [void] ClearLogs() {
        try {
            Get-ChildItem -Path $this.Config.LogsPath -File | Remove-Item -Force -ErrorAction Stop
            $this.LoadLogs()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to clear logs: $_", "Error")
        }
    }
}
