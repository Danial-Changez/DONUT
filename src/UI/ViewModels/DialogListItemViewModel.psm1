<#
.SYNOPSIS
    Display-ready row for a dialog's item list.

.DESCRIPTION
    One flat collection drives every dialog list: DialogPresenter normalizes whatever a
    caller passes - a bare string, or any object carrying Left/Right - into these, so the
    single DataTemplate can align a value column against a label column. Hazard marks a
    row the operator should look twice at (a user profile among the folders a clear would
    empty); the template leads that row with the lucide triangle-alert and turns its text
    yellow, and leaves every other row alone.

.NOTES
    A class rather than a pscustomobject on purpose: a pscustomobject exposes no CLR
    property, so WPF reaches it only through ICustomTypeDescriptor and Hazard cannot
    drive a Visibility trigger the way a real bool does. Values are set once per dialog
    and never change while the modal is up, so no INotifyPropertyChanged is needed.
    WPF-free, so the mapping is unit-tested headless.
#>
class DialogListItemViewModel {
    [string] $Left = ''       # the value, e.g. a path or a machine name
    [string] $Right = ''      # the aligned trailing column, e.g. "(4.9 GB)", or ''
    [bool]   $Hazard = $false # marks the row for the warning glyph and yellow text

    DialogListItemViewModel([string]$left, [string]$right, [bool]$hazard) {
        $this.Left = $left
        $this.Right = $right
        $this.Hazard = $hazard
    }
}
