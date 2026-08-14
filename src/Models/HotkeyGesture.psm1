using namespace System.Windows.Input

<#
.SYNOPSIS
    Parses a hotkey gesture string (e.g. "Ctrl+Alt+D") into RegisterHotKey inputs.

.DESCRIPTION
    Pure, static-parse model with no side effects. Splits a gesture on '+',
    resolves modifier tokens (case-insensitively, with common aliases) into the
    Win32 MOD_* bitmask and the single non-modifier key into a virtual-key code
    via WPF's KeyConverter/KeyInterop. Rejects gestures that can't be a global
    hotkey (no key, two keys, or no Ctrl/Alt/Win), returning a Reason for the UI.

.NOTES
    Modifier flags are the Win32 MOD_* values RegisterHotKey expects (Alt 0x1,
    Ctrl 0x2, Shift 0x4, Win 0x8). Shift-only is rejected on purpose: a bare
    letter+Shift just types text, so it makes a useless global hotkey.
#>
class HotkeyGesture {
    [bool] $Valid
    [string] $Reason
    [uint32] $Modifiers
    [uint32] $VirtualKey
    [string] $Normalized
    [object] $WpfKey     # the resolved [System.Windows.Input.Key] (for a WPF KeyBinding)

    static [uint32] $MOD_ALT = [uint32]0x1
    static [uint32] $MOD_CONTROL = [uint32]0x2
    static [uint32] $MOD_SHIFT = [uint32]0x4
    static [uint32] $MOD_WIN = [uint32]0x8

    # KeyConverter only accepts Oem* names, so alias both ways and echo what the user typed.
    static [hashtable] $PunctToKey = @{
        ',' = 'OemComma'; '.' = 'OemPeriod'; '/' = 'OemQuestion'; ';' = 'OemSemicolon'
        '-' = 'OemMinus'; '=' = 'OemPlus'; '[' = 'OemOpenBrackets'; ']' = 'Oem6'
    }
    # Derived inverse of PunctToKey, so the two directions can never drift apart.
    static [hashtable] $KeyToPunct = [HotkeyGesture]::Invert([HotkeyGesture]::PunctToKey)

    hidden static [hashtable] Invert([hashtable]$map) {
        $out = @{}
        foreach ($k in $map.Keys) { $out[$map[$k]] = $k }
        return $out
    }

    static [HotkeyGesture] Parse([string]$text) {
        $g = [HotkeyGesture]::new()

        if ([string]::IsNullOrWhiteSpace($text)) {
            $g.Reason = 'No hotkey set.'
            return $g
        }

        $tokens = @($text.Split('+') | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne '' })
        if ($tokens.Count -eq 0) {
            $g.Reason = 'No hotkey set.'
            return $g
        }

        $mods = [uint32]0
        $keyTokens = [System.Collections.Generic.List[string]]::new()
        foreach ($tok in $tokens) {
            $low = $tok.ToLowerInvariant()
            if ($low -in @('ctrl', 'control', 'ctl')) { $mods = $mods -bor [HotkeyGesture]::MOD_CONTROL }
            elseif ($low -in @('alt')) { $mods = $mods -bor [HotkeyGesture]::MOD_ALT }
            elseif ($low -in @('shift')) { $mods = $mods -bor [HotkeyGesture]::MOD_SHIFT }
            elseif ($low -in @('win', 'windows', 'super', 'meta')) { $mods = $mods -bor [HotkeyGesture]::MOD_WIN }
            else { $keyTokens.Add($tok) }
        }

        if ($keyTokens.Count -eq 0) {
            $g.Reason = 'Add a non-modifier key (e.g. D).'
            return $g
        }
        if ($keyTokens.Count -gt 1) {
            $g.Reason = "Only one non-modifier key is allowed (got '$($keyTokens -join "', '")')."
            return $g
        }

        $key = [HotkeyGesture]::ResolveKey($keyTokens[0])
        if ($null -eq $key) {
            $g.Reason = "Unrecognized key '$($keyTokens[0])'."
            return $g
        }

        # A bare Shift cannot gate a global hotkey since it just types, so require a real one.
        $realMods = [HotkeyGesture]::MOD_CONTROL -bor [HotkeyGesture]::MOD_ALT -bor [HotkeyGesture]::MOD_WIN
        if (($mods -band $realMods) -eq 0) {
            $g.Reason = 'Add Ctrl, Alt, or Win - Shift alone types text.'
            return $g
        }

        $g.Modifiers = $mods
        $g.VirtualKey = [uint32][KeyInterop]::VirtualKeyFromKey($key)
        $g.WpfKey = $key
        $g.Normalized = [HotkeyGesture]::Normalize($mods, $key)
        $g.Valid = $true
        return $g
    }

    # Builds a gesture from a live key event (the recorder): held modifiers + the single
    # non-modifier key. Routes through Parse so it validates/normalizes like a typed one.
    static [HotkeyGesture] FromKeys([ModifierKeys]$mods, [Key]$key) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($mods -band [ModifierKeys]::Control) { $parts.Add('Ctrl') }
        if ($mods -band [ModifierKeys]::Alt) { $parts.Add('Alt') }
        if ($mods -band [ModifierKeys]::Shift) { $parts.Add('Shift') }
        if ($mods -band [ModifierKeys]::Windows) { $parts.Add('Win') }
        $parts.Add($key.ToString())
        return [HotkeyGesture]::Parse($parts -join '+')
    }

    # Resolves a key token to a [Key] via WPF's KeyConverter (case-insensitive), mapping
    # bare punctuation to its Oem* name first. $null when the token is not a key name.
    hidden static [object] ResolveKey([string]$token) {
        if ([HotkeyGesture]::PunctToKey.ContainsKey($token)) {
            $token = [HotkeyGesture]::PunctToKey[$token]
        }
        try {
            $conv = [KeyConverter]::new()
            $key = $conv.ConvertFromInvariantString($token)
            if ($null -ne $key -and [Key]$key -ne [Key]::None) { return $key }
        }
        catch { }
        return $null
    }

    # Canonical form: modifiers in a fixed order (Ctrl, Alt, Shift, Win) then the key.
    hidden static [string] Normalize([uint32]$mods, [object]$key) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($mods -band [HotkeyGesture]::MOD_CONTROL) { $parts.Add('Ctrl') }
        if ($mods -band [HotkeyGesture]::MOD_ALT) { $parts.Add('Alt') }
        if ($mods -band [HotkeyGesture]::MOD_SHIFT) { $parts.Add('Shift') }
        if ($mods -band [HotkeyGesture]::MOD_WIN) { $parts.Add('Win') }
        $name = [KeyConverter]::new().ConvertToInvariantString($key)
        if ([HotkeyGesture]::KeyToPunct.ContainsKey($name)) {
            $name = [HotkeyGesture]::KeyToPunct[$name]
        }
        $parts.Add($name)
        return $parts -join '+'
    }
}
