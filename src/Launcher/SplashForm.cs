using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using Timer = System.Windows.Forms.Timer;   // disambiguate from System.Threading.Timer

namespace Donut.Launcher;

/// <summary>
/// Borderless startup splash carrying the donut GIF, the current init milestone, and
/// an owner-drawn progress bar. Lives on the main thread while the app graph parses on
/// the worker thread, so it stays responsive throughout.
/// </summary>
/// <remarks>
/// Minimizes, drags, and is not <c>TopMost</c>: <see cref="Bootstrap"/> raises an
/// owner-less <see cref="ErrorDialog"/> from the worker thread, which a TopMost splash
/// covered, leaving a first run that reads as frozen on its last milestone.
/// </remarks>
public sealed class SplashForm : Form {
    // Matches the app's violet accent, and loading.gif is keyed to this ground.
    private static readonly Color Violet = Color.FromArgb(0x8E, 0x51, 0xFF);

    private readonly PictureBox _art;
    private readonly Label _word;
    private readonly Label _status;
    private readonly Label _pct;
    private readonly SmoothProgressBar _bar;
    private readonly Button _minimize;

    /// <summary>Builds the splash window and loads its art from embedded resources.</summary>
    public SplashForm() {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true;
        MaximizeBox = false;
        // Bounds below are designed at 96 DPI, so a scaled display needs this anchor.
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Color.FromArgb(0x0A, 0x0A, 0x0A);
        ClientSize = new Size(420, 300);
        DoubleBuffered = true;

        _art = new PictureBox {
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Color.Transparent,
            Bounds = new Rectangle((420 - 132) / 2, 40, 132, 132),
        };
        TryLoadArtFromResources();

        _word = new Label {
            Text = "DONUT",
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 20f, FontStyle.Bold),
            TextAlign = ContentAlignment.MiddleCenter,
            Bounds = new Rectangle(0, 190, 420, 34),
            BackColor = Color.Transparent,
        };

        _status = new Label {
            Text = "Starting up…",
            ForeColor = Color.FromArgb(0x9A, 0x9A, 0x9A),
            Font = new Font("Segoe UI", 10.5f),
            TextAlign = ContentAlignment.MiddleLeft,
            Bounds = new Rectangle(44, 240, 250, 20),
            BackColor = Color.Transparent,
        };

        _pct = new Label {
            Text = "",
            ForeColor = Violet,
            Font = new Font("Cascadia Mono", 10.5f),
            TextAlign = ContentAlignment.MiddleRight,
            Bounds = new Rectangle(286, 240, 90, 20),
            BackColor = Color.Transparent,
        };

        _bar = new SmoothProgressBar {
            Bounds = new Rectangle(44, 268, 332, 10),
            FillColor = Violet,
        };

        _minimize = new Button {
            FlatStyle = FlatStyle.Flat,
            BackColor = BackColor,
            Bounds = new Rectangle(420 - 50, 0, 50, 36),
            Cursor = Cursors.Hand,
            TabStop = false,
        };
        _minimize.FlatAppearance.BorderSize = 0;
        _minimize.FlatAppearance.MouseOverBackColor = Color.FromArgb(0x1C, 0x1C, 0x1C);
        _minimize.FlatAppearance.MouseDownBackColor = Color.FromArgb(0x26, 0x26, 0x26);
        _minimize.Paint += PaintMinimize;
        _minimize.Click += (s, e) => WindowState = FormWindowState.Minimized;

        Controls.Add(_minimize);
        Controls.Add(_art);
        Controls.Add(_word);
        Controls.Add(_status);
        Controls.Add(_pct);
        Controls.Add(_bar);
    }

    // Draws the app's Minimize geometry ('M5 12h14') plus the accent it would otherwise cover.
    private void PaintMinimize(object? sender, PaintEventArgs e) {
        var button = (Control)sender!;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (var accent = new Pen(Color.FromArgb(90, Violet), 2))
            e.Graphics.DrawLine(accent, 0, 1, button.Width, 1);
        using var glyph = new Pen(Color.FromArgb(0x9A, 0x9A, 0x9A), 1.4f);
        float mid = button.Height / 2f;
        e.Graphics.DrawLine(glyph, (button.Width - 14) / 2f, mid, (button.Width + 14) / 2f, mid);
    }

    // Falls back to the static logo, and a PictureBox animates a GIF on its own.
    private void TryLoadArtFromResources() {
        foreach (string logical in new[] { "assets/Images/loading.gif",
                                           "assets/Images/logo yellow arrow.png" }) {
            Image? img = EmbeddedAssets.LoadImage(logical);
            if (img != null) { _art.Image = img; return; }
        }
    }

    // A borderless form gets no DWM rounding, so the corners are clipped by hand.
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        using var path = new GraphicsPath();
        int r = 16;
        path.AddArc(0, 0, r, r, 180, 90);
        path.AddArc(Width - r, 0, r, r, 270, 90);
        path.AddArc(Width - r, Height - r, r, r, 0, 90);
        path.AddArc(0, Height - r, r, r, 90, 90);
        path.CloseFigure();
        Region = new Region(path);
    }

    // No caption to drag by, so the ground answers as one (children still hit-test themselves).
    protected override void WndProc(ref Message m) {
        const int WM_NCHITTEST = 0x0084, HTCLIENT = 1, HTCAPTION = 2;
        base.WndProc(ref m);
        if (m.Msg == WM_NCHITTEST && (int)m.Result == HTCLIENT) { m.Result = HTCAPTION; }
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        using var pen = new Pen(Color.FromArgb(90, Violet), 2);
        e.Graphics.DrawLine(pen, 0, 1, Width, 1);   // hairline accent along the top edge
    }

    // --- invoked on the UI thread via StartupProgress ---

    /// <summary>Moves the bar to a determinate value and updates the status line.</summary>
    /// <param name="percent">Completion 0–100.</param>
    /// <param name="status">Status line shown under the bar.</param>
    public void SetProgress(int percent, string status) {
        _status.Text = status;
        _bar.Value = percent;
        _pct.Text = percent + "%";
    }

    /// <summary>Fills the bar to 100%, then dismisses the splash after a brief settle.</summary>
    public void CompleteAndClose() {
        if (IsDisposed) return;
        _bar.Value = 100;
        _pct.Text = "100%";
        _status.Text = "Ready";
        // Let the bar visibly settle at 100% before dismissing.
        var t = new Timer { Interval = 220 };
        t.Tick += (s, e) => {
            t.Stop();
            t.Dispose();
            Close();
        };
        t.Start();
    }
}
