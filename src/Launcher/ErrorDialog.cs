using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Donut.Launcher;

/// <summary>
/// The themed stand-in for <c>MessageBox</c> on every path that runs before WPF exists.
/// Leads with a one-line reason, follows with what to do, and keeps the exception behind
/// a Details toggle.
/// </summary>
/// <remarks>
/// Mirrors DialogWindow.xaml and the popup chrome contract in docs/development/ui-reference.md:
/// a 48px header with the X flush right, 24px content gutters, the TextPaneTitle / TextSubtitle /
/// TextBody tiers, and no footer - an error carries no decision, and a dismiss-only button is
/// banned because X and Esc already dismiss.
///
/// Themed by hand like <see cref="SplashForm"/>, since the WPF resource dictionaries are
/// not loaded (and two call sites fire precisely because they failed to load). The text
/// faces come from the embedded Montserrat files through GDI+, so the labels render with
/// compatible text rendering; the native details box keeps the mono fallback.
/// </remarks>
public sealed class ErrorDialog : Form {
    const int Gutter = 24;
    const int Width_ = 440;
    const int HeaderHeight = 48;

    // UIColors.xaml by hand, in its order: ground, title, body, link, border, hover, destructive, terminal.
    static readonly Color Ground = Color.FromArgb(0x0A, 0x0A, 0x0A);
    static readonly Color Title = Color.FromArgb(0xFA, 0xFA, 0xFA);
    static readonly Color Body = Color.FromArgb(0x9A, 0x9A, 0x9A);
    static readonly Color Link = Color.FromArgb(0xC4, 0xB5, 0xFD);
    static readonly Color Edge = Color.FromArgb(0x23, 0x23, 0x23);
    static readonly Color Hover = Color.FromArgb(0x27, 0x27, 0x2A);
    static readonly Color FocusRing = Color.FromArgb(0x99, 0x80, 0x22, 0xFE);
    static readonly Color HoverSubtle = Color.FromArgb(0x1E, 0x1E, 0x1E);
    static readonly Color Destructive = Color.FromArgb(0xFF, 0x64, 0x67);
    static readonly Color Terminal = Color.FromArgb(0x0B, 0x0B, 0x0E);
    static readonly Color TerminalText = Color.FromArgb(0xD4, 0xD4, 0xD4);

    readonly Label _reason;
    readonly Label _action;
    readonly LinkButton _toggle;
    readonly Panel _detailsFrame;
    readonly string _detailText;
    bool _open;
    bool _toggleHot;

