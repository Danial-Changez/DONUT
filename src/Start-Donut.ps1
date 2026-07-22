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

# Resolve an already-loaded assembly to its on-disk path by simple name.
#
# Add-Type -ReferencedAssemblies must get the *runtime* WPF assemblies by path. Passing
# a bare simple name (e.g. 'WindowsBase') instead lets the C# compiler bind it to the
# 4.0.0.0 .NET Framework reference facade; PresentationCore then pulls in the real 10.x
# runtime WindowsBase and the compile dies with CS1705 ("WindowsBase 10.0.0.0 ... has a
# higher version than referenced assembly WindowsBase 4.0.0.0"). The caller loads these
# assemblies explicitly first (PresentationFramework loads them lazily, so they may not
# be present otherwise), so this lookup finds them; if one is genuinely missing we throw
# rather than fall back to the bare name and reintroduce the mismatch.
function Get-RuntimeAssemblyPath([string]$SimpleName) {
    $asm = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq $SimpleName -and $_.Location } |
        Select-Object -First 1
    if (-not $asm) {
        throw "Assembly '$SimpleName' is not loaded with a file path (dev-path Add-Type)."
    }
    return $asm.Location
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
    # dot-sourcing the app graph. PresentationCore and WindowsBase are dependencies of
    # PresentationFramework that load lazily; load them explicitly so they're present
    # (with a real runtime path) when Get-RuntimeAssemblyPath resolves references below.
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Security

    # C# helper types the class graph parses against: compiled into Donut.Launcher in
    # production, compiled here on the `pwsh -Sta` dev path. Each file is guarded by
    # ITS OWN type and compiled individually. Guarding them all on ObservableObject
    # alone crashed startup: any session where the MVVM types are already resident
    # but a newer helper is not - a console that ran an older tree, or an installed
    # launcher (which hosts this very script) built before the helper existed -
    # skipped the whole block, and the graph parse died on the first reference
    # ("Unable to find type [WindowChromeHelper]"). Per-file guards compile exactly
    # what is missing and never recompile a resident type, which would make its
    # name ambiguous across assemblies.
    #
    # Reference the loaded runtime assemblies by path so versions match (see
    # Get-RuntimeAssemblyPath). System.ObjectModel defines ICommand /
    # INotifyPropertyChanged; WindowsBase + PresentationCore back the interop helpers.
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
        # Same version-safe resolution as the MVVM block above.
        $refs = @(
            Get-RuntimeAssemblyPath 'WindowsBase'
            Get-RuntimeAssemblyPath 'PresentationCore'
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
