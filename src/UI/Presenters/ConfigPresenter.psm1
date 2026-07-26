using namespace System.Windows
using namespace System.Windows.Controls
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\ConfigManager.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\ViewLoader.psm1"
using module ".\KeybindRecorder.psm1"
using module ".\ToastService.psm1"

<#
.SYNOPSIS
    Drives the Config page: command selection and real-time option persistence.

.DESCRIPTION
    Loads the active command and its option sub-view, binds the controls to the
    AppConfig command args, and persists every edit the moment it changes (no Save
    button) - toggles/chips on change, text fields on lost-focus, keybinds via the
    recorder. Config lives under %LOCALAPPDATA%\DONUT so it survives reinstalls.

.NOTES
    Side-effects that live outside the JSON (global hotkey, window shortcut, startup
    task) are re-applied per change via the SideEffects callbacks passed in by
    MainPresenter. Event scriptblocks capture $self, since a WPF handler rebinds $this.
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
    [FrameworkElement] $CurrentOptionView
    [string] $CurrentSection
    [ToastService] $Toast
    [hashtable] $SideEffects       # @{ Hotkey; WindowShortcut; StartupTask } scriptblocks
    hidden [object] $HotkeyRecorder
    hidden [object] $ShortcutRecorder

    ConfigPresenter([AppConfig] $config, [ConfigManager] $configManager, [FrameworkElement] $view,
        [ToastService] $toast, [hashtable] $sideEffects) {
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.Logger = $configManager.Logger
        $this.ViewContent = $view
        $this.Toast = $toast
        $this.SideEffects = $sideEffects
        $this.Initialize()
    }

    [void] Initialize() {
        $this.CmdScan = $this.ViewContent.FindName('cmdScan')
        $this.CmdApplyUpdates = $this.ViewContent.FindName('cmdApplyUpdates')
        $this.CmdGeneral = $this.ViewContent.FindName('cmdGeneral')
        $this.ConfigOptionsContent = $this.ViewContent.FindName('ConfigOptionsContent')

        # Picking a segment is view navigation (which option form shows), not data.
        $presenter = $this
        if ($this.CmdScan) {
            $this.CmdScan.Add_Checked({ $presenter.LoadOptionView('Scan') }.GetNewClosure())
        }
        if ($this.CmdApplyUpdates) {
            $this.CmdApplyUpdates.Add_Checked({ $presenter.LoadOptionView('ApplyUpdates') }.GetNewClosure())
        }
        if ($this.CmdGeneral) {
            # The General view holds the app-wide settings (throttle, startup, tray, hotkeys).
            $this.CmdGeneral.Add_Checked({ $presenter.LoadOptionView('General') }.GetNewClosure())
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
                $this.CurrentOptionView = [ViewLoader]::Load(
                    $this.Config.SourceRoot, "UI\Views\Config Options\$fileName")

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

        # The General view isn't a DCU command - it edits the app-wide settings.
        if ($this.CurrentSection -eq 'General') {
            $this.PopulateGeneralSettings()
            return
        }

        $cmd = $this.SectionCommand()
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

        # Wire live-persist AFTER populating, so setting initial values doesn't fire it.
        $this.WireDcuPersistence($allControls)
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

    # Attaches change/lost-focus handlers so each DCU control persists its arg live.
    hidden [void] WireDcuPersistence([object]$allControls) {
        $self = $this
        foreach ($ctrl in $allControls) {
            if ([string]::IsNullOrWhiteSpace($ctrl.Name)) { continue }
            if ($ctrl -is [Controls.Primitives.ToggleButton]) {
                $h = { param($s, $e) $self.PersistDcuArg($s) }.GetNewClosure()
                $ctrl.Add_Checked($h)
                $ctrl.Add_Unchecked($h)
            }
            elseif ($ctrl -is [Controls.TextBox]) {
                $ctrl.Add_LostFocus({ param($s, $e) $self.PersistDcuArg($s) }.GetNewClosure())
            }
            elseif ($ctrl -is [Controls.Panel]) {
                $panel = $ctrl
                foreach ($child in $ctrl.Children) {
                    if ($child -is [Controls.CheckBox]) {
                        $h = { param($s, $e) $self.PersistDcuArg($panel) }.GetNewClosure()
                        $child.Add_Checked($h)
                        $child.Add_Unchecked($h)
                    }
                }
            }
        }
    }

    # Writes one DCU control's value into its command args and flushes. Does NOT change the
    # active command - editing a command's options is separate from selecting it to run.
    hidden [void] PersistDcuArg([object]$ctrl) {
        if ($this.CurrentSection -eq 'General' -or [string]::IsNullOrWhiteSpace($this.CurrentSection)) { return }
        if (-not $this.Config.Settings.ContainsKey('commands')) { return }
        $cmd = $this.SectionCommand()
        $commands = $this.Config.Settings['commands']
        if (-not $commands.ContainsKey($cmd)) { return }
        if (-not $commands[$cmd].ContainsKey('args')) { $commands[$cmd]['args'] = @{} }
        $this.UpdateArgFromControl($commands[$cmd]['args'], $ctrl)
        $this.SaveConfigSafely()
    }

    # Section name ('Scan'/'ApplyUpdates') -> command key ('scan'/'applyUpdates').
    hidden [string] SectionCommand() {
        if ([string]::IsNullOrWhiteSpace($this.CurrentSection)) { return '' }
        return $this.CurrentSection.Substring(0, 1).ToLower() + $this.CurrentSection.Substring(1)
    }

    # Fills the General controls from config and wires each to persist live.
    hidden [void] PopulateGeneralSettings() {
        $self = $this
        $view = $this.CurrentOptionView

        $throttle = $view.FindName('throttleLimit')
        if ($throttle) {
            $throttle.Text = [string]$this.Config.GetThrottleLimit()
            $throttle.Add_TextChanged({ param($s, $e) $s.Tag = $null }.GetNewClosure())   # clear error while editing
            $throttle.Add_LostFocus({ param($s, $e) $self.PersistThrottle($s) }.GetNewClosure())
        }

        $folders = $view.FindName('folderScanCount')
        if ($folders) {
            $folders.Text = [string]$this.Config.GetFolderScanCount()
            $folders.Add_TextChanged({ param($s, $e) $s.Tag = $null }.GetNewClosure())   # clear error while editing
            $folders.Add_LostFocus({ param($s, $e) $self.PersistFolderScanCount($s) }.GetNewClosure())
        }

        $startWin = $view.FindName('chkStartWithWindows')
        if ($startWin) {
            $startWin.IsChecked = $this.Config.GetStartWithWindows()
            $h = { param($s, $e) $self.PersistToggle('startWithWindows', [bool]$s.IsChecked, 'StartupTask') }.GetNewClosure()
            $startWin.Add_Checked($h)
            $startWin.Add_Unchecked($h)
        }

        $closeTray = $view.FindName('chkCloseToTray')
        if ($closeTray) {
            $closeTray.IsChecked = $this.Config.GetCloseToTray()
            $h = { param($s, $e) $self.PersistToggle('closeToTray', [bool]$s.IsChecked, $null) }.GetNewClosure()
            $closeTray.Add_Checked($h)
            $closeTray.Add_Unchecked($h)
        }

        $debugLog = $view.FindName('chkDebugLogging')
        if ($debugLog) {
            $debugLog.IsChecked = $this.Config.GetDebugLogging()
            $h = { param($s, $e) $self.PersistToggle('debugLogging', [bool]$s.IsChecked, 'DebugLog') }.GetNewClosure()
            $debugLog.Add_Checked($h)
            $debugLog.Add_Unchecked($h)
        }

        # Keybind recorders (replace the old typed text boxes).
        $hkValue = $view.FindName('recGlobalHotkeyValue')
        $hkRecord = $view.FindName('recGlobalHotkeyRecord')
        $hkClear = $view.FindName('recGlobalHotkeyClear')
        if ($hkValue -and $hkRecord) {
            $commit = { param($v) $self.PersistGesture('globalHotkey', $v, 'Hotkey') }.GetNewClosure()
            $this.HotkeyRecorder = [KeybindRecorder]::new($hkValue, $hkRecord, $hkClear, $this.Config.GetGlobalHotkey(), $commit)
        }

        $osValue = $view.FindName('recOpenSettingsValue')
        $osRecord = $view.FindName('recOpenSettingsRecord')
        $osClear = $view.FindName('recOpenSettingsClear')
        if ($osValue -and $osRecord) {
            $commit = { param($v) $self.PersistGesture('openSettingsShortcut', $v, 'WindowShortcut') }.GetNewClosure()
            $this.ShortcutRecorder = [KeybindRecorder]::new($osValue, $osRecord, $osClear, $this.Config.GetOpenSettingsShortcut(), $commit)
        }
    }

    # Persists a boolean setting and re-applies its side-effect (if any).
    hidden [void] PersistToggle([string]$key, [bool]$value, [object]$sideEffect) {
        $this.Config.SetSetting($key, $value)
        $this.SaveConfigSafely()
        if ($sideEffect) { $this.InvokeSideEffect([string]$sideEffect) }
    }

    # Validates the throttle on lost-focus and persists when it's a whole number >= 1.
    hidden [void] PersistThrottle([object]$box) {
        $text = ([string]$box.Text).Trim()
        if ($text -match '^\d+$' -and [int]$text -ge 1) {
            $this.SetFieldError($box, $false)
            $this.Config.SetThrottleLimit([int]$text)
            $this.SaveConfigSafely()
        }
        else {
            $this.SetFieldError($box, $true)
            if ($this.Toast) { $this.Toast.ShowError('Throttle limit', 'Enter a whole number of 1 or more.') }
        }
    }

    # Validates the storage-scan folder count on lost-focus and persists when it's >= 1.
    hidden [void] PersistFolderScanCount([object]$box) {
        $text = ([string]$box.Text).Trim()
        if ($text -match '^\d+$' -and [int]$text -ge 1) {
            $this.SetFieldError($box, $false)
            $this.Config.SetFolderScanCount([int]$text)
            $this.SaveConfigSafely()
        }
        else {
            $this.SetFieldError($box, $true)
            if ($this.Toast) { $this.Toast.ShowError('Folders to scan', 'Enter a whole number of 1 or more.') }
        }
    }

    # Persists a recorded gesture ('' disables it) and re-applies it. The recorder only
    # commits a valid or empty value, so no re-validation is needed here.
    hidden [void] PersistGesture([string]$key, [string]$value, [string]$sideEffect) {
        $this.Config.SetSetting($key, $value)
        $this.SaveConfigSafely()
        $this.InvokeSideEffect($sideEffect)
    }

    hidden [void] InvokeSideEffect([string]$name) {
        if ($this.SideEffects -and $this.SideEffects.ContainsKey($name) -and $this.SideEffects[$name]) {
            & $this.SideEffects[$name]
        }
    }

    hidden [void] SaveConfigSafely() {
        try {
            $this.ConfigManager.SaveConfig($this.Config)
        }
        catch {
            $this.Logger.LogException('Config save failed', $_)
            if ($this.Toast) { $this.Toast.ShowError('Save failed', "$_") }
        }
    }

    # Flags or clears a field's inline validation error (the red border comes from the
    # ModernTextBox Tag='error' trigger).
    hidden [void] SetFieldError([object]$box, [bool]$hasError) {
        if ($null -eq $box) { return }
        $box.Tag = if ($hasError) { 'error' } else { $null }
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
