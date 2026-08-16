#nullable enable
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Donut.Interop {
    /// <summary>
    /// Registers a single global show/restore hotkey via user32 RegisterHotKey and raises
    /// <see cref="Pressed"/> when it fires. RegisterHotKey (not a keyboard hook) is used on
    /// purpose: it never observes the global keystroke stream, so it does not trip AV/EDR
    /// keylogger heuristics. The WM_HOTKEY message is delivered to the window's WndProc, so
    /// the hook (and thus <see cref="Pressed"/>) runs on that window's UI thread.
    /// </summary>
    public sealed class HotkeyManager {
        private const int HotkeyId = 0x0D0;
        private const uint MOD_NOREPEAT = 0x4000;
        private const int WM_HOTKEY = 0x0312;

        private IntPtr _hwnd;
        private HwndSource? _source;
        private bool _registered;

        /// <summary>Raised on the UI thread each time the registered combo is pressed.</summary>
        public event EventHandler? Pressed;

        /// <summary>Win32 error from the last <see cref="Attach"/> (1409 = combo already in use).</summary>
        public int LastError { get; private set; }

        /// <summary>
        /// Registers the combo on <paramref name="hwnd"/> and hooks its WndProc. Replaces any
        /// prior registration. Returns false on failure (see <see cref="LastError"/>).
        /// </summary>
        /// <param name="hwnd">Target window handle (must already exist).</param>
        /// <param name="modifiers">MOD_ALT/CONTROL/SHIFT/WIN bitmask.</param>
        /// <param name="vk">Virtual-key code of the non-modifier key.</param>
        public bool Attach(IntPtr hwnd, uint modifiers, uint vk) {
            Detach();

            _source = HwndSource.FromHwnd(hwnd);
            if (_source == null) { LastError = 0; return false; }

            _hwnd = hwnd;
            _source.AddHook(WndHook);

            // MOD_NOREPEAT: one event per physical press, not an autorepeat stream.
            if (!RegisterHotKey(hwnd, HotkeyId, modifiers | MOD_NOREPEAT, vk)) {
                LastError = Marshal.GetLastWin32Error();
                _source.RemoveHook(WndHook);
                _source = null;
                _hwnd = IntPtr.Zero;
                return false;
            }

            _registered = true;
            LastError = 0;
            return true;
        }

        /// <summary>Unregisters the combo and removes the WndProc hook. Idempotent.</summary>
        public void Detach() {
            if (_registered && _hwnd != IntPtr.Zero) {
                UnregisterHotKey(_hwnd, HotkeyId);
                _registered = false;
            }
            if (_source != null) {
                _source.RemoveHook(WndHook);
                _source = null;
            }
            _hwnd = IntPtr.Zero;
        }

        private IntPtr WndHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
            if (msg == WM_HOTKEY && wParam.ToInt32() == HotkeyId) {
                Pressed?.Invoke(this, EventArgs.Empty);
                handled = true;
            }
            return IntPtr.Zero;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    }
}
