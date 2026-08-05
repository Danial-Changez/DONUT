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
    [object] $ToggleSettingsCommand   # the configurable shortcut opens and closes the overlay
    [object] $MinimizeCommand
    [object] $MaximizeCommand     # toggles Maximized <-> Normal
    [object] $CloseCommand

    # QR overlay: a secret rendered to an in-memory image, never to disk.
    [bool]   $IsQrOpen = $false
    [object] $QrImage             # ImageSource bound to the overlay's Image.Source
    [string] $QrCaption = ''      # e.g. the BitLocker recovery key caption for a WSID
    [string] $QrHint = ''         # the line under the QR, varying with the payload kind
    [object] $CloseQrCommand

    # Reset-password overlay: IsResetOpen gates it, ResetVm holds the target and form.
    [bool]   $IsResetOpen = $false
    [object] $ResetVm             # ResetPasswordViewModel, set once by MainPresenter
    [object] $CloseResetCommand

    # Guided tour: IsTourOpen gates the overlay and TourPresenter drives step navigation.
    [bool]   $IsTourOpen = $false
    [object] $OpenTourCommand
    [object] $CloseTourCommand
    [object] $OpenDocsCommand     # opens the online documentation in the default browser
}
