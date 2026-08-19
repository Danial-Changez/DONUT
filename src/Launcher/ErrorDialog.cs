using System.Drawing;
using System.Windows.Forms;

namespace Donut.Launcher;

/// <summary>
/// The themed stand-in for <c>MessageBox</c> on every path that runs before WPF exists.
/// Leads with a one-line reason, follows with what to do, and keeps the exception behind
/// a Details toggle.
/// </summary>
/// <remarks>
/// Follows the popup chrome contract in docs/development/ui-reference.md: a 48px header
/// with the X flush right, 24px content gutters, and no footer - an error carries no
/// decision, and a dismiss-only button is banned because X and Esc already dismiss.
///
/// Themed by hand like <see cref="SplashForm"/>, since the WPF resource dictionaries are
/// not loaded (and two call sites fire precisely because they failed to load).
/// </remarks>
public sealed class ErrorDialog : Form {
    const int Gutter = 24;
    const int Width_ = 440;

    static readonly Color Ground = Color.FromArgb(0x0A, 0x0A, 0x0A);
    static readonly Color Title = Color.FromArgb(0xFA, 0xFA, 0xFA);
    static readonly Color Body = Color.FromArgb(0x9A, 0x9A, 0x9A);
    static readonly Color Link = Color.FromArgb(0xC4, 0xB5, 0xFD);
    static readonly Color Edge = Color.FromArgb(0x26, 0x26, 0x26);
    static readonly Color Terminal = Color.FromArgb(0x0B, 0x0B, 0x0E);
    static readonly Color TerminalText = Color.FromArgb(0xD4, 0xD4, 0xD4);

    readonly Label _reason;
    readonly Label _action;
    readonly Button _toggle;
    readonly TextBox _details;
    readonly string _detailText;
    bool _open;

    ErrorDialog(string caption, string reason, string action, string details) {
        FormBorderStyle = FormBorderStyle.None;
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
            Font = new Font("Segoe UI", 12f, FontStyle.Bold),
            TextAlign = ContentAlignment.MiddleLeft,
            Bounds = new Rectangle(Gutter, 0, Width_ - Gutter - 56, 48),
            BackColor = Color.Transparent,
        };

        var close = new Button {
            Text = "✕",
            FlatStyle = FlatStyle.Flat,
            ForeColor = Body,
            BackColor = Ground,
            Font = new Font("Segoe UI", 10f),
            Bounds = new Rectangle(Width_ - 46, 0, 46, 36),
            Cursor = Cursors.Hand,
            TabStop = false,
        };
        close.FlatAppearance.BorderSize = 0;
        close.Click += (s, e) => Close();

        // One line by contract, so a long reason clips rather than pushing the dialog open.
        _reason = new Label {
            Text = reason,
            ForeColor = Title,
            Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
            AutoEllipsis = true,
            AutoSize = false,
            Bounds = new Rectangle(Gutter, 50, Width_ - Gutter * 2, 22),
            BackColor = Color.Transparent,
        };

        _action = new Label {
            Text = action,
            ForeColor = Body,
            Font = new Font("Segoe UI", 9.5f),
            AutoSize = false,
            Bounds = new Rectangle(Gutter, 76, Width_ - Gutter * 2, 40),
            BackColor = Color.Transparent,
        };

        // A button, not a label, so the keyboard can open the details too.
        _toggle = new Button {
            Text = "▸ Details",
            FlatStyle = FlatStyle.Flat,
            ForeColor = Link,
            BackColor = Ground,
            Font = new Font("Segoe UI", 9f),
            TextAlign = ContentAlignment.MiddleLeft,
            Bounds = new Rectangle(Gutter - 4, 120, 90, 24),
            Cursor = Cursors.Hand,
        };
        _toggle.FlatAppearance.BorderSize = 0;
        _toggle.Click += (s, e) => Toggle();

        _details = new TextBox {
            Text = _detailText,
            ReadOnly = true,
            Multiline = true,
            WordWrap = true,
            ScrollBars = ScrollBars.Vertical,
            BorderStyle = BorderStyle.FixedSingle,
            BackColor = Terminal,
            ForeColor = TerminalText,
            Font = new Font("Cascadia Mono", 8.5f),
            Bounds = new Rectangle(Gutter, 144, Width_ - Gutter * 2, 120),
            Visible = false,
            TabStop = false,
        };

        Controls.AddRange([title, close, _reason, _action, _toggle, _details]);
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
        _toggle.Text = (_open ? "▾" : "▸") + " Details";
        _details.Visible = _open;
        Layout_();
    }

    // Grows to its content, since the action line wraps and the details block is optional.
    void Layout_() {
        int actionHeight = TextRenderer.MeasureText(
            _action.Text, _action.Font, new Size(_action.Width, 0), TextFormatFlags.WordBreak).Height;
        _action.Height = Math.Max(actionHeight, 18);
        _toggle.Top = _action.Bottom + 16;
        _details.Top = _toggle.Bottom + 10;
        // Not _toggle.Visible: a control reports invisible until its form is shown.
        bool hasDetails = _detailText.Length > 0;
        int bottom = hasDetails ? (_open ? _details.Bottom : _toggle.Bottom) : _action.Bottom;
        ClientSize = new Size(Width_, bottom + 20);
    }

    // The border the WPF popups draw with PanelBorder, which a borderless form must paint.
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        using var pen = new Pen(Edge, 1);
        e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
    }

    // No caption to drag by, so the ground answers as one (children still hit-test themselves).
    protected override void WndProc(ref Message m) {
        const int WM_NCHITTEST = 0x0084, HTCLIENT = 1, HTCAPTION = 2;
        base.WndProc(ref m);
        if (m.Msg == WM_NCHITTEST && (int)m.Result == HTCLIENT) { m.Result = HTCAPTION; }
    }
}
