using namespace Donut.Mvvm

<#
.SYNOPSIS
    View-model backing the GitHub device-flow login window's content.

.DESCRIPTION
    LoginWindow binds the output panel (verification URI + user code / status) to
    OutputText and the GitHub button to AuthCommand. LoginPresenter remains the
    coordinator: it owns the device-flow poll timer, the DeviceFlowDecision handling,
    and the modal lifecycle, and pushes each status update here via SetOutput.
#>
class LoginViewModel : ObservableObject {
    [string] $OutputText = ''
    [object] $AuthCommand   # RelayCommand -> LoginPresenter.StartAuthFlow

    [void] SetOutput([string]$text) {
        $this.Set('OutputText', $text)
    }
}
