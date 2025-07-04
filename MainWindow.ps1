Add-Type -AssemblyName PresentationFramework

Function Import-Xaml {
    param (
        [Parameter(Mandatory)]
        [string]$RelativePath
    )
    $fullPath = Join-Path $PSScriptRoot $RelativePath
    $stream = [System.IO.File]::OpenRead($fullPath)
    try {
        [Windows.Markup.XamlReader]::Load($stream)
    }
    finally {
        $stream.Close()
    }
}

Function Import-XamlView {
    param([string]$RelativePath)
    $fullPath = Join-Path $PSScriptRoot $RelativePath
    Write-Host "Loading XAML file from path: $fullPath"
    if (-Not (Test-Path $fullPath)) {
        Write-Host "File not found: $fullPath"
        return $null
    }
    $stream = [System.IO.File]::OpenRead($fullPath)
    try {
        $xaml = [Windows.Markup.XamlReader]::Load($stream)
        Write-Host "XAML file loaded successfully."
        return $xaml
    }
    catch {
        Write-Host "Failed to load XAML file: $($_.Exception.Message)"
        return $null
    }
    finally {
        $stream.Close()
    }
}

Function Set-PlaceholderLogic {
    param($txt, $placeHolder)
    # Set placeholder if needed
    if ([string]::IsNullOrWhiteSpace($txt.Text) -or $txt.Text -eq $placeHolder) {
        Show-Placeholder $txt $placeHolder
    }
    else {
        $txt.Tag = $null
    }

    # Ensure placeholder is cleared on focus
    $txt.Add_GotFocus({
            if ($this.Tag -eq "placeholder") {
                $this.Text = ""
                $this.Tag = $null
            }
        })
    
    # Restore placeholder on lost focus if text is empty
    $txt.Add_LostFocus({
            if ([string]::IsNullOrWhiteSpace($this.Text)) {
                Show-Placeholder $this $placeHolder
            }
            elseif ($this.Tag -ne "placeholder") {
                $script:HomeViewText = $this.Text
            }
        })
}

Function Initialize-HomeView {
    # Only do one-time setup: event wiring, variable assignment
    $script:HomeView = Import-XamlView "Views\HomeView.xaml"
    if ($null -eq $script:HomeView) {
        Write-Host "Failed to load HomeView.xaml."
        return
    }
    # Initialize the search bar
    $script:SearchBar = $script:HomeView.FindName('txtHomeMessage')
    if ($script:SearchBar) {
        Initialize-SearchBar $script:SearchBar
        Set-PlaceholderLogic $script:SearchBar "WSID..."
        Write-Host "Search bar initialized with: '$($script:SearchBar.Text)'"
    }
    else {
        Write-Host "Search bar not found in HomeView."
    }
    # Attach the click event to the Search button
    $searchButton = $script:HomeView.FindName('btnSearch')
    if ($searchButton) {
        $null = $searchButton.Remove_Click
        $searchButton.Add_Click({
                $bar = $script:HomeView.FindName('txtHomeMessage')
                Update-WSIDFile $bar
            })
        Write-Host "Search button click event attached."
    }
    else {
        Write-Host "Search button not found in HomeView."
    }
    # Attach the SelectionChanged event to the ComboBox
    $mainCommandComboBox = $script:HomeView.FindName('MainCommandComboBox')
    if ($mainCommandComboBox) {
        $null = $mainCommandComboBox.Remove_SelectionChanged
        $mainCommandComboBox.Style = $script:HomeView.Resources["ModernComboBox"]
        $mainCommandComboBox.Add_SelectionChanged({
                OnMainCommandChanged $mainCommandComboBox
            })
        Write-Host "MainCommandComboBox SelectionChanged event attached."
    }
    else {
        Write-Host "MainCommandComboBox not found in HomeView."
    }
}

# Define Show-Placeholder globally
Function Show-Placeholder {
    param($txt, $placeHolder)
    $txt.Text = $placeHolder
    $txt.Tag = "placeholder"
}

# Function to initialize the search bar with the content of WSID.txt
Function Initialize-SearchBar {
    param($textBox)
    if (Test-Path $wsidFilePath) {
        # Read file, ignore blank/whitespace lines
        $lines = Get-Content -Path $wsidFilePath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $textBox.Text = $lines -join "`r`n"
    }
}

