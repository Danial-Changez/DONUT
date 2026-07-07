using namespace Donut.Mvvm

<#
.SYNOPSIS
    View-model backing the shell: the settings overlay and window chrome.

.DESCRIPTION
    The gear binds OpenSettingsCommand; the overlay's backdrop, Esc, and close button
    bind CloseSettingsCommand; the caption buttons bind the window commands.
    MainPresenter remains the composition root/coordinator: the commands call back into
    it for the imperative shell work. IsSettingsOpen gates the overlay's visibility.
#>
class MainViewModel : ObservableObject {
    [bool]   $IsSettingsOpen = $false
    [object] $OpenSettingsCommand
    [object] $CloseSettingsCommand
    [object] $MinimizeCommand
    [object] $MaximizeCommand     # toggles Maximized <-> Normal
    [object] $CloseCommand
}
