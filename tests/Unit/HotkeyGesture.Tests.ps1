using module "..\..\src\Models\HotkeyGesture.psm1"
using namespace System.Windows.Input

BeforeDiscovery {
    # The parse uses WPF's KeyConverter/KeyInterop at runtime.
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
}

Describe "HotkeyGesture.Parse" {

    BeforeAll {
        Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        # Win32 MOD_* flags, mirrored so the tests read independently of the class.
        $script:ALT = [uint32]0x1
        $script:CTRL = [uint32]0x2
        $script:SHIFT = [uint32]0x4
        $script:WIN = [uint32]0x8
    }

    Context "Valid gestures" {
        It "Parses the default Ctrl+Alt+D" {
            $g = [HotkeyGesture]::Parse('Ctrl+Alt+D')
            $g.Valid | Should -BeTrue
            $g.Modifiers | Should -Be ($script:CTRL -bor $script:ALT)
            $g.VirtualKey | Should -Be 68     # VK_D
            $g.Normalized | Should -Be 'Ctrl+Alt+D'
        }

        It "Accepts modifier aliases (control/windows) and is case-insensitive" {
            (([HotkeyGesture]::Parse('CONTROL+alt+d')).Normalized) | Should -Be 'Ctrl+Alt+D'
            $win = [HotkeyGesture]::Parse('windows+K')
            $win.Valid | Should -BeTrue
            $win.Modifiers | Should -Be $script:WIN
            $win.Normalized | Should -Be 'Win+K'
        }

        It "Accepts a Win-modifier combo" {
            $g = [HotkeyGesture]::Parse('Ctrl+Win+K')
            $g.Valid | Should -BeTrue
            $g.Modifiers | Should -Be ($script:CTRL -bor $script:WIN)
        }

        It "Accepts bare punctuation and round-trips it (Ctrl+, for settings)" {
            $g = [HotkeyGesture]::Parse('Ctrl+,')
            $g.Valid | Should -BeTrue
            $g.Modifiers | Should -Be $script:CTRL
            $g.Normalized | Should -Be 'Ctrl+,'
            $g.VirtualKey | Should -Be 188      # VK_OEM_COMMA
        }

        It "Exposes the resolved WPF Key for a KeyBinding" {
            $g = [HotkeyGesture]::Parse('Ctrl+,')
            [string]$g.WpfKey | Should -Be 'OemComma'
            ([ModifierKeys]$g.Modifiers) | Should -Be ([ModifierKeys]::Control)
        }

        It "Tolerates whitespace and mixed order around tokens" {
            $g = [HotkeyGesture]::Parse('  alt +  ctrl + d ')
            $g.Valid | Should -BeTrue
            # Modifiers always normalize to the canonical Ctrl, Alt, Shift, Win order.
            $g.Normalized | Should -Be 'Ctrl+Alt+D'
        }

        It "Allows Shift when a real modifier is also present" {
            $g = [HotkeyGesture]::Parse('Ctrl+Shift+K')
            $g.Valid | Should -BeTrue
            $g.Modifiers | Should -Be ($script:CTRL -bor $script:SHIFT)
            $g.Normalized | Should -Be 'Ctrl+Shift+K'
        }
    }

    Context "Normalization round-trip" {
        It "Re-parses its own Normalized form to the same gesture" -ForEach @(
            @{ Text = 'ctrl+alt+d' }
            @{ Text = 'WIN+shift+f5' }
            @{ Text = 'alt+escape' }
            @{ Text = 'ctrl+1' }
        ) {
            $first = [HotkeyGesture]::Parse($Text)
            $first.Valid | Should -BeTrue
            $second = [HotkeyGesture]::Parse($first.Normalized)
            $second.Valid | Should -BeTrue
            $second.Normalized | Should -Be $first.Normalized
            $second.Modifiers | Should -Be $first.Modifiers
            $second.VirtualKey | Should -Be $first.VirtualKey
        }
    }

    Context "Invalid gestures" {
        It "Rejects an empty or whitespace gesture with a reason" {
            foreach ($t in @('', '   ', "`t")) {
                $g = [HotkeyGesture]::Parse($t)
                $g.Valid | Should -BeFalse
                $g.Reason | Should -Not -BeNullOrEmpty
            }
        }

        It "Rejects a key with no modifier" {
            $g = [HotkeyGesture]::Parse('D')
            $g.Valid | Should -BeFalse
            $g.Reason | Should -Match 'Ctrl'
        }

        It "Rejects a Shift-only combo (it just types text)" {
            $g = [HotkeyGesture]::Parse('Shift+D')
            $g.Valid | Should -BeFalse
            $g.Reason | Should -Match 'Shift'
        }

        It "Rejects two non-modifier keys" {
            $g = [HotkeyGesture]::Parse('Ctrl+D+E')
            $g.Valid | Should -BeFalse
            $g.Reason | Should -Match 'one non-modifier'
        }

        It "Rejects an unknown key token" {
            $g = [HotkeyGesture]::Parse('Ctrl+Frobnicate')
            $g.Valid | Should -BeFalse
            $g.Reason | Should -Match 'Unrecognized'
        }

        It "Rejects modifiers with no key at all" {
            $g = [HotkeyGesture]::Parse('Ctrl+Alt')
            $g.Valid | Should -BeFalse
            $g.Reason | Should -Match 'non-modifier key'
        }
    }
}

Describe "HotkeyGesture.FromKeys" {
    BeforeAll {
        Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    }

    It "Builds Ctrl+Alt+D from held modifiers + a key" {
        $mods = [ModifierKeys]::Control -bor [ModifierKeys]::Alt
        $g = [HotkeyGesture]::FromKeys($mods, [Key]::D)
        $g.Valid | Should -BeTrue
        $g.Normalized | Should -Be 'Ctrl+Alt+D'
    }

    It "Normalizes a punctuation key back to its symbol (Ctrl+,)" {
        $g = [HotkeyGesture]::FromKeys([ModifierKeys]::Control, [Key]::OemComma)
        $g.Valid | Should -BeTrue
        $g.Normalized | Should -Be 'Ctrl+,'
    }

    It "Rejects a Shift-only recording (matches Parse rules)" {
        $g = [HotkeyGesture]::FromKeys([ModifierKeys]::Shift, [Key]::A)
        $g.Valid | Should -BeFalse
        $g.Reason | Should -Match 'Shift'
    }

    It "Rejects a bare key with no Ctrl/Alt/Win" {
        $g = [HotkeyGesture]::FromKeys([ModifierKeys]::None, [Key]::F8)
        $g.Valid | Should -BeFalse
    }

    It "Round-trips through Parse (recorded == typed)" {
        $recorded = [HotkeyGesture]::FromKeys(
            [ModifierKeys]::Control -bor [ModifierKeys]::Shift,
            [Key]::F5)
        $typed = [HotkeyGesture]::Parse('Ctrl+Shift+F5')
        $recorded.Normalized | Should -Be $typed.Normalized
        $recorded.VirtualKey | Should -Be $typed.VirtualKey
    }
}
