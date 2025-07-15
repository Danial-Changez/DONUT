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
        $tab.DataContext = "No log files found in the logs directory."
        $logsTabControl.Items.Add($tab)
        return $logsViewInstance
    }
    $logFiles = Get-ChildItem -Path $logsDir -File | Sort-Object LastWriteTime -Descending
    if ($logFiles.Count -eq 0) {
        $tab = [System.Windows.Controls.TabItem]::new()
        $tab.Header = "No logs found"
        $tab.DataContext = "No log files found in the logs directory."
        $logsTabControl.Items.Add($tab)
        return $logsViewInstance
    }
    foreach ($file in $logFiles) {
        $tab = [System.Windows.Controls.TabItem]::new()
        $tab.Header = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $tb = [System.Windows.Controls.TextBox]::new()
        $tb.VerticalScrollBarVisibility = 'Auto'
        $tb.HorizontalScrollBarVisibility = 'Auto'
        $tb.HorizontalAlignment = 'Stretch'
        $tb.VerticalAlignment = 'Stretch'
        try {
            $tb.Text = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
        } catch {
            $tb.Text = "Failed to load log file: $($file.Name): $($_.Exception.Message)"
        }
        $tab.Content = $tb
        $logsTabControl.Items.Add($tab)
    }
    $logsTabControl.SelectedIndex = 0
    return $logsViewInstance
}