if (-not $script:ActiveRunspaces) { $script:ActiveRunspaces = @() }
if (-not $script:RunspaceJobs) { $script:RunspaceJobs = @{} }
if (-not $script:QueuedOrRunning) { $script:QueuedOrRunning = @{} }
if (-not $script:PendingQueue) { $script:PendingQueue = [System.Collections.Queue]::new() }
if (-not $script:TabsMap) { $script:TabsMap = @{} }
if (-not $script:SyncUI) { $script:SyncUI = [hashtable]::Synchronized(@{}) }

# Define Start-NextRunspace as a script-scoped scriptblock
$script:StartNextRunspace = {
    if ($script:PendingQueue.Count -eq 0) { return }
    $computer = $script:PendingQueue.Dequeue()
    if (-not $script:TabsMap.ContainsKey($computer)) {
        Write-Host "No tab for $computer, skipping runspace creation."
        return
    }
    $queue = $script:SyncUI[$computer]
    $tb = $script:TabsMap[$computer]
    $tb.AppendText("[$computer] Runspace started at $(Get-Date).`n")
    $tb.ScrollToEnd()
    $remoteDCUPathAbs = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'src\remoteDCU.ps1'))
    $ps = [PowerShell]::Create()
    $ps.AddScript({
            param($hostName, $scriptPath, $queue, $tb)
            if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
                $tb.Dispatcher.Invoke([action[string]] {
                        param($l)
                        $tb.AppendText("ERROR: remoteDCU.ps1 path is invalid or missing.`n")
                        $tb.ScrollToEnd()
                    }, "")
                return
            }
            $psi = New-Object System.Diagnostics.ProcessStartInfo(
                'pwsh', "-NoProfile -NoLogo -File `"$scriptPath`" -ComputerName $hostName"
            )
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start() | Out-Null

            $stdout = $proc.StandardOutput
            $stderr = $proc.StandardError
            $lastErrorLine = $null
            while (-not $stdout.EndOfStream) {
                $line = $stdout.ReadLine()
                $cleanLine = $line -replace "`e\[[\d;]*[A-Za-z]", ""
                if ($cleanLine -match "pwsh exited on .+ with error code (\d+)\.") {
                    $lastErrorLine = $matches[0]
                }
                elseif ($cleanLine -notmatch "Connecting to|Starting PSEXESVC|Copying authentication key|Connecting with PsExec service|Starting pwsh on" -and $cleanLine -match '\S') {
                    $queue.Enqueue($cleanLine) | Out-Null
                }
            }
            while (-not $stderr.EndOfStream) {
                $line = $stderr.ReadLine()
                $cleanLine = $line -replace "`e\[[\d;]*[A-Za-z]", ""
                if ($cleanLine -notmatch "Connecting to|Starting PSEXESVC|Copying authentication key|Connecting with PsExec service|Starting pwsh on" -and $cleanLine -match '\S') {
                    $queue.Enqueue($cleanLine) | Out-Null
                }
            }
            $proc.WaitForExit()
            if ($lastErrorLine) {
                $tb.Dispatcher.Invoke([action[string]] {
                        param($l)
                        $tb.AppendText("Final status: $l`n")
                        $tb.ScrollToEnd()
                    }, $lastErrorLine)
            }
        }).AddArgument($computer).AddArgument($remoteDCUPathAbs).AddArgument($queue).AddArgument($tb)

    $async = $ps.BeginInvoke()
    $script:ActiveRunspaces += $ps
    $script:RunspaceJobs[$ps] = @{
        Computer    = $computer
        PowerShell  = $ps
        AsyncResult = $async
    }
    Write-Host "Started runspace for $computer. Active: $($script:ActiveRunspaces.Count), Pending: $($script:PendingQueue.Count)"
}

