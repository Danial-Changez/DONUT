Add-Type -AssemblyName PresentationFramework

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "ConfigView.psm1")
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "Helpers.psm1")
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "ImportXaml.psm1")
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "LogsView.psm1")
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "WindowEvents.psm1")


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
    $remoteDCUPathAbs = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'remoteDCU.ps1'))
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
                $queue.Enqueue($cleanLine) | Out-Null
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
    $configPath = Join-Path $PSScriptRoot '..\config.txt'
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

    # Prepare queue of computers to process, and only append new computers, do not reset existing tabs/queues
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
    $script:Notified = $false
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

        # Show Popup when all runspaces and queue are empty
        if ($script:ActiveRunspaces.Count -eq 0 -and $script:PendingQueue.Count -eq 0 -and -not $script:Notified) {
            if (-not $script:PopupOpen) {
                $popup = Import-XamlView "..\Views\PopUp.xaml"
                if ($popup) {
                    $popupWin = $popup
                    # Merge all style dictionaries from Styles folder
                    $stylesPath = Join-Path $PSScriptRoot '..\Styles'
                    Get-ChildItem -Path $stylesPath -Filter '*.xaml' | ForEach-Object {
                        $styleStream = [System.IO.File]::OpenRead($_.FullName)
                        try {
                            $styleDict = [Windows.Markup.XamlReader]::Load($styleStream)
                            try {
                                $popupWin.Resources.MergedDictionaries.Add($styleDict)
                            } catch {
                                Write-Host "[WARN] Failed to add style dictionary: $($_.FullName) - $_" -ForegroundColor Yellow
                            }
                        } catch {
                            Write-Host "[WARN] Failed to load style dictionary: $($_.FullName) - $_" -ForegroundColor Yellow
                        } finally {
                            $styleStream.Close()
                        }
                    }
                    $closeBtn = $popupWin.FindName('btnClose')
                    $okBtn = $popupWin.FindName('btnOk')
                    $panelBar = $popupWin.FindName('panelControlBar')
                    $minBtn = $popupWin.FindName('btnMinimize')
                    if ($closeBtn) {
                        $closeBtn.Add_Click({
                            if ($null -ne $popupWin) {
                                try { $popupWin.Close() } catch {}
                            }
                            $script:PopupOpen = $false
                        })
                    }
                    if ($okBtn) {
                        $okBtn.Add_Click({
                            if ($null -ne $popupWin) {
                                try { $popupWin.Close() } catch {}
                            }
                            $script:PopupOpen = $false
                        })
                    }
                    if ($minBtn) {
                        $minBtn.Add_Click({
                            if ($null -ne $popupWin) {
                                try { $popupWin.WindowState = 'Minimized' } catch {}
                            }
                        })
                    }
                    if ($panelBar) {
                        $panelBar.Add_MouseLeftButtonDown({
                            if ($null -ne $popupWin) {
                                try { $popupWin.DragMove() } catch {}
                            }
                        })
                    }
                    # Pause the main DispatcherTimer while popup is open
                    if ($script:Timer) { $script:Timer.Stop() }
                    $script:PopupOpen = $true
                    # Auto-close after 10 seconds (in popup scope)
                    $timer = New-Object System.Windows.Threading.DispatcherTimer
                    $timer.Interval = [TimeSpan]::FromSeconds(10)
                    $timer.Add_Tick({
                        if ($null -ne $popupWin) {
                            try { $popupWin.Close() } catch {}
                        }
                        $script:PopupOpen = $false
                        $timer.Stop()
                    })
                    $timer.Start()
                    $null = $popupWin.ShowDialog()
                    # Resume the main DispatcherTimer after popup closes
                    if ($script:Timer) { $script:Timer.Start() }
                }
                $script:Notified = $true
            }
        }
        if ($script:ActiveRunspaces.Count -gt 0 -or $script:PendingQueue.Count -gt 0) {
            $script:Notified = $false
            $script:PopupOpen = $false
        }
    })
    $script:Timer.Start()

    if ($tabs.Items.Count -gt 0) {
        $tabs.SelectedIndex = 0
    }
}

