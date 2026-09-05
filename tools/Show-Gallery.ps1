<#
.SYNOPSIS
    Shows every Home scene - populated, empty, storage, Lens - plus the update
    dialog, from one window with a floating switcher (Show-View, whole-app-shaped).

.DESCRIPTION
    Composes the main window the way Show-View -Main does (per-file styles with
    a UI\Styles BaseUri, regions into the Home shell's slots), then binds a
    different sample state per scene:

        Fleet mid-scan, Empty fleet, Storage (largest folders, with a checked
        user profile wearing its hazard), Person Lens, Update prompt (its own
        window, like the dialog really is).

    Nothing here touches the network or the machine's config: every scene is
    plain sample POCOs, so this previews exactly what is on disk.

.PARAMETER Screenshot
    A DIRECTORY: renders each scene off-screen and saves one PNG per scene
    (01-fleet.png ... 05-update-prompt.png), then exits. CI and docs friendly.

.EXAMPLE
    pwsh -Sta -File tools\Show-Gallery.ps1

.EXAMPLE
    pwsh -Sta -File tools\Show-Gallery.ps1 -Screenshot docs\shots

.NOTES
    Dev-path only, like Show-View: reads the checkout, never the launcher's
    embedded copy. Show-View stays the single-view tool; this is the contact sheet.
#>
param(
    [string]$Screenshot
)

$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Error "WPF needs STA. Run: pwsh -Sta -File `"$PSCommandPath`""
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$srcRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\src')).Path
$stylesPath = Join-Path $srcRoot 'UI\Styles'

# ResourceService.LoadStylesInto, dev path: BaseUri must sit in UI\Styles for ./Fonts.
$styles = [System.Windows.ResourceDictionary]::new()
foreach ($file in Get-ChildItem -Path $stylesPath -Filter '*.xaml') {
    $context = [System.Windows.Markup.ParserContext]::new()
    $context.BaseUri = [Uri]::new($file.FullName)
    $stream = [System.IO.File]::OpenRead($file.FullName)
    try { $styles.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Load($stream, $context)) }
    finally { $stream.Dispose() }
}

# ViewLoader.Load, dev path.
function Read-DonutView([string]$RelativePath) {
    $path = Join-Path $srcRoot $RelativePath
    if (-not (Test-Path $path)) { Write-Error "View not found: $path" }
    $stream = [System.IO.File]::OpenRead($path)
    try { return [System.Windows.Markup.XamlReader]::Load($stream) }
    finally { $stream.Dispose() }
}

# One dispatcher pass so bindings and templates catch up with a scene change.
function Invoke-UiPump {
    param([int]$Milliseconds = 250)
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Save-WindowPng {
    param([object]$Window, [string]$Path)
    $w = [int]$Window.ActualWidth
    $h = [int]$Window.ActualHeight
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($Window)
    $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    Write-Host "saved $Path (${w}x${h})"
}

# --- The composed main window, Show-View -Main's recipe ---
$window = Read-DonutView 'UI\Views\MainWindow.xaml'
$window.Resources.MergedDictionaries.Add($styles)
$window.WindowStartupLocation = 'CenterScreen'

$shell = Read-DonutView 'UI\Views\HomeView.xaml'
$actionBar = Read-DonutView 'UI\Views\Home\ActionBar.xaml'
$statCards = Read-DonutView 'UI\Views\Home\StatCards.xaml'
$machinePane = Read-DonutView 'UI\Views\Home\MachinePane.xaml'
$detailPane = Read-DonutView 'UI\Views\Home\DetailPane.xaml'
$lensPane = Read-DonutView 'UI\Views\Home\LensPane.xaml'
$shell.FindName('slotActionBar').Content = $actionBar
$shell.FindName('slotStatCards').Content = $statCards
$shell.FindName('slotMachinePane').Content = $machinePane
# Machine detail and the Lens share the slot the way HomePresenter stacks them.
$detailHost = [System.Windows.Controls.Grid]::new()
[void]$detailHost.Children.Add($detailPane)
[void]$detailHost.Children.Add($lensPane)
$shell.FindName('slotDetailArea').Content = $detailHost
$window.FindName('contentMain').Content = $shell

$logo = Join-Path $PSScriptRoot '..\assets\Images\logo yellow arrow.png'
$logoImage = $window.FindName('Logo')
$logoImage.Source = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]::new($logo))
[System.Windows.Media.RenderOptions]::SetBitmapScalingMode($logoImage, 'HighQuality')

# Plain POCOs: WPF cannot bind to PSCustomObject members, and still frames need no INPC.
if (-not ('GalleryMachine' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
public class GalleryHome {
    public string DetailMode { get; set; }
    public List<object> Machines { get; set; } = new List<object>();
    public GalleryMachine SelectedMachine { get; set; }
    public GalleryPerson SelectedPerson { get; set; }
    public string AppVersion { get; set; }
    public bool HasAppVersion { get; set; }
    public bool IsSettingsOpen { get; set; }
    public bool IsResetOpen { get; set; }
    public bool IsQrOpen { get; set; }
    public bool IsTourOpen { get; set; }
}
public class GalleryMachine {
    public string HostName { get; set; }
    public string OwnerName { get; set; } = "";
    public string OwnerTip { get; set; } = "";
    public string Subtitle { get; set; } = "";
    public string ChipText { get; set; } = "";
    public string StatusGlyph { get; set; } = "";
    public bool ChipVisible { get; set; }
    public object DotBrush { get; set; }
    public object ChipForeground { get; set; }
    public object ChipBackground { get; set; }
    public object ChipBorderBrush { get; set; }
    public string DetailIp { get; set; } = "";
    public string OvUptime { get; set; } = "";
    public string OvModel { get; set; } = "";
    public string OvModelSub { get; set; } = "";
    public string OvModelSubValue { get; set; } = "";
    public string OvBattery { get; set; } = "";
    public string OvBatterySub { get; set; } = "";
    public string OvDisk { get; set; } = "";
    public string OvDiskSub { get; set; } = "";
    public string OvBios { get; set; } = "";
    public bool HasUpdates { get; set; }
    public List<object> Updates { get; set; }
    public string UpdatesIdentityText { get; set; } = "";
    public string IdentityState { get; set; } = "";
    public bool HasFolders { get; set; }
    public List<object> Folders { get; set; } = new List<object>();
}
public class GalleryUpdate {
    public string Name { get; set; }
    public string Urgency { get; set; }
    public string Category { get; set; }
    public string VersionText { get; set; }
    public string SizeText { get; set; }
    public bool IsNewer { get; set; }
}
public class GalleryLog {
    public string StampText { get; set; }
    public string DisplayText { get; set; }
    public string Severity { get; set; } = "";
}
public class GalleryFolder {
    public string Label { get; set; }
    public string SizeText { get; set; }
    public string Path { get; set; }
    public bool IsRoot { get; set; }
    public bool IsDeletable { get; set; }
    public bool IsUserDir { get; set; }
    public bool IsSelected { get; set; }
    public List<object> Children { get; set; } = new List<object>();
}
public class GalleryPerson {
    public string DisplayName { get; set; } = "";
    public string Upn { get; set; } = "";
    public string StatusText { get; set; } = "";
    public bool HasError { get; set; }
    public bool IsLoading { get; set; }
    public string Email { get; set; } = "";
    public string Manager { get; set; } = "";
    public string Sam { get; set; } = "";
    public string Office { get; set; } = "";
    public bool HasDevices { get; set; }
    public List<object> Devices { get; set; } = new List<object>();
    public bool IsSoftwareShown { get; set; }
    public string SoftwareStatusText { get; set; } = "";
    public string ListLabel { get; set; } = "DEVICES";
    public string ToggleLabel { get; set; } = "Software";
    public List<object> Deployments { get; set; } = new List<object>();
}
public class GalleryDevice {
    public string Name { get; set; } = "";
    public string Model { get; set; } = "";
    public string TagText { get; set; } = "";
    public string Serial { get; set; } = "";
    public string LastSeenText { get; set; } = "";
    public string Note { get; set; } = "";
    public string DetailTip { get; set; } = "";
    public bool HasBitLocker { get; set; }
    public bool IsBitLockerRevealed { get; set; }
    public string BitLockerText { get; set; } = "";
    public object RevealCommand { get; set; }
    public object ShowQrCommand { get; set; }
    public object AddCommand { get; set; }
}
'@
}

function Get-Brush([string]$Key) { return $window.FindResource($Key) }

# --- Sample data, one bundle per scene ---
$selected = [GalleryMachine]@{
    HostName = 'CAP-9F3KQ2'; OwnerName = 'Priya N'; OwnerTip = 'Priya Nair'
    Subtitle            = 'Yesterday 4:12 PM - 3 updates'
    ChipText = 'Scanning…'; StatusGlyph = [char]0x21BB; ChipVisible = $true
    DotBrush = Get-Brush AccentCyan; ChipForeground = Get-Brush AccentCyan
    ChipBackground = Get-Brush TintSky; ChipBorderBrush = Get-Brush TintSkyBorder
    DetailIp = '10.24.118.37'; OvUptime = 'Up 3 days'
    OvModel = 'Latitude 5440'; OvModelSub = 'Tag 7GZK2M3'; OvModelSubValue = '7GZK2M3'
    OvBattery = '92% health'; OvBatterySub = '78% - on battery'
    OvDisk = '182.5 GB free'; OvDiskSub = '512 GB Total'; OvBios = '1.24.0'
    HasUpdates = $true; IdentityState = 'Match'
    UpdatesIdentityText = 'Service tag 7GZK2M3 matches the scanned machine.'
    Updates             = [System.Collections.Generic.List[object]]@(
        [GalleryUpdate]@{ Name = 'Dell BIOS'; Urgency = 'Urgent'; Category = 'BIOS'
            VersionText = '1.24.0 → 1.26.1'; SizeText = '14.2 MB'
        }
        [GalleryUpdate]@{ Name = 'Intel UHD Graphics 770 Driver'; Urgency = 'Recommended'
            Category = 'Driver'; VersionText = '31.0.101.4502 → 31.0.101.5186'
            SizeText = '428.1 MB'; IsNewer = $true
        }
        [GalleryUpdate]@{ Name = 'Realtek Audio Driver'; Urgency = 'Optional'; Category = 'Driver'
            VersionText = '6.0.9789.1 → 6.0.9944.1'; SizeText = '62.4 MB'
        }
    )
}
$fleet = [System.Collections.Generic.List[object]]@(
    $selected
    [GalleryMachine]@{
        HostName = 'B4021-LAB'; Subtitle = 'Today 9:04 AM - 4 updates'
        ChipText = 'Completed'; StatusGlyph = [char]0x2713; ChipVisible = $true
        DotBrush = Get-Brush AccentGreen; ChipForeground = Get-Brush AccentGreen
        ChipBackground = Get-Brush TintGreen; ChipBorderBrush = Get-Brush TintGreenBorder
    }
    [GalleryMachine]@{
        HostName = 'WVD-PROD-07'; OwnerName = 'Marcus W'; OwnerTip = 'Marcus Webb'
        Subtitle = 'Today 8:56 AM - 2 updates'
        ChipText = 'Reboot Required'; StatusGlyph = [char]0x26A0; ChipVisible = $true
        DotBrush = Get-Brush AccentYellow; ChipForeground = Get-Brush AccentYellow
        ChipBackground = Get-Brush TintAmber; ChipBorderBrush = Get-Brush TintAmberBorder
    }
    [GalleryMachine]@{
        HostName = 'LT-8842-EDU'; Subtitle = 'Never run'
        DotBrush = Get-Brush BodyTextTertiary
    }
)

# Storage scene: the largest-folders tree, with a checked user profile wearing its hazard.
$storageMachine = [GalleryMachine]@{
    HostName   = 'CAP-9F3KQ2'; OwnerName = 'Priya N'; OwnerTip = 'Priya Nair'
    Subtitle   = 'Today 9:20 AM - storage scan'; ChipVisible = $false
    DotBrush   = Get-Brush AccentGreen
    DetailIp   = '10.24.118.37'; OvUptime = 'Up 3 days'
    OvModel    = 'Latitude 5440'; OvModelSub = 'Tag 7GZK2M3'; OvModelSubValue = '7GZK2M3'
    OvBattery  = '92% health'; OvBatterySub = '78% - on battery'
    OvDisk     = '38.2 GB free'; OvDiskSub = '512 GB Total'; OvBios = '1.24.0'
    HasFolders = $true
    Folders    = [System.Collections.Generic.List[object]]@(
        [GalleryFolder]@{ Label = 'C:\'; SizeText = '473.8 GB'; Path = 'C:\'; IsRoot = $true
            Children = [System.Collections.Generic.List[object]]@(
                [GalleryFolder]@{ Label = 'Users'; SizeText = '221.4 GB'; Path = 'C:\Users'
                    Children = [System.Collections.Generic.List[object]]@(
                        [GalleryFolder]@{ Label = 'priya.nair'; SizeText = '148.7 GB'
                            Path = 'C:\Users\priya.nair'; IsDeletable = $true
                            IsUserDir = $true; IsSelected = $true
                        }
                        [GalleryFolder]@{ Label = 'old.intern'; SizeText = '41.9 GB'
                            Path = 'C:\Users\old.intern'; IsDeletable = $true; IsUserDir = $true
                        }
                    )
                }
                [GalleryFolder]@{ Label = 'Windows'; SizeText = '96.2 GB'; Path = 'C:\Windows'
                    Children = [System.Collections.Generic.List[object]]@(
                        [GalleryFolder]@{ Label = 'ccmcache'; SizeText = '18.3 GB'
                            Path = 'C:\Windows\ccmcache'; IsDeletable = $true
                        }
                    )
                }
                [GalleryFolder]@{ Label = 'temp'; SizeText = '22.6 GB'; Path = 'C:\temp'
                    IsDeletable = $true
                }
            )
        }
    )
}

# Lens scene: a person with a Dell and a non-Dell device, one key revealed.
$person = [GalleryPerson]@{
    DisplayName = 'Priya Nair'; Upn = 'priya.nair@corp.example'
    Email = 'priya.nair@corp.example'; Manager = 'Danial Changez'
    Sam = 'priya.nair'; Office = 'Guelph - 4th Floor'
    HasDevices = $true
    Devices    = [System.Collections.Generic.List[object]]@(
        [GalleryDevice]@{ Name = 'CAP-9F3KQ2'; Model = 'Latitude 5440'; TagText = 'Tag 7GZK2M3'
            Serial = '7GZK2M3'; LastSeenText = 'Seen today'; HasBitLocker = $true
            IsBitLockerRevealed = $true; BitLockerText = '111111-222222-333333-444444-555555-666666'
        }
        [GalleryDevice]@{ Name = 'CAP-TP14S22'; Model = 'ThinkPad T14s'; TagText = 'Tag MJ0D4A55'
            Serial = 'MJ0D4A55'; LastSeenText = 'Seen 6 days ago'
            Note = 'Lenovo hardware: scans and updates are Dell-only (dcu-cli).'
        }
    )
}

$emptyHome = [GalleryHome]@{ DetailMode = ''; AppVersion = '2.6.2'; HasAppVersion = $true }
$fleetHome = [GalleryHome]@{
    DetailMode = 'Machine'; Machines = $fleet; SelectedMachine = $selected
    AppVersion = '2.6.2'; HasAppVersion = $true
}
$storageHome = [GalleryHome]@{
    DetailMode = 'Machine'; Machines = $fleet; SelectedMachine = $storageMachine
    AppVersion = '2.6.2'; HasAppVersion = $true
}
$lensHome = [GalleryHome]@{
    DetailMode = 'Person'; Machines = $fleet; SelectedPerson = $person
    AppVersion = '2.6.2'; HasAppVersion = $true
}

$bar = $detailPane.FindName('DetailProgress')
$log = $detailPane.FindName('lstDetailLog')
$scanLines = [System.Collections.Generic.List[object]]::new()
# Leading commas: statements inside @() unroll, so bare inner arrays would flatten.
foreach ($line in @(
        , @('09:12:04  ', 'Connected to CAP-9F3KQ2; DCU 5.4 found.', '')
        , @('09:12:06  ', 'Scan started: checking device updates (3 of 5).', '')
        , @('09:12:31  ', '[Warn] On battery power; BIOS updates defer until AC.', 'Warn')
        , @('09:12:47  ', 'Driver catalog synced; 3 updates apply to this system.', 'Success')
    )) {
    $scanLines.Add([GalleryLog]@{ StampText = $line[0]; DisplayText = $line[1]; Severity = $line[2] })
}
$storageLines = [System.Collections.Generic.List[object]]::new()
foreach ($line in @(
        , @('09:20:11  ', 'Storage scan finished: 6 folders over 10 GB.', 'Success')
        , @('09:21:02  ', 'skipped C:\Users\priya.nair - that user is signed in on this machine', 'Warn')
    )) {
    $storageLines.Add([GalleryLog]@{ StampText = $line[0]; DisplayText = $line[1]; Severity = $line[2] })
}

# --- Scenes: name, label, and the state swap that produces each still ---
$scenes = @(
    @{ Name = 'fleet'; Label = 'Fleet Mid-Scan'; Apply = {
            $window.DataContext = $fleetHome
            $machinePane.FindName('MachineList').SelectedIndex = 0
            $bar.Visibility = 'Visible'
            $bar.Value = 62
            $log.ItemsSource = $scanLines
        }
    }
    @{ Name = 'empty'; Label = 'Empty Fleet'; Apply = {
            $window.DataContext = $emptyHome
            $bar.Visibility = 'Collapsed'
            $log.ItemsSource = $null
        }
    }
    @{ Name = 'storage'; Label = 'Storage + Hazard'; Apply = {
            $window.DataContext = $storageHome
            $machinePane.FindName('MachineList').SelectedIndex = 0
            $bar.Visibility = 'Collapsed'
            $log.ItemsSource = $storageLines
        }
    }
    @{ Name = 'lens'; Label = 'Person Lens'; Apply = {
            $window.DataContext = $lensHome
            $bar.Visibility = 'Collapsed'
        }
    }
)

# The update prompt rides along as its own window, the shape it really has.
function New-UpdatePromptWindow {
    if (-not ('GalleryDialog' -as [type])) {
        Add-Type -TypeDefinition @'
public class GalleryDialog {
    public string Title { get; set; }
    public bool HasTitle { get; set; }
    public string Message { get; set; }
    public bool HasMessage { get; set; }
    public bool HasList { get; set; }
    public string PrimaryText { get; set; }
    public object PrimaryStyle { get; set; }
    public string SecondaryText { get; set; }
    public bool HasSecondary { get; set; }
    public string RememberText { get; set; }
    public bool HasRemember { get; set; }
    public bool Remember { get; set; }
    public string VersionFrom { get; set; }
    public string VersionTo { get; set; }
    public bool HasVersionCard { get; set; }
    public string ReleaseUrl { get; set; }
    public bool HasReleaseUrl { get; set; }
    public string ReleaseLinkText { get; set; }
}
'@
    }
    $dialog = Read-DonutView 'UI\Views\DialogWindow.xaml'
    $dialog.Resources.MergedDictionaries.Add($styles)
    $dialog.DataContext = [GalleryDialog]@{
        Title = 'Update Available'; HasTitle = $true
        Message    = 'A newer release is ready to install. DONUT restarts by itself when it finishes.'
        HasMessage = $true
        PrimaryText = 'Update Now'; PrimaryStyle = $dialog.FindResource('ButtonTintPrimary')
        SecondaryText = 'Not Now'; HasSecondary = $true
        RememberText = 'Update automatically from now on'; HasRemember = $true
        VersionFrom = '2.5.819'; VersionTo = '2.6.1'; HasVersionCard = $true
        ReleaseUrl = 'https://example.invalid'; HasReleaseUrl = $true; ReleaseLinkText = 'Release Notes'
    }
    $dialog.add_KeyDown({ if ($_.Key -eq 'Escape') { $this.Close() } })
    return $dialog
}

if ($Screenshot) {
    New-Item $Screenshot -ItemType Directory -Force | Out-Null
    $outDir = (Resolve-Path $Screenshot).Path
    # Off-screen + visual-tree render (Show-View's recipe): covering windows cannot leak in.
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -20000
    $window.Top = 0
    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
    $window.Show()
    Invoke-UiPump 400
    $n = 0
    foreach ($scene in $scenes) {
        $n++
        & $scene.Apply | Out-Null
        Invoke-UiPump 350
        Save-WindowPng $window (Join-Path $outDir ('{0:d2}-{1}.png' -f $n, $scene.Name))
    }
    $dialog = New-UpdatePromptWindow
    $dialog.WindowStartupLocation = 'Manual'
    $dialog.Left = -20000
    $dialog.Top = 0
    $dialog.ShowActivated = $false
    $dialog.ShowInTaskbar = $false
    $dialog.Show()
    Invoke-UiPump 400
    Save-WindowPng $dialog (Join-Path $outDir ('{0:d2}-update-prompt.png' -f ($n + 1)))
    $dialog.Close()
    $window.Close()
    return
}

# --- Interactive: the app plus a floating scene switcher ---
& $scenes[0].Apply | Out-Null

$panel = [System.Windows.Controls.StackPanel]::new()
$panel.Margin = [System.Windows.Thickness]::new(10)
foreach ($scene in $scenes) {
    $btn = [System.Windows.Controls.Button]::new()
    $btn.Content = $scene.Label
    $btn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $apply = $scene.Apply
    $btn.add_Click({ & $apply | Out-Null }.GetNewClosure())
    $panel.Children.Add($btn) | Out-Null
}
$dialogBtn = [System.Windows.Controls.Button]::new()
$dialogBtn.Content = 'Update Prompt'
$dialogBtn.add_Click({ (New-UpdatePromptWindow).Show() })
$panel.Children.Add($dialogBtn) | Out-Null

$switcher = [System.Windows.Window]::new()
$switcher.Title = 'Scenes'
$switcher.Width = 200
$switcher.SizeToContent = 'Height'
$switcher.Topmost = $true
$switcher.WindowStartupLocation = 'Manual'
$switcher.Left = 40
$switcher.Top = 120
$switcher.Content = $panel
$switcher.Resources.MergedDictionaries.Add($styles)
foreach ($child in $panel.Children) {
    $child.Style = $switcher.FindResource('ButtonSecondary')
}
$switcher.Background = $switcher.FindResource('PrimaryBackground')
$switcher.Show()
$window.add_Closed({ $switcher.Close() }.GetNewClosure())

$window.Add_KeyDown({ if ($_.Key -eq 'Escape') { $window.Close() } }.GetNewClosure())
[void]$window.ShowDialog()
