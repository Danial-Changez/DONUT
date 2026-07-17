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

# WPF needs pwsh 7+ on an STA thread (see .NOTES); relaunch under pwsh -Sta
# instead of failing later in the XAML load.
if ($PSVersionTable.PSVersion.Major -lt 7 -or
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Error "DONUT requires PowerShell 7+ (pwsh). Install it from https://aka.ms/powershell"
        exit 1
    }
    & $pwsh.Source -NoProfile -Sta -ExecutionPolicy Bypass -File $PSCommandPath @args
    exit $LASTEXITCODE
}

# Assemblies are resolved at runtime (not parse time), so load them before
# dot-sourcing the app graph.
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Security

# MVVM base types: compiled into Donut.Launcher in production (guard skips); on the
# `pwsh -Sta` dev path compile them here, before the class graph parses against them.
if (-not ('Donut.Mvvm.ObservableObject' -as [type])) {
    # Reference the loaded WPF assemblies by path so versions match; the simple name
    # can resolve to an older reference assembly that conflicts with PresentationCore.
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies()
    $refs = foreach ($name in 'System.ObjectModel', 'WindowsBase', 'PresentationCore') {
        $asm = $loaded | Where-Object { $_.GetName().Name -eq $name } | Select-Object -First 1
        if ($asm -and $asm.Location) { $asm.Location } else { $name }
    }
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

. "$PSScriptRoot\Scripts\DonutApp.ps1"
