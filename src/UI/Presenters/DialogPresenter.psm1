using namespace System.Windows
using namespace Donut.Mvvm
using module '..\..\Services\ResourceService.psm1'
using module '..\ViewModels\DialogViewModel.psm1'

<#
.SYNOPSIS
    Hosts the modal dialog window (confirmation / alert / update prompt).

.DESCRIPTION
    Shows a themed modal DialogWindow for decisions that must block: confirm an
    action (with an optional item list), acknowledge an alert, or approve an
    update/rollback. Returns the user's choice as a bool.

.NOTES
    Event-handler scriptblocks capture $self, since in a WPF handler $this rebinds
    to the sender (the button), not the presenter.
#>
class DialogPresenter {
    [ResourceService]$Resources
    [Window]$Window
    [bool]$Result
    [bool]$IsShowing = $false   # true while a modal is up; the pump defers dialog-opening work

    DialogPresenter([ResourceService]$resources) {
        $this.Resources = $resources
        $this.Result = $false
    }

    hidden [void] Initialize() {
        $xamlPath = Join-Path $this.Resources.SourceRoot "UI\Views\DialogWindow.xaml"
        if (-not (Test-Path $xamlPath)) { throw "DialogWindow.xaml not found at $xamlPath" }

        try {
            $reader = [System.Xml.XmlReader]::Create($xamlPath)
            $this.Window = [System.Windows.Markup.XamlReader]::Load($reader)
            $reader.Close()

            $this.Resources.ApplyResourcesToWindow($this.Window)

            # Handlers must close over $self (see .NOTES) or the buttons silently die.
            $self = $this

            $btnClose = $this.Window.FindName("btnClose")
            if ($btnClose) { $btnClose.Add_Click({ $self.Window.Close() }.GetNewClosure()) }

            # Esc cancels the modal (result stays $false), matching the X button.
            $this.Window.Add_PreviewKeyDown({
                    param($s, $e)
                    if ($e.Key -eq 'Escape') { $self.Result = $false; $self.Window.Close() }
                }.GetNewClosure())

            $panelControlBar = $this.Window.FindName("panelControlBar")
            if ($panelControlBar) {
                $panelControlBar.Add_MouseLeftButtonDown({
                        if ($_.ButtonState -eq 'Pressed') { $self.Window.DragMove() }
                    }.GetNewClosure())
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to load DialogWindow: $_", "Error")
            throw
        }
    }

    [bool] ShowConfirmation([string]$title, [string]$message, [string[]]$listItems) {
        return $this.ShowConfirmation($title, $message, $listItems, 'Confirm', $false)
    }

    # Destructive-aware confirmation: $primaryText names the action (per the modal pattern -
    # not a generic "Confirm"), and $isDestructive paints the primary button red.
    [bool] ShowConfirmation([string]$title, [string]$message, [string[]]$listItems,
        [string]$primaryText, [bool]$isDestructive) {
        $this.Initialize()
        $vm = $this.NewVm($title, $message, $listItems, $primaryText, 'Cancel')
        if ($isDestructive) { $vm.PrimaryStyle = $this.Window.TryFindResource('ButtonDestructive') }
        $this.Window.DataContext = $vm
        return $this.ShowModal()
    }

    [void] ShowAlert([string]$title, [string]$message, [string[]]$listItems) {
        $this.Initialize()
        # No secondary button: the primary just acknowledges (result is ignored).
        $this.Window.DataContext = $this.NewVm($title, $message, $listItems, 'OK', '')
        [void]$this.ShowModal()
    }

    [bool] ShowUpdatePrompt([string]$currentVer, [string]$newVer, [bool]$isRollback) {
        $this.Initialize()
        $msg = "Current: $currentVer`nNew: $newVer`n`nWould you like to update now?"
        if ($isRollback) {
            $msg = "Current: $currentVer`nTarget: $newVer`n`nRollback detected. Proceed?"
        }
        $this.Window.DataContext = $this.NewVm("Updates Detected!", $msg, @(),
            'Update Now', 'Later')
        return $this.ShowModal()
    }

    # Builds the dialog's content view-model: Has* flags for which parts show, plus the
    # button commands (primary resolves $true, secondary $false; empty secondary = alert).
    hidden [DialogViewModel] NewVm(
        [string]$title,
        [string]$message,
        [string[]]$listItems,
        [string]$primaryText,
        [string]$secondaryText
    ) {
        $vm = [DialogViewModel]::new()
        $vm.Title = $title
        $vm.HasTitle = -not [string]::IsNullOrEmpty($title)
        $vm.Message = $message
        $vm.HasMessage = -not [string]::IsNullOrEmpty($message)
        $vm.ListItems = @($listItems | Where-Object { $null -ne $_ })
        $vm.HasList = ($vm.ListItems.Count -gt 0)

        $self = $this
        $vm.PrimaryText = $primaryText
        # The view binds Button.Style to this (MVVM); the destructive overload overrides it.
        $vm.PrimaryStyle = $this.Window.TryFindResource('ButtonPrimary')
        $prim = { param($p) $self.Result = $true; $self.Window.Close() }.GetNewClosure()
        $vm.PrimaryCommand = [RelayCommand]::new([System.Action[object]]$prim)

        if (-not [string]::IsNullOrEmpty($secondaryText)) {
            $vm.SecondaryText = $secondaryText
            $vm.HasSecondary = $true
            $sec = { param($p) $self.Result = $false; $self.Window.Close() }.GetNewClosure()
            $vm.SecondaryCommand = [RelayCommand]::new([System.Action[object]]$sec)
        }
        return $vm
    }

    # Runs the modal: parents/fronts the window, flags IsShowing for the pump's
    # reentrancy guard, and returns the button verdict.
    hidden [bool] ShowModal() {
        $this.Result = $false
        $this.PrepareToShow()
        $this.IsShowing = $true
        try { $this.Window.ShowDialog() | Out-Null } finally { $this.IsShowing = $false }
        return $this.Result
    }

    # Parents the dialog to the main window (or makes it topmost when there isn't one yet)
    # so it opens in front with focus. Must be called before ShowDialog().
    hidden [void] PrepareToShow() {
        if ($null -eq $this.Window) { return }

        $main = $null
        if ([System.Windows.Application]::Current) {
            $main = [System.Windows.Application]::Current.MainWindow
        }

        if ($null -ne $main -and $main -ne $this.Window -and $main.IsLoaded) {
            $this.Window.Owner = $main
            $this.Window.WindowStartupLocation = 'CenterOwner'
        }
        else {
            # No usable owner (e.g. the startup update prompt) - force it forward.
            $this.Window.Topmost = $true
        }
    }

}
