Add-Type -AssemblyName PresentationFramework

# --- XAML Import Helpers ---
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

# --- Window and Resources ---
$window = Import-Xaml "Views\MainWindow.xaml"

# Merge resource dictionaries
$uiColorsPath = Join-Path $PSScriptRoot 'Styles\UIColors.xaml'
$uiColorsStream = [System.IO.File]::OpenRead($uiColorsPath)
try {
    $uiColorsDict = [Windows.Markup.XamlReader]::Load($uiColorsStream)
    $window.Resources.MergedDictionaries.Add($uiColorsDict)
}
finally {
    $uiColorsStream.Close()
}

$buttonStylesPath = Join-Path $PSScriptRoot 'Styles\ButtonStyles.xaml'
$buttonStylesStream = [System.IO.File]::OpenRead($buttonStylesPath)
try {
    $buttonStylesDict = [Windows.Markup.XamlReader]::Load($buttonStylesStream)
    $window.Resources.MergedDictionaries.Add($buttonStylesDict)
}
finally {
    $buttonStylesStream.Close()
}

$iconsPath = Join-Path $PSScriptRoot 'Styles\Icons.xaml'
$iconsStream = [System.IO.File]::OpenRead($iconsPath)
try {
    $iconsDict = [Windows.Markup.XamlReader]::Load($iconsStream)
    $window.Resources.MergedDictionaries.Add($iconsDict)
}
finally {
    $iconsStream.Close()
}

# Set logo image
$logoImage = $window.FindName('Logo')
$logoPath = Join-Path $PSScriptRoot 'Images\logo yellow arrow.png'
$logoImage.Source = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]$logoPath)

# --- Window Controls and Events ---
Add-Type -AssemblyName System.Windows.Forms

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

# --- HomeView Placeholder Logic ---
$HomeViewText = ""

# Define Show-Placeholder globally
Function Show-Placeholder {
    param($txt, $placeHolder)
    $txt.Text = $placeHolder
    $txt.Tag = "placeholder"
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
                $global:HomeViewText = $this.Text
            }
        })
}

Function Init-HomeView {
    param($contentControl)
    $global:HomeView = Import-XamlView "Views\HomeView.xaml"
    if ($null -eq $global:HomeView) {
        Write-Host "Failed to load HomeView.xaml."
        return
    }
    $contentControl.Content = $global:HomeView

    # Initialize the search bar
    $global:SearchBar = $global:HomeView.FindName('txtHomeMessage')
    if ($global:SearchBar) {
        Init-SearchBar $global:SearchBar
        Write-Host "Search bar initialized with: '$($global:SearchBar.Text)'"
    }
    else {
        Write-Host "Search bar not found in HomeView."
    }

    # Attach the click event to the Search button
    $searchButton = $global:HomeView.FindName('btnSearch')
    if ($searchButton) {
        $searchButton.Add_Click({
                Update-WSIDFile $global:SearchBar
            })
        Write-Host "Search button click event attached."
    }
    else {
        Write-Host "Search button not found in HomeView."
    }
}

# --- WSID File Handling ---
# Define the path to the WSID.txt file
$wsidFilePath = Join-Path $PSScriptRoot "res\WSID.txt"

# Function to initialize the search bar with the content of WSID.txt
Function Init-SearchBar {
    param($textBox)
    if (Test-Path $wsidFilePath) {
        # Read file, ignore blank/whitespace lines
        $lines = Get-Content -Path $wsidFilePath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $textBox.Text = $lines -join "`r`n"
    }
}

# Function to update WSID.txt with the content of the search bar
# Thread-safe global UI update queue
$global:SyncUI = [hashtable]::Synchronized(@{ Lines = New-Object System.Collections.ArrayList })

Function Update-WSIDFile {
    param($textBox)
    # Ensure the TextBox reference is valid
    if ($null -eq $textBox) {
        Write-Host "TextBox reference is null. Ensure 'txtHomeMessage' exists in the XAML."
        return
    }

    # Ensure the TextBox has valid content before updating the file
    if (![string]::IsNullOrWhiteSpace($textBox.Text)) {
        
        # Split, remove empty lines, then take unique entries
        $valid = ($textBox.Text -split "[\r\n]+") |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique

        Set-Content -Path $wsidFilePath -Value $valid
        Write-Host "WSID.txt updated with: '$($valid -join ',')'"

        # Prevent multiple invocations by disabling the search button temporarily
        $searchButton = $global:HomeView.FindName('btnSearch')
        if ($searchButton) {
            $searchButton.IsEnabled = $false
        }

        # Read throttleLimit from config.txt
        $configPath = Join-Path $PSScriptRoot 'config.txt'
        # Default
        $throttleLimit = 5
        if (Test-Path $configPath) {
            $configLines = Get-Content $configPath | Where-Object { $_ -match 'throttleLimit' }
            if ($configLines) {
                $line = $configLines -replace '[\r\n ]', ''
                if ($line -match 'throttleLimit=(\d+)') {
                    $throttleLimit = [int]$matches[1]
                }
            }
        }

        $tabs = $global:HomeView.FindName('TerminalTabs')
        $tabs.Items.Clear()

        # prepare synchronized queues and UI map
        $global:SyncUI = [hashtable]::Synchronized(@{})
        $tabsMap = @{}

        # Prepare queue of computers to process
        $pending = [System.Collections.Queue]::new()
        foreach ($computer in $valid) {
            $pending.Enqueue($computer)
            # create a Tab + readonly TextBox
            $tab = [System.Windows.Controls.TabItem]::new(); $tab.Header = $computer
            $tb = [System.Windows.Controls.TextBox]::new(); $tb.IsReadOnly = $true
            $tab.Content = $tb; $tabs.Items.Add($tab)
            $tabsMap[$computer] = $tb
            $global:SyncUI[$computer] = New-Object System.Collections.Concurrent.ConcurrentQueue[string]

            # Set default text for this computer's textbox
            $tb.AppendText("[$computer] Starting runspace and remoteDCU.ps1...`n")
            $tb.ScrollToEnd()
        }

        $activeRunspaces = @()
        $runspaceJobs = @{}

        function Start-NextRunspace {
            if ($pending.Count -eq 0) { return }
            $computer = $pending.Dequeue()
            $queue = $global:SyncUI[$computer]
            $tb = $tabsMap[$computer]
            # Set default text again in case of retry/restart
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
                    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true

                    $proc = [System.Diagnostics.Process]::new(); $proc.StartInfo = $psi
                    $proc.Start() | Out-Null

                    $stdout = $proc.StandardOutput
                    $stderr = $proc.StandardError
                    $lastErrorLine = $null
                    while (-not $stdout.EndOfStream) {
                        $line = $stdout.ReadLine()
                        # Remove ANSI escape sequences
                        $cleanLine = $line -replace "`e\[[\d;]*[A-Za-z]", ""
                        # Only capture the last error code line, ignore PsExec connection/service lines
                        if ($cleanLine -match "pwsh exited on .+ with error code (\d+)\.") {
                            $lastErrorLine = $matches[0]
                        }
                        # Suppress PsExec connection/service lines
                        elseif ($cleanLine -notmatch "Connecting to|Starting PSEXESVC|Copying authentication key|Connecting with PsExec service|Starting pwsh on" -and $cleanLine -match '\S') {
                            $queue.Enqueue($cleanLine) | Out-Null
                            $tb.Dispatcher.Invoke([action[string]] {
                                    param($l)
                                    $tb.AppendText("$l`n")
                                    $tb.ScrollToEnd()
                                }, $cleanLine)
                        }
                    }
                    while (-not $stderr.EndOfStream) {
                        $line = $stderr.ReadLine()
                        $cleanLine = $line -replace "`e\[[\d;]*[A-Za-z]", ""
                        # Suppress PsExec connection/service lines in stderr as well
                        if ($cleanLine -notmatch "Connecting to|Starting PSEXESVC|Copying authentication key|Connecting with PsExec service|Starting pwsh on" -and $cleanLine -match '\S') {
                            $queue.Enqueue($cleanLine) | Out-Null
                            $tb.Dispatcher.Invoke([action[string]] {
                                    param($l)
                                    $tb.AppendText("$l`n")
                                    $tb.ScrollToEnd()
                                }, $cleanLine)
                        }
                    }
                    $proc.WaitForExit()
                    # After process ends, print only the last error code line if it was found
                    if ($lastErrorLine) {
                        $tb.Dispatcher.Invoke([action[string]] {
                                param($l)
                                $tb.AppendText("Final status: $l`n")
                                $tb.ScrollToEnd()
                            }, $lastErrorLine)
                    }
                }).AddArgument($computer).AddArgument($remoteDCUPathAbs).AddArgument($queue).AddArgument($tb)

            $async = $ps.BeginInvoke()
            $activeRunspaces += $ps
            $runspaceJobs[$ps] = @{
                Computer    = $computer
                PowerShell  = $ps
                AsyncResult = $async
            }
        }

        # Start up to $throttleLimit runspaces
        for ($i = 0; $i -lt $throttleLimit -and $pending.Count -gt 0; $i++) {
            Start-NextRunspace
        }

        # Timer to flush queues and manage runspaces
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $timer.Add_Tick({
                # Flush output to textboxes
                foreach ($comp in $tabsMap.Keys) {
                    $tb = $tabsMap[$comp]
                    $queue = $global:SyncUI[$comp]
                    $line = $null
                    while ($queue.TryDequeue([ref]$line)) {
                        $tb.AppendText("$line`n"); $tb.ScrollToEnd()
                    }
                }
                # Check for completed runspaces and start new ones if needed
                $finished = @()
                foreach ($ps in $activeRunspaces) {
                    $job = $runspaceJobs[$ps]
                    if ($ps.InvocationStateInfo.State -eq 'Completed' -or $ps.InvocationStateInfo.State -eq 'Failed' -or $ps.InvocationStateInfo.State -eq 'Stopped') {
                        $ps.EndInvoke($job.AsyncResult)
                        $ps.Dispose()
                        $finished += $ps
                    }
                }
                foreach ($ps in $finished) {
                    $activeRunspaces = $activeRunspaces | Where-Object { $_ -ne $ps }
                    $runspaceJobs.Remove($ps)
                    # Start a new runspace if there are more computers pending
                    Start-NextRunspace
                }
            })
        $timer.Start()

        if ($tabs.Items.Count -gt 0) {
            $tabs.SelectedIndex = 0
        }
    }
    else {
        Write-Host "TextBox is empty. File not updated."
    }
}

# --- Main Content Control and Navigation ---
$contentControl = $window.FindName('contentMain')
$btnHome = $window.FindName('btnHome')
$btnConfig = $window.FindName('btnConfig')
$btnLogs = $window.FindName('btnLogs')

if ($contentControl) {
    # Set HomeView as default view
    Init-HomeView $contentControl
}

if ($btnHome) {
    $btnHome.Add_Checked({
            Init-HomeView $contentControl
        })
}
if ($btnConfig) {
    $btnConfig.Add_Checked({
            $contentControl.Content = Import-XamlView "Views\ConfigView.xaml"
        })
}
if ($btnLogs) {
    $btnLogs.Add_Checked({
            $contentControl.Content = Import-XamlView "Views\LogsView.xaml"
        })
}

# --- Show Window ---
$null = $window.ShowDialog()
