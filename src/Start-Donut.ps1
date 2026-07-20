<#
.SYNOPSIS
    Entry point that loads the WPF assemblies and launches the DONUT app.

.DESCRIPTION
    Loads the PresentationFramework / WinForms / Security assemblies the WPF UI
    needs at runtime, then dot-sources DonutApp.ps1, which builds the config,
    logger and runspace pool and shows the main window.

.NOTES
    Hosted by Donut.Launcher.exe in production. Must run under PowerShell 7+ in
    STA — Windows PowerShell 5.1 fails to load the XAML. The guard below covers
    hosts that don't qualify (e.g. right-click "Run with PowerShell" picks up
    5.1, and some hosts start MTA) by relaunching itself via pwsh -Sta, so the
    script can be started from any shell or Explorer without touching the exe.
#>

# -Tray starts hidden in the system tray (used by the autostart scheduled task).
param([switch]$Tray)

# WPF needs pwsh 7+ on an STA thread (see .NOTES); relaunch under pwsh -Sta
# instead of failing later in the XAML load.
if ($PSVersionTable.PSVersion.Major -lt 7 -or
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Error "DONUT requires PowerShell 7+ (pwsh). Install it from https://aka.ms/powershell"
        exit 1
    }
    # The param() block empties $args, so forward the switch explicitly.
    $childArgs = @('-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Tray) { $childArgs += '-Tray' }
    & $pwsh.Source @childArgs
    exit $LASTEXITCODE
}

# Single instance (dev path only; the launcher owns it in prod via the injected
# $global:SingleInstanceOwned). Acquired below the guard so its parent can't clash.
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

# Resolve a runtime assembly to its on-disk path via a type it defines.
#
# Passing a bare simple name (e.g. 'WindowsBase') to Add-Type -ReferencedAssemblies
# lets the C# compiler bind it to the 4.0.0.0 .NET Framework *reference* facade.
# PresentationCore (resolved by path to the real runtime, 10.x on .NET 10) then pulls
# in WindowsBase 10.x, and the compile dies with CS1705 ("WindowsBase 10.0.0.0 ... has
# a higher version than referenced assembly WindowsBase 4.0.0.0"). Searching the loaded
# assemblies by name is timing-dependent (WindowsBase loads lazily, so it may be absent
# when we look and fall back to the bare name) — that mismatch surfaces only on some
# runtimes. Anchoring on a type forces the correct runtime assembly to load and yields
# its actual path, so the reference versions always match.
function Get-RuntimeAssemblyPath([type]$TypeInAssembly) {
    $location = $TypeInAssembly.Assembly.Location
    if ([string]::IsNullOrEmpty($location)) {
        $name = $TypeInAssembly.Assembly.GetName().Name
        throw "Cannot resolve a file path for assembly '$name' (needed for the dev-path Add-Type)."
    }
    return $location
}

# Everything that loads the WPF assemblies, compiles the dev-path C# helpers and
# dot-sources the module graph runs behind this handler. A failed Add-Type compile
# (e.g. the CS1705 above) or a parse error in the using-module graph would otherwise
# kill the process silently — on the relaunched `pwsh -Sta` path the window just
# closes with no trace. Capture it to a crash log and surface it instead. (DonutApp.ps1
# has its own try/catch for *runtime* errors after a clean parse; this covers the
# load/compile/parse failures it can't reach.)
try {
    # Assemblies are resolved at runtime (not parse time), so load them before
    # dot-sourcing the app graph.
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Security

    # MVVM base types: compiled into Donut.Launcher in production (guard skips); on the
    # `pwsh -Sta` dev path compile them here, before the class graph parses against them.
    if (-not ('Donut.Mvvm.ObservableObject' -as [type])) {
        # Anchor each reference on a type it defines so versions match the loaded runtime
        # (see Get-RuntimeAssemblyPath): ICommand -> System.ObjectModel, DependencyObject ->
        # WindowsBase, HwndSource -> PresentationCore.
        $refs = @(
            Get-RuntimeAssemblyPath ([System.Windows.Input.ICommand])
            Get-RuntimeAssemblyPath ([System.Windows.DependencyObject])
            Get-RuntimeAssemblyPath ([System.Windows.Interop.HwndSource])
        )
        Add-Type -Path @(
            "$PSScriptRoot\Launcher\ObservableObject.cs",
            "$PSScriptRoot\Launcher\RelayCommand.cs",
            "$PSScriptRoot\Launcher\WindowChromeHelper.cs"
        ) -ReferencedAssemblies $refs
    }

    # QR helper (Donut.Qr.QrCode): wraps bundled QRCoder (MIT) for the BitLocker QR overlay.
    # Prod compiles it into Donut.Launcher (guard skips); the dev path loads + compiles it here.
    if (-not ('Donut.Qr.QrCode' -as [type])) {
        $qrDll = Join-Path $PSScriptRoot 'Lib\QRCoder.dll'
        if (Test-Path $qrDll) {
            Add-Type -Path $qrDll
            # System.Drawing.Primitives: GetGraphic's Color overloads need it to resolve;
            # nowarn 1701/1702: QRCoder targets .NET 6, Add-Type escalates the mismatch.
            Add-Type -Path "$PSScriptRoot\Launcher\QrCode.cs" `
                -ReferencedAssemblies @($qrDll, 'System.Drawing.Primitives') `
                -CompilerOptions '/nowarn:1701,1702'
        }
    }

    # Global-hotkey interop (Donut.Interop.HotkeyManager): a RegisterHotKey wrapper. Prod
    # compiles it into Donut.Launcher (guard skips); the dev path compiles it here.
    if (-not ('Donut.Interop.HotkeyManager' -as [type])) {
        # Same version-safe resolution as the MVVM block above: DependencyObject ->
        # WindowsBase, HwndSource -> PresentationCore.
        $refs = @(
            Get-RuntimeAssemblyPath ([System.Windows.DependencyObject])
            Get-RuntimeAssemblyPath ([System.Windows.Interop.HwndSource])
        )
        Add-Type -Path "$PSScriptRoot\Launcher\HotkeyManager.cs" -ReferencedAssemblies $refs
    }

    . "$PSScriptRoot\Scripts\DonutApp.ps1"
}
catch {
    # Snapshot the error + host details up front (labels kept short so the record
    # lines stay within the column limit).
    $errMsg = $_.Exception.Message
    $ps = $PSVersionTable.PSVersion
    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()

    # Write a crash record to %LOCALAPPDATA%\DONUT\logs (created here in case we failed
    # before ConfigManager ran) so a silent startup death always leaves a trace.
    $crashDir = Join-Path $env:LOCALAPPDATA 'DONUT\logs'
    try {
        if (-not (Test-Path $crashDir)) {
            New-Item -ItemType Directory -Path $crashDir -Force | Out-Null
        }
    }
    catch { }
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

    # Console output (visible when launched from a terminal).
    Write-Error "DONUT failed to start: $errMsg`nCrash log: $crashFile"

    # GUI output (visible when launched from Explorer); skip the modal on the
    # unattended tray/autostart path so a headless failure can't hang on a dialog.
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
