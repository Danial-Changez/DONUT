# FolderNodeViewModel derives from the Donut.Mvvm ObservableObject base (a WPF-free C# type),
# so compile that before the tests' `using module` graph parses. It does NOT need RelayCommand
# (which pulls in WPF), so this test runs off-Windows too. Per-type guard so it composes with
# the presenter tests regardless of which loads first.
if (-not ('Donut.Mvvm.ObservableObject' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\..\src\Launcher\ObservableObject.cs" -ReferencedAssemblies System.ObjectModel
}

. "$PSScriptRoot\FolderNodeViewModel.Tests.Internal.ps1"