# Function to update WSID.txt with the content of the search bar
Function Update-WSIDFile {
    param($textBox)
    # Ensure the TextBox reference is valid
    if ($null -eq $textBox) {
        Write-Host "TextBox reference is null. Ensure 'txtHomeMessage' exists in the XAML."
        return
    }

    # Ensure the TextBox has valid content before updating the file
    if ([string]::IsNullOrWhiteSpace($textBox.Text)) {
        Write-Host "TextBox is empty. File not updated."
        return
    }
        
    # Split, remove empty lines, then take unique entries
    $valid = ($textBox.Text -split "[\r\n]+") |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique

    Set-Content -Path $wsidFilePath -Value $valid
    Write-Host "WSID.txt updated with: '$($valid -join ',')'"

    # Read throttleLimit from config.txt
    $configPath = Join-Path $PSScriptRoot 'config.txt'
    # Default
    $script:throttleLimit = 5
    if (Test-Path $configPath) {
        $configLines = Get-Content $configPath | Where-Object { $_ -match 'throttleLimit' }
        if ($configLines) {
            $line = $configLines -replace '[\r\n ]', ''
            if ($line -match 'throttleLimit=(\d+)') {
                $script:throttleLimit = [int]$matches[1]
            }
        }
    }
    $tabs = $script:HomeView.FindName('TerminalTabs')
    
    # Prepare queue of computers to process
    # Only append new computers, do not reset existing tabs/queues
    foreach ($computer in $valid) {
        if (-not $script:QueuedOrRunning.ContainsKey($computer)) {
            $script:PendingQueue.Enqueue($computer)
            
            # Create a Tab + readonly TextBox
            $tab = [System.Windows.Controls.TabItem]::new() 
            $tb = [System.Windows.Controls.TextBox]::new()
            $tab.Header = $computer
            $tab.Content = $tb
            $tabs.Items.Add($tab)

            $script:TabsMap[$computer] = $tb
            $script:SyncUI[$computer] = New-Object System.Collections.Concurrent.ConcurrentQueue[string]

            # Set default text for this computer's textbox
            $tb.AppendText("[$computer] Starting runspace and remoteDCU.ps1...`n")
            $tb.ScrollToEnd()
            $script:QueuedOrRunning[$computer] = $true
        }
    }

    # Start up to $throttleLimit runspaces
    for ($i = 0; $i -lt $script:throttleLimit -and $script:PendingQueue.Count -gt 0; $i++) {
        & $script:StartNextRunspace
    }

    # Only start the DispatcherTimer ONCE per search/click
    if ($script:Timer) {
        $script:Timer.Stop()
        $script:Timer = $null
    }
    # Only clear the output queue and textbox for new computers, not for all tabs
    foreach ($computer in $valid) {
        if ($script:TabsMap.ContainsKey($computer)) { continue }
        
        $queue = $script:SyncUI[$computer]
        while ($queue.Count -gt 0) { $null = $queue.TryDequeue([ref]([string]::Empty)) }
        $tb = $script:TabsMap[$computer]
        $tb.Clear()
    }

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:Timer.Add_Tick({

            foreach ($comp in $script:TabsMap.Keys) {
                $tb = $script:TabsMap[$comp]
                $queue = $script:SyncUI[$comp]
                $line = $null
                while ($queue.TryDequeue([ref]$line)) {
                    $tb.AppendText("$line`n")
                    $tb.ScrollToEnd()
                }
            }
            $finished = @()
            foreach ($ps in @($script:ActiveRunspaces)) {
                if ($ps -and $script:RunspaceJobs.ContainsKey($ps)) {
                    $job = $script:RunspaceJobs[$ps]
                    if ($ps.InvocationStateInfo.State -eq 'Completed' -or $ps.InvocationStateInfo.State -eq 'Failed' -or $ps.InvocationStateInfo.State -eq 'Stopped') {
                        try { $ps.EndInvoke($job.AsyncResult) } catch {}
                        $ps.Dispose()
                        Write-Host "`n[DEBUG] Runspace for $($job.Computer) finished and disposed. State: $($ps.InvocationStateInfo.State)" -ForegroundColor Green
                        $finished += $ps
                    }
                }
            }
            foreach ($ps in $finished) {
                if ($script:RunspaceJobs.ContainsKey($ps)) {
                    $comp = $script:RunspaceJobs[$ps].Computer
                    Write-Host "[DEBUG] Cleaning up Runspace for $comp`n" -ForegroundColor Green
                    $script:RunspaceJobs.Remove($ps)
                }
                else {
                    Write-Host "[DEBUG] Attempted cleanup for runspace not in RunspaceJobs." -ForegroundColor Yellow
                }
                $script:ActiveRunspaces = $script:ActiveRunspaces | Where-Object { $_ -ne $ps }
            }
            while ($script:ActiveRunspaces.Count -lt $script:throttleLimit -and $script:PendingQueue.Count -gt 0) {
                & $script:StartNextRunspace
                Write-Host "[DEBUG] Started new runspace. Active: $($script:ActiveRunspaces.Count), Pending: $($script:PendingQueue.Count)" -ForegroundColor Cyan
            }
        })
    $script:Timer.Start()

    if ($tabs.Items.Count -gt 0) {
        $tabs.SelectedIndex = 0
    }
}

