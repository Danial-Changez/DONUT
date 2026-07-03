using namespace Donut.Mvvm
using namespace System.Collections.ObjectModel
using module ".\HostViewModel.psm1"

<#
.SYNOPSIS
    View-model backing the Home screen: machine list, selection, and finder rows.

.DESCRIPTION
    Holds the bindable machine collection and the selected machine. The ListBox in
    HomeView binds ItemsSource -> Machines and SelectedItem -> SelectedMachine (TwoWay);
    the detail pane and overview strip bind to SelectedMachine.*. HomePresenter is the
    coordinator: it owns this VM, adds/updates HostViewModels, and reacts to selection.

.NOTES
    Mutate Machines only on the UI thread (the presenter's pump already runs there).
    SetSelected raises PropertyChanged so a programmatic select updates the ListBox.
#>
class HomeViewModel : ObservableObject {
    [ObservableCollection[HostViewModel]] $Machines
    [HostViewModel] $SelectedMachine

    # AD finder dropdown rows (SearchRowViewModel headers + results, one flat list).
    # The popup's ItemsControl binds ItemsSource here; the presenter repopulates it
    # per render (UI thread only, like Machines).
    [ObservableCollection[object]] $SearchResults

    HomeViewModel() {
        $this.Machines = [ObservableCollection[HostViewModel]]::new()
        $this.SearchResults = [ObservableCollection[object]]::new()
    }

    # Programmatic selection: raises so the bound ListBox.SelectedItem follows (which then
    # fires SelectionChanged, so the presenter's select side-effects run uniformly).
    [void] SetSelected([HostViewModel]$vm) {
        $this.Set('SelectedMachine', $vm)
    }
}
