# InventoryPresenter's class graph pulls in WPF controls and the Donut.Mvvm base
# types, so load those assemblies before the tests' `using module` graph parses.
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

if (-not ('Donut.Mvvm.ObservableObject' -as [type])) {
    Add-Type -Path @(
        "$PSScriptRoot\..\..\src\Launcher\ObservableObject.cs",
        "$PSScriptRoot\..\..\src\Launcher\RelayCommand.cs"
    ) -ReferencedAssemblies System.ObjectModel, WindowsBase, PresentationCore
}

. "$PSScriptRoot\InventoryPresenter.Tests.Internal.ps1"
