<#
.SYNOPSIS
    Entry point that loads the WPF assemblies and launches the DONUT app.

.DESCRIPTION
    Loads the PresentationFramework / WinForms / Security assemblies the WPF UI
    needs at runtime, then dot-sources DonutApp.ps1, which builds the config,
    logger and runspace pool and shows the main window.

.PARAMETER Tray
    Start hidden in the system tray instead of showing the main window.

.PARAMETER DebugLog
    Force verbose logging for this session only, without touching the setting.

.PARAMETER AwaitPid
    Wait out the instance being replaced before starting (the launcher's
    --await-pid twin, used by the elevation relaunch).

.NOTES
    Hosted by Donut.Launcher.exe in production. Must run under PowerShell 7+ in
    STA; Windows PowerShell 5.1 fails to load the XAML. The guard below covers
    hosts that don't qualify (e.g. right-click "Run with PowerShell" picks up
    5.1, and some hosts start MTA) by relaunching itself via pwsh -Sta, so the
    script can be started from any shell or Explorer without touching the exe.

    There is no data-root redirect here any more. DONUT's data lives at a single
    machine-wide root (DonutPaths), so every instance reads the same config, token
    and logs whatever account it runs as.
#>

param([switch]$Tray, [switch]$DebugLog, [int]$AwaitPid = 0)

# WPF needs pwsh 7+ on an STA thread, so relaunch rather than fail in the XAML load.
if ($PSVersionTable.PSVersion.Major -lt 7 -or
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Error "DONUT requires PowerShell 7+ (pwsh). Install it from https://aka.ms/powershell"
        exit 1
    }
    # The param() block empties $args, so forward the switches explicitly.
    $childArgs = @('-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Tray) { $childArgs += '-Tray' }
    if ($DebugLog) { $childArgs += '-DebugLog' }
    if ($AwaitPid -gt 0) { $childArgs += @('-AwaitPid', $AwaitPid) }
    & $pwsh.Source @childArgs
    exit $LASTEXITCODE
}

# The mutex below is Local\-scoped, so per-session and not per-token.
if ($AwaitPid -gt 0) {
    $predecessor = Get-Process -Id $AwaitPid -ErrorAction SilentlyContinue
    if ($predecessor) { $predecessor | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue }
}

# Dev path only, and acquired below the guard so the relaunching parent cannot clash.
if (-not $global:SingleInstanceOwned) {
    $createdNew = $false
    $global:DonutInstanceMutex = [System.Threading.Mutex]::new(
        $true, 'Local\DONUT.SingleInstance', [ref]$createdNew)
    if (-not $createdNew) {
        # Another instance is running: ask it to surface its window, then exit quietly.
        try {
            $evt = [System.Threading.EventWaitHandle]::OpenExisting('Local\DONUT.ShowRequest')
            [void]$evt.Set()
            $evt.Dispose()
        }
        catch { }
        exit 0
    }
}

# Read by DonutApp.ps1 for the hidden-start decision on the dev path.
$global:TrayStart = [bool]$Tray
# Session-only debug override, read by DonutApp.ps1 (and the settings side-effect).
$global:DebugLogStart = [bool]$DebugLog

# Resolves a loaded assembly to its on-disk path: Add-Type references must use the
# runtime WPF paths or the compiler binds 4.0 facades and dies with CS1705.
function Get-RuntimeAssemblyPath([string]$SimpleName) {
    $asm = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq $SimpleName -and $_.Location } |
        Select-Object -First 1
    if (-not $asm) {
        throw "Assembly '$SimpleName' is not loaded with a file path (dev-path Add-Type)."
    }
    return $asm.Location
}

