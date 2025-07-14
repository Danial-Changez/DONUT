Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "ImportXaml.psm1")

Function Show-LogsView {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Controls.ContentControl]$contentControl
    )
    $logsViewInstance = Import-XamlView "..\Views\LogsView.xaml"
    $contentControl.Content = $logsViewInstance
    Show-HeaderPanel "Collapsed" "Collapsed" "Visible"

    $logsTabControl = $logsViewInstance.FindName('LogsTabControl')
    if (-not $logsTabControl) {
        Write-Host "[Logs] LogsTabControl not found in LogsViewInstance." -ForegroundColor Red
        return $logsViewInstance
    }
    $logsTabControl.Items.Clear()

    $logsDir = Join-Path $PSScriptRoot '..\logs'
    if (-not (Test-Path $logsDir)) {
        Write-Host "[Logs] Logs directory not found: $logsDir" -ForegroundColor Yellow
        $tab = [System.Windows.Controls.TabItem]::new()
        $tab.Header = "No logs found"
        $tb = [System.Windows.Controls.TextBox]::new()
        $tb.Text = "No log files found in the logs directory."
        $tb.IsReadOnly = $true
        $tb.VerticalScrollBarVisibility = 'Auto'
        $tb.HorizontalScrollBarVisibility = 'Auto'
        $tab.Content = $tb
        $logsTabControl.Items.Add($tab)
        return $logsViewInstance
    }
    $logFiles = Get-ChildItem -Path $logsDir -File | Sort-Object LastWriteTime -Descending
    if ($logFiles.Count -eq 0) {
        $tab = [System.Windows.Controls.TabItem]::new()
        $tab.Header = "No logs found"
        $tb = [System.Windows.Controls.TextBox]::new()
        $tb.Text = "No log files found in the logs directory."
        $tb.IsReadOnly = $true
        $tb.VerticalScrollBarVisibility = 'Auto'
        $tb.HorizontalScrollBarVisibility = 'Auto'
        $tab.Content = $tb
        $logsTabControl.Items.Add($tab)
        return $logsViewInstance
    }
    foreach ($file in $logFiles) {
        $tab = [System.Windows.Controls.TabItem]::new()
        $tab.Header = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        # Use a ScrollViewer to wrap the TextBox for reliable scrolling
        $scrollViewer = [System.Windows.Controls.ScrollViewer]::new()
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Auto'
        $tb = [System.Windows.Controls.TextBox]::new()
        $tb.IsReadOnly = $true
        $tb.FontFamily = [System.Windows.Media.FontFamily]::new("Consolas")
        $tb.FontSize = 13
        $tb.AcceptsReturn = $true
        $tb.AcceptsTab = $true
        $tb.TextWrapping = 'NoWrap'
        $tb.VerticalScrollBarVisibility = 'Hidden'  # Let ScrollViewer handle it
        $tb.HorizontalScrollBarVisibility = 'Hidden'
        try {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
            $tb.Text = $content
        } catch {
            $tb.Text = "Failed to load log file: $($_.Exception.Message)"
        }
        $scrollViewer.Content = $tb
        $tab.Content = $scrollViewer
        $logsTabControl.Items.Add($tab)
    }
    $logsTabControl.SelectedIndex = 0
    return $logsViewInstance
}