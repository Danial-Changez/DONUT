<#
.SYNOPSIS
    Previews a XAML view with the app's merged styles, without launching DONUT.

.DESCRIPTION
    Loads every dictionary under src\UI\Styles the way ResourceService does (per
    file, BaseUri pointed into UI\Styles so the embedded fonts resolve), then
    loads the requested view and shows it in a themed window. Views resolve
    their keys via DynamicResource, so per-file loading in any order works; the
    two traps a bare pwsh attempt hits are the WPF assemblies not being loaded
    first, and a XamlReader-loaded window not inheriting Application resources.

    DialogWindow and the Home composition get sample data so their bindings
    render; other views show their chrome (bindings without a context stay
    empty).

.PARAMETER View
    View path relative to src\ (default UI\Views\DialogWindow.xaml).

.PARAMETER Main
    Compose the full main window instead: MainWindow hosting the Home shell and
    its four regions, filled with a sample fleet mid-scan. The docs hero shot.

.PARAMETER ErrorDialog
    Preview the C# launcher ErrorDialog instead of a XAML view. Builds the
    launcher first, since C# only previews compiled, then shows the dialog with
    sample content (open the details with the toggle).

.PARAMETER Screenshot
    Save a PNG here and close by itself instead of waiting for Esc or X.

.EXAMPLE
    pwsh -File tools\Show-View.ps1
    Shows the themed DialogWindow with sample content.

.EXAMPLE
    pwsh -File tools\Show-View.ps1 -Main -Screenshot home.png

.EXAMPLE
    pwsh -File tools\Show-View.ps1 -ErrorDialog

.EXAMPLE
    pwsh -File tools\Show-View.ps1 -View UI\Views\Home\MachinePane.xaml -Screenshot pane.png

.NOTES
    Dev-path only: reads the checkout, never the launcher's embedded copy, so it
    previews exactly what is on disk before a commit.
#>
param(
    [string]$View = 'UI\Views\DialogWindow.xaml',
    [switch]$Main,
    [switch]$ErrorDialog,
    [string]$Screenshot
)

$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Error "WPF needs STA. Run: pwsh -Sta -File `"$PSCommandPath`""
    exit 1
}

if ($ErrorDialog) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $proj = Join-Path $PSScriptRoot '..\src\Launcher\Donut.Launcher.csproj'
    dotnet build $proj -nologo -v q
    if ($LASTEXITCODE -ne 0) { Write-Error 'Launcher build failed.'; exit 1 }
    $dll = Join-Path $PSScriptRoot '..\src\Launcher\bin\Debug\net10.0-windows\Donut.Launcher.dll'
    [void][System.Reflection.Assembly]::LoadFrom((Resolve-Path $dll))

    if ($Screenshot) {
        # A WinForms timer fires inside the modal loop, on the dialog's own thread.
        $timer = [System.Windows.Forms.Timer]::new()
        $timer.Interval = 1200
        $timer.Add_Tick({
                $timer.Stop()
                $form = [System.Windows.Forms.Application]::OpenForms |
                    Where-Object { $_.GetType().Name -eq 'ErrorDialog' } | Select-Object -First 1
                if (-not $form) { return }
                ($form.Controls | Where-Object { $_.AccessibleName -eq 'Details' }).PerformClick()
                [System.Windows.Forms.Application]::DoEvents()
                # DrawToBitmap renders the form itself, so a covered window still captures true.
                $bmp = [System.Drawing.Bitmap]::new($form.Width, $form.Height)
                $form.DrawToBitmap($bmp, [System.Drawing.Rectangle]::new(0, 0, $form.Width, $form.Height))
                $bmp.Save($Screenshot, [System.Drawing.Imaging.ImageFormat]::Png)
                Write-Host "saved $Screenshot ($($form.Width)x$($form.Height))"
                $form.Close()
            })
        $timer.Start()
    }
    [Donut.Launcher.ErrorDialog]::Show('DONUT Setup', 'DONUT needs one administrator launch.',
        'Start it as administrator once to finish setup. Normal launches work after that.',
        "Missing: disk scan tool`nSystem.IO.FileNotFoundException: ...\app\src\Tools\wiztree64.exe")
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

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

$root = Read-DonutView $(if ($Main) { 'UI\Views\MainWindow.xaml' } else { $View })

