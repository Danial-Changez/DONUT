# Global hashtable for in-memory persistent view states
if (-not $Global:ConfigViewStates) {
    $Global:ConfigViewStates = @{}
}

# Loads config.txt and pre-fills all controls in the child view for the given command
Function Get-ConfigFromFile {
    param(
        [string]$commandKey,
        [System.Windows.FrameworkElement]$childView,
        $config
    )
    
    $configPath = Join-Path $PSScriptRoot '../config.txt'
    if (-not (Test-Path $configPath)) { 
        return
    }
    
    $lines = Get-Content $configPath
    $config = @{}
    foreach ($line in $lines) {
        if ($line -match '^-\\s*(\\w+)\\s*=\\s*(.*)$') {
            $name = $matches[1]
            $val = $matches[2]
            $config[$name] = $val
        }
        elseif ($line -match '^throttleLimit\\s*=\\s*(\\d+)$') {
            $config['throttleLimit'] = $matches[1]
        }
    }
    # Only prefill controls for the enabled command's child view
    $enabledCmd = $config.EnabledCmdOption
    if ($enabledCmd -and $enabledCmd -ne $commandKey) { return }
    # Prefill controls
    foreach ($key in $config.Keys) {
        $ctrl = $null
        try { $ctrl = $childView.FindName($key) } catch {}
        if (-not $ctrl) { continue }
        if ($ctrl.PSObject.TypeNames[0] -match 'TextBox') {
            $ctrl.Text = $config[$key]
        }
        elseif ($ctrl.PSObject.TypeNames[0] -match 'ComboBox') {
            foreach ($item in $ctrl.Items) {
                $content = $item
                if ($item -is [System.Windows.Controls.ComboBoxItem]) { $content = $item.Content }
                if ($content -eq $config[$key]) {
                    $ctrl.SelectedItem = $item
                    break
                }
            }
        }
        elseif ($ctrl.PSObject.TypeNames[0] -match 'ToggleButton|CheckBox') {
            $ctrl.IsChecked = ($config[$key] -eq 'enable')
        }
        elseif ($ctrl.Children) {
            # Multi-checkbox panel
            foreach ($c in $ctrl.Children) {
                if ($c -is [System.Windows.Controls.CheckBox]) {
                    $c.IsChecked = $false
                    if ($config[$key] -and $config[$key] -match $c.Content) {
                        $c.IsChecked = $true
                    }
                }
            }
        }
    }
    # Prefill throttleLimit if present
    if ($config.ContainsKey('throttleLimit')) {
        $throttleBox = $null
        try { $throttleBox = $childView.FindName('throttleLimit') } catch {}
        if ($throttleBox -and $throttleBox.PSObject.TypeNames[0] -match 'TextBox') {
            $throttleBox.Text = $config['throttleLimit']
        }
    }
}

# Save current child view state to memory
Function Save-ConfigViewState {
    param(
        [string]$commandKey,
        [System.Windows.FrameworkElement]$childView
    )
    $state = @{}
    foreach ($ctrl in $childView.Children) {
        if ($ctrl.PSObject.TypeNames[0] -match 'TextBox') {
            $state[$ctrl.Name] = $ctrl.Text
        }
        elseif ($ctrl.PSObject.TypeNames[0] -match 'ComboBox') {
            $val = $ctrl.SelectedItem
            if ($val -is [System.Windows.Controls.ComboBoxItem]) { $val = $val.Content }
            $state[$ctrl.Name] = $val
        }
        elseif ($ctrl.PSObject.TypeNames[0] -match 'ToggleButton|CheckBox') {
            $state[$ctrl.Name] = $ctrl.IsChecked
        }
        elseif ($ctrl.Children) {
            foreach ($c in $ctrl.Children) {
                if ($c -is [System.Windows.Controls.CheckBox]) {
                    $state[$c.Name] = $c.IsChecked
                }
            }
        }
    }
    $Global:ConfigViewStates[$commandKey] = $state
}

# Restore child view state from memory
Function Restore-ConfigViewState {
    param(
        [string]$commandKey,
        [System.Windows.FrameworkElement]$childView
    )
    if (-not $Global:ConfigViewStates.ContainsKey($commandKey)) { return }
    $state = $Global:ConfigViewStates[$commandKey]
    foreach ($key in $state.Keys) {
        $ctrl = $null
        try { $ctrl = $childView.FindName($key) } catch {}
        if (-not $ctrl) { continue }
        if ($ctrl.PSObject.TypeNames[0] -match 'TextBox') {
            $ctrl.Text = $state[$key]
        }
        elseif ($ctrl.PSObject.TypeNames[0] -match 'ComboBox') {
            foreach ($item in $ctrl.Items) {
                $content = $item
                if ($item -is [System.Windows.Controls.ComboBoxItem]) { $content = $item.Content }
                if ($content -eq $state[$key]) {
                    $ctrl.SelectedItem = $item
                    break
                }
            }
        }
        elseif ($ctrl.PSObject.TypeNames[0] -match 'ToggleButton|CheckBox') {
            $ctrl.IsChecked = $state[$key]
        }
    }
    # Multi-checkboxes
    foreach ($ctrl in $childView.Children) {
        if ($ctrl.Children) {
            foreach ($c in $ctrl.Children) {
                if ($c -is [System.Windows.Controls.CheckBox] -and $state.ContainsKey($c.Name)) {
                    $c.IsChecked = $state[$c.Name]
                }
            }
        }
    }
}
# Saves the current configuration from the UI to config.txt.
# - Reads all relevant controls from the child view for the selected command.
# - Handles toggles, multi-selects, textboxes, and dropdowns.
# - Preserves existing script options and throttle limit.
# - Updates config.txt with the new settings.
Function Save-ConfigFromUI {
    param(
        [string]$selectedKey,
        [System.Windows.Controls.ContentControl]$contentControl,
        [System.Windows.FrameworkElement]$childView
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

    # Validate parameters
    if (-not $selectedKey) {
        Write-Host "[Config] No key for selected command (argument missing)." -ForegroundColor Red
        return
    }
    if (-not $childView) { 
        Write-Host "[Config] No child view loaded."
        return 
    }

    # Loop to find all controls of a type by name
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
    
    # Add throttleLimit if present in the UI, otherwise default to 5
    $throttleBox = $null
    try { $throttleBox = $childView.FindName('throttleLimit') } catch {}
    if ($throttleBox -and $throttleBox.PSObject.TypeNames[0] -match 'TextBox' -and $throttleBox.Text -and -not [string]::IsNullOrWhiteSpace($throttleBox.Text)) {
        $lines += "throttleLimit = $($throttleBox.Text)"
    }
    else {
        $lines += "throttleLimit = 5"
    }
    Set-Content -Path $configPath -Value $lines
}