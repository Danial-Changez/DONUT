using namespace System.Windows
using namespace System.Windows.Controls
using namespace Donut.Mvvm
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\ConfigManager.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\ViewModels\ConfigViewModel.psm1"
using module ".\ToastService.psm1"

<#
.SYNOPSIS
    Drives the Config page: command selection and DCU option persistence.

.DESCRIPTION
    Loads the active command and its option sub-view, binds the controls to the
    AppConfig command args, and saves edited options back through ConfigManager.
#>
class ConfigPresenter {
    [AppConfig] $Config
    [ConfigManager] $ConfigManager
    [LogService] $Logger
    [FrameworkElement] $ViewContent
    [ComboBox] $MainCommandComboBox
    [ContentControl] $ConfigOptionsContent
    [ConfigViewModel] $ConfigVm
    [FrameworkElement] $CurrentOptionView
    [string] $CurrentSection
    [ToastService] $Toast
    [object] $OnSaved             # invoked after a successful save (closes the overlay)

    ConfigPresenter([AppConfig] $config, [ConfigManager] $configManager, [FrameworkElement] $view,
        [ToastService] $toast, [object] $onSaved) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.Logger = $configManager.Logger
        $this.ViewContent = $view
        $this.Toast = $toast
        $this.OnSaved = $onSaved
        $this.Initialize()
    }

    [void] Initialize() {
        $this.MainCommandComboBox = $this.ViewContent.FindName('MainCommandComboBox')
        $this.ConfigOptionsContent = $this.ViewContent.FindName('ConfigOptionsContent')

        # Page VM: Save binds SaveCommand; the command combo's SelectionChanged stays an
        # event - it's view navigation (which option form shows), not data.
        $this.ConfigVm = [ConfigViewModel]::new()
        $presenter = $this
        $save = { param($p) $presenter.OnSave() }.GetNewClosure()
        $this.ConfigVm.SaveCommand = [RelayCommand]::new([System.Action[object]]$save)
        $this.ViewContent.DataContext = $this.ConfigVm

        if ($this.MainCommandComboBox) {
            $this.MainCommandComboBox.Add_SelectionChanged({
                    if ($_.AddedItems.Count -gt 0) {
                        $presenter.OnCommandChanged($_.AddedItems[0])
                    }
                }.GetNewClosure())
        }

        $this.LoadCurrentConfig()
    }

    [void] LoadCurrentConfig() {
        if (-not $this.MainCommandComboBox) { return }

        $activeCmd = $this.Config.GetActiveCommand()

        # ComboBox index: 0 = Scan, 1 = Apply Updates.
        $index = 0
        if ($activeCmd -eq 'applyUpdates') { $index = 1 }

        $this.MainCommandComboBox.SelectedIndex = $index

        # Force the view load: setting an index that was already 0 raises no event.
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
                $this.PopulateFields()
            }
            catch {
                $this.Logger.LogException("Failed to load option view $fileName", $_)
            }
        }
    }

    [void] PopulateFields() {
        if (-not $this.CurrentSection -or -not $this.CurrentOptionView) {
            return
        }

        $cmd = $this.CurrentSection.Substring(0, 1).ToLower() + $this.CurrentSection.Substring(1)

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
                    # Panels hold multi-checkbox groups (comma-joined values).
                    $values = if ($val) { $val -split "," | ForEach-Object { $_.Trim() } }
                    else { @() }
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
            $activeCommand = $this.CurrentSection.Substring(0, 1).ToLower() +
            $this.CurrentSection.Substring(1)
            # Persist the dropdown choice so it round-trips on reload.
            $this.Config.SetActiveCommand($activeCommand)

            if ($this.Config.Settings.ContainsKey('commands')) {
                $commands = $this.Config.Settings['commands']

                foreach ($cmdKey in $commands.Keys) {
                    if ($commands[$cmdKey] -is [hashtable]) {
                        $commands[$cmdKey]['enabled'] = ($cmdKey -eq $activeCommand)
                    }
                }

                if ($commands.ContainsKey($activeCommand)) {
                    $cmdConfig = $commands[$activeCommand]
                    if (-not $cmdConfig.ContainsKey('args')) { $cmdConfig['args'] = @{} }

                    foreach ($ctrl in $this.GetAllControls($this.CurrentOptionView)) {
                        $this.UpdateArgFromControl($cmdConfig['args'], $ctrl)
                    }
                }
            }
            else {
                $this.Config.SetSetting('EnabledCmdOption', $activeCommand)
            }
        }

        try {
            $this.ConfigManager.SaveConfig($this.Config)
            if ($this.Toast) {
                $this.Toast.ShowSuccess('Config saved', "Active command: $activeCommand")
            }
            if ($this.OnSaved) { & $this.OnSaved }
        }
        catch {
            if ($this.Toast) { $this.Toast.ShowError('Save failed', "$_") }
        }
    }

    hidden [void] UpdateArgFromControl([hashtable]$cmdArgs, [FrameworkElement]$ctrl) {
        if ([string]::IsNullOrWhiteSpace($ctrl.Name) -or
            -not $cmdArgs.ContainsKey($ctrl.Name)) { return }

        $value = switch ($ctrl.GetType().Name) {
            'TextBox' { $ctrl.Text }
            'CheckBox' { $ctrl.IsChecked }
            'ToggleButton' { $ctrl.IsChecked }
            default {
                if ($ctrl -is [Controls.Panel]) {
                    ($ctrl.Children |
                        Where-Object { $_ -is [Controls.CheckBox] -and $_.IsChecked } |
                        ForEach-Object { $_.Content.ToString() }) -join ","
                }
                else { $null }
            }
        }

        if ($null -ne $value) { $cmdArgs[$ctrl.Name] = $value }
    }
}
