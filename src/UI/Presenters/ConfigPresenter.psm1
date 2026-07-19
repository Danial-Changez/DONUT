using namespace System.Windows
using namespace System.Windows.Controls
using namespace Donut.Mvvm
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Models\HotkeyGesture.psm1"
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
    [RadioButton] $CmdScan
    [RadioButton] $CmdApplyUpdates
    [RadioButton] $CmdGeneral
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
        $this.CmdScan = $this.ViewContent.FindName('cmdScan')
        $this.CmdApplyUpdates = $this.ViewContent.FindName('cmdApplyUpdates')
        $this.CmdGeneral = $this.ViewContent.FindName('cmdGeneral')
        $this.ConfigOptionsContent = $this.ViewContent.FindName('ConfigOptionsContent')

        # Page VM: Save binds SaveCommand; the command segments stay events - picking
        # one is view navigation (which option form shows), not data.
        $this.ConfigVm = [ConfigViewModel]::new()
        $presenter = $this
        $save = { param($p) $presenter.OnSave() }.GetNewClosure()
        $this.ConfigVm.SaveCommand = [RelayCommand]::new([System.Action[object]]$save)
        $this.ViewContent.DataContext = $this.ConfigVm

        if ($this.CmdScan) {
            $scan = { $presenter.LoadOptionView('Scan') }.GetNewClosure()
            $this.CmdScan.Add_Checked($scan)
        }
        if ($this.CmdApplyUpdates) {
            $apply = { $presenter.LoadOptionView('ApplyUpdates') }.GetNewClosure()
            $this.CmdApplyUpdates.Add_Checked($apply)
        }
        if ($this.CmdGeneral) {
            # The Configure view holds the app-wide settings (throttle, startup, tray, hotkey).
            $general = { $presenter.LoadOptionView('Configure') }.GetNewClosure()
            $this.CmdGeneral.Add_Checked($general)
        }

        $this.LoadCurrentConfig()
    }

    [void] LoadCurrentConfig() {
        # Checking a segment fires its Checked handler, which loads the option view.
        if ($this.Config.GetActiveCommand() -eq 'applyUpdates' -and $this.CmdApplyUpdates) {
            $this.CmdApplyUpdates.IsChecked = $true
        }
        elseif ($this.CmdScan) {
            $this.CmdScan.IsChecked = $true
        }
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

        # The Configure view isn't a DCU command - it edits the app-wide settings.
        if ($this.CurrentSection -eq 'Configure') {
            $this.PopulateGeneralSettings()
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
        # The Configure view saves the app-wide settings on its own path (it rejects an
        # invalid hotkey before persisting anything).
        if ($this.CurrentSection -eq 'Configure') {
            $this.SaveGeneralSettings()
            return
        }

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

    # Fills the Configure view's app-wide controls from the current config.
    hidden [void] PopulateGeneralSettings() {
        $throttle = $this.CurrentOptionView.FindName('throttleLimit')
        if ($throttle) { $throttle.Text = [string]$this.Config.GetThrottleLimit() }

        $startWin = $this.CurrentOptionView.FindName('chkStartWithWindows')
        if ($startWin) { $startWin.IsChecked = $this.Config.GetStartWithWindows() }

        $closeTray = $this.CurrentOptionView.FindName('chkCloseToTray')
        if ($closeTray) { $closeTray.IsChecked = $this.Config.GetCloseToTray() }

        $hotkey = $this.CurrentOptionView.FindName('txtGlobalHotkey')
        if ($hotkey) { $hotkey.Text = $this.Config.GetGlobalHotkey() }
    }

    # Persists the app-wide settings. A non-blank hotkey must parse first, or the whole
    # save is rejected with the reason shown (blank disables the hotkey).
    hidden [void] SaveGeneralSettings() {
        $hotkeyBox = $this.CurrentOptionView.FindName('txtGlobalHotkey')
        $hotkeyText = if ($hotkeyBox) { [string]$hotkeyBox.Text } else { '' }

        if (-not [string]::IsNullOrWhiteSpace($hotkeyText)) {
            $gesture = [HotkeyGesture]::Parse($hotkeyText)
            if (-not $gesture.Valid) {
                if ($this.Toast) { $this.Toast.ShowError('Invalid hotkey', $gesture.Reason) }
                return
            }
            $hotkeyText = $gesture.Normalized
        }
        else { $hotkeyText = '' }

        $throttleBox = $this.CurrentOptionView.FindName('throttleLimit')
        if ($throttleBox -and [string]$throttleBox.Text -match '^\d+$') {
            $this.Config.SetThrottleLimit([int]$throttleBox.Text)
        }

        $startWin = $this.CurrentOptionView.FindName('chkStartWithWindows')
        if ($startWin) { $this.Config.SetSetting('startWithWindows', [bool]$startWin.IsChecked) }

        $closeTray = $this.CurrentOptionView.FindName('chkCloseToTray')
        if ($closeTray) { $this.Config.SetSetting('closeToTray', [bool]$closeTray.IsChecked) }

        $this.Config.SetSetting('globalHotkey', $hotkeyText)

        try {
            $this.ConfigManager.SaveConfig($this.Config)
            if ($this.Toast) {
                $this.Toast.ShowSuccess('Settings saved', 'Startup, tray, and hotkey updated.')
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