Function Initialize-HomeView {
    # Only do one-time setup: event wiring, variable assignment
    $script:HomeView = Import-XamlView "..\Views\HomeView.xaml"
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
}

# --- Update-HomeView: restore dynamic content (tabs, search bar, etc.) ---
Function Update-HomeView {
    if (-not $script:HomeView) { return }
    $tabs = $script:HomeView.FindName('TerminalTabs')
    if ($tabs -and $script:TabsCollection) {
        $tabs.Items.Clear()
        foreach ($tab in $script:TabsCollection) {
            $tabs.Items.Add($tab)
        }
        Write-Host "[Update-HomeView] Restored $($script:TabsCollection.Count) tabs to TerminalTabs." -ForegroundColor Cyan
    }
    $searchBar = $script:HomeView.FindName('txtHomeMessage')
    if ($searchBar) {
        Initialize-SearchBar $searchBar
        Set-PlaceholderLogic $searchBar "WSID..."
        Write-Host "[Update-HomeView] Search bar refreshed with: '$($searchBar.Text)'" -ForegroundColor Cyan
    }
}

# Window and Resources 
$window = Import-Xaml "..\Views\MainWindow.xaml"
$script:wsidFilePath = Join-Path $PSScriptRoot "..\res\WSID.txt"

# Merge all resource dictionaries from the Styles folder
$stylesPath = Join-Path $PSScriptRoot '..\Styles'
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
$logoPath = Join-Path $PSScriptRoot '..\Images\logo yellow arrow.png'
$logoImage.Source = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]$logoPath)

# Window Controls and Events 
Add-Type -AssemblyName System.Windows.Forms

# Maximize/Restore/Minimize/Close buttons
$script:LastWindowBounds = $null
$script:IsCustomMaximized = $false

$panelControlBar = $window.FindName('panelControlBar')
function Switch-CustomMaximize {
    Add-Type -AssemblyName System.Windows.Forms
    # Get the screen the window is currently on
    $rect = New-Object System.Drawing.Rectangle([int]$window.Left, [int]$window.Top, [int]$window.Width, [int]$window.Height)
    $screen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.IntersectsWith($rect) } | Select-Object -First 1
    if (-not $screen) { $screen = [System.Windows.Forms.Screen]::PrimaryScreen }
    $workArea = $screen.WorkingArea

    $isNativeMaximized = ($window.WindowState -eq 'Maximized')
    $isCustomMaximized = (
        [math]::Abs($window.Left - $workArea.Left) -le 2 -and
        [math]::Abs($window.Top - $workArea.Top) -le 2 -and
        [math]::Abs($window.Width - $workArea.Width) -le 2 -and
        [math]::Abs($window.Height - $workArea.Height) -le 2
    )

    if ($isNativeMaximized -or $isCustomMaximized -or $script:IsCustomMaximized) {
        # Restore previous bounds
        $window.WindowState = 'Normal'
        if ($script:LastWindowBounds) {
            $window.Left = $script:LastWindowBounds.Left
            $window.Top = $script:LastWindowBounds.Top
            $window.Width = $script:LastWindowBounds.Width
            $window.Height = $script:LastWindowBounds.Height
        }
        $script:IsCustomMaximized = $false
    } else {
        # Save current bounds
        $script:LastWindowBounds = [PSCustomObject]@{
            Left   = $window.Left
            Top    = $window.Top
            Width  = $window.Width
            Height = $window.Height
        }
        # Maximize to working area (excluding taskbar)
        $window.WindowState = 'Normal'
        $window.Left = $workArea.Left
        $window.Top = $workArea.Top
        $window.Width = $workArea.Width
        $window.Height = $workArea.Height
        $script:IsCustomMaximized = $true
    }
}

