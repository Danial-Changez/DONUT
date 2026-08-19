using namespace Donut.Mvvm

<#
.SYNOPSIS
    Content of one modal dialog (confirmation / alert / update prompt).

.DESCRIPTION
    DialogWindow binds its header, message, item list, and buttons here; the Has*
    flags gate each part's visibility so one window serves all three dialog shapes.
    DialogPresenter (the dialog service) builds a fresh instance per ShowX call and
    wires Primary/SecondaryCommand to set the result and close - values never change
    while the modal is up, so the properties are set once before ShowDialog.
#>
class DialogViewModel : ObservableObject {
    [string] $Title = ''
    [bool]   $HasTitle = $false
    [string] $Message = ''
    [bool]   $HasMessage = $false
    [object] $ListItems = @()
    [bool]   $HasList = $false
    [string] $PrimaryText = 'OK'
    [object] $PrimaryCommand      # RelayCommand: Result = true, close
    [object] $PrimaryStyle        # Style the primary button binds to (accent or destructive)
    [string] $SecondaryText = ''
    [bool]   $HasSecondary = $false
    [object] $SecondaryCommand    # RelayCommand: Result = false, close
    [string] $RememberText = ''
    [bool]   $HasRemember = $false  # opt-in checkbox, off for every existing caller
    [bool]   $Remember = $false     # two-way bound, read by the caller after the modal
    # The update prompt's version card, whose arrow reverses on a rollback.
    [string] $VersionFrom = ''
    [string] $VersionTo = ''
    [bool]   $HasVersionCard = $false
    [string] $ReleaseUrl = ''
    [bool]   $HasReleaseUrl = $false
    [string] $ReleaseLinkText = ''
}
