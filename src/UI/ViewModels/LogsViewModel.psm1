using namespace Donut.Mvvm
using namespace System.Collections.ObjectModel
using module ".\LogTabViewModel.psm1"

<#
.SYNOPSIS
    View-model backing the Logs page: the tab collection + the clear command.

.DESCRIPTION
    LogsView's TabControl binds ItemsSource -> Tabs (LogTabViewModels) and the Clear
    button binds ClearCommand. LogsPresenter is the coordinator: it owns the file I/O
    (enumerate, tail-read, full-read, delete) and repopulates Tabs; mutate Tabs on the
    UI thread only.
#>
class LogsViewModel : ObservableObject {
    [ObservableCollection[object]] $Tabs
    [object] $ClearCommand   # RelayCommand -> LogsPresenter.ClearLogs

    LogsViewModel() {
        $this.Tabs = [ObservableCollection[object]]::new()
    }
}
