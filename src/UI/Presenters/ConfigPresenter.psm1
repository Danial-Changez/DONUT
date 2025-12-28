using namespace System.Windows
using namespace System.Windows.Controls
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\ConfigManager.psm1"

class ConfigPresenter {
    [AppConfig] $Config
    [ConfigManager] $ConfigManager
    [FrameworkElement] $ViewContent
    [ComboBox] $MainCommandComboBox
    [ContentControl] $ConfigOptionsContent
    [Button] $SaveButton
    [FrameworkElement] $CurrentOptionView
    [string] $CurrentSection

    ConfigPresenter([AppConfig] $config, [ConfigManager] $configManager, [FrameworkElement] $view) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.ViewContent = $view
        $this.Initialize()
    }

    [void] Initialize() {
        $this.MainCommandComboBox = $this.ViewContent.FindName('MainCommandComboBox')
        $this.ConfigOptionsContent = $this.ViewContent.FindName('ConfigOptionsContent')
        $this.SaveButton = $this.ViewContent.FindName('btnSaveConfig')

        if ($this.MainCommandComboBox) {
            $presenter = $this
            $this.MainCommandComboBox.Add_SelectionChanged({ 
                if ($_.AddedItems.Count -gt 0) {
                    $presenter.OnCommandChanged($_.AddedItems[0]) 
                }
            }.GetNewClosure())
        }

        if ($this.SaveButton) {
            $presenter = $this
            $this.SaveButton.Add_Click({ $presenter.OnSave() }.GetNewClosure())
        }

        $this.LoadCurrentConfig()
    }

    [void] LoadCurrentConfig() {
        if (-not $this.MainCommandComboBox) { return }

        $activeCmd = $this.Config.GetActiveCommand()
        
        # Map command key to ComboBox index or content
        # 0: Scan, 1: Apply Updates
        $index = 0
        if ($activeCmd -eq 'applyUpdates') { $index = 1 }
        
        $this.MainCommandComboBox.SelectedIndex = $index
        
        # Force load of the view if it hasn't happened yet (SelectedIndex change might not trigger if already 0)
        if ($this.MainCommandComboBox.SelectedItem) {
             $this.OnCommandChanged($this.MainCommandComboBox.SelectedItem)
        }
    }

    [void] OnCommandChanged([object] $selectedItem) {
        $content = $selectedItem
        if ($selectedItem -is [Controls.ComboBoxItem]) {
            $content = $selectedItem.Content
        }
        
        $viewName = $content.ToString().Replace(" ", "")
        $this.LoadOptionView($viewName)
    }

    [void] LoadOptionView([string] $viewName) {
        $fileName = "${viewName}OptionView.xaml"
        $path = Join-Path $this.Config.SourceRoot "UI\Views\Config Options\$fileName"
        
        if (Test-Path $path) {
            try {
                $reader = [System.Xml.XmlReader]::Create($path)
                $this.CurrentOptionView = [Markup.XamlReader]::Load($reader)
                $reader.Close()
                
                $this.ConfigOptionsContent.Content = $this.CurrentOptionView
                $this.CurrentSection = $viewName
                
                # Populate fields
                $this.PopulateFields()
            } catch {
                Write-Error "Failed to load option view $fileName : $_"
            }
        }
    }
    
    [void] PopulateFields() {
        if (-not $this.CurrentSection -or -not $this.CurrentOptionView) { 
            return 
        }
        
        $cmd = $this.CurrentSection.Substring(0,1).ToLower() + $this.CurrentSection.Substring(1)
        
        # Get Args
        $cmdArgs = @{}
        if ($this.Config.Settings.ContainsKey('commands') -and 
            $this.Config.Settings['commands'].ContainsKey($cmd) -and 
            $this.Config.Settings['commands'][$cmd].ContainsKey('args')) {
            
            $cmdArgs = $this.Config.Settings['commands'][$cmd]['args']
        }

        if ($null -eq $cmdArgs -or $cmdArgs.Count -eq 0) { return }

        $allControls = $this.GetAllControls($this.CurrentOptionView)

        foreach ($ctrl in $allControls) {
            if ([string]::IsNullOrWhiteSpace($ctrl.Name)) { continue }
            
            if ($cmdArgs.ContainsKey($ctrl.Name)) {
                $val = $cmdArgs[$ctrl.Name]
                
                if ($ctrl -is [Controls.TextBox]) {
                    $ctrl.Text = $val
                }
                elseif ($ctrl -is [Controls.Primitives.ToggleButton]) {
                    $ctrl.IsChecked = ($val -eq 'enable' -or $val -eq $true -or $val -eq 'true')
                }
                elseif ($ctrl -is [Controls.Panel]) {
                    # Handle multi-checkbox groups
                    $values = if ($val) { $val -split "," | ForEach-Object { $_.Trim() } } else { @() }
                    foreach ($child in $ctrl.Children) {
                        if ($child -is [Controls.CheckBox]) {
                            $child.IsChecked = ($child.Content.ToString() -in $values)
                        }
                    }
                }
            }
        }
    }

    [System.Collections.ArrayList] GetAllControls([FrameworkElement] $parent) {
        $controls = [System.Collections.ArrayList]::new()
        if (-not [string]::IsNullOrWhiteSpace($parent.Name)) { $controls.Add($parent) | Out-Null }
        
        if ($parent -is [Controls.Panel]) {
            foreach ($child in $parent.Children) {
                if ($child -is [FrameworkElement]) {
                    $controls.AddRange($this.GetAllControls($child))
                }
            }
        }
        elseif ($parent -is [Controls.ContentControl] -and $parent.Content -is [FrameworkElement]) {
            $controls.AddRange($this.GetAllControls($parent.Content))
        }
        elseif ($parent -is [Controls.ScrollViewer] -and $parent.Content -is [FrameworkElement]) {
            $controls.AddRange($this.GetAllControls($parent.Content))
        }
        elseif ($parent -is [Controls.Decorator] -and $parent.Child -is [FrameworkElement]) {
             $controls.AddRange($this.GetAllControls($parent.Child))
        }
        
        return $controls
    }

    [void] OnSave() {
        $activeCommand = "Unknown"

        if ($this.CurrentSection) {
            # Convert PascalCase to camelCase
            $activeCommand = $this.CurrentSection.Substring(0,1).ToLower() + $this.CurrentSection.Substring(1)
            
            if ($this.Config.Settings.ContainsKey('commands')) {
                $commands = $this.Config.Settings['commands']
                
                # Enable only the selected command
                foreach ($cmdKey in $commands.Keys) {
                    if ($commands[$cmdKey] -is [hashtable]) {
                        $commands[$cmdKey]['enabled'] = ($cmdKey -eq $activeCommand)
                    }
                }
                
                # Update command arguments from UI controls
                if ($commands.ContainsKey($activeCommand)) {
                    $cmdConfig = $commands[$activeCommand]
                    if (-not $cmdConfig.ContainsKey('args')) { $cmdConfig['args'] = @{} }
                    
                    foreach ($ctrl in $this.GetAllControls($this.CurrentOptionView)) {
                        $this.UpdateArgFromControl($cmdConfig['args'], $ctrl)
                    }
                }
            } else {
                $this.Config.SetSetting('EnabledCmdOption', $activeCommand)
            }
        }
        
        try {
            $this.ConfigManager.SaveConfig($this.Config)
            [Forms.MessageBox]::Show(
                "Config saved successfully.`nActive Command: $activeCommand", 
                "Success"
            )
        } catch {
            [Forms.MessageBox]::Show("Failed to save config: $_", "Error")
        }
    }
    
    hidden [void] UpdateArgFromControl([hashtable]$cmdArgs, [FrameworkElement]$ctrl) {
        if ([string]::IsNullOrWhiteSpace($ctrl.Name) -or -not $cmdArgs.ContainsKey($ctrl.Name)) { return }
        
        $value = switch ($ctrl.GetType().Name) {
            'TextBox' { $ctrl.Text }
            'CheckBox' { $ctrl.IsChecked }
            'ToggleButton' { $ctrl.IsChecked }
            default {
                if ($ctrl -is [Controls.Panel]) {
                    ($ctrl.Children | 
                        Where-Object { $_ -is [Controls.CheckBox] -and $_.IsChecked } | 
                        ForEach-Object { $_.Content.ToString() }) -join ","
                } else { $null }
            }
        }
        
        if ($null -ne $value) { $cmdArgs[$ctrl.Name] = $value }
    }
}
