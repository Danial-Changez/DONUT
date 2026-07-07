using namespace Donut.Mvvm

<#
.SYNOPSIS
    View-model backing the shell: navigation, rail state, and window chrome.

.DESCRIPTION
    MainWindow's rail buttons bind NavigateCommand (CommandParameter = page name),
    the logo toggle binds ToggleRailCommand, the gear binds OpenSettingsCommand, and
    the caption buttons bind the window commands. MainPresenter remains the composition
    root/coordinator: the commands call back into it for the imperative shell work -
    lazy page construction (the Config perf win), the rail animations, the header swap,
    and toggling the settings overlay. IsSettingsOpen gates that overlay's visibility.
#>
class MainViewModel : ObservableObject {
    [string] $ActivePage = ''
    [bool]   $IsRailCollapsed = $false
    [bool]   $IsSettingsOpen = $false
    [object] $NavigateCommand     # RelayCommand, param: 'Home' | 'Config'
    [object] $ToggleRailCommand
    [object] $OpenSettingsCommand
    [object] $CloseSettingsCommand
    [object] $MinimizeCommand
    [object] $MaximizeCommand     # toggles Maximized <-> Normal
    [object] $CloseCommand
}