    ErrorDialog(string caption, string reason, string action, string details) {
        // Borderless draws no caption, but the taskbar, Alt-Tab, and UIA read Text.
        Text = caption;
        FormBorderStyle = FormBorderStyle.None;
        ResizeRedraw = true;
        DoubleBuffered = true;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true;
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Ground;
        ClientSize = new Size(Width_, 200);
        KeyPreview = true;
        _detailText = details ?? string.Empty;

        var title = new Label {
            Text = caption,
            ForeColor = Title,
            Font = Fonts.Sans(18, FontStyle.Bold),
            UseCompatibleTextRendering = true,
            TextAlign = ContentAlignment.MiddleLeft,
            Bounds = new Rectangle(Gutter, 0, Width_ - Gutter - 56, HeaderHeight),
            BackColor = Ground,
        };

        // controlButton + controlButtonIcon: 50x36 in the corner, a 10px X, Destructive on hover.
        var close = new Button {
            FlatStyle = FlatStyle.Flat,
            BackColor = Ground,
            Bounds = new Rectangle(Width_ - 50, 0, 50, 36),
            Cursor = Cursors.Hand,
            TabStop = false,
            AccessibleName = "Close",
        };
        close.FlatAppearance.BorderSize = 0;
        close.FlatAppearance.MouseOverBackColor = Hover;
        close.FlatAppearance.MouseDownBackColor = Hover;
        close.Paint += PaintClose;
        close.MouseEnter += (s, e) => close.Invalidate();
        close.MouseLeave += (s, e) => close.Invalidate();
        close.Click += (s, e) => Close();

        // One line by contract, so a long reason clips rather than pushing the dialog open.
        _reason = new Label {
            Text = reason,
            ForeColor = Title,
            Font = Fonts.Sans(14, FontStyle.Bold),
            UseCompatibleTextRendering = true,
            AutoEllipsis = true,
            AutoSize = false,
            Bounds = new Rectangle(Gutter, HeaderHeight + 6, Width_ - Gutter * 2, 22),
            BackColor = Ground,
        };

        _action = new Label {
            Text = action,
            ForeColor = Body,
            Font = Fonts.Sans(13, FontStyle.Regular),
            UseCompatibleTextRendering = true,
            AutoSize = false,
            Bounds = new Rectangle(Gutter, _reason.Bottom + 4, Width_ - Gutter * 2, 40),
            BackColor = Ground,
        };

        // A button, not a label, so the keyboard can open the details; the chevron is drawn.
        _toggle = new LinkButton {
            FlatStyle = FlatStyle.Flat,
            BackColor = Ground,
            Font = Fonts.Sans(12, FontStyle.Regular),
            Bounds = new Rectangle(Gutter - 4, 120, 80, 26),
            Cursor = Cursors.Hand,
            AccessibleName = "Details",
        };
        _toggle.FlatAppearance.BorderSize = 0;
        _toggle.Paint += PaintToggle;
        _toggle.GotFocus += (s, e) => _toggle.Invalidate();
        _toggle.LostFocus += (s, e) => _toggle.Invalidate();
        _toggle.MouseEnter += (s, e) => { _toggleHot = true; _toggle.Invalidate(); };
        _toggle.MouseLeave += (s, e) => { _toggleHot = false; _toggle.Invalidate(); };
        _toggle.Click += (s, e) => Toggle();

        // TerminalBackground inside a PanelBorder frame, with the log's 6px inset.
        var detailsBox = new TextBox {
            Text = _detailText,
            ReadOnly = true,
            Multiline = true,
            WordWrap = true,
            ScrollBars = ScrollBars.Vertical,
            BorderStyle = BorderStyle.None,
            BackColor = Terminal,
            ForeColor = TerminalText,
            Font = Fonts.Mono(12),
            Dock = DockStyle.Fill,
            TabStop = false,
        };
        detailsBox.HandleCreated += (s, e) => SetWindowTheme(detailsBox.Handle, "DarkMode_Explorer", null);
        var detailsInner = new Panel { BackColor = Terminal, Padding = new Padding(10, 8, 10, 8), Dock = DockStyle.Fill };
        detailsInner.Controls.Add(detailsBox);
        _detailsFrame = new Panel {
            BackColor = Edge,
            Padding = new Padding(1),
            Bounds = new Rectangle(Gutter, 150, Width_ - Gutter * 2, 132),
            Visible = false,
        };
        _detailsFrame.Controls.Add(detailsInner);

        Controls.AddRange([title, close, _reason, _action, _toggle, _detailsFrame]);
        _toggle.Visible = _detailText.Length > 0;
        Layout_();

        KeyDown += (s, e) => {
            if (e.KeyCode == Keys.Escape) { Close(); }
        };
    }

    /// <summary>Shows the dialog modally. Safe to call from the STA worker thread.</summary>
    /// <param name="caption">Header text, Title Case, naming the surface that failed.</param>
    /// <param name="reason">One line saying what went wrong.</param>
    /// <param name="action">A sentence or two saying what to do. May be empty.</param>
    /// <param name="details">Exception text and anything else worth pasting. May be empty.</param>
    public static void Show(string caption, string reason, string action, string details) {
        using var dlg = new ErrorDialog(caption, reason, action, details);
        dlg.ShowDialog();
    }

    void Toggle() {
        _open = !_open;
        _detailsFrame.Visible = _open;
        _toggle.Invalidate();
        Layout_();
    }

    // Grows to its content, since the action line wraps and the details block is optional.
    void Layout_() {
        using (var g = CreateGraphics()) {
            float h = g.MeasureString(_action.Text, _action.Font, _action.Width).Height;
            _action.Height = Math.Max((int)Math.Ceiling(h), 18);
        }
        _toggle.Top = _action.Bottom + 16;
        _detailsFrame.Top = _toggle.Bottom + 10;
        // Not _toggle.Visible: a control reports invisible until its form is shown.
        bool hasDetails = _detailText.Length > 0;
        int bottom = hasDetails ? (_open ? _detailsFrame.Bottom : _toggle.Bottom) : _action.Bottom;
        ClientSize = new Size(Width_, bottom + 20);
    }

