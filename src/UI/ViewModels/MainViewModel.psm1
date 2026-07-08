using namespace Donut.Mvvm

<#
.SYNOPSIS
    View-model backing the shell: the settings overlay and window chrome.

.DESCRIPTION
    The gear binds OpenSettingsCommand; the overlay's backdrop, Esc, and close button
    bind CloseSettingsCommand; the caption buttons bind the window commands.
    MainPresenter remains the composition root/coordinator: the commands call back into
    it for the imperative shell work. IsSettingsOpen gates the overlay's visibility.

    The QR overlay mirrors the settings overlay: IsQrOpen gates a dim + centered card
    that shows QrImage (an in-memory QR of a BitLocker recovery key) under QrCaption;
    its backdrop, Esc, and close button bind CloseQrCommand. MainPresenter.ShowQr fills
    QrImage/QrCaption and flips IsQrOpen when a Lens device's QR button is clicked.
#>
class MainViewModel : ObservableObject {
    [bool]   $IsSettingsOpen = $false
    [object] $OpenSettingsCommand
    [object] $CloseSettingsCommand
    [object] $MinimizeCommand
    [object] $MaximizeCommand     # toggles Maximized <-> Normal
    [object] $CloseCommand

    # QR overlay: a BitLocker recovery key rendered to an in-memory image (never disk).
    [bool]   $IsQrOpen = $false
    [object] $QrImage             # ImageSource; bound to the overlay's Image.Source
    [string] $QrCaption = ''      # e.g. "BitLocker recovery key - WSID123"
    [object] $CloseQrCommand
}
