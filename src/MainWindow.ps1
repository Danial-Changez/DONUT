Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "Read-Config.psm1")
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "ConfigView.psm1")
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "Helpers.psm1")
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "ImportXaml.psm1")
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "LogsView.psm1")

# Define config path at script level for consistency
$script:configPath = Join-Path $PSScriptRoot '..\config.txt'

# Initialize global state hashtable for config view persistence
if (-not $Global:ConfigViewStates) { $Global:ConfigViewStates = @{} }

# Track the last selected config option for state management
$script:LastSelectedConfigOption = $null
$script:LastSelectedComboBoxOption = $null
$script:ConfigPageFirstLoad = $true

if (-not $script:ManualRebootQueue) { $script:ManualRebootQueue = [hashtable]::Synchronized(@{}) }
if (-not $script:ActiveRunspaces) { $script:ActiveRunspaces = [System.Collections.Generic.List[object]]::new() }
if (-not $script:RunspaceJobs) { $script:RunspaceJobs = @{} }
if (-not $script:QueuedOrRunning) { $script:QueuedOrRunning = @{} }
if (-not $script:PendingQueue) { $script:PendingQueue = [System.Collections.Queue]::new() }
if (-not $script:TabsMap) { $script:TabsMap = @{} }
if (-not $script:SyncUI) { $script:SyncUI = [hashtable]::Synchronized(@{}) }
if (-not $script:RebootDetection) { $script:RebootDetection = @{} }

# Script block to start a new PowerShell runspace for remote execution.
# - Dequeues the next computer from the pending queue.
# - Validates required UI and queue objects.
# - Launches remoteDCU.ps1 on the target computer in a background process.
# - Captures and enqueues output and error lines for UI display.
# - Updates runspace tracking structures for job management.
$script:StartNextRunspace = {
    if ($script:PendingQueue.Count -eq 0) { return }
    $computer = $script:PendingQueue.Dequeue()
    if (-not $script:TabsMap.ContainsKey($computer)) {
        return
    }
    $queue = $script:SyncUI[$computer]
    $tb = $script:TabsMap[$computer]

    # Used AbsPath as at the time with IO.Path lib, as it was the only parameter being accepted as full path for $ps.AddScript 
    $remoteDCUPathAbs = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'remoteDCU.ps1'))
    
    # Create Runspace
    $ps = [PowerShell]::Create()
    $ps.AddScript({
            param($hostName, $scriptPath, $queue, $tb)
            if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
                $queue.Enqueue("ERROR: remoteDCU.ps1 path is invalid or missing.") | Out-Null
                return
            }

            # Cmd to run remoteDCU.ps1 with the computer name
            $psi = New-Object System.Diagnostics.ProcessStartInfo(
                'pwsh', "-NoProfile -NoLogo -File `"$scriptPath`" -ComputerName $hostName"
            )
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            # Start the process
            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start() | Out-Null

            $stdout = $proc.StandardOutput
            $stderr = $proc.StandardError
            $lastErrorLine = $null

            # Read output and error streams
            while (-not $stdout.EndOfStream) {
                $line = $stdout.ReadLine()
                $cleanLine = ($line -replace "`e\[[\d;]*[A-Za-z]", "").Trim()
                if ($cleanLine -match "pwsh exited on .+ with error code (\d+).") {
                    $lastErrorLine = $matches[0]
                }
                else {
                    $queue.Enqueue($cleanLine) | Out-Null
                }
            }
            while (-not $stderr.EndOfStream) {
                $line = $stderr.ReadLine()
                $cleanLine = ($line -replace "`e\[[\d;]*[A-Za-z]", "").Trim()
                # Exclude unwanted lines
                if ($cleanLine -notmatch 'Connecting to|Starting PSEXESVC|Copying authentication key|Connecting with PsExec service|Starting pwsh on' -and $cleanLine -match '\S') {
                    $queue.Enqueue($cleanLine) | Out-Null
                }
            }
            # Wait for process to exit
            $proc.WaitForExit()
            if ($lastErrorLine) {
                $queue.Enqueue("Final status: $lastErrorLine") | Out-Null
            }
        }).AddArgument($computer).AddArgument($remoteDCUPathAbs).AddArgument($queue).AddArgument($tb)

    # Start the PowerShell runspace asynchronously
    $async = $ps.BeginInvoke()

    $script:ActiveRunspaces.Add($ps)
    $script:RunspaceJobs[$ps] = @{
        Computer    = $computer
        PowerShell  = $ps
        AsyncResult = $async
    }
}

# Updates the WSID.txt file with entries from the search bar.
# - Validates and parses the search bar content.
# - Updates the file and prepares the computer queue.
# - Handles config flags and applyUpdates confirmation popup.
Function Update-WSIDFile {
param(
    [System.Windows.Controls.TextBox]$textBox,
    [string]$wsidFilePath,
    [string]$configPath
)
    # Ensure the TextBox reference is valid
    if ($null -eq $textBox) {
        Write-Host "TextBox reference is null. Ensure 'GoogleSearchBar' exists in the XAML."
        return
    }

    # Ensure the TextBox has valid content before updating the file
    if ([string]::IsNullOrWhiteSpace($textBox.Text)) {
        return
    }
    
    # Reset ApplyUpdatesConfirmed flag for this run
    $script:ApplyUpdatesConfirmed = $false
        
    # Split on newlines and commas, trim, remove empty, and take unique entries
    $valid = ($textBox.Text -split "[\r\n,]+") |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
    Set-Content -Path $wsidFilePath -Value $valid

    $config = $null
    try {
        if (Test-Path $script:configPath) {
            $config = Read-Config -configPath $script:configPath
        } else {
            Write-Warning "Config file not found"
        }
    } catch {
        Write-Warning "Error reading config file: $_"
    }

    # Set throttleLimit from config
    $script:throttleLimit = if ($config -and $config.throttleLimit) { $config.throttleLimit } else { 5 }
    $tabs = $script:HomeView.FindName('TerminalTabs')

    # Prepare queue of computers to process, and only append new computers, do not reset existing tabs/queues
    $needsManualReboot = $false
    $flagPresent = $false
    $applyUpdatesEnabled = $false
    if ($config) {
        if ($config.Args -and ($config.Args.reboot -or $config.Args.forceRestart)) { $flagPresent = $true }
        if ($config.Args -and (($config.Args.reboot -eq $false) -or ($config.Args.forceRestart -eq $false))) { $needsManualReboot = $true }
        if ($config.EnabledCmdOption -eq 'applyUpdates') { $applyUpdatesEnabled = $true }
    }

    # If applyUpdates is enabled and there's more than 1 computer, show a single confirmation popup
    if ($applyUpdatesEnabled -and $valid.Count -gt 1) {
        $popup = Import-XamlView "..\Views\Confirmation.xaml"
        $script:ApplyUpdatesConfirmed = $false
        if ($popup) {
            $popupWin = $popup
            
            # Merge all style dictionaries from Styles folder
            Add-ResourceDictionaries -window $popupWin
            
            $computerListBox = $popupWin.FindName('popupComputerList')
            if ($computerListBox) {
                $computerListBox.Items.Clear()
                foreach ($name in $valid) { $null = $computerListBox.Items.Add($name) }
            }
            $okBtn = $popupWin.FindName('btnContinue')
            $cancelBtn = $popupWin.FindName('btnAbort')
            if ($okBtn) {
                $okBtn.Add_Click({
                        $script:ApplyUpdatesConfirmed = $true
                        try { $popupWin.Close() } catch {}
                    })
            }
            if ($cancelBtn) {
                $cancelBtn.Add_Click({
                        $script:ApplyUpdatesConfirmed = $false
                        try { $popupWin.Close() } catch {}
                    })
            }

            # Wire control bar drag, minimize, and close for popup
            $panelBar = $popupWin.FindName('panelControlBar')
            $minBtn = $popupWin.FindName('btnMinimize')
            $closeBtn = $popupWin.FindName('btnClose')
            if ($panelBar) {
                $panelBar.Add_MouseLeftButtonDown({
                        if ($null -ne $popupWin) {
                            try { $popupWin.DragMove() } catch {}
                        }
                    })
            }
            if ($minBtn) {
                $minBtn.Add_Click({
                        if ($null -ne $popupWin) {
                            try { $popupWin.WindowState = 'Minimized' } catch {}
                        }
                    })
            }
            if ($closeBtn) {
                $closeBtn.Add_Click({
                        if ($null -ne $popupWin) {
                            try { $popupWin.Close() } catch {}
                        }
                    })
            }

            # Show the Confirmation Popup Dialog
            $null = $popupWin.ShowDialog()
        }
        
        # Handle Apply Updates abort
        if (-not $script:ApplyUpdatesConfirmed) {
            # User cancelled, abort all computers
            foreach ($computer in $valid) {
                # Create tab if missing, show abort message
                if (-not $script:TabsMap.ContainsKey($computer)) {
                    $tab = [System.Windows.Controls.TabItem]::new()
                    $tb = [System.Windows.Controls.RichTextBox]::new()
                    $tab.Header = $computer
                    $tab.Content = $tb
                    $tabs.Items.Add($tab)
                    $script:TabsMap[$computer] = $tb
                    $script:SyncUI[$computer] = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
                }
                $tb = $script:TabsMap[$computer]
                $tb.AppendText("[ABORTED] User cancelled apply updates for $computer.`n")
                $tb.ScrollToEnd()
                $script:QueuedOrRunning[$computer] = $true
            }
            return
        }
    } else {
        # If applyUpdates is enabled but there's only 1 computer, or applyUpdates is not enabled, proceed without confirmation
        $script:ApplyUpdatesConfirmed = $true
    }

    # Populate ManualRebootQueue and PendingQueue
    foreach ($computer in $valid) {
        if ($flagPresent -and $needsManualReboot) {
            $script:ManualRebootQueue[$computer] = $true
        }
        else {
            if ($script:ManualRebootQueue.ContainsKey($computer)) { $script:ManualRebootQueue.Remove($computer) }
        }
        if (-not $script:QueuedOrRunning.ContainsKey($computer)) {
            $script:PendingQueue.Enqueue($computer)
            $tab = [System.Windows.Controls.TabItem]::new() 
            $tb = [System.Windows.Controls.RichTextBox]::new()
            $tab.Header = $computer
            $tab.Content = $tb
            $tabs.Items.Add($tab)

            $script:TabsMap[$computer] = $tb
            $script:SyncUI[$computer] = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
            $script:QueuedOrRunning[$computer] = $true
        }
    }

    # Start up to $throttleLimit runspaces
    for ($i = 0; $i -lt $script:throttleLimit -and $script:PendingQueue.Count -gt 0; $i++) {
        & $script:StartNextRunspace
    }

    # Start the DispatcherTimer ONCE per search/click
    if ($script:Timer) {
        $script:Timer.Stop()
        $script:Timer = $null
    }
    # Clear output queue and textbox for new computers only
    foreach ($computer in $valid) {
        if ($script:TabsMap.ContainsKey($computer)) { continue }
        $queue = $script:SyncUI[$computer]
        while ($queue.Count -gt 0) { $null = $queue.TryDequeue([ref]([string]::Empty)) }
        $tb = $script:TabsMap[$computer]
        $tb.Clear()
    }
    # Main DispatcherTimer for UI and popups
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:Notified = $false
    
    # DispatcherTimer Tick Event Handler
    $script:Timer.Add_Tick({
            # Process output queue for each computer tab
            foreach ($comp in $script:TabsMap.Keys) {
                $tb = $script:TabsMap[$comp]
                $queue = $script:SyncUI[$comp]
                $line = $null
                while ($queue.Count -gt 0) {
                    $deq = $queue.TryDequeue([ref]$line)
                    if (-not $deq) { break }

                    # Show Update.xaml confirmation popup for applyUpdates
                    if ($line -is [hashtable] -and $line.Type -eq 'ShowApplyUpdatesPopup') {
                        $popup = Import-XamlView "..\Views\Update.xaml"
                        if ($popup) {
                            $popupWin = $popup
                            $popupHeader = $popupWin.FindName('popupHeader')
                            $popupText = $popupWin.FindName('popupText')
                            if ($popupHeader) { 
                                $popupHeader.Text = "Confirm Apply Updates" 
                            }
                            if ($popupText) { 
                                $popupText.Text = "Are you sure you want to apply updates to the target machine(s)?" 
                            }
                            $okBtn = $popupWin.FindName('btnOk')
                            $cancelBtn = $popupWin.FindName('btnLater')
                            $script:ApplyUpdatesConfirmed = $false
                            if ($okBtn) {
                                $okBtn.Add_Click({
                                        $script:ApplyUpdatesConfirmed = $true
                                        try { $popupWin.Close() } catch {}
                                    })
                            }
                            if ($cancelBtn) {
                                $cancelBtn.Add_Click({
                                        $script:ApplyUpdatesConfirmed = $false
                                        try { $popupWin.Close() } catch {}
                                    })
                            }
                            $null = $popupWin.ShowDialog()
                            
                            # Signal the runspace to continue
                            if ($line.SyncEvent) { $line.SyncEvent.Set() | Out-Null }
                        }
                    }
                    else {
                        # [BUG-FIX] Remove initial empty lines by clearing Document.Blocks if the first block is empty
                        if ($tb.Document.Blocks.Count -gt 0) {
                            $firstBlock = $tb.Document.Blocks.FirstBlock
                            $blockText = $null
                            if ($firstBlock -is [System.Windows.Documents.Paragraph]) {
                                $blockText = ($firstBlock.Inlines | ForEach-Object { $_.Text }) -join ''
                            } else {
                                $blockText = $firstBlock.ToString()
                            }
                            if ([string]::IsNullOrWhiteSpace($blockText) -and $tb.Document.Blocks.Count -le 2) {
                                $tb.Document.Blocks.Clear()
                            }
                        }

                        $para = New-Object System.Windows.Documents.Paragraph
                        $para.Margin = [System.Windows.Thickness]::new(0)

                        # Generalized command-to-color mapping (add more as needed)
                        $commandColorMap = @{
                            '/applyUpdates' = $window.FindResource('AccentCyan')
                            '/scan'         = $window.FindResource('AccentBlueLight')
                        }

                        $matched = $false
                        if ($line.StartsWith('Command: ')) {
                            $delimiterIdx = $line.IndexOf(":")
                            $before = $line.Substring(0, $delimiterIdx + 1)
                            $after = $line.Substring($delimiterIdx + 1)
                            
                            # Try to match a known command in the after part
                            foreach ($cmd in $commandColorMap.Keys) {
                                if ($after.TrimStart() -like "*$cmd*") {
                                    $matched = $true
                                    $color = $commandColorMap[$cmd]
                                    
                                    # Add the part before and including colon in default color
                                    $runBefore = New-Object System.Windows.Documents.Run($before)
                                    $para.Inlines.Add($runBefore)
                                    
                                    # Add the after part in color
                                    if ($after) {
                                        $runAfter = New-Object System.Windows.Documents.Run($after)
                                        $runAfter.Foreground = $color
                                        $para.Inlines.Add($runAfter)
                                    }
                                    break
                                }
                            }
                        }
                        if (-not $matched) {
                            $run = New-Object System.Windows.Documents.Run($line)
                            $para.Inlines.Add($run)
                        }

                        $tb.Document.Blocks.Add($para)
                        $tb.ScrollToEnd()

                        # Check for reboot detection lines
                        if (-not $script:RebootDetection.ContainsKey($comp)) {
                            $script:RebootDetection[$comp] = @{ 
                                SawRebootLine     = $false
                                SawAutoRebootLine = $false
                                NeedsManualReboot = $false
                            }
                        }
                        if ($line -like '*The system has been updated and requires a reboot to complete the process.*') {
                            $script:RebootDetection[$comp].SawRebootLine = $true
                        }
                        elseif ($line -like '*The system will automatically reboot to finish applying the updates.*') {
                            $script:RebootDetection[$comp].SawAutoRebootLine = $true
                        }

                        if ($script:RebootDetection[$comp].SawRebootLine -and -not $script:RebootDetection[$comp].SawAutoRebootLine) {
                            if (-not $script:ManualRebootQueue.ContainsKey($comp)) {
                                $script:ManualRebootQueue[$comp] = $true
                            }
                            $script:RebootDetection[$comp].NeedsManualReboot = $true
                        }
                        elseif ($script:RebootDetection[$comp].SawRebootLine -and $script:RebootDetection[$comp].SawAutoRebootLine) {
                            if ($script:ManualRebootQueue.ContainsKey($comp)) {
                                $script:ManualRebootQueue.Remove($comp)
                            }
                            $script:RebootDetection[$comp].NeedsManualReboot = $false
                        }
                        elseif (-not $script:RebootDetection[$comp].SawRebootLine -and -not $script:RebootDetection[$comp].SawAutoRebootLine) {
                            if ($script:ManualRebootQueue.ContainsKey($comp)) {
                                $script:ManualRebootQueue.Remove($comp)
                            }
                            $script:RebootDetection[$comp].NeedsManualReboot = $false
                        }
                    }
                }
            }

            # Cleanup finished runspaces
            $finished = [System.Collections.Generic.List[object]]::new()
            foreach ($ps in $script:ActiveRunspaces) {
                if ($ps -and $script:RunspaceJobs.ContainsKey($ps)) {
                    $job = $script:RunspaceJobs[$ps]
                    if ($ps.InvocationStateInfo.State -eq 'Completed' -or $ps.InvocationStateInfo.State -eq 'Failed' -or $ps.InvocationStateInfo.State -eq 'Stopped') {
                        try { $ps.EndInvoke($job.AsyncResult) } catch {}
                        $ps.Dispose()
                        $finished.Add($ps)
                    }
                }
            }

            # Remove finished runspaces from ActiveRunspaces and RunspaceJobs
            foreach ($ps in $finished) {
                if ($script:RunspaceJobs.ContainsKey($ps)) {
                    $comp = $script:RunspaceJobs[$ps].Computer
                    $script:RunspaceJobs.Remove($ps)
                }
                else {
                    Write-Warning "Attempted cleanup for runspace not in RunspaceJobs."
                }
                $script:ActiveRunspaces.Remove($ps) | Out-Null
            }

            # Start new runspaces if below throttle limit
            while ($script:ActiveRunspaces.Count -lt $script:throttleLimit -and $script:PendingQueue.Count -gt 0) {
                & $script:StartNextRunspace
            }

            # Show Popup when all runspaces and queue are empty
            if ($script:ActiveRunspaces.Count -eq 0 -and $script:PendingQueue.Count -eq 0 -and -not $script:Notified) {
                if (-not $script:PopupOpen) {
                    $popup = Import-XamlView "..\Views\PopUp.xaml"
                    if ($popup) {
                        $popupWin = $popup

                        # Merge all style dictionaries from Styles folder
                        Add-ResourceDictionaries -window $popupWin

                        # Find popup controls and computer list
                        $closeBtn = $popupWin.FindName('btnClose')
                        $okBtn = $popupWin.FindName('btnOk')
                        $panelBar = $popupWin.FindName('panelControlBar')
                        $minBtn = $popupWin.FindName('btnMinimize')
                        $popupSubHeader = $popupWin.FindName('popupSubHeader')
                        $popupComputerList = $popupWin.FindName('popupComputerList')
                        $names = $script:ManualRebootQueue.Keys
                        
                        # Show/hide computer list in popup
                        if ($names.Count -gt 0) {
                            if ($popupSubHeader) { $popupSubHeader.Visibility = 'Visible' }
                            if ($popupComputerList) {
                                $popupComputerList.Visibility = 'Visible'
                                $popupComputerList.Items.Clear()
                                foreach ($name in $names) { $null = $popupComputerList.Items.Add($name) }
                            }
                        }
                        else {
                            if ($popupSubHeader) { $popupSubHeader.Visibility = 'Collapsed' }
                            if ($popupComputerList) { $popupComputerList.Visibility = 'Collapsed' }
                        }
                        
                        # Wire up popup close button
                        if ($closeBtn) {
                            $closeBtn.Add_Click({
                                    if ($null -ne $popupWin) {
                                        try { $popupWin.Close() } catch {}
                                    }
                                    $script:PopupOpen = $false
                                    $script:ManualRebootQueue.Clear()
                                    $script:Notified = $false
                                    if ($script:Timer) { $script:Timer.Start() }
                                })
                        }

                        # Wire up popup ok button
                        if ($okBtn) {
                            $okBtn.Add_Click({
                                    if ($null -ne $popupWin) {
                                        try { $popupWin.Close() } catch {}
                                    }
                                    $script:PopupOpen = $false
                                    $script:ManualRebootQueue.Clear()
                                    $script:Notified = $false
                                    if ($script:Timer) { $script:Timer.Start() }
                                })
                        }

                        # Wire up popup minimize button
                        if ($minBtn) {
                            $minBtn.Add_Click({
                                    if ($null -ne $popupWin) {
                                        try { $popupWin.WindowState = 'Minimized' } catch {}
                                    }
                                })
                        }

                        # Wire up popup drag move
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
                        $null = $popupWin.ShowDialog()
                        
                        # After popup closes, allow future popups
                        $script:Notified = $true
                    }
                }
            }

            # Reset popup state if runspaces or queue are not empty
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

# Initializes the HomeView UI and wires up event handlers.
# - Loads HomeView.xaml and sets up the search bar and buttons.
# - Wires click events for search and clear tabs.
Function Initialize-HomeView {
    $script:HomeView = Import-XamlView "..\Views\HomeView.xaml"
    if ($null -eq $script:HomeView) {
        Write-Host "Failed to load HomeView.xaml."
        return
    }    
    Update-SearchButtonLabel $script:HomeView $script:configPath

    # Initialize the search bar
    $script:SearchBar = $script:HomeView.FindName('GoogleSearchBar')
    if ($script:SearchBar) {
        Initialize-SearchBar $script:SearchBar
        Set-PlaceholderLogic $script:SearchBar "WSID..."
    }
    else {
        Write-Host "Search bar not found in HomeView."
    }

    # Attach the click event to the Search button
    $searchButton = $script:HomeView.FindName('btnSearch')
    if ($searchButton) {
        $null = $searchButton.Remove_Click
        $searchButton.Add_Click({
                $bar = $script:HomeView.FindName('GoogleSearchBar')
                $wsidFilePath = Join-Path $PSScriptRoot "..\res\WSID.txt"
                # Pass only configPath for maintainability
                Update-WSIDFile $bar $wsidFilePath $script:configPath
            })
    }
    else {
        Write-Host "Search button not found in HomeView."
    }

    # Attach the click event to the "Clear Completed Tabs" button
    $clearButton = $script:HomeView.FindName('btnClearTabs')
    if ($clearButton) {
        $null = $clearButton.Remove_Click
        $clearButton.Add_Click({
                $tabs = $script:HomeView.FindName('TerminalTabs')
                $toRemove = @()

                # Collect computers to remove
                foreach ($computer in $script:TabsMap.Keys) {
                    $isActive = $false
                    foreach ($ps in $script:ActiveRunspaces) {
                        if ($script:RunspaceJobs[$ps].Computer -eq $computer) {
                            $isActive = $true
                            break
                        }
                    }
                    if (-not $isActive) {
                        $toRemove += $computer
                    }
                }
                
                # Remove tabs for computers that are not active
                foreach ($computer in $toRemove) {
                    $tabItem = $null
                    foreach ($item in $tabs.Items) {
                        if ($item.Header -eq $computer) {
                            $tabItem = $item
                            break
                        }
                    }
                    if ($tabItem) { $tabs.Items.Remove($tabItem) }

                    # Remove from script data structures
                    $script:TabsMap.Remove($computer)
                    $script:SyncUI.Remove($computer)
                    $script:QueuedOrRunning.Remove($computer)
                }
            })
    }
}

# Restores dynamic content in the HomeView (tabs, search bar, etc).
# - Restores tabs from collection and search bar state.
# - Updates the Search button label.
Function Update-HomeView {
    if (-not $script:HomeView) { return }
    $tabs = $script:HomeView.FindName('TerminalTabs')

    # Restore tabs from TabsCollection
    if ($tabs -and $script:TabsCollection) {
        $tabs.Items.Clear()
        foreach ($tab in $script:TabsCollection) {
            $tabs.Items.Add($tab)
        }
    }
    
    # Restore the search bar
    $searchBar = $script:HomeView.FindName('GoogleSearchBar')
    if ($searchBar) {
        Initialize-SearchBar $searchBar
        Set-PlaceholderLogic $searchBar "WSID..."
    }
    Update-SearchButtonLabel $script:HomeView $script:configPath
}

# Custom maximize/restore logic for the main window.
# - Maximizes window to working area (excluding taskbar).
# - Restores previous bounds if already maximized.
# - Tracks custom maximize state for toggling.
Function Switch-CustomMaximize {
    param(
        [System.Windows.Window]$window
    )
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
    }
    else {
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

# Window Initialization
$window = Import-Xaml "..\Views\MainWindow.xaml"
$panelControlBar = $window.FindName('panelControlBar')

# Merge all resource dictionaries from the Styles folder
Add-ResourceDictionaries -window $window

# Set logo image
$logoImage = $window.FindName('Logo')
$logoPath = Join-Path $PSScriptRoot '..\Images\logo yellow arrow.png'
$logoImage.Source = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]$logoPath)

# Maximize/Restore/Minimize/Close buttons
$script:LastWindowBounds = $null
$script:IsCustomMaximized = $false

if ($null -ne $panelControlBar) {
    $panelControlBar.Add_MouseLeftButtonDown({
            if ($_.ClickCount -eq 2) {
                Switch-CustomMaximize $window
                return
            }
            $window.DragMove()
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
            Switch-CustomMaximize $window
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
            
            # Determine resize direction based on mouse position
            if ($pos.X -le $margin -and $pos.Y -le $margin) { $resizeDir = 'TopLeft' }
            elseif ($pos.X -ge ($window.Width - $margin) -and $pos.Y -le $margin) { $resizeDir = 'TopRight' }
            elseif ($pos.X -le $margin -and $pos.Y -ge ($window.Height - $margin)) { $resizeDir = 'BottomLeft' }
            elseif ($pos.X -ge ($window.Width - $margin) -and $pos.Y -ge ($window.Height - $margin)) { $resizeDir = 'BottomRight' }
            elseif ($pos.X -le $margin) { $resizeDir = 'Left' }
            elseif ($pos.X -ge ($window.Width - $margin)) { $resizeDir = 'Right' }
            elseif ($pos.Y -le $margin) { $resizeDir = 'Top' }
            elseif ($pos.Y -ge ($window.Height - $margin)) { $resizeDir = 'Bottom' }
            else { $resizeDir = $null }
            
            # Set cursor and visibility of resize border based on direction
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
            }

            # If not in a resize area, reset cursor and hide border
            else {
                $WindowResizeBorder.IsHitTestVisible = $false
                $window.Cursor = [System.Windows.Input.Cursors]::Arrow
            }
        })

    # Handle mouse left button down for resizing
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
            
            # If a resize direction was determined, send the appropriate message to dll
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
            # Save config state when leaving config page
            if ($script:LastSelectedConfigOption -and $script:ConfigViewInstance) {
                $optionContent = $script:ConfigViewInstance.FindName('ConfigOptionsContent')
                if ($optionContent -and $optionContent.Content) {
                    Save-ConfigViewState -commandKey $script:LastSelectedConfigOption -childView $optionContent.Content
                }
                
                # Update the combo box selection to reflect what the user was last viewing
                $mainCombo = $script:ConfigViewInstance.FindName('MainCommandComboBox')
                if ($mainCombo -and $mainCombo.SelectedItem) {
                    $selectedText = if ($mainCombo.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { 
                        $mainCombo.SelectedItem.Content 
                    } else { 
                        $mainCombo.SelectedItem.ToString() 
                    }
                    $script:LastSelectedComboBoxOption = $selectedText
                }
            }
            
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
        $isFirstTimeLoad = $false
        if (-not $configViewInstance) {
            $configViewInstance = Import-XamlView "..\Views\ConfigView.xaml"
            $script:ConfigViewInstance = $configViewInstance
            $isFirstTimeLoad = $true
        }

        $contentControl.Content = $configViewInstance
        Show-HeaderPanel "Collapsed" "Visible" "Collapsed" $headerHome $headerConfig $headerLogs

        $mainCommandCombo = $configViewInstance.FindName('MainCommandComboBox')
        $optionContent = $configViewInstance.FindName('ConfigOptionsContent')

        if ($mainCommandCombo -and $optionContent) {
            $SetConfigOptionView = {
                param(
                    [System.Windows.Controls.ContentControl]$optionContent,
                    [string]$selected
                )
                if (-not $optionContent) {
                    return
                }
                
                # Save current view state before switching if there's already content
                if ($optionContent.Content -and $script:LastSelectedConfigOption) {
                    $currentView = $optionContent.Content
                    Save-ConfigViewState -commandKey $script:LastSelectedConfigOption -childView $currentView
                }
                
                if (-not $selected -or [string]::IsNullOrWhiteSpace($selected)) {
                    $optionContent.Content = $null
                    $script:LastSelectedConfigOption = $null
                    return
                }

                # Map selected option to corresponding XAML view file (some commented out in the xaml after leadership discussion)
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
                $commandMap = @{
                    "Scan"                        = "scan"
                    "Apply Updates"               = "applyUpdates"
                    "Configure"                   = "configure"
                    "Driver Install"              = "driverInstall"
                    "Version"                     = "version"
                    "Help"                        = "help"
                    "Generate Encrypted Password" = "generateEncryptedPassword"
                    "Custom Notification"         = "customnotification"
                }
                
                $file = $viewMap[$selected]
                $commandKey = $commandMap[$selected]
                
                if ($file) {
                    $childView = Import-XamlView "..\Views\Config Options\$file"
                    if ($childView) {
                        $optionContent.Content = $childView
                        $script:LastSelectedConfigOption = $commandKey
                        
                        # Determine loading strategy:
                        # 1. If we have state in memory, use it (user has been here before in this session)
                        # 2. If first load and this is the enabled command, load from config file
                        # 3. Otherwise, leave controls at default values
                        
                        if ($Global:ConfigViewStates.ContainsKey($commandKey)) {
                            # We have memory state - restore it
                            Restore-ConfigViewState -commandKey $commandKey -childView $childView
                        }
                        else {
                            # No memory state - check if we should load from config file
                            $shouldLoadFromConfig = $false
                            
                            # Load from config file if this is the enabled command and we're on first load
                            if ($script:ConfigPageFirstLoad -and (Test-Path $script:configPath)) {
                                $cfg = Read-Config -configPath $script:configPath
                                if ($cfg.EnabledCmdOption -eq $commandKey) {
                                    $shouldLoadFromConfig = $true
                                }
                            }
                            
                            if ($shouldLoadFromConfig) {
                                Get-ConfigFromFile -commandKey $commandKey -childView $childView -configPath $script:configPath
                            }
                            # If not loading from config, controls will remain at their default values
                        }
                        
                        # Always ensure throttleLimit is loaded from config for every view (global setting)
                        if (Test-Path $script:configPath) {
                            $cfg = Read-Config -configPath $script:configPath
                            if ($cfg.ThrottleLimit) {
                                $throttleBox = $null
                                try { $throttleBox = $childView.FindName('throttleLimit') } catch {}
                                if ($throttleBox -and $throttleBox.PSObject.TypeNames[0] -match 'TextBox') {
                                    $throttleBox.Text = $cfg.ThrottleLimit
                                }
                            }
                        }
                    }
                    else {
                        $optionContent.Content = $null
                        $script:LastSelectedConfigOption = $null
                        Write-Host "Failed to load child view: $file" -ForegroundColor Red
                    }
                }
                else {
                    $optionContent.Content = $null
                    $script:LastSelectedConfigOption = $null
                }
            }

            # Always read enabled command from config and set ComboBox accordingly - but only on first load
            $enabledCmd = $null
            $shouldLoadEnabledFromConfig = $script:ConfigPageFirstLoad
            
            if ($shouldLoadEnabledFromConfig -and (Test-Path $script:configPath)) {
                $cfg = Read-Config -configPath $script:configPath
                $enabledCmd = $cfg.EnabledCmdOption
            }
            
            $viewMapCmd = @{
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
            
            # Determine which option to select
            if ($shouldLoadEnabledFromConfig -and $enabledCmd) {
                # First load - use config file
                foreach ($k in $viewMapCmd.Keys) {
                    if ($viewMapCmd[$k] -eq $enabledCmd) { $selectedKey = $k; break }
                }
            }
            elseif ($script:LastSelectedComboBoxOption) {
                # Returning to config page - use last selected option
                $selectedKey = $script:LastSelectedComboBoxOption
            }
            
            if ($selectedKey) {
                # Set ComboBox to the enabled command
                for ($i = 0; $i -lt $mainCommandCombo.Items.Count; $i++) {
                    $item = $mainCommandCombo.Items[$i]
                    $itemText = if ($item -is [System.Windows.Controls.ComboBoxItem]) { $item.Content } else { $item.ToString() }
                    if ($itemText -eq $selectedKey) {
                        $mainCommandCombo.SelectedIndex = $i
                        break
                    }
                }
                $script:LastSelectedComboBoxOption = $selectedKey
                & $SetConfigOptionView $optionContent $selectedKey
                
                # After first load, mark as no longer first time
                if ($script:ConfigPageFirstLoad) {
                    $script:ConfigPageFirstLoad = $false
                }
            } else {
                # Fallback to first item if no match
                if ($mainCommandCombo.Items.Count -gt 0) {
                    $mainCommandCombo.SelectedIndex = 0
                    $sel = $mainCommandCombo.Items[0]
                    $selText = if ($sel -is [System.Windows.Controls.ComboBoxItem]) { $sel.Content } else { $sel.ToString() }
                    $script:LastSelectedComboBoxOption = $selText
                    & $SetConfigOptionView $optionContent $selText
                }
            }

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
                
                # Update the last selected combo box option
                $script:LastSelectedComboBoxOption = $sel
                
                $currentOptionContent = $configViewInstance.FindName('ConfigOptionsContent')
                if ($currentOptionContent) {
                    & $SetConfigOptionView $currentOptionContent $sel
                }
            }).GetNewClosure())
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
                        if ($selectedCmd -is [System.Windows.Controls.ComboBoxItem]) { 
                            $selectedCmd = $selectedCmd.Content 
                        }
                        $selectedKey = $null
                        foreach ($k in $viewMap.Keys) {
                            if ($k -eq $selectedCmd) { $selectedKey = $viewMap[$k]; break }
                        }
                        $optionContent = $configViewInstance.FindName('ConfigOptionsContent')
                        $childView = $null
                        if ($optionContent) { $childView = $optionContent.Content }
                        Save-ConfigFromUI -selectedKey $selectedKey -ContentControl $contentControl -childView $childView -configPath $script:configPath
                    })
            }
        })
}
if ($btnLogs) {
    $btnLogs.Add_Checked({
            # Save config state when leaving config page
            if ($script:LastSelectedConfigOption -and $script:ConfigViewInstance) {
                $optionContent = $script:ConfigViewInstance.FindName('ConfigOptionsContent')
                if ($optionContent -and $optionContent.Content) {
                    Save-ConfigViewState -commandKey $script:LastSelectedConfigOption -childView $optionContent.Content
                }
                
                # Update the combo box selection to reflect what the user was last viewing
                $mainCombo = $script:ConfigViewInstance.FindName('MainCommandComboBox')
                if ($mainCombo -and $mainCombo.SelectedItem) {
                    $selectedText = if ($mainCombo.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { 
                        $mainCombo.SelectedItem.Content 
                    } else { 
                        $mainCombo.SelectedItem.ToString() 
                    }
                    $script:LastSelectedComboBoxOption = $selectedText
                }
            }
            
            Show-HeaderPanel "Collapsed" "Collapsed" "Visible" $headerHome $headerConfig $headerLogs
            $script:LogsViewInstance = Show-LogsView -contentControl $contentControl
        })
}

# Show Window 
$null = $window.ShowDialog()