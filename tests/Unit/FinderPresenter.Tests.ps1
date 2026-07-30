# FinderPresenter's class graph pulls in WPF (DispatcherTimer) and the Donut.Mvvm base
# types, so load those assemblies before the tests' `using module` graph parses.
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# Per-type guards: ObservableObject (WPF-free) may already be loaded by a lighter VM test, so
# compile each independently rather than skipping RelayCommand when ObservableObject exists.
if (-not ('Donut.Mvvm.ObservableObject' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\..\src\Launcher\ObservableObject.cs" -ReferencedAssemblies System.ObjectModel
}
if (-not ('Donut.Mvvm.RelayCommand' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\..\src\Launcher\RelayCommand.cs" -ReferencedAssemblies System.ObjectModel, WindowsBase, PresentationCore
}

. "$PSScriptRoot\FinderPresenter.Tests.Internal.ps1"