if ($root -is [System.Windows.Window]) {
    $window = $root
} else {
    # Region views get the shell's ground and the content column's 25px inset.
    $window = [System.Windows.Window]::new()
    $window.Title = $View
    $window.SizeToContent = 'WidthAndHeight'
    $window.Content = [System.Windows.Controls.Border]::new()
    $window.Content.Padding = '25'
    $window.Content.MinWidth = 460
    $window.Content.Child = $root
}
$window.Resources.MergedDictionaries.Add($styles)
if (-not ($root -is [System.Windows.Window])) {
    $window.Background = $window.FindResource('PrimaryBackground')
}
$window.WindowStartupLocation = 'CenterScreen'

if ($Main) {
    # The HomePresenter composition, minus presenters: shell into contentMain, regions into slots.
    $shell = Read-DonutView 'UI\Views\HomeView.xaml'
    $actionBar = Read-DonutView 'UI\Views\Home\ActionBar.xaml'
    $statCards = Read-DonutView 'UI\Views\Home\StatCards.xaml'
    $machinePane = Read-DonutView 'UI\Views\Home\MachinePane.xaml'
    $detailPane = Read-DonutView 'UI\Views\Home\DetailPane.xaml'
    $shell.FindName('slotActionBar').Content = $actionBar
    $shell.FindName('slotStatCards').Content = $statCards
    $shell.FindName('slotMachinePane').Content = $machinePane
    $shell.FindName('slotDetailArea').Content = $detailPane
    $window.FindName('contentMain').Content = $shell

    $logo = Join-Path $PSScriptRoot '..\assets\Images\logo yellow arrow.png'
    $logoImage = $window.FindName('Logo')
    $logoImage.Source = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]::new($logo))
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($logoImage, 'HighQuality')

    # Plain POCOs: WPF cannot bind to PSCustomObject members, and a still frame needs no INPC.
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
public class HomeSample {
    public string DetailMode { get; set; }
    public List<object> Machines { get; set; }
    public MachineSample SelectedMachine { get; set; }
    public string AppVersion { get; set; }
    public bool HasAppVersion { get; set; }
    public bool IsSettingsOpen { get; set; }
    public bool IsResetOpen { get; set; }
    public bool IsQrOpen { get; set; }
    public bool IsTourOpen { get; set; }
}
public class MachineSample {
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
    public string DetailTitle { get; set; } = "";
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
}
public class UpdateSample {
    public string Name { get; set; }
    public string Urgency { get; set; }
    public string Category { get; set; }
    public string VersionText { get; set; }
    public string SizeText { get; set; }
    public bool IsNewer { get; set; }
}
public class LogSample {
    public string StampText { get; set; }
    public string DisplayText { get; set; }
    public string Severity { get; set; } = "";
}
'@ -ErrorAction SilentlyContinue

    function Get-Brush([string]$Key) { return $window.FindResource($Key) }

    $selected = [MachineSample]@{
        HostName = 'CAP-9F3KQ2'; OwnerName = 'Priya N'; OwnerTip = 'Priya Nair'
        Subtitle            = 'Yesterday 4:12 PM - 3 updates'
        ChipText = 'Scanning…'; StatusGlyph = [char]0x21BB; ChipVisible = $true
        DotBrush = Get-Brush AccentCyan; ChipForeground = Get-Brush AccentCyan
        ChipBackground = Get-Brush TintSky; ChipBorderBrush = Get-Brush TintSkyBorder
        DetailTitle = 'CAP-9F3KQ2'; DetailIp = '10.24.118.37'; OvUptime = 'up 3 days'
        OvModel = 'Latitude 5440'; OvModelSub = 'Tag 7GZK2M3'; OvModelSubValue = '7GZK2M3'
        OvBattery = '92% health'; OvBatterySub = '78% - on battery'
        OvDisk = '182.5 GB free'; OvDiskSub = 'of 512 GB'; OvBios = '1.24.0'
        HasUpdates = $true; IdentityState = 'Match'
        UpdatesIdentityText = 'Service tag 7GZK2M3 matches the scanned machine.'
        Updates             = [System.Collections.Generic.List[object]]@(
            [UpdateSample]@{ Name = 'Dell BIOS'; Urgency = 'Urgent'; Category = 'BIOS'
                VersionText = '1.24.0 → 1.26.1'; SizeText = '14.2 MB'
            }
            [UpdateSample]@{ Name = 'Intel UHD Graphics 770 Driver'; Urgency = 'Recommended'
                Category = 'Driver'; VersionText = '31.0.101.4502 → 31.0.101.5186'
                SizeText = '428.1 MB'; IsNewer = $true
            }
            [UpdateSample]@{ Name = 'Realtek Audio Driver'; Urgency = 'Optional'; Category = 'Driver'
                VersionText = '6.0.9789.1 → 6.0.9944.1'; SizeText = '62.4 MB'
            }
        )
    }
    $fleet = [System.Collections.Generic.List[object]]@(
        $selected
        [MachineSample]@{
            HostName = 'B4021-LAB'; Subtitle = 'Today 9:04 AM - 4 updates'
            ChipText = 'Completed'; StatusGlyph = [char]0x2713; ChipVisible = $true
            DotBrush = Get-Brush AccentGreen; ChipForeground = Get-Brush AccentGreen
            ChipBackground = Get-Brush TintGreen; ChipBorderBrush = Get-Brush TintGreenBorder
        }
        [MachineSample]@{
            HostName = 'WVD-PROD-07'; OwnerName = 'Marcus W'; OwnerTip = 'Marcus Webb'
            Subtitle = 'Today 8:56 AM - 2 updates'
            ChipText = 'Reboot required'; StatusGlyph = [char]0x26A0; ChipVisible = $true
            DotBrush = Get-Brush AccentYellow; ChipForeground = Get-Brush AccentYellow
            ChipBackground = Get-Brush TintAmber; ChipBorderBrush = Get-Brush TintAmberBorder
        }
        [MachineSample]@{
            HostName = 'LT-8842-EDU'; Subtitle = 'never run'
            DotBrush = Get-Brush BodyTextTertiary
        }
    )
    $window.DataContext = [HomeSample]@{
        DetailMode = 'Machine'; Machines = $fleet; SelectedMachine = $selected
        AppVersion = '2.6.2'; HasAppVersion = $true
    }
    $machinePane.FindName('MachineList').SelectedIndex = 0

    # The live pieces a presenter would drive: the scan bar and the tailed log.
    $bar = $detailPane.FindName('DetailProgress')
    $bar.Visibility = 'Visible'
    $bar.Value = 62
    $lines = [System.Collections.Generic.List[object]]::new()
    # Leading commas: statements inside @() unroll, so bare inner arrays would flatten.
    foreach ($line in @(
            , @('09:12:04  ', 'Connected to CAP-9F3KQ2; DCU 5.4 found.', '')
            , @('09:12:06  ', 'Scan started: checking device updates (3 of 5).', '')
            , @('09:12:31  ', '[Warn] On battery power; BIOS updates defer until AC.', 'Warn')
            , @('09:12:47  ', 'Driver catalog synced; 3 updates apply to this system.', 'Success')
        )) {
        $lines.Add([LogSample]@{ StampText = $line[0]; DisplayText = $line[1]; Severity = $line[2] })
    }
    $detailPane.FindName('lstDetailLog').ItemsSource = $lines
}