# Load, compile, and parse failures die silently otherwise, so crash-log them.
try {
    # They load lazily, so Get-RuntimeAssemblyPath needs them resolved first.
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Security

    # One guard per file: a shared guard once skipped a helper and killed the parse.
    $refs = @(
        Get-RuntimeAssemblyPath 'System.ObjectModel'
        Get-RuntimeAssemblyPath 'WindowsBase'
        Get-RuntimeAssemblyPath 'PresentationCore'
    )
    if (-not ('Donut.Mvvm.ObservableObject' -as [type])) {
        Add-Type -Path "$PSScriptRoot\Launcher\ObservableObject.cs" -ReferencedAssemblies $refs
    }
    if (-not ('Donut.Mvvm.RelayCommand' -as [type])) {
        Add-Type -Path "$PSScriptRoot\Launcher\RelayCommand.cs" -ReferencedAssemblies $refs
    }
    if (-not ('Donut.Interop.WindowChromeHelper' -as [type])) {
        Add-Type -Path "$PSScriptRoot\Launcher\WindowChromeHelper.cs" -ReferencedAssemblies $refs
    }

    # Prod compiles this into Donut.Launcher, and the dev path compiles it here.
    if (-not ('Donut.Qr.QrCode' -as [type])) {
        $qrDll = Join-Path $PSScriptRoot 'Lib\QRCoder.dll'
        if (Test-Path $qrDll) {
            Add-Type -Path $qrDll
            # Primitives resolves the Color overloads, and nowarn covers QRCoder's .NET 6.
            Add-Type -Path "$PSScriptRoot\Launcher\QrCode.cs" `
                -ReferencedAssemblies @($qrDll, 'System.Drawing.Primitives') `
                -CompilerOptions '/nowarn:1701,1702'
        }
    }

    # A RegisterHotKey wrapper. Prod compiles it into Donut.Launcher, the dev path here.
    if (-not ('Donut.Interop.HotkeyManager' -as [type])) {
        # Same version-safe resolution as the MVVM block above.
        $refs = @(
            Get-RuntimeAssemblyPath 'WindowsBase'
            Get-RuntimeAssemblyPath 'PresentationCore'
        )
        Add-Type -Path "$PSScriptRoot\Launcher\HotkeyManager.cs" -ReferencedAssemblies $refs
    }

    # The one WinForms surface WPF styles cannot reach. Prod compiles it into the launcher.
    if (-not ('Donut.Interop.TrayTheme' -as [type])) {
        Add-Type -AssemblyName System.Windows.Forms
        # Facades load lazily, so touch one type from each for the path resolution below.
        [void][System.Drawing.Color]
        [void][System.ComponentModel.CancelEventArgs]
        [void][System.ComponentModel.CancelEventHandler]
        [void][System.ComponentModel.Component]
        $refs = @(
            Get-RuntimeAssemblyPath 'System.Windows.Forms'
            Get-RuntimeAssemblyPath 'System.Drawing.Primitives'
            Get-RuntimeAssemblyPath 'System.ComponentModel.Primitives'
            Get-RuntimeAssemblyPath 'System.ComponentModel.TypeConverter'
            Get-RuntimeAssemblyPath 'System.ComponentModel'
        )
        Add-Type -Path "$PSScriptRoot\Launcher\TrayTheme.cs" -ReferencedAssemblies $refs
    }

    . "$PSScriptRoot\Scripts\DonutApp.ps1"
}
catch {
    # Snapshot the error and host details before anything else can overwrite $_.
    $errMsg = $_.Exception.Message
    $ps = $PSVersionTable.PSVersion
    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()

    # Spelled out rather than via DonutPaths: the module graph may have failed to load.
    $crashDir = Join-Path $env:ProgramData 'DONUT\data\logs'
    try {
        if (-not (Test-Path $crashDir)) {
            New-Item -ItemType Directory -Path $crashDir -Force | Out-Null
        }
    }
    catch {
        Write-Warning "Could not create the crash-log folder '$crashDir': $($_.Exception.Message)"
    }
    $crashFile = Join-Path $crashDir 'startup-crash.log'
    $record = @(
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] DONUT failed to start.",
        "PowerShell : $ps  ($apartment)",
        "Error      : $errMsg",
        "Type       : $($_.Exception.GetType().FullName)",
        "Stack      :",
        $_.ScriptStackTrace,
        ($_ | Out-String),
        ('-' * 78)
    ) -join [Environment]::NewLine
    try { Add-Content -Path $crashFile -Value $record -Encoding UTF8 } catch { }

    Write-Error "DONUT failed to start: $errMsg`nCrash log: $crashFile"

    # Skip the modal on the unattended tray path so a headless failure cannot hang.
    if (-not $Tray) {
        try {
            [System.Windows.Forms.MessageBox]::Show(
                "DONUT failed to start:`n`n$errMsg`n`nDetails written to:`n$crashFile",
                'DONUT - Startup Error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        catch { }
    }
    exit 1
}