# --- Config Save Logic ---
Function Save-ConfigFromUI {
    param(
        [string]$selectedKey
    )
    # Canonical command and option tables (must match config file spec)
    $MAIN_COMMANDS = @("scan", "applyUpdates", "configure", "customnotification", "driverInstall", "generateEncryptedPassword", "help", "version")
    $COMMAND_OPTIONS = @{
        scan = @("silent", "outputLog", "updateSeverity", "updateType", "updateDeviceCategory", "catalogLocation", "report")
        applyUpdates = @("silent", "outputLog", "updateSeverity", "updateType", "updateDeviceCategory", "catalogLocation", "reboot", "encryptedPassword", "encryptedPasswordFile", "encryptionKey", "secureEncryptedPassword", "secureEncryptionKey", "autoSuspendBitLocker", "forceupdate")
        configure = @("silent", "outputLog", "updateSeverity", "updateType", "updateDeviceCategory", "catalogLocation", "driverLibraryLocation", "downloadLocation", "delayDays", "allowXML", "importSettings", "exportSettings", "lockSettings", "advancedDriverRestore", "userConsent", "secureBiosPassword", "biosPassword", "customProxy", "proxyAuthentication", "proxyFallbackToDirectConnection", "proxyHost", "proxyPort", "proxyUserName", "secureProxyPassword", "proxyPassword", "scheduleWeekly", "scheduleMonthly", "scheduleDaily", "scheduleManual", "scheduleAuto", "scheduleAction", "restoreDefaults", "forceRestart", "autoSuspendBitLocker", "defaultSourceLocation", "installationDeferral", "deferralInstallInterval", "deferralInstallCount", "systemRestartDeferral", "deferralRestartInterval", "deferralRestartCount", "updatesNotification", "maxretry")
        customnotification = @("heading", "body", "timestamp")
        driverInstall = @("silent", "outputLog", "driverLibraryLocation", "reboot")
        generateEncryptedPassword = @("encryptionKey", "password", "outputPath", "secureEncryptionKey", "securePassword")
        help = @()
        version = @()
    }
    $FLAG_OPTIONS = @{
        scan = @("silent")
        applyUpdates = @("silent", "reboot", "autoSuspendBitLocker", "forceupdate")
        configure = @("silent", "allowXML", "lockSettings", "advancedDriverRestore", "userConsent", "customProxy", "proxyAuthentication", "proxyFallbackToDirectConnection", "scheduleAuto", "scheduleManual", "restoreDefaults", "forceRestart", "autoSuspendBitLocker", "defaultSourceLocation", "installationDeferral", "systemRestartDeferral", "updatesNotification")
        customnotification = @()
        driverInstall = @("silent", "reboot")
        generateEncryptedPassword = @()
        help = @()
        version = @()
    }
    $GLOBAL_OPTIONS = @("throttleLimit")

    $configView = $contentControl.Content
    if (-not $configView) { Write-Host "[Config] No config view loaded."; return }
    $mainCommandCombo = $configView.FindName('MainCommandComboBox')
    $optionContent = $configView.FindName('ConfigOptionsContent')
    if (-not $mainCommandCombo -or -not $optionContent) { Write-Host "[Config] MainCommandComboBox or ConfigOptionsContent not found."; return }
    if (-not $selectedKey) {
        Write-Host "[Config] No key for selected command (argument missing)." -ForegroundColor Red
        return
    }
    $childView = $optionContent.Content
    if (-not $childView) { Write-Host "[Config] No child view loaded."; return }

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
    # Write to config.txt
    # Global options (e.g., throttleLimit) - preserve any existing global options at the end
    $configPath = Join-Path $PSScriptRoot 'config.txt'
    if (Test-Path $configPath) {
        $globalLines = Get-Content $configPath | Where-Object { $_ -match '^[a-zA-Z]+\s*=\s*\d+$' -and ($_ -notmatch '^(scan|applyupdates|configure|customnotification|driverinstall|generateencryptedpassword|help|version)\s*=') }
        foreach ($g in $globalLines) { $lines += $g }
    }
    Set-Content -Path $configPath -Value $lines
    Write-Host "[Config] Saved config to $configPath"
    # --- Ensure config.txt is reloaded if needed elsewhere ---
}

# Window and Resources 
$window = Import-Xaml "Views\MainWindow.xaml"
$wsidFilePath = Join-Path $PSScriptRoot "res\WSID.txt"

