using namespace System.Windows.Input
using module "..\..\Models\HotkeyGesture.psm1"

<#
.SYNOPSIS
    Behaviour for a "Record Keybind" control: capture a gesture from live key events.

.DESCRIPTION
    Wraps a display TextBlock, a Record button, and an optional Clear button. Clicking
    Record captures the held modifiers plus one non-modifier key (via HotkeyGesture.FromKeys),
    shows it live, and commits when the keys are released. Esc cancels; Delete/Backspace
    clears (disables). OnCommit receives the normalized gesture ('' when cleared).

    The Clear button is the X inside the field, so it is disabled rather than hidden when
    there is nothing to clear - collapsing it would reflow the value on every commit.

.NOTES
    Event scriptblocks close over $self, since a WPF handler rebinds $this to the sender.
    A global hotkey is modifier(s) + one key, so only the last non-modifier key is kept.
    Captured mods/key are held as [object] to avoid parse-time WPF type resolution.
#>
class KeybindRecorder {
    hidden [object] $Display
    hidden [object] $RecordButton
    hidden [object] $ClearButton
    hidden [object] $OnCommit       # scriptblock([string])
    hidden [string] $Current = ''
    hidden [bool]   $Recording = $false
    hidden [object] $CapturedKey = $null
    hidden [object] $CapturedMods = $null

    KeybindRecorder([object]$display, [object]$recordButton, [object]$clearButton,
        [string]$initial, [object]$onCommit) {
        $this.Display = $display
        $this.RecordButton = $recordButton
        $this.ClearButton = $clearButton
        $this.OnCommit = $onCommit
        $this.Current = if ($initial) { $initial } else { '' }
        $this.Wire()
        $this.UpdateDisplay()
    }

    hidden [void] Wire() {
        $self = $this
        if ($this.RecordButton) {
            $this.RecordButton.Add_Click({ param($s, $e) $self.StartRecording() }.GetNewClosure())
            $this.RecordButton.Add_PreviewKeyDown({ param($s, $e) $self.OnKeyDown($e) }.GetNewClosure())
            $this.RecordButton.Add_PreviewKeyUp({ param($s, $e) $self.OnKeyUp($e) }.GetNewClosure())
            $this.RecordButton.Add_LostKeyboardFocus({ param($s, $e) $self.CancelRecording() }.GetNewClosure())
        }
        if ($this.ClearButton) {
            $this.ClearButton.Add_Click({ param($s, $e) $self.Commit('') }.GetNewClosure())
        }
    }

    hidden [void] StartRecording() {
        if ($this.Recording) { return }
        $this.Recording = $true
        $this.CapturedKey = $null
        $this.CapturedMods = $null
        if ($this.RecordButton) { $this.RecordButton.Content = 'Press keys…' }
        if ($this.Display) { $this.Display.Text = 'Press a key combo  ·  Esc cancels' }
        if ($this.RecordButton) { [Keyboard]::Focus($this.RecordButton) | Out-Null }
    }

    hidden [void] OnKeyDown([object]$e) {
        if (-not $this.Recording) { return }
        $e.Handled = $true
        $key = if ($e.Key -eq [Key]::System) { $e.SystemKey } else { $e.Key }
        if ([KeybindRecorder]::IsModifierKey($key)) {
            $this.ShowPreview([Keyboard]::Modifiers, $null)
            return
        }
        if ($key -eq [Key]::Escape) { $this.CancelRecording(); return }
        if ($key -eq [Key]::Back -or $key -eq [Key]::Delete) { $this.Commit(''); return }
        $this.CapturedKey = $key
        $this.CapturedMods = [Keyboard]::Modifiers
        $this.ShowPreview([Keyboard]::Modifiers, $key)
    }

    hidden [void] OnKeyUp([object]$e) {
        if (-not $this.Recording -or $null -eq $this.CapturedKey) { return }
        $e.Handled = $true
        # Any release after a main key was captured commits (matches "let go to save").
        $g = [HotkeyGesture]::FromKeys([ModifierKeys]$this.CapturedMods, [Key]$this.CapturedKey)
        if ($g.Valid) {
            $this.Commit($g.Normalized)
        }
        else {
            if ($this.Display) { $this.Display.Text = $g.Reason }
            $this.CapturedKey = $null   # let them try again without leaving record mode
        }
    }

    hidden [void] Commit([string]$value) {
        $this.Recording = $false
        $this.CapturedKey = $null
        $this.Current = if ($value) { $value } else { '' }
        if ($this.RecordButton) { $this.RecordButton.Content = 'Record keybind' }
        $this.UpdateDisplay()
        if ($this.OnCommit) { & $this.OnCommit $this.Current }
    }

    hidden [void] CancelRecording() {
        if (-not $this.Recording) { return }
        $this.Recording = $false
        $this.CapturedKey = $null
        if ($this.RecordButton) { $this.RecordButton.Content = 'Record keybind' }
        $this.UpdateDisplay()   # restores the prior value (no commit)
    }

    hidden [void] ShowPreview([object]$mods, [object]$key) {
        $m = [ModifierKeys]$mods
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($m -band [ModifierKeys]::Control) { $parts.Add('Ctrl') }
        if ($m -band [ModifierKeys]::Alt) { $parts.Add('Alt') }
        if ($m -band [ModifierKeys]::Shift) { $parts.Add('Shift') }
        if ($m -band [ModifierKeys]::Windows) { $parts.Add('Win') }
        if ($null -ne $key) { $parts.Add(([Key]$key).ToString()) } else { $parts.Add('…') }
        if ($this.Display) { $this.Display.Text = ($parts -join '+') }
    }

    hidden [void] UpdateDisplay() {
        $blank = [string]::IsNullOrWhiteSpace($this.Current)
        if ($this.Display) { $this.Display.Text = if ($blank) { 'No keybind set' } else { $this.Current } }
        # Disabled, not collapsed: hiding the inline X would reflow the value on every commit.
        if ($this.ClearButton) { $this.ClearButton.IsEnabled = -not $blank }
    }

    static [bool] IsModifierKey([object]$key) {
        return ([Key]$key) -in @(
            [Key]::LeftCtrl, [Key]::RightCtrl, [Key]::LeftAlt, [Key]::RightAlt,
            [Key]::LeftShift, [Key]::RightShift, [Key]::LWin, [Key]::RWin, [Key]::System)
    }
}
