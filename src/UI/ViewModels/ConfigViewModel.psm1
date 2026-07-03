using namespace Donut.Mvvm

<#
.SYNOPSIS
    View-model backing the Config page's chrome: the save command.

.DESCRIPTION
    Deliberately thin. The option forms under Config Options/ are DATA-DRIVEN: every
    named control maps 1:1 to a dcu-cli arg key in AppConfig (control Name == arg key),
    and ConfigPresenter's generic binder (PopulateFields/UpdateArgFromControl) IS that
    mapping - hand-writing a property per field on a view-model would restate the same
    key list a third time for zero behaviour gain, and break the "add a control, get a
    setting" convention. So the VM carries the page-level surface (SaveCommand); the
    dynamic form binder stays the presenter's job, and the command combo's
    SelectionChanged remains view navigation.
#>
class ConfigViewModel : ObservableObject {
    [object] $SaveCommand   # RelayCommand -> ConfigPresenter.OnSave
}
