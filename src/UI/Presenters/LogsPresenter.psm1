using namespace System.Windows.Controls
using module "..\..\Models\AppConfig.psm1"

<#
.SYNOPSIS
    Drives the Logs page: loads per-host log files into tabs and clears them.

.DESCRIPTION
    Reads the log files under %LOCALAPPDATA%\DONUT\logs into a tab each (plus a
    Default tab) and clears them on request. Large files are tail-loaded (the last
    TailBytes) with a "Load full file" button, so opening the tab never blocks on
    reading a multi-MB log into a TextBox.
#>
class LogsPresenter {
    [AppConfig] $Config
    [System.Windows.FrameworkElement] $ViewContent
    [TabControl] $LogsTabControl
    [Button] $ClearLogsButton

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
        $this.LogsTabControl = $this.ViewContent.FindName('LogsTabControl')
        $this.ClearLogsButton = $this.ViewContent.FindName('btnClearLogs')

        $presenter = $this
        if ($this.ClearLogsButton) {
            $this.ClearLogsButton.Add_Click({ $presenter.ClearLogs() }.GetNewClosure())
        }

        $this.LoadLogs()
    }

    [void] LoadLogs() {
        if (-not $this.LogsTabControl) { return }

        $this.LogsTabControl.Items.Clear()

        $logsDir = $this.Config.LogsPath
        if (-not (Test-Path $logsDir)) {
            $this.AddTab("No logs found", "No log files found.")
            return
        }

        $logFiles = @(Get-ChildItem -Path $logsDir -File | Sort-Object LastWriteTime -Descending)

        if ($logFiles.Count -eq 0) {
            $this.AddTab("No logs found", "No log files found.")
            return
        }

        foreach ($file in $logFiles) {
            try {
                $this.AddFileTab($file)
            } catch {
                $this.AddTab($file.BaseName, "Error reading file: $_")
            }
        }
    }

    # Simple text tab (used for status messages like "No logs found.").
    [void] AddTab([string]$header, [string]$content) {
        $tab = [TabItem]::new()
        $tab.Header = $header
        $tab.Content = $this.NewLogTextBox($content)
        $this.LogsTabControl.Items.Add($tab)
    }

    # File-backed tab: full content for small files; a tail + "Load full file" bar for
    # large ones, so the Logs tab opens instantly regardless of log size.
    hidden [void] AddFileTab([System.IO.FileInfo]$file) {
        $tab = [TabItem]::new()
        $tab.Header = $file.BaseName
        $path = $file.FullName

        if ($file.Length -le [LogsPresenter]::FullLoadThresholdBytes) {
            $tab.Content = $this.NewLogTextBox($this.ReadFull($path))
            $this.LogsTabControl.Items.Add($tab)
            return
        }

        $tb = $this.NewLogTextBox($this.ReadTail($path, [LogsPresenter]::TailBytes))

        $grid = [Grid]::new()
        $r0 = [RowDefinition]::new(); $r0.Height = [System.Windows.GridLength]::Auto
        $r1 = [RowDefinition]::new(); $r1.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $grid.RowDefinitions.Add($r0); $grid.RowDefinitions.Add($r1)

        $bar = [Border]::new()
        $bar.Padding = [System.Windows.Thickness]::new(8, 4, 8, 6)
        $panel = [StackPanel]::new()
        $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal

        $note = [TextBlock]::new()
        $sizeMb = [Math]::Round($file.Length / 1MB, 1)
        $note.Text = "Showing the last $([int]([LogsPresenter]::TailBytes / 1KB)) KB of $sizeMb MB.  "
        $note.Foreground = [System.Windows.Media.Brushes]::Gray
        $note.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void]$panel.Children.Add($note)

        $btn = [Button]::new()
        $btn.Content = 'Load full file'
        $btn.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
        $style = $this.LogsTabControl.TryFindResource('ButtonOutline')
        if (-not $style) { $style = $this.LogsTabControl.TryFindResource('ModernButton') }
        if ($style) { $btn.Style = $style }
        [void]$panel.Children.Add($btn)

        $bar.Child = $panel
        [Grid]::SetRow($bar, 0)
        [Grid]::SetRow($tb, 1)
        [void]$grid.Children.Add($bar)
        [void]$grid.Children.Add($tb)

        # Load the whole file on demand, then hide the bar.
        $presenter = $this
        $capturedPath = $path
        $btn.Add_Click({
            $tb.Text = $presenter.ReadFull($capturedPath)
            $bar.Visibility = [System.Windows.Visibility]::Collapsed
        }.GetNewClosure())

        $tab.Content = $grid
        $this.LogsTabControl.Items.Add($tab)
    }

    hidden [TextBox] NewLogTextBox([string]$content) {
        $tb = [TextBox]::new()
        $tb.Text = $content
        $tb.IsReadOnly = $true
        $tb.VerticalScrollBarVisibility = 'Auto'
        $tb.HorizontalScrollBarVisibility = 'Auto'
        $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
        $tb.Background = [System.Windows.Media.Brushes]::Transparent
        $tb.Foreground = [System.Windows.Media.Brushes]::White
        $tb.BorderThickness = [System.Windows.Thickness]::new(0)
        return $tb
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
