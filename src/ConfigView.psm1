Import-Module (Join-Path $PSScriptRoot 'Read-Config.psm1') -Force

# Loads config.txt and pre-fills all controls in the child view for the given command
Function Get-ConfigFromFile {
param(
    [string]$commandKey,
    [System.Windows.FrameworkElement]$childView,
    [string]$configPath
)
    if (-not (Test-Path $configPath)) { return }
    $cfg = Read-Config -configPath $configPath
    
    # Prefill controls from Args for the current command
    $multiCheckboxGroups = @('updateSeverity', 'updateType', 'updateDeviceCategory')
    
    foreach ($key in $cfg.Args.Keys) {
        $ctrl = $null
        try { $ctrl = $childView.FindName($key) } catch {}
        if (-not $ctrl) { continue }
        
        # Handle multi-checkbox groups (StackPanels containing multiple checkboxes)
        if ($key -in $multiCheckboxGroups -and $ctrl -is [System.Windows.Controls.Panel]) {
            $values = if ($cfg.Args[$key]) { $cfg.Args[$key] -split ',' | ForEach-Object { $_.Trim() } } else { @() }
            foreach ($child in $ctrl.Children) {
                if ($child -is [System.Windows.Controls.CheckBox]) {
                    $child.IsChecked = $child.Content.ToString() -in $values
                }
            }
        }
        # Handle individual controls
        elseif ($ctrl.PSObject.TypeNames[0] -match 'TextBox') {
            $ctrl.Text = $cfg.Args[$key]
        }
        elseif ($ctrl.PSObject.TypeNames[0] -match 'ComboBox') {
            foreach ($item in $ctrl.Items) {
                $content = $item
                if ($item -is [System.Windows.Controls.ComboBoxItem]) { $content = $item.Content }
                if ($content -eq $cfg.Args[$key]) {
                    $ctrl.SelectedItem = $item
                    break
                }
            }
        }
        elseif ($ctrl.PSObject.TypeNames[0] -match 'ToggleButton|CheckBox') {
            $ctrl.IsChecked = ($cfg.Args[$key] -eq 'enable')
        }
    }
    # Prefill throttleLimit if present
    if ($cfg.ThrottleLimit) {
        $throttleBox = $null
        try { $throttleBox = $childView.FindName('throttleLimit') } catch {}
        if ($throttleBox -and $throttleBox.PSObject.TypeNames[0] -match 'TextBox') {
            $throttleBox.Text = $cfg.ThrottleLimit
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
    
    # Recursively find all named controls
    function Get-AllControls {
        param([System.Windows.FrameworkElement]$parent)
        $controls = @()
        
        if ($parent.Name -and -not [string]::IsNullOrWhiteSpace($parent.Name)) {
            $controls += $parent
        }
        
        # Handle different container types
        if ($parent -is [System.Windows.Controls.Panel]) {
            foreach ($child in $parent.Children) {
                if ($child -is [System.Windows.FrameworkElement]) {
                    $controls += Get-AllControls $child
                }
            }
        }
        elseif ($parent -is [System.Windows.Controls.ContentControl] -and $parent.Content -is [System.Windows.FrameworkElement]) {
            $controls += Get-AllControls $parent.Content
        }
        elseif ($parent -is [System.Windows.Controls.ScrollViewer] -and $parent.Content -is [System.Windows.FrameworkElement]) {
            $controls += Get-AllControls $parent.Content
        }
        
        return $controls
    }
    
    $allControls = Get-AllControls $childView
    
    # Special handling for multi-checkbox groups
    $multiCheckboxGroups = @('updateSeverity', 'updateType', 'updateDeviceCategory')
    
    foreach ($ctrl in $allControls) {
        if (-not $ctrl.Name -or [string]::IsNullOrWhiteSpace($ctrl.Name)) { continue }
        
        # Handle multi-checkbox groups (StackPanels containing multiple checkboxes)
        if ($ctrl.Name -in $multiCheckboxGroups -and $ctrl -is [System.Windows.Controls.Panel]) {
            $checkedItems = @()
            foreach ($child in $ctrl.Children) {
                if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked) {
                    $checkedItems += $child.Content.ToString()
                }
            }
            $state[$ctrl.Name] = $checkedItems
        }
        # Handle individual controls
        elseif ($ctrl.PSObject.TypeNames[0] -match 'TextBox') {
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
    }
    
    $Global:ConfigViewStates[$commandKey] = $state
}

# Restore child view state from memory
Function Restore-ConfigViewState {
    param(
        [string]$commandKey,
        [System.Windows.FrameworkElement]$childView
    )
    if (-not $Global:ConfigViewStates.ContainsKey($commandKey)) { 
        return 
    }
    
    $state = $Global:ConfigViewStates[$commandKey]
    
    # Special handling for multi-checkbox groups
    $multiCheckboxGroups = @('updateSeverity', 'updateType', 'updateDeviceCategory')
    
    foreach ($key in $state.Keys) {
        $ctrl = $null
        try { $ctrl = $childView.FindName($key) } catch {}
        if (-not $ctrl) { 
            continue 
        }
        
        # Handle multi-checkbox groups (StackPanels containing multiple checkboxes)
        if ($key -in $multiCheckboxGroups -and $ctrl -is [System.Windows.Controls.Panel]) {
            $checkedItems = $state[$key]
            if ($checkedItems -is [Array]) {
                # First, uncheck all checkboxes in this group
                foreach ($child in $ctrl.Children) {
                    if ($child -is [System.Windows.Controls.CheckBox]) {
                        $child.IsChecked = $false
                    }
                }
                # Then, check the ones that should be checked
                foreach ($child in $ctrl.Children) {
                    if ($child -is [System.Windows.Controls.CheckBox] -and $child.Content.ToString() -in $checkedItems) {
                        $child.IsChecked = $true
                    }
                }
            }
        }
        # Handle individual controls
        elseif ($ctrl.PSObject.TypeNames[0] -match 'TextBox') {
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
        [System.Windows.FrameworkElement]$childView,
        [string]$configPath
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