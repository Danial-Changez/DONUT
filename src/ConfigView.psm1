Function Save-ConfigFromUI {
    param(
        [Parameter(Mandatory)]
        [string]$selectedKey,
        [System.Windows.Controls.ContentControl]$contentControl
    )
    # Command and option tables
    $MAIN_COMMANDS = @("scan", "applyUpdates", "configure", "customnotification", "driverInstall", "generateEncryptedPassword", "help", "version")
    $COMMAND_OPTIONS = @{
        scan                      = @("silent", "outputLog", "updateSeverity", "updateType", "updateDeviceCategory", "catalogLocation", "report")
        applyUpdates              = @("silent", "outputLog", "updateSeverity", "updateType", "updateDeviceCategory", "catalogLocation", "reboot", "encryptedPassword", "encryptedPasswordFile", "encryptionKey", "secureEncryptedPassword", "secureEncryptionKey", "autoSuspendBitLocker", "forceupdate")
        configure                 = @("silent", "outputLog", "updateSeverity", "updateType", "updateDeviceCategory", "catalogLocation", "driverLibraryLocation", "downloadLocation", "delayDays", "allowXML", "importSettings", "exportSettings", "lockSettings", "advancedDriverRestore", "userConsent", "secureBiosPassword", "biosPassword", "customProxy", "proxyAuthentication", "proxyFallbackToDirectConnection", "proxyHost", "proxyPort", "proxyUserName", "secureProxyPassword", "proxyPassword", "scheduleWeekly", "scheduleMonthly", "scheduleDaily", "scheduleManual", "scheduleAuto", "scheduleAction", "restoreDefaults", "forceRestart", "autoSuspendBitLocker", "defaultSourceLocation", "installationDeferral", "deferralInstallInterval", "deferralInstallCount", "systemRestartDeferral", "deferralRestartInterval", "deferralRestartCount", "updatesNotification", "maxretry")
        customnotification        = @("heading", "body", "timestamp")
        driverInstall             = @("silent", "outputLog", "driverLibraryLocation", "reboot")
        generateEncryptedPassword = @("encryptionKey", "password", "outputPath", "secureEncryptionKey", "securePassword")
        help                      = @()
        version                   = @()
    }
    $FLAG_OPTIONS = @{
        scan                      = @("silent")
        applyUpdates              = @("silent", "reboot", "autoSuspendBitLocker", "forceupdate")
        configure                 = @("silent", "allowXML", "lockSettings", "advancedDriverRestore", "userConsent", "customProxy", "proxyAuthentication", "proxyFallbackToDirectConnection", "scheduleAuto", "scheduleManual", "restoreDefaults", "forceRestart", "autoSuspendBitLocker", "defaultSourceLocation", "installationDeferral", "systemRestartDeferral", "updatesNotification")
        customnotification        = @()
        driverInstall             = @("silent", "reboot")
        generateEncryptedPassword = @()
        help                      = @()
        version                   = @()
    }
    $script_OPTIONS = @("throttleLimit")

    $script:ConfigViewInstance = $contentControl.Content
    if (-not $script:ConfigViewInstance) { 
        Write-Host "[Config] No config view loaded."; return 
    }
    $mainCommandCombo = $script:ConfigViewInstance.FindName('MainCommandComboBox')
    $optionContent = $script:ConfigViewInstance.FindName('ConfigOptionsContent')
    if (-not $mainCommandCombo -or -not $optionContent) { 
        Write-Host "[Config] MainCommandComboBox or ConfigOptionsContent not found."; return 
    }
    if (-not $selectedKey) {
        Write-Host "[Config] No key for selected command (argument missing)." -ForegroundColor Red
        return
    }
    
    $childView = $optionContent.Content
    if (-not $childView) { 
        Write-Host "[Config] No child view loaded."; return 
    }

    $lines = @()
    foreach ($cmd in $MAIN_COMMANDS) {
        $enabled = if ($cmd -eq $selectedKey) { 'enable' } else { 'disable' }
        $lines += "$cmd = $enabled"
        if ($cmd -eq $selectedKey) {
            # Flags (toggles)
            foreach ($flag in $FLAG_OPTIONS[$cmd]) {
                # Find toggle by name (case-insensitive, ignoring spaces)
                $toggle = $null
                $toggles = $childView.Children | Where-Object { $_ -is [System.Windows.Controls.StackPanel] } | ForEach-Object { $_.Children } | Where-Object { $_ -is [System.Windows.Controls.ToggleButton] }
                foreach ($t in $toggles) {
                    $label = $t.Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] } | Select-Object -First 1
                    $flagName = ($label.Text -split ':')[0] -replace ' ', ''
                    if ($flagName.ToLower() -eq $flag.ToLower()) { $toggle = $t; break }
                }
                $val = if ($toggle -and $toggle.IsChecked) { 'enable' } else { '' }
                $lines += "- $flag = $val"
            }
            # Multi-checkboxes (multi-select)
            foreach ($multi in @("updateSeverity", "updateType", "updateDeviceCategory")) {
                if ($COMMAND_OPTIONS[$cmd] -contains $multi) {
                    $wrap = $childView.Children | Where-Object { $_ -is [System.Windows.Controls.WrapPanel] } | Where-Object { $_.Tag -eq $multi }
                    if ($wrap) {
                        $checked = $wrap.Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Content }
                        if ($checked) {
                            $lines += "- $multi = $($checked -join ',')"
                        }
                    }
                }
            }
            # Textboxes
            foreach ($opt in $COMMAND_OPTIONS[$cmd]) {
                if ($FLAG_OPTIONS[$cmd] -contains $opt) { continue }
                if ($opt -in @("updateSeverity", "updateType", "updateDeviceCategory", "scheduleAction")) { continue }
                $tb = $childView.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] -and $_.Tag -eq $opt }
                if ($tb -and $tb.Text) {
                    $lines += "- $opt = $($tb.Text)"
                }
            }
            # Dropdowns (ComboBox)
            if ($COMMAND_OPTIONS[$cmd] -contains "scheduleAction") {
                $combo = $childView.Children | Where-Object { $_ -is [System.Windows.Controls.ComboBox] -and $_.Tag -eq "scheduleAction" }
                if ($combo) {
                    $val = $combo.SelectedItem
                    if ($val -is [System.Windows.Controls.ComboBoxItem]) { $val = $val.Content }
                    if ($val) {
                        $lines += "- scheduleAction = $val"
                    }
                }
            }
        }
    }
    # Write to config.txt and preserve any existing script options at the end
    $configPath = Join-Path $PSScriptRoot 'config.txt'
    if (Test-Path $configPath) {
        $scriptLines = Get-Content $configPath | Where-Object { $_ -match '^[a-zA-Z]+\s*=\s*\d+$' -and ($_ -notmatch '^(scan|applyupdates|configure|customnotification|driverinstall|generateencryptedpassword|help|version)\s*=') }
        foreach ($g in $scriptLines) { $lines += $g }
    }
    Set-Content -Path $configPath -Value $lines
    Write-Host "[Config] Saved config to $configPath"
}