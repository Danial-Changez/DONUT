using namespace Donut.Mvvm
using namespace System.Collections.ObjectModel
using module "..\..\Models\PersonLens.psm1"
using module ".\LensDeviceViewModel.psm1"

<#
.SYNOPSIS
    View-model backing the user Lens shown in the Home detail pane.

.DESCRIPTION
    Holds a person's directory facts (UPN/SAM/email/manager/office) plus their devices
    (LensDeviceViewModels). HomePresenter shows this in the detail pane when a user is
    picked in the AD finder: SetLoading while the de-elevated lookup runs, then Apply the
    resolved PersonLens. Inherits ObservableObject so the pane updates live; the device
    collection is mutated on the UI thread only (the presenter's poll runs there).
#>
class PersonLensViewModel : ObservableObject {
    [string] $Upn = ''
    [string] $Sam = ''
    [string] $DisplayName = ''
    [string] $Email = ''
    [string] $Manager = ''
    [string] $Office = ''
    [bool]   $IsLoading = $false
    [bool]   $HasError = $false
    [string] $StatusText = ''             # loading / error message
    [bool]   $HasDevices = $false
    [ObservableCollection[object]] $Devices

    PersonLensViewModel() {
        $this.Devices = [ObservableCollection[object]]::new()
    }

    # Loading state while the de-elevated lookup runs (shows the picked name immediately).
    [void] SetLoading([string]$who) {
        $this.Set('DisplayName', $who)
        $this.Set('Upn', '')
        $this.Set('IsLoading', $true)
        $this.Set('HasError', $false)
        $this.Set('StatusText', 'Looking up directory + SCCM…')
        $this.Devices.Clear()
        $this.Set('HasDevices', $false)
    }

    # Maps a resolved PersonLens onto the VM. AddCommand per device is wired by the caller
    # afterward (it needs the presenter to add the WSID to the machine list).
    [void] Apply([PersonLens]$lens) {
        $this.Set('IsLoading', $false)
        if ($null -eq $lens) { return }
        $this.Set('Upn', $lens.Upn)
        $this.Set('Sam', $lens.Sam)
        $this.Set('DisplayName', $(if ($lens.DisplayName) { $lens.DisplayName } else { $lens.Upn }))
        $this.Set('Email', $lens.Email)
        $this.Set('Manager', $lens.Manager)
        $this.Set('Office', $lens.Office)

        $this.Devices.Clear()
        foreach ($d in $lens.Devices) { $this.Devices.Add([LensDeviceViewModel]::new($d)) }
        $this.Set('HasDevices', ($this.Devices.Count -gt 0))

        if ($lens.Errors.Count -gt 0) {
            $this.Set('HasError', $true)
            $this.Set('StatusText', ($lens.Errors -join '  |  '))
        }
        else {
            $this.Set('HasError', $false)
            $this.Set('StatusText', '')
        }
    }
}
