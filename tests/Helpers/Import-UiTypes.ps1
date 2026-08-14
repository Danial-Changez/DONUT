# Loads WPF and the Donut.Mvvm base types before a UI test file's using-module graph parses.
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# Per-type guards: a lighter VM test may already have loaded ObservableObject on its own.
if (-not ('Donut.Mvvm.ObservableObject' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\..\src\Launcher\ObservableObject.cs" -ReferencedAssemblies System.ObjectModel
}
if (-not ('Donut.Mvvm.RelayCommand' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\..\src\Launcher\RelayCommand.cs" -ReferencedAssemblies System.ObjectModel, WindowsBase, PresentationCore
}
