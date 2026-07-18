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

    static [uint32] $MOD_ALT = [uint32]0x1
    static [uint32] $MOD_CONTROL = [uint32]0x2
    static [uint32] $MOD_SHIFT = [uint32]0x4
    static [uint32] $MOD_WIN = [uint32]0x8

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

        # A bare Shift can't gate a global hotkey (it just types); require a real modifier.
        $realMods = [HotkeyGesture]::MOD_CONTROL -bor [HotkeyGesture]::MOD_ALT -bor [HotkeyGesture]::MOD_WIN
        if (($mods -band $realMods) -eq 0) {
            $g.Reason = 'Add Ctrl, Alt, or Win - Shift alone types text.'
            return $g
        }

        $g.Modifiers = $mods
        $g.VirtualKey = [uint32][KeyInterop]::VirtualKeyFromKey($key)
        $g.Normalized = [HotkeyGesture]::Normalize($mods, $key)
        $g.Valid = $true
        return $g
    }

    # Resolves a key token to a [Key] via WPF's KeyConverter (case-insensitive); $null
    # when the token isn't a key name.
    hidden static [object] ResolveKey([string]$token) {
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
        $parts.Add([KeyConverter]::new().ConvertToInvariantString($key))
        return $parts -join '+'
    }
}