# Merge all resource dictionaries from the Styles folder
$stylesPath = Join-Path $PSScriptRoot 'Styles'
Get-ChildItem -Path $stylesPath -Filter '*.xaml' | ForEach-Object {
    $styleStream = [System.IO.File]::OpenRead($_.FullName)
    try {
        $styleDict = [Windows.Markup.XamlReader]::Load($styleStream)
        $window.Resources.MergedDictionaries.Add($styleDict)
    }
    finally {
        $styleStream.Close()
    }
}

# Set logo image
$logoImage = $window.FindName('Logo')
$logoPath = Join-Path $PSScriptRoot 'Images\logo yellow arrow.png'
$logoImage.Source = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]$logoPath)

# Window Controls and Events 
Add-Type -AssemblyName System.Windows.Forms

# Maximize/Restore/Minimize/Close buttons
$panelControlBar = $window.FindName('panelControlBar')
$panelControlBar.Add_MouseLeftButtonDown({
        if ($_.ClickCount -eq 2) {
            # Double-click: toggle maximize/restore
            if ($window.WindowState -eq 'Maximized') {
                $window.WindowState = 'Normal'
            }
            else {
                $window.WindowState = 'Maximized'
            }
            return
        }
        $window.DragMove()
    })

$exitButton = $window.FindName('btnClose')
$exitButton.Add_Click({
        $window.Close()
    })

$lastWindowState = 'Normal'
$maximizeButton = $window.FindName('btnMaximize')
$maximizeButton.Add_Click({
        if ($window.WindowState -ne 'Maximized') {
            $lastWindowState = $window.WindowState
            $window.WindowState = 'Maximized'
        }
        else {
            $window.WindowState = $lastWindowState
        }
    })

$minimizeButton = $window.FindName('btnMinimize')
$minimizeButton.Add_Click({
        $window.WindowState = 'Minimized'
    })

# Header panels for dynamic icon/text
$headerHome = $window.FindName('headerHome')
$headerConfig = $window.FindName('headerConfig')
$headerLogs = $window.FindName('headerLogs')

Function Show-HeaderPanel {
    param($homeVisibility, $configVisibility, $logsVisibility)
    if ($headerHome) { $headerHome.Visibility = $homeVisibility }
    if ($headerConfig) { $headerConfig.Visibility = $configVisibility }
    if ($headerLogs) { $headerLogs.Visibility = $logsVisibility }
}

# Main Content Control and Navigation 
$contentControl = $window.FindName('contentMain')
$btnHome = $window.FindName('btnHome')
$btnConfig = $window.FindName('btnConfig')
$btnLogs = $window.FindName('btnLogs')

# --- Persistent View Instances ---
$script:HomeViewInstance = $null
$script:ConfigViewInstance = $null
$script:LogsViewInstance = $null

# --- Update-HomeView: restore dynamic content (tabs, search bar, etc.) ---
Function Update-HomeView {
    if (-not $script:HomeViewInstance) { return }
    $tabs = $script:HomeViewInstance.FindName('TerminalTabs')
    if ($tabs -and $script:TabsCollection) {
        $tabs.Items.Clear()
        foreach ($tab in $script:TabsCollection) {
            $tabs.Items.Add($tab)
        }
        Write-Host "[Update-HomeView] Restored $($script:TabsCollection.Count) tabs to TerminalTabs." -ForegroundColor Cyan
    }
    $searchBar = $script:HomeViewInstance.FindName('txtHomeMessage')
    if ($searchBar) {
        Initialize-SearchBar $searchBar
        Set-PlaceholderLogic $searchBar "WSID..."
        Write-Host "[Update-HomeView] Search bar refreshed with: '$($searchBar.Text)'" -ForegroundColor Cyan
    }
}

# Set HomeView as default view and header
if ($contentControl) {
    if (-not $script:HomeViewInstance) {
        Initialize-HomeView $contentControl
        $script:HomeViewInstance = $script:HomeView
    }
    $contentControl.Content = $script:HomeViewInstance
    Update-HomeView
    Show-HeaderPanel "Visible" "Collapsed" "Collapsed"
}

