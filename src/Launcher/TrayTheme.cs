using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Donut.Interop;

/// <summary>
/// Themes the tray <see cref="ContextMenuStrip"/> to the app's Arcane look: near-black
/// surface, zinc hover, subtle border, Win11 rounded corners. The tray menu is the one
/// WinForms surface the WPF resource dictionaries cannot reach, so its palette lives
/// here (values mirror UIColors.xaml: PanelBackground / PanelBackgroundActive / the
/// PanelBorder hairline composited over the surface).
/// </summary>
public static class TrayTheme
{
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWCP_ROUNDSMALL = 3;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    private static readonly Color Surface = Color.FromArgb(0x12, 0x12, 0x12);
    private static readonly Color Hover = Color.FromArgb(0x27, 0x27, 0x2A);
    private static readonly Color Border = Color.FromArgb(0x2B, 0x2B, 0x2B);

    /// <summary>Applies the app palette and rounded corners to a tray menu.</summary>
    public static void Apply(ContextMenuStrip menu)
    {
        menu.Renderer = new ToolStripProfessionalRenderer(new DonutColorTable())
        {
            RoundedEdges = false,
        };
        menu.ShowImageMargin = false;
        menu.BackColor = Surface;
        menu.ForeColor = Color.FromArgb(0xFA, 0xFA, 0xFA);
        menu.Opening += (s, e) =>
        {
            // Win11 DWM rounding on the dropdown's own window; pre-Win11 the call
            // fails and the menu stays square - still themed, just not rounded.
            int pref = DWMWCP_ROUNDSMALL;
            try { _ = DwmSetWindowAttribute(menu.Handle, DWMWA_WINDOW_CORNER_PREFERENCE, ref pref, sizeof(int)); }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        };
        // Opened from the taskbar's overflow flyout, the FLYOUT holds foreground; when
        // it auto-dismisses, no deactivation ever reaches the menu and it floats
        // orphaned (the old NotifyIcon menu bug). Foregrounding the menu itself makes
        // click-away and focus loss dismiss it like every other tray menu.
        menu.Opened += (s, e) => SetForegroundWindow(menu.Handle);
    }

    private sealed class DonutColorTable : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground => Surface;
        public override Color MenuItemSelected => Hover;
        public override Color MenuItemSelectedGradientBegin => Hover;
        public override Color MenuItemSelectedGradientEnd => Hover;
        public override Color MenuItemBorder => Hover;
        public override Color MenuBorder => Border;
        public override Color ImageMarginGradientBegin => Surface;
        public override Color ImageMarginGradientMiddle => Surface;
        public override Color ImageMarginGradientEnd => Surface;
        public override Color SeparatorDark => Border;
        public override Color SeparatorLight => Surface;
    }
}
