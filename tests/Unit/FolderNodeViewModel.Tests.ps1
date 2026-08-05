# The WPF-free ObservableObject base must compile before the `using module` graph parses.
if (-not ('Donut.Mvvm.ObservableObject' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\..\src\Launcher\ObservableObject.cs" -ReferencedAssemblies System.ObjectModel
}

. "$PSScriptRoot\FolderNodeViewModel.Tests.Internal.ps1"