    void PaintClose(object? sender, PaintEventArgs e) {
        var b = (Control)sender!;
        bool hot = b.ClientRectangle.Contains(b.PointToClient(MousePosition));
        using (var fill = new SolidBrush(hot ? Hover : Ground))
            e.Graphics.FillRectangle(fill, b.ClientRectangle);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var pen = new Pen(hot ? Destructive : Body, 1f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        float cx = b.Width / 2f, cy = b.Height / 2f, r = 5f;
        e.Graphics.DrawLine(pen, cx - r, cy - r, cx + r, cy + r);
        e.Graphics.DrawLine(pen, cx - r, cy + r, cx + r, cy - r);
    }

    void PaintToggle(object? sender, PaintEventArgs e) {
        var b = (LinkButton)sender!;
        using (var fill = new SolidBrush(Ground)) e.Graphics.FillRectangle(fill, b.ClientRectangle);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        if (_toggleHot) {
            using var hover = new SolidBrush(HoverSubtle);
            e.Graphics.FillRoundedRectangle(hover, new Rectangle(0, 0, b.Width - 1, b.Height - 1), new Size(6, 6));
        }
        if (b.Focused && b.FocusCues) {
            using var ring = new Pen(FocusRing, 2f);
            e.Graphics.DrawRoundedRectangle(ring, new Rectangle(1, 1, b.Width - 3, b.Height - 3), new Size(6, 6));
        }
        Color ink = Link;
        using var pen = new Pen(ink, 1.2f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        float cy = b.Height / 2f, x = 8f;
        if (_open) {
            e.Graphics.DrawLine(pen, x, cy - 2, x + 3.5f, cy + 1.5f);
            e.Graphics.DrawLine(pen, x + 3.5f, cy + 1.5f, x + 7, cy - 2);
        } else {
            e.Graphics.DrawLine(pen, x + 1.5f, cy - 3.5f, x + 5, cy);
            e.Graphics.DrawLine(pen, x + 5, cy, x + 1.5f, cy + 3.5f);
        }
        using var brush = new SolidBrush(ink);
        using var fmt = new StringFormat { LineAlignment = StringAlignment.Center };
        e.Graphics.DrawString("Details", b.Font, brush, new RectangleF(x + 14, 0, b.Width, b.Height), fmt);
    }

    // The border the WPF popups draw with PanelBorder, which a borderless form must paint.
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        using var pen = new Pen(Edge, 1);
        e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
    }

    // The DWM rounding every WPF popup window gets; a borderless WinForms form must ask.
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        int round = 2;   // DWMWCP_ROUND
        _ = DwmSetWindowAttribute(Handle, 33, ref round, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hwnd, string subAppName, string? subIdList);

    // No caption to drag by, so the ground answers as one (children still hit-test themselves).
    protected override void WndProc(ref Message m) {
        const int WM_NCHITTEST = 0x0084, HTCLIENT = 1, HTCAPTION = 2;
        base.WndProc(ref m);
        if (m.Msg == WM_NCHITTEST && (int)m.Result == HTCLIENT) { m.Result = HTCAPTION; }
    }

    // Exposes the protected keyboard-cue flag, so the ring draws for Tab and never for a click.
    sealed class LinkButton : Button {
        public bool FocusCues => ShowFocusCues;
    }

    /// <summary>
    /// The embedded Montserrat faces for WinForms, loaded once from the launcher's resources so
    /// the pre-WPF windows share the app's type. Falls back to Segoe UI when a face is
    /// missing, the same fallback UIColors.xaml names.
    /// </summary>
    static class Fonts {
        static readonly PrivateFontCollection Collection = Load();

        public static Font Sans(float px, FontStyle style) {
            float pt = px * 72f / 96f;
            foreach (FontFamily fam in Collection.Families) {
                if (fam.Name == "Montserrat" && fam.IsStyleAvailable(style)) return new Font(fam, pt, style);
            }
            return new Font("Segoe UI", pt, style);
        }

        public static Font Mono(float px) {
            float pt = px * 72f / 96f;
            foreach (FontFamily fam in Collection.Families) {
                if (fam.Name == "Geist Mono") return new Font(fam, pt);
            }
            return new Font("Cascadia Mono", pt);
        }

        // The bytes stay pinned for the process: GDI+ reads memory fonts lazily.
        static PrivateFontCollection Load() {
            var collection = new PrivateFontCollection();
            string dir = Path.Combine(Path.GetTempPath(), "donut-fonts");
            foreach (string file in new[] { "Montserrat-Regular.ttf", "Montserrat-Bold.ttf", "GeistMono-Regular.ttf" }) {
                using var s = EmbeddedAssets.Open("src/UI/Styles/Fonts/" + file);
                if (s is null) continue;
                var bytes = new byte[s.Length];
                s.ReadExactly(bytes);
                IntPtr mem = Marshal.AllocHGlobal(bytes.Length);
                Marshal.Copy(bytes, 0, mem, bytes.Length);
                try { collection.AddMemoryFont(mem, bytes.Length); } catch { Marshal.FreeHGlobal(mem); }
                // GDI as well: WinForms DPI autoscale recreates fonts by NAME, not by family object.
                try {
                    Directory.CreateDirectory(dir);
                    string path = Path.Combine(dir, file);
                    if (!File.Exists(path)) File.WriteAllBytes(path, bytes);
                    _ = AddFontResourceEx(path, FR_PRIVATE, IntPtr.Zero);
                } catch { /* the Segoe fallback still renders */ }
            }
            return collection;
        }

        const uint FR_PRIVATE = 0x10;

        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        static extern int AddFontResourceEx(string file, uint flags, IntPtr reserved);
    }
}
