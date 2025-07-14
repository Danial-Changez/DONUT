Function Save-ConfigFromUI {
    param(
        [Parameter(Mandatory)]
        [string]$selectedKey,
        [System.Windows.Controls.ContentControl]$contentControl,
        $childView
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


    if (-not $selectedKey) {
        Write-Host "[Config] No key for selected command (argument missing)." -ForegroundColor Red
        return
    }
    if (-not $childView) { 
        Write-Host "[Config] No child view loaded."; return 
    }

    # Recursive function to find all controls of a type (optionally by Tag)


    $lines = @()
    foreach ($cmd in $MAIN_COMMANDS) {
        $enabled = if ($cmd -eq $selectedKey) { 'enable' } else { 'disable' }
        $lines += "$cmd = $enabled"
        if ($cmd -eq $selectedKey) {
            # Flags (toggles)
            foreach ($flag in $FLAG_OPTIONS[$cmd]) {
                $ctrl = $null
                try { $ctrl = $childView.FindName($flag) } catch {}
                if ($ctrl -and $ctrl.PSObject.TypeNames[0] -match 'ToggleButton|CheckBox') {
                    $val = if ($ctrl.IsChecked) { 'enable' } else { '' }
                    $lines += "- $flag = $val"
                }
            }
            # Multi-checkboxes (multi-select)
            foreach ($multi in @("updateSeverity", "updateType", "updateDeviceCategory")) {
                if ($COMMAND_OPTIONS[$cmd] -contains $multi) {
                    $checked = @()
                    # Try to find a parent panel by name
                    $panel = $null
                    try { $panel = $childView.FindName($multi) } catch {}
                    if ($panel -and $panel.Children) {
                        foreach ($c in $panel.Children) {
                            if ($c -is [System.Windows.Controls.CheckBox] -and $c.IsChecked) {
                                $checked += $c.Content
                            }
                        }
                    }
                    if ($checked) {
                        $lines += "- $multi = $($checked -join ',')"
                    }
                }
            }
            # Textboxes
            foreach ($opt in $COMMAND_OPTIONS[$cmd]) {
                if ($FLAG_OPTIONS[$cmd] -contains $opt) { continue }
                if ($opt -in @("updateSeverity", "updateType", "updateDeviceCategory", "scheduleAction")) { continue }
                $tb = $null
                try { $tb = $childView.FindName($opt) } catch {}
                if ($tb -and $tb.PSObject.TypeNames[0] -match 'TextBox' -and $tb.Text -and -not [string]::IsNullOrWhiteSpace($tb.Text)) {
                    $lines += "- $opt = $($tb.Text)"
                }
            }
            # Dropdowns (ComboBox)
            if ($COMMAND_OPTIONS[$cmd] -contains "scheduleAction") {
                $combo = $null
                try { $combo = $childView.FindName("scheduleAction") } catch {}
                if ($combo -and $combo.PSObject.TypeNames[0] -match 'ComboBox') {
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
    $configPath = Join-Path $PSScriptRoot '../config.txt'
    if (Test-Path $configPath) {
        $scriptLines = Get-Content $configPath | Where-Object { $_ -match '^[a-zA-Z]+\s*=\s*\d+$' -and ($_ -notmatch '^(scan|applyupdates|configure|customnotification|driverinstall|generateencryptedpassword|help|version|throttleLimit)\s*=') }
        foreach ($g in $scriptLines) { $lines += $g }
    }
    # Add throttleLimit if present in the UI (after removing all previous ones)
    $throttleBox = $null
    try { $throttleBox = $childView.FindName('throttleLimit') } catch {}
    if ($throttleBox -and $throttleBox.PSObject.TypeNames[0] -match 'TextBox' -and $throttleBox.Text -and -not [string]::IsNullOrWhiteSpace($throttleBox.Text)) {
        $lines += "throttleLimit = $($throttleBox.Text)"
    } else {
        $lines += "throttleLimit = 5"
    }
    Set-Content -Path $configPath -Value $lines
    Write-Host "[Config] Saved config to $configPath"
}