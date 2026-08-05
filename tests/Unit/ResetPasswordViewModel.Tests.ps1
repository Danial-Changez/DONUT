<#
    ResetPasswordViewModel derives from the Donut.Mvvm ObservableObject base (a WPF-free
    C# type), so compile that before the tests' `using module` graph parses. RelayCommand
    is not needed (it pulls in WPF), so this test runs off-Windows too. The per-type guard
    lets it compose with the presenter tests whichever loads first.
#>
if (-not ('Donut.Mvvm.ObservableObject' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\..\src\Launcher\ObservableObject.cs" -ReferencedAssemblies System.ObjectModel
}

. "$PSScriptRoot\ResetPasswordViewModel.Tests.Internal.ps1"
