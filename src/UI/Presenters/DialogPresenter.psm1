using namespace System.Windows
using module '..\..\Services\ResourceService.psm1'

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
            
            # Bind Standard Events
            $btnClose = $this.Window.FindName("btnClose")
            if ($btnClose) { $btnClose.Add_Click({ $this.Window.Close() }) }
            
            $btnMinimize = $this.Window.FindName("btnMinimize")
            if ($btnMinimize) { $btnMinimize.Add_Click({ $this.Window.WindowState = 'Minimized' }) }
            
            $panelControlBar = $this.Window.FindName("panelControlBar")
            if ($panelControlBar) { 
                $panelControlBar.Add_MouseLeftButtonDown({ 
                    if ($_.ButtonState -eq 'Pressed') { $this.Window.DragMove() } 
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
        
        # Configure UI
        $this.SetText("txtHeader", $title)
        $this.SetText("txtSubHeader", $message)
        $this.SetList($listItems)
        
        # Configure Buttons
        $this.ConfigureButton("btnPrimary", "Confirm", { 
            $this.Result = $true
            $this.Window.Close() 
        })
        
        $this.ConfigureButton("btnSecondary", "Cancel", { 
            $this.Result = $false
            $this.Window.Close() 
        })
        
        $this.Window.ShowDialog() | Out-Null
        return $this.Result
    }

    [void] ShowAlert([string]$title, [string]$message, [string[]]$listItems) {
        $this.Initialize()
        
        # Configure UI
        $this.SetText("txtHeader", $title)
        $this.SetText("txtSubHeader", $message)
        $this.SetList($listItems)
        
        # Configure Buttons
        $this.ConfigureButton("btnPrimary", "OK", { $this.Window.Close() })
        $this.HideControl("btnSecondary")
        
        $this.Window.ShowDialog() | Out-Null
    }

    [bool] ShowUpdatePrompt([string]$currentVer, [string]$newVer, [bool]$isRollback) {
        $this.Initialize()
        
        $title = "Updates Detected!"
        $msg = "Current: $currentVer`nNew: $newVer`n`nWould you like to update now?"
        if ($isRollback) {
            $msg = "Current: $currentVer`nTarget: $newVer`n`nRollback detected. Proceed?"
        }
        
        $this.SetText("txtHeader", $title)
        $this.SetText("txtSubHeader", $msg)
        $this.HideControl("lstContent")
        
        $this.ConfigureButton("btnPrimary", "Update Now", { 
            $this.Result = $true
            $this.Window.Close() 
        })
        
        $this.ConfigureButton("btnSecondary", "Later", { 
            $this.Result = $false
            $this.Window.Close() 
        })
        
        $this.Window.ShowDialog() | Out-Null
        return $this.Result
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

    hidden [void] ConfigureButton([string]$btnName, [string]$text, [scriptblock]$action) {
        $btn = $this.Window.FindName($btnName)
        if ($btn) {
            $btn.Content = $text
            $btn.Visibility = 'Visible'
            # Remove old events (not easily possible in PS without keeping track, but Initialize creates new window each time)
            $btn.Add_Click($action.GetNewClosure())
        }
    }

    hidden [void] HideControl([string]$controlName) {
        $ctrl = $this.Window.FindName($controlName)
        if ($ctrl) { $ctrl.Visibility = 'Collapsed' }
    }
}
