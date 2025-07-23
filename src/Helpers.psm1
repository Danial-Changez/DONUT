# Sets placeholder text and logic for a TextBox control.
# - Shows placeholder when empty.
# - Handles focus events to clear or restore placeholder.
Function Set-PlaceholderLogic {
    param(
        [System.Windows.Controls.TextBox]$txt,
        [string]$placeHolder
    )
    if ([string]::IsNullOrWhiteSpace($txt.Text) -or $txt.Text -eq $placeHolder) {
        Show-Placeholder $txt $placeHolder
    }
    else {
        $txt.Tag = $null
    }
    $txt.Add_GotFocus({
            if ($this.Tag -eq "placeholder") {
                $this.Text = ""
                $this.Tag = $null
            }
        })
    $txt.Add_LostFocus({
            if ([string]::IsNullOrWhiteSpace($this.Text)) {
                Show-Placeholder $this $placeHolder
            }
            elseif ($this.Tag -ne "placeholder") {
                $script:HomeViewText = $this.Text
            }
        })
}

# Displays placeholder text in a TextBox and marks it as a placeholder.
Function Show-Placeholder {
    param(
        [System.Windows.Controls.TextBox]$txt,
        [string]$placeHolder
    )
    $txt.Text = $placeHolder
    $txt.Tag = "placeholder"
}


# Initializes the search bar with content from WSID.txt if available.
# - Loads and displays non-empty lines from the file.
Function Initialize-SearchBar {
    param(
        [System.Windows.Controls.TextBox]$textBox,
        [string]$wsidFilePath
    )
    if ($wsidFilePath -and (Test-Path $wsidFilePath)) {
        $lines = Get-Content -Path $wsidFilePath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $textBox.Text = $lines -join "`r`n"
    }
}

# Sets the visibility of header panels for Home, Config, and Logs views.
# - Updates the Visibility property for each header control.
Function Show-HeaderPanel {
    param(
        [string]$homeVisibility,
        [string]$configVisibility,
        [string]$logsVisibility,
        $headerHome,
        $headerConfig,
        $headerLogs
    )
    if ($headerHome) { $headerHome.Visibility = $homeVisibility }
    if ($headerConfig) { $headerConfig.Visibility = $configVisibility }
    if ($headerLogs) { $headerLogs.Visibility = $logsVisibility }
}

# Returns the enabled command in the config
Function Get-EnabledConfigCommand {
    param($homeView)
    $configPath = Join-Path $PSScriptRoot '..\config.txt'
    $enabledCmd = $null
    if (Test-Path $configPath) {
        $configLines = Get-Content $configPath
        foreach ($line in $configLines) {
            if ($line -notmatch '^-') {
                if ($line -match '^\s*(?<cmd>\w+)\s*=\s*enable') {
                    $enabledCmd = $matches['cmd']
                    break
                }
            }
        }
    }
    return $enabledCmd
}

# Adds all resource dictionaries from the Styles folder to the window.
Function Add-ResourceDictionaries {
    param(
        [System.Windows.Window]$window
    )
    $stylesPath = Join-Path $PSScriptRoot '..\Styles'
    Get-ChildItem -Path $stylesPath -Filter '*.xaml' | ForEach-Object {
        $styleStream = [System.IO.File]::OpenRead($_.FullName)
        try {
            $styleDict = [Windows.Markup.XamlReader]::Load($styleStream)
            try {
                $window.Resources.MergedDictionaries.Add($styleDict)
            }
            catch {
                Write-Warning "Failed to add style dictionary: $($_.FullName) - $_"
            }
        }
        catch {
            Write-Warning "Failed to load style dictionary: $($_.FullName) - $_"
        }
        finally {
            $styleStream.Close()
        }
    }
}

# Updates the label of the Search button based on config.txt settings.
# - Reads config.txt to determine which command is enabled.
# - Sets the button label accordingly in the HomeView.
Function Update-SearchButtonLabel {
    param($homeView)
    $enabledCmd = Get-EnabledConfigCommand -homeView $homeView
    $viewMap = @{
        "Scan"                        = "scan"
        "Apply Updates"               = "applyUpdates"
        "Configure"                   = "configure"
        "Driver Install"              = "driverInstall"
        "Version"                     = "version"
        "Help"                        = "help"
        "Generate Encrypted Password" = "generateEncryptedPassword"
        "Custom Notification"         = "customnotification"
    }
    $selectedKey = $null
    foreach ($k in $viewMap.Keys) {
        if ($viewMap[$k] -eq $enabledCmd) { $selectedKey = $k; break }
    }
    $searchButton = $homeView.FindName('btnSearch')
    if ($searchButton -and $selectedKey) {
        $searchButton.Content = $selectedKey
    }
}