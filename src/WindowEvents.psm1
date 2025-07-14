# Window event handlers and header panel logic
Function Show-HeaderPanel {
    param(
        $homeVisibility,
        $configVisibility,
        $logsVisibility,
        $headerHome,
        $headerConfig,
        $headerLogs
    )
    if ($headerHome) { $headerHome.Visibility = $homeVisibility }
    if ($headerConfig) { $headerConfig.Visibility = $configVisibility }
    if ($headerLogs) { $headerLogs.Visibility = $logsVisibility }
}
