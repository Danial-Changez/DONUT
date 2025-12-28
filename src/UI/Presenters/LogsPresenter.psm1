using namespace System.Windows.Controls
using module "..\..\Models\AppConfig.psm1"

class LogsPresenter {
    [AppConfig] $Config
    [System.Windows.FrameworkElement] $ViewContent
    [TabControl] $LogsTabControl
    [Button] $ClearLogsButton

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

        $logFiles = Get-ChildItem -Path $logsDir -File | Sort-Object LastWriteTime -Descending
        
        if ($logFiles.Count -eq 0) {
            $this.AddTab("No logs found", "No log files found.")
            return
        }

        foreach ($file in $logFiles) {
            try {
                $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
                $this.AddTab($file.BaseName, $content)
            } catch {
                $this.AddTab($file.BaseName, "Error reading file: $_")
            }
        }
    }

    [void] AddTab([string]$header, [string]$content) {
        $tab = [TabItem]::new()
        $tab.Header = $header
        
        $tb = [TextBox]::new()
        $tb.Text = $content
        $tb.IsReadOnly = $true
        $tb.VerticalScrollBarVisibility = 'Auto'
        $tb.HorizontalScrollBarVisibility = 'Auto'
        $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
        $tb.Background = [System.Windows.Media.Brushes]::Transparent
        $tb.Foreground = [System.Windows.Media.Brushes]::White
        $tb.BorderThickness = [System.Windows.Thickness]::new(0)
        
        $tab.Content = $tb
        $this.LogsTabControl.Items.Add($tab)
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
