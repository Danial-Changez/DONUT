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

    The software list (the person's application deployments) shares the device list's
    slot behind a toggle: its lookup runs in parallel with the person lookup and lands
    via ApplySoftware, so neither ever waits on the other.
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
    [bool]   $IsSoftwareShown = $false
    [string] $SoftwareStatusText = ''     # loading / error / empty message for the software view
    [string] $ListLabel = 'DEVICES'
    [string] $ToggleLabel = 'Software'
    [object[]] $Deployments = @()
    [object] $ToggleSoftwareCommand       # RelayCommand: swap the list slot (self-wired)

    PersonLensViewModel() {
        $this.Devices = [ObservableCollection[object]]::new()
        $self = $this
        # Pure UI state, so the toggle self-wires like a device row's reveal.
        $toggle = { param($p)
            $shown = -not $self.IsSoftwareShown
            $self.Set('IsSoftwareShown', $shown)
            $self.Set('ListLabel', $(if ($shown) { 'SOFTWARE' } else { 'DEVICES' }))
            $self.Set('ToggleLabel', $(if ($shown) { 'Devices' } else { 'Software' }))
        }.GetNewClosure()
        $this.ToggleSoftwareCommand = [RelayCommand]::new([System.Action[object]]$toggle)
    }

    # Devices newest-seen first: parsed LastLogon descending, blanks last.
    hidden [object[]] SortByLastSeen([LensDevice[]]$devices) {
        return @($devices | Sort-Object -Descending -Stable -Property @{
                Expression = {
                    $at = [datetime]::MinValue
                    [void][datetime]::TryParse([string]$_.LastLogon,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)
                    $at
                }
            })
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
        # The software view resets too, since its parallel lookup restarts with the pick.
        $this.Set('Deployments', @())
        $this.Set('IsSoftwareShown', $false)
        $this.Set('SoftwareStatusText', 'Looking up software…')
        $this.Set('ListLabel', 'DEVICES')
        $this.Set('ToggleLabel', 'Software')
    }

    # Maps the parallel software lookup onto the VM (rows, or the reason there are none).
    [void] ApplySoftware([object[]]$rows, [string]$reason) {
        $this.Set('Deployments', @($rows))
        $status =
        if (@($rows).Count -gt 0) { '' }
        elseif ($reason) { $reason }
        else { 'No application deployments.' }
        $this.Set('SoftwareStatusText', $status)
    }

    # Applies a mid-flight partial bundle (1 = directory facts, 2 = name-only device rows)
    # so they paint early. The loading state stays on until Apply.
    [void] ApplyPartial([PersonLens]$lens) {
        if ($null -eq $lens -or -not $this.IsLoading) { return }
        if ($lens.Upn) { $this.Set('Upn', $lens.Upn) }
        if ($lens.Sam) { $this.Set('Sam', $lens.Sam) }
        if ($lens.DisplayName) { $this.Set('DisplayName', $lens.DisplayName) }
        if ($lens.Email) { $this.Set('Email', $lens.Email) }
        if ($lens.Manager) { $this.Set('Manager', $lens.Manager) }
        if ($lens.Office) { $this.Set('Office', $lens.Office) }
        if ($lens.Devices.Count -gt 0) {
            $this.Devices.Clear()
            $sorted = $this.SortByLastSeen($lens.Devices)
            foreach ($d in $sorted) { $this.Devices.Add([LensDeviceViewModel]::new($d)) }
            $this.Set('HasDevices', $true)
            $this.Set('StatusText', 'Loading device details…')
        }
        else {
            $this.Set('StatusText', 'Looking up devices…')
        }
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
        $sorted = $this.SortByLastSeen($lens.Devices)
        foreach ($d in $sorted) { $this.Devices.Add([LensDeviceViewModel]::new($d)) }
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
