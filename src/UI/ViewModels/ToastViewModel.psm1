using namespace Donut.Mvvm
using namespace System.Windows.Media

<#
.SYNOPSIS
    One toast card in the top-right overlay.

.DESCRIPTION
    The toastHost ItemsControl renders these via its DataTemplate: an accent bar and
    title, an optional message line, and a click-to-dismiss command. IsClosing drives
    the slide+fade exit animation (a DataTrigger storyboard); ToastService flips it
    and removes the item once the animation has played. Values are set once at
    creation except IsClosing.
#>
class ToastViewModel : ObservableObject {
    [string] $Title = ''
    [string] $Message = ''
    [bool]   $HasMessage = $false
    [Brush]  $Accent          # bar and title
    [bool]   $IsClosing = $false
    [object] $DismissCommand  # RelayCommand -> ToastService.Dismiss(this)

    ToastViewModel([string]$title, [string]$message, [Brush]$accent) {
        $this.Title = $title
        $this.Message = $message
        $this.HasMessage = -not [string]::IsNullOrWhiteSpace($message)
        $this.Accent = $accent
    }

    # Starts the exit animation (the service removes the item shortly after).
    [void] Close() {
        $this.Set('IsClosing', $true)
    }
}