if ($null -ne $panelControlBar) {
    $panelControlBar.Add_MouseLeftButtonDown({
        if ($_.ClickCount -eq 2) {
            Switch-CustomMaximize
            return
        }
        $window.DragMove()
        [System.Windows.Input.Mouse]::Capture($null) # Release mouse capture to prevent stuck drag/resize
    })
}

$exitButton = $window.FindName('btnClose')
if ($null -ne $exitButton) {
    $exitButton.Add_Click({
        $window.Close()
    })
}

$maximizeButton = $window.FindName('btnMaximize')
if ($null -ne $maximizeButton) {
    $maximizeButton.Add_Click({
        Switch-CustomMaximize
    })
}

$minimizeButton = $window.FindName('btnMinimize')
if ($null -ne $minimizeButton) {
    $minimizeButton.Add_Click({
        $window.WindowState = 'Minimized'
    })
}

# Resize Border and MouseMove/LeftButtonDown events
$WindowResizeBorder = $window.FindName('WindowResizeBorder')
if ($WindowResizeBorder) {
    $window.Add_MouseMove({
        $pos = [System.Windows.Input.Mouse]::GetPosition($window)
        $margin = 6
        $resizeDir = $null
        if ($pos.X -le $margin -and $pos.Y -le $margin) { $resizeDir = 'TopLeft' }
        elseif ($pos.X -ge ($window.Width - $margin) -and $pos.Y -le $margin) { $resizeDir = 'TopRight' }
        elseif ($pos.X -le $margin -and $pos.Y -ge ($window.Height - $margin)) { $resizeDir = 'BottomLeft' }
        elseif ($pos.X -ge ($window.Width - $margin) -and $pos.Y -ge ($window.Height - $margin)) { $resizeDir = 'BottomRight' }
        elseif ($pos.X -le $margin) { $resizeDir = 'Left' }
        elseif ($pos.X -ge ($window.Width - $margin)) { $resizeDir = 'Right' }
        elseif ($pos.Y -le $margin) { $resizeDir = 'Top' }
        elseif ($pos.Y -ge ($window.Height - $margin)) { $resizeDir = 'Bottom' }
        else { $resizeDir = $null }
        if ($resizeDir) {
            $WindowResizeBorder.IsHitTestVisible = $true
            switch ($resizeDir) {
                'Left' { $window.Cursor = [System.Windows.Input.Cursors]::SizeWE }
                'Right' { $window.Cursor = [System.Windows.Input.Cursors]::SizeWE }
                'Top' { $window.Cursor = [System.Windows.Input.Cursors]::SizeNS }
                'Bottom' { $window.Cursor = [System.Windows.Input.Cursors]::SizeNS }
                'TopLeft' { $window.Cursor = [System.Windows.Input.Cursors]::SizeNWSE }
                'BottomRight' { $window.Cursor = [System.Windows.Input.Cursors]::SizeNWSE }
                'TopRight' { $window.Cursor = [System.Windows.Input.Cursors]::SizeNESW }
                'BottomLeft' { $window.Cursor = [System.Windows.Input.Cursors]::SizeNESW }
            }
        } else {
            $WindowResizeBorder.IsHitTestVisible = $false
            $window.Cursor = [System.Windows.Input.Cursors]::Arrow
        }
    })
    $WindowResizeBorder.Add_MouseLeftButtonDown({
        $pos = [System.Windows.Input.Mouse]::GetPosition($window)
        $margin = 6
        $resizeDir = $null
        if ($pos.X -le $margin -and $pos.Y -le $margin) { $resizeDir = 'TopLeft' }
        elseif ($pos.X -ge ($window.Width - $margin) -and $pos.Y -le $margin) { $resizeDir = 'TopRight' }
        elseif ($pos.X -le $margin -and $pos.Y -ge ($window.Height - $margin)) { $resizeDir = 'BottomLeft' }
        elseif ($pos.X -ge ($window.Width - $margin) -and $pos.Y -ge ($window.Height - $margin)) { $resizeDir = 'BottomRight' }
        elseif ($pos.X -le $margin) { $resizeDir = 'Left' }
        elseif ($pos.X -ge ($window.Width - $margin)) { $resizeDir = 'Right' }
        elseif ($pos.Y -le $margin) { $resizeDir = 'Top' }
        elseif ($pos.Y -ge ($window.Height - $margin)) { $resizeDir = 'Bottom' }
        else { $resizeDir = $null }
        if ($resizeDir) {
            $sig = '[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);'
            $type = Add-Type -MemberDefinition $sig -Name 'Win32SendMessage' -Namespace Win32 -PassThru
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
            $msg = 0x112 # WM_SYSCOMMAND
            $sc = switch ($resizeDir) {
                'Left' { 0xF001 }
                'Right' { 0xF002 }
                'Top' { 0xF003 }
                'Bottom' { 0xF006 }
                'TopLeft' { 0xF004 }
                'TopRight' { 0xF005 }
                'BottomLeft' { 0xF007 }
                'BottomRight' { 0xF008 }
            }
            $type::SendMessage($hwnd, $msg, $sc, 0) | Out-Null
        }
    })
}

# Header panels for dynamic icon/text
$headerHome = $window.FindName('headerHome')
$headerConfig = $window.FindName('headerConfig')
$headerLogs = $window.FindName('headerLogs')

# Main Content Control and Navigation 
$contentControl = $window.FindName('contentMain')
$btnHome = $window.FindName('btnHome')
$btnConfig = $window.FindName('btnConfig')
$btnLogs = $window.FindName('btnLogs')

# --- Persistent View Instances ---
$script:HomeView = $null
$script:ConfigViewInstance = $null
$script:LogsViewInstance = $null

# Set HomeView as default view and header
if ($contentControl) {
    if (-not $script:HomeView) {
        Initialize-HomeView
    }
    $contentControl.Content = $script:HomeView
    Update-HomeView
    Show-HeaderPanel "Visible" "Collapsed" "Collapsed" $headerHome $headerConfig $headerLogs
}

if ($btnHome) {
    $btnHome.Add_Checked({
        if (-not $script:HomeView) {
            Initialize-HomeView
        }
        $contentControl.Content = $script:HomeView
        Update-HomeView
        Show-HeaderPanel "Visible" "Collapsed" "Collapsed" $headerHome $headerConfig $headerLogs
    })
}
if ($btnConfig) {
    $btnConfig.Add_Checked({
        # Use a local variable for the config view instance
        $configViewInstance = $script:ConfigViewInstance
        $firstLoad = $false
        if (-not $configViewInstance) {
            Write-Host "[DEBUG] ConfigViewInstance is null, loading ConfigView.xaml"
            $configViewInstance = Import-XamlView "..\Views\ConfigView.xaml"
            $script:ConfigViewInstance = $configViewInstance
            $firstLoad = $true
        }

        $contentControl.Content = $configViewInstance
        Show-HeaderPanel "Collapsed" "Visible" "Collapsed" $headerHome $headerConfig $headerLogs

        $mainCommandCombo = $configViewInstance.FindName('MainCommandComboBox')
        $optionContent = $configViewInstance.FindName('ConfigOptionsContent')
        Write-Host "[DEBUG] optionContent: $optionContent, type: $($optionContent.GetType().FullName)" -ForegroundColor Cyan

        if ($mainCommandCombo -and $optionContent) {
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
                    "Scan"                        = "Scan.xaml"
                    "Apply Updates"               = "ApplyUpdates.xaml"
                    "Configure"                   = "Configure.xaml"
                    "Driver Install"              = "DriverInstall.xaml"
                    "Version"                     = "Version.xaml"
                    "Help"                        = "Help.xaml"
                    "Generate Encrypted Password" = "GenerateEncryptedPassword.xaml"
                    "Custom Notification"         = "CustomNotification.xaml"
                }
                $file = $viewMap[$selected]
                if ($file) {
                    $childView = Import-XamlView "..\Views\Config Options\$file"
                    if ($childView) {
                        $optionContent.Content = $childView
                        Write-Host "Loaded child view: $file" -ForegroundColor Green
                    }
                    else {
                        $optionContent.Content = $null
                        Write-Host "Failed to load child view: $file" -ForegroundColor Red
                    }
                }
                else {
                    $optionContent.Content = $null
                }
            }
            if ($firstLoad) {
                # Remove any previous SelectionChanged handlers before adding a new one
                $null = $mainCommandCombo.Remove_SelectionChanged
                $mainCommandCombo.Add_SelectionChanged(({
                    $selEventArgs = $args[1]
                    if ($selEventArgs.AddedItems.Count -gt 0) {
                        $selItem = $selEventArgs.AddedItems[0]
                        if ($selItem -is [System.Windows.Controls.ComboBoxItem]) {
                            $sel = $selItem.Content
                        }
                        else {
                            $sel = $selItem.ToString()
                        }
                    }
                    else {
                        $sel = $mainCommandCombo.Text
                    }
                    Write-Host "$sel selected from MainCommandComboBox." -ForegroundColor Cyan
                    $currentOptionContent = $configViewInstance.FindName('ConfigOptionsContent')
                    if ($currentOptionContent) {
                        & $SetConfigOptionView $currentOptionContent $sel
                    }
                    else {
                        Write-Host "optionContent is null." -ForegroundColor Red
                    }
                }).GetNewClosure())
                # On first load, set ComboBox to index 0 so event fires and UI syncs
                if ($mainCommandCombo.Items.Count -gt 0) {
                    $mainCommandCombo.SelectedIndex = 0
                }
            } else {
                # On subsequent loads, just load the current selection or default to Scan
                $selected = $mainCommandCombo.Text
                if (-not $selected -or [string]::IsNullOrWhiteSpace($selected)) { $selected = 'Scan' }
                & $SetConfigOptionView $optionContent $selected
            }
        }
        else {
            Write-Host "[ERROR] mainCommandCombo or optionContent not found or not valid." -ForegroundColor Red
        }

        # Wire up Save button in ConfigView
        $saveBtn = $configViewInstance.FindName('btnSaveConfig')
        if ($saveBtn) {
            $null = $saveBtn.Remove_Click
            $saveBtn.Add_Click({
                $mainCommandCombo = $configViewInstance.FindName('MainCommandComboBox')
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
                $selectedCmd = $mainCommandCombo.SelectedItem
                Write-Host "[DEBUG] Selected command: $selectedCmd" -ForegroundColor Cyan
                if ($selectedCmd -is [System.Windows.Controls.ComboBoxItem]) { 
                    $selectedCmd = $selectedCmd.Content 
                    Write-Host "[DEBUG] Selected command content: $selectedCmd" -ForegroundColor Cyan
                }
                $selectedKey = $null
                foreach ($k in $viewMap.Keys) {
                    if ($k -eq $selectedCmd) { $selectedKey = $viewMap[$k]; break }
                }
                $optionContent = $configViewInstance.FindName('ConfigOptionsContent')
                $childView = $null
                if ($optionContent) { $childView = $optionContent.Content }
                Save-ConfigFromUI -selectedKey $selectedKey -ContentControl $contentControl -childView $childView
            })
        }
    })
}
if ($btnLogs) {
    $btnLogs.Add_Checked({
            Show-HeaderPanel "Collapsed" "Collapsed" "Visible" $headerHome $headerConfig $headerLogs
            $script:LogsViewInstance = Show-LogsView -contentControl $contentControl
        })
}

# Show Window 
$null = $window.ShowDialog()