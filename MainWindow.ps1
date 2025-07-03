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
    param($contentControl)
    $script:HomeView = Import-XamlView "Views\HomeView.xaml"
    if ($null -eq $script:HomeView) {
        Write-Host "Failed to load HomeView.xaml."
        return
    }
    $contentControl.Content = $script:HomeView

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
        $searchButton.Add_Click({
                Update-WSIDFile $script:SearchBar
            })
        Write-Host "Search button click event attached."
    }
    else {
        Write-Host "Search button not found in HomeView."
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

    # Prevent multiple invocations by disabling the search button temporarily
    $searchButton = $script:HomeView.FindName('btnSearch')
    if ($searchButton) {
        $searchButton.IsEnabled = $false
    }

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
    $tabs.Items.Clear()

    # prepare synchronized queues and UI map
    $script:SyncUI = [hashtable]::Synchronized(@{})
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
        $script:SyncUI[$computer] = New-Object System.Collections.Concurrent.ConcurrentQueue[string]

        # Set default text for this computer's textbox
        $tb.AppendText("[$computer] Starting runspace and remoteDCU.ps1...`n")
        $tb.ScrollToEnd()
    }

    # Use a script-scoped hashtable for shared state instead of global variables
    $script:ActiveRunspaces = @()
    $script:RunspaceJobs = @{}
    $script:PendingQueue = $pending
    $script:TabsMap = $tabsMap
    $script:SyncUI = $script:SyncUI

    # Start up to $throttleLimit runspaces
    for ($i = 0; $i -lt $script:throttleLimit -and $script:PendingQueue.Count -gt 0; $i++) {
        & $script:StartNextRunspace
    }

    # Only start the DispatcherTimer ONCE per search/click
    if ($script:Timer) {
        $script:Timer.Stop()
        $script:Timer = $null
    }
    # Clear all output queues before starting new timer/runspaces to prevent leftover lines
    foreach ($comp in $script:TabsMap.Keys) {
        $queue = $script:SyncUI[$comp]
        while ($queue.Count -gt 0) { $null = $queue.TryDequeue([ref]([string]::Empty)) }
        $tb = $script:TabsMap[$comp]
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
                    $tb.AppendText("$line`n"); $tb.ScrollToEnd()
                }
            }
            $finished = @()
            foreach ($ps in @($script:ActiveRunspaces)) {
                if ($ps -and $script:RunspaceJobs.ContainsKey($ps)) {
                    $job = $script:RunspaceJobs[$ps]
                    if ($ps.InvocationStateInfo.State -eq 'Completed' -or $ps.InvocationStateInfo.State -eq 'Failed' -or $ps.InvocationStateInfo.State -eq 'Stopped') {
                        try { $ps.EndInvoke($job.AsyncResult) } catch {}
                        $ps.Dispose()
                        $finished += $ps
                    }
                }
            }
            foreach ($ps in $finished) {
                $script:ActiveRunspaces = $script:ActiveRunspaces | Where-Object { $_ -ne $ps }
                $script:RunspaceJobs.Remove($ps)
            }
            while ($script:ActiveRunspaces.Count -lt $script:throttleLimit -and $script:PendingQueue.Count -gt 0) {
                & $script:StartNextRunspace
            }
        })
    $script:Timer.Start()

    if ($tabs.Items.Count -gt 0) {
        $tabs.SelectedIndex = 0
    }
}

# --- Window and Resources ---
$window = Import-Xaml "Views\MainWindow.xaml"

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

# --- Window Controls and Events ---
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

# --- WSID Path ---
$wsidFilePath = Join-Path $PSScriptRoot "res\WSID.txt"

# --- Main Content Control and Navigation ---
$contentControl = $window.FindName('contentMain')
$btnHome = $window.FindName('btnHome')
$btnConfig = $window.FindName('btnConfig')
$btnLogs = $window.FindName('btnLogs')

# Set HomeView as default view
if ($contentControl) {
    Initialize-HomeView $contentControl
}

if ($btnHome) {
    $btnHome.Add_Checked({
            Initialize-HomeView $contentControl
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