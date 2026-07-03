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
            
            # Apply Resources
            $this.Resources.ApplyResourcesToWindow($this.Window)
            
            # Bind Standard Events. Capture $self: inside a WPF event handler $this
            # is rebound to the sender (the button), NOT this DialogPresenter, so the
            # handlers must close over $self or they silently no-op (dead buttons).
            $self = $this

            $btnClose = $this.Window.FindName("btnClose")
            if ($btnClose) { $btnClose.Add_Click({ $self.Window.Close() }.GetNewClosure()) }

            $btnMinimize = $this.Window.FindName("btnMinimize")
            if ($btnMinimize) { $btnMinimize.Add_Click({ $self.Window.WindowState = 'Minimized' }.GetNewClosure()) }

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
        $this.Initialize()
        $this.Window.DataContext = $this.NewVm($title, $message, $listItems, 'Confirm', 'Cancel')
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
        $this.Window.DataContext = $this.NewVm("Updates Detected!", $msg, @(), 'Update Now', 'Later')
        return $this.ShowModal()
    }

    # Builds the dialog's content view-model: which parts show (Has* flags) and the
    # two button commands. Primary resolves the dialog $true, secondary $false; an
    # empty secondary text means a single-button (alert-style) dialog. Commands close
    # over $self because $this rebinds to the sender inside WPF callbacks.
    hidden [DialogViewModel] NewVm([string]$title, [string]$message, [string[]]$listItems, [string]$primaryText, [string]$secondaryText) {
        $vm = [DialogViewModel]::new()
        $vm.Title = $title
        $vm.HasTitle = -not [string]::IsNullOrEmpty($title)
        $vm.Message = $message
        $vm.HasMessage = -not [string]::IsNullOrEmpty($message)
        $vm.ListItems = @($listItems | Where-Object { $null -ne $_ })
        $vm.HasList = ($vm.ListItems.Count -gt 0)

        $self = $this
        $vm.PrimaryText = $primaryText
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

    # Parents the dialog to the main window (or, if there isn't one yet, makes it
    # topmost) so it reliably appears in front and grabs focus instead of opening
    # behind the main window. Must be called before ShowDialog().
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