if ($View -like '*DialogWindow.xaml' -and -not $Main) {
    # A plain POCO: WPF cannot bind to PSCustomObject members, and a static preview needs no INPC.
    Add-Type -TypeDefinition @'
public class DialogSample {
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
'@ -ErrorAction SilentlyContinue
    $sample = [DialogSample]@{
        Title = 'Update Available'; HasTitle = $true
        Message    = 'A newer release is ready to install. DONUT restarts by itself when it finishes.'
        HasMessage = $true
        PrimaryText = 'Update Now'; PrimaryStyle = $window.FindResource('ButtonTintPrimary')
        SecondaryText = 'Not Now'; HasSecondary = $true
        RememberText = 'Update automatically from now on'; HasRemember = $true
        VersionFrom = '2.5.819'; VersionTo = '2.6.1'; HasVersionCard = $true
        ReleaseUrl = 'https://example.invalid'; HasReleaseUrl = $true; ReleaseLinkText = 'Release notes'
    }
    $window.DataContext = $sample
}

$window.Add_KeyDown({ if ($_.Key -eq 'Escape') { $window.Close() } }.GetNewClosure())

if ($Screenshot) {
    # Parked off-screen and rendered from the visual tree, so covering windows cannot leak in.
    $out = $Screenshot
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -20000
    $window.Top = 0
    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
    $window.Add_ContentRendered({
            $w = [int]$window.ActualWidth
            $h = [int]$window.ActualHeight
            $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
                $w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($window)
            $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [System.IO.File]::Create($out)
            try { $enc.Save($fs) } finally { $fs.Dispose() }
            Write-Host "saved $out (${w}x${h})"
            $window.Close()
        }.GetNewClosure())
}

[void]$window.ShowDialog()
