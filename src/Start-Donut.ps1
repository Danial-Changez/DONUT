<#
.SYNOPSIS
    Entry point that loads the WPF assemblies and launches the DONUT app.

.DESCRIPTION
    Loads the PresentationFramework / WinForms / Security assemblies the WPF UI
    needs at runtime, then dot-sources DonutApp.ps1, which builds the config,
    logger and runspace pool and shows the main window.

.NOTES
    Hosted by Donut.Launcher.exe in production. Must run under PowerShell 7+ in
    STA — Windows PowerShell 5.1 fails to load the XAML.
#>

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

. "$PSScriptRoot\Scripts\DonutApp.ps1"
