<#
.SYNOPSIS
    Entry point that loads the WPF assemblies and launches the DONUT app.

.DESCRIPTION
    Loads the PresentationFramework / WinForms / Security assemblies the WPF UI
    needs at runtime, then dot-sources DonutApp.ps1, which builds the config,
    logger and runspace pool and shows the main window.

.NOTES
    Hosted by Donut.Launcher.exe in production. Must run under PowerShell 7+ in
    STA; Windows PowerShell 5.1 fails to load the XAML. The guard below covers
    hosts that don't qualify (e.g. right-click "Run with PowerShell" picks up
    5.1, and some hosts start MTA) by relaunching itself via pwsh -Sta, so the
    script can be started from any shell or Explorer without touching the exe.

    The SYSTEM data-root redirect exists because an autostarted instance under
    the system profile read a default config (startWithWindows off) and
    unregistered its own task. The settings live under the profile of whoever
    toggled autostart on (over-the-shoulder UAC means the admin account, not the
    console user), so the pointer StartupTaskService pins at register time wins
    over deriving a profile from the token.
#>

# -Tray starts hidden in the system tray (used by the autostart scheduled task).
# -DebugLog forces verbose [DEBUG] logging this session without touching settings.
param([switch]$Tray, [switch]$DebugLog)

# Under a SYSTEM token %LOCALAPPDATA% is the system profile, splitting config/logs
# from the operator's: re-point it before anything reads it (see .NOTES).
if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    $redirected = $false
    $pointerFile = Join-Path $env:ProgramData 'DONUT\dataroot.txt'
    if (Test-Path -LiteralPath $pointerFile) {
        $pinned = [string](Get-Content -LiteralPath $pointerFile -First 1 -ErrorAction SilentlyContinue)
        if ($pinned -and (Test-Path -LiteralPath $pinned.Trim())) {
            $env:LOCALAPPDATA = $pinned.Trim()
            $redirected = $true
        }
    }
    if (-not $redirected) {
        $ownSession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        # No pointer: fall back to the desktop this process is on, then any desktop.
        $explorer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
                Sort-Object { $_.SessionId -ne $ownSession }) | Select-Object -First 1
        $explorerOwner = if ($explorer) {
            Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
        }
        if ($explorerOwner -and $explorerOwner.User) {
            try {
                $ownerSid = ([System.Security.Principal.NTAccount]"$($explorerOwner.Domain)\$($explorerOwner.User)").Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
                $profilePath = (Get-ItemProperty -ErrorAction Stop `
                        -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$ownerSid").ProfileImagePath
                if ($profilePath) { $env:LOCALAPPDATA = Join-Path $profilePath 'AppData\Local' }
            }
            catch {
                Write-Warning "Could not resolve the console user's profile ($($explorerOwner.Domain)\$($explorerOwner.User)): $($_.Exception.Message)"
            }
        }
    }
}

# WPF needs pwsh 7+ on an STA thread (see .NOTES); relaunch under pwsh -Sta
# instead of failing later in the XAML load.
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

# All assembly loads, helper compiles, and the graph dot-source run behind this
# handler: load/compile/parse failures die silently otherwise - crash-log them.
try {
    # Load the WPF set explicitly (they load lazily) so Get-RuntimeAssemblyPath can
    # resolve real runtime paths before the graph dot-sources.
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Security

    # Dev-path C# helpers: each file guarded by its own type and compiled alone -
    # a shared guard once skipped a missing helper and killed the graph parse.
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
