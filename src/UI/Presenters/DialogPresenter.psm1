using namespace System.Windows
using module '..\..\Services\ResourceService.psm1'

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
        $self = $this

        $this.SetText("txtHeader", $title)
        $this.SetText("txtSubHeader", $message)
        $this.SetList($listItems)

        # Configure Buttons (close over $self - $this is the sender inside the handler)
        $this.ConfigureButton("btnPrimary", "Confirm", {
            $self.Result = $true
            $self.Window.Close()
        }.GetNewClosure())

        $this.ConfigureButton("btnSecondary", "Cancel", {
            $self.Result = $false
            $self.Window.Close()
        }.GetNewClosure())

        $this.PrepareToShow()
        $this.Window.ShowDialog() | Out-Null
        return $this.Result
    }

    [void] ShowAlert([string]$title, [string]$message, [string[]]$listItems) {
        $this.Initialize()
        $self = $this

        $this.SetText("txtHeader", $title)
        $this.SetText("txtSubHeader", $message)
        $this.SetList($listItems)

        # Configure Buttons (close over $self - $this is the sender inside the handler)
        $this.ConfigureButton("btnPrimary", "OK", { $self.Window.Close() }.GetNewClosure())
        $this.HideControl("btnSecondary")

        $this.PrepareToShow()
        $this.Window.ShowDialog() | Out-Null
    }

    [bool] ShowUpdatePrompt([string]$currentVer, [string]$newVer, [bool]$isRollback) {
        $this.Initialize()
        
        $title = "Updates Detected!"
        $msg = "Current: $currentVer`nNew: $newVer`n`nWould you like to update now?"
        if ($isRollback) {
            $msg = "Current: $currentVer`nTarget: $newVer`n`nRollback detected. Proceed?"
        }
        
        $self = $this
        $this.SetText("txtHeader", $title)
        $this.SetText("txtSubHeader", $msg)
        $this.HideControl("lstContent")

        $this.ConfigureButton("btnPrimary", "Update Now", {
            $self.Result = $true
            $self.Window.Close()
        }.GetNewClosure())

        $this.ConfigureButton("btnSecondary", "Later", {
            $self.Result = $false
            $self.Window.Close()
        }.GetNewClosure())

        $this.PrepareToShow()
        $this.Window.ShowDialog() | Out-Null
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

    hidden [void] SetText([string]$controlName, [string]$text) {
        $ctrl = $this.Window.FindName($controlName)
        if ($ctrl) {
            if ([string]::IsNullOrEmpty($text)) {
                $ctrl.Visibility = 'Collapsed'
            } else {
                $ctrl.Text = $text
                $ctrl.Visibility = 'Visible'
            }
        }
    }

    hidden [void] SetList([string[]]$items) {
        $ctrl = $this.Window.FindName("lstContent")
        if ($ctrl) {
            if ($null -eq $items -or $items.Count -eq 0) {
                $ctrl.Visibility = 'Collapsed'
            } else {
                $ctrl.ItemsSource = $items
                $ctrl.Visibility = 'Visible'
            }
        }
    }

    # $action must already be a closure (built with .GetNewClosure() in the caller,
    # where $self is in scope). We do NOT re-close it here: $this in this scope isn't
    # the caller's $self, and the handler must not pick up $this (which becomes the
    # sender at click time). Initialize creates a fresh window each time, so there are
    # no stale handlers to remove.
    hidden [void] ConfigureButton([string]$btnName, [string]$text, [scriptblock]$action) {
        $btn = $this.Window.FindName($btnName)
        if ($btn) {
            $btn.Content = $text
            $btn.Visibility = 'Visible'
            $btn.Add_Click($action)
        }
    }

    hidden [void] HideControl([string]$controlName) {
        $ctrl = $this.Window.FindName($controlName)
        if ($ctrl) { $ctrl.Visibility = 'Collapsed' }
    }
}
