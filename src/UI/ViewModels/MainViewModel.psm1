using namespace Donut.Mvvm

<#
.SYNOPSIS
    View-model backing the shell: navigation, rail state, and window chrome.

.DESCRIPTION
    MainWindow's rail buttons bind NavigateCommand (CommandParameter = page name),
    the logo toggle binds ToggleRailCommand, and the caption buttons bind the window
    commands. MainPresenter remains the composition root/coordinator: the commands
    call back into it for the imperative shell work that stays imperative by design -
    lazy page construction (the Config/Logs perf win), the rail width/label
    animations, and the header swap. ActivePage/IsRailCollapsed expose the state.
#>
class MainViewModel : ObservableObject {
    [string] $ActivePage = ''
    [bool]   $IsRailCollapsed = $false
    [object] $NavigateCommand     # RelayCommand, param: 'Home' | 'Config' | 'Logs'
    [object] $ToggleRailCommand
    [object] $MinimizeCommand
    [object] $MaximizeCommand     # toggles Maximized <-> Normal
    [object] $CloseCommand
}