if ($btnHome) {
    $btnHome.Add_Checked({
            if (-not $script:HomeViewInstance) {
                Initialize-HomeView $contentControl
                $script:HomeViewInstance = $script:HomeView
            }
            $contentControl.Content = $script:HomeViewInstance
            Update-HomeView
            Show-HeaderPanel "Visible" "Collapsed" "Collapsed"
        })
}
if ($btnConfig) {
    $btnConfig.Add_Checked({
        $configView = Import-XamlView "Views\\ConfigView.xaml"
        $contentControl.Content = $configView
        Show-HeaderPanel "Collapsed" "Visible" "Collapsed"

        $mainCommandCombo = $configView.FindName('MainCommandComboBox')
        $optionContent = $configView.FindName('ConfigOptionsContent')
        Write-Host "[DEBUG] optionContent: $optionContent, type: $($optionContent.GetType().FullName)" -ForegroundColor Cyan

        if ($mainCommandCombo -and $optionContent) {
            # Inline script block for testing
            $SetConfigOptionView = {
                param($optionContent, $selected)
                if (-not $optionContent) {
                    Write-Host "optionContent is null." -ForegroundColor Red
                    return
                }
                if (-not $selected -or [string]::IsNullOrWhiteSpace($selected)) {
                    $optionContent.Content = $null
                    return
                }
                $viewMap = @{
                    "Scan"           = "Scan.xaml"
                    "Apply Updates"  = "ApplyUpdates.xaml"
                    "Configure"      = "Configure.xaml"
                    "Driver Install" = "DriverInstall.xaml"
                    "Version"        = "Version.xaml"
                    "Help"           = "Help.xaml"
                    "Generate Encrypted Password" = "GenerateEncryptedPassword.xaml"
                    "Custom Notification" = "CustomNotification.xaml"
                }
                $file = $viewMap[$selected]
                if ($file) {
                    $childView = Import-XamlView "Views\\Config Options\\$file"
                    if ($childView) {
                        $optionContent.Content = $childView
                        Write-Host "Loaded child view: $file" -ForegroundColor Green
                    } else {
                        $optionContent.Content = $null
                        Write-Host "Failed to load child view: $file" -ForegroundColor Red
                    }
                }
                else {
                    $optionContent.Content = $null
                }
            }
            & $SetConfigOptionView $optionContent 'Scan'
            $mainCommandCombo.Add_SelectionChanged(({
                $selEventArgs = $args[1]
                if ($selEventArgs.AddedItems.Count -gt 0) {
                    $selItem = $selEventArgs.AddedItems[0]
                    if ($selItem -is [System.Windows.Controls.ComboBoxItem]) {
                        $sel = $selItem.Content
                    } else {
                        $sel = $selItem.ToString()
                    }
                } else {
                    $sel = $mainCommandCombo.Text
                }
                Write-Host "$sel selected from MainCommandComboBox." -ForegroundColor Cyan
                $currentOptionContent = $configView.FindName('ConfigOptionsContent')
                if ($currentOptionContent) {
                    & $SetConfigOptionView $currentOptionContent $sel
                } else {
                    Write-Host "optionContent is null." -ForegroundColor Red
                }
            }).GetNewClosure())
        } else {
            Write-Host "[ERROR] mainCommandCombo or optionContent not found or not valid." -ForegroundColor Red
        }

        # Wire up Save button in ConfigView
        $saveBtn = $configView.FindName('btnSaveConfig')
        if ($saveBtn) {
            $null = $saveBtn.Remove_Click
            $saveBtn.Add_Click({
                # Get selected command key robustly
                $mainCommandCombo = $configView.FindName('MainCommandComboBox')
                $viewMap = @{
                    "Scan"           = "scan"
                    "Apply Updates"  = "applyUpdates"
                    "Configure"      = "configure"
                    "Driver Install" = "driverInstall"
                    "Version"        = "version"
                    "Help"           = "help"
                    "Generate Encrypted Password" = "generateEncryptedPassword"
                    "Custom Notification" = "customnotification"
                }
                $selectedCmd = $mainCommandCombo.SelectedItem
                if ($selectedCmd -is [System.Windows.Controls.ComboBoxItem]) { $selectedCmd = $selectedCmd.Content }
                $selectedCmdNorm = $selectedCmd -replace '\s+', ' ' -replace '^\s+|\s+$',''
                $selectedKey = $null
                foreach ($k in $viewMap.Keys) {
                    if ($k.ToLower() -eq $selectedCmdNorm.ToLower()) { $selectedKey = $viewMap[$k]; break }
                }
                Save-ConfigFromUI -selectedKey $selectedKey
            })
        }
    })
}
if ($btnLogs) {
    $btnLogs.Add_Checked({
            if (-not $script:LogsViewInstance) {
                $script:LogsViewInstance = Import-XamlView "Views\LogsView.xaml"
            }
            $contentControl.Content = $script:LogsViewInstance
            Show-HeaderPanel "Collapsed" "Collapsed" "Visible"
        })
}

# Show Window 
$null = $window.ShowDialog()