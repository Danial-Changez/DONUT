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

    The detail pane is mode-switched by DetailMode ('Empty' | 'Machine' | 'Person'):
    selecting a machine shows machine detail; picking a user in the AD finder shows the
    Lens (SelectedPerson). SetSelected / SetPerson keep the two mutually exclusive.

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

    # Detail-pane mode + the Lens shown in Person mode (a PersonLensViewModel; typed
    # [object] so this VM stays decoupled from the Lens graph - the presenter sets it).
    [string] $DetailMode = 'Empty'
    [object] $SelectedPerson

    HomeViewModel() {
        $this.Machines = [ObservableCollection[HostViewModel]]::new()
        $this.SearchResults = [ObservableCollection[object]]::new()
    }

    # Programmatic selection: raises so the bound ListBox.SelectedItem follows (which then
    # fires SelectionChanged, so the presenter's select side-effects run uniformly).
    # Selecting a machine switches the detail pane to Machine mode and drops any open Lens.
    [void] SetSelected([HostViewModel]$vm) {
        $this.Set('SelectedMachine', $vm)
        if ($null -ne $vm) {
            $this.Set('SelectedPerson', $null)
            $this.Set('DetailMode', 'Machine')
        }
        elseif ($this.DetailMode -eq 'Machine') {
            $this.Set('DetailMode', 'Empty')
        }
    }

    # Picking a user shows the Lens in the detail pane (leaves the machine list untouched).
    [void] SetPerson([object]$vm) {
        $this.Set('SelectedPerson', $vm)
        $this.Set('DetailMode', $(if ($null -ne $vm) { 'Person' } else { 'Empty' }))
    }
}
