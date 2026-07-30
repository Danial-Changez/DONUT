using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using Timer = System.Windows.Forms.Timer;   // disambiguate from System.Threading.Timer

namespace Donut.Launcher;

/// <summary>
/// Borderless startup splash - spinning-donut GIF, the current init milestone, and an
/// owner-drawn progress bar. Lives on the main thread while the app graph parses on the
/// worker thread, so it stays responsive through the parse.
/// </summary>
public sealed class SplashForm : Form
{
    // Arcane splash: near-black ground + violet accent (matches the app's theme); the
    // loading.gif is keyed transparent so the pink donut floats on it.
    private static readonly Color Violet = Color.FromArgb(0x8E, 0x51, 0xFF);

    private readonly PictureBox _art;
    private readonly Label _word;
    private readonly Label _status;
    private readonly Label _pct;
    private readonly SmoothProgressBar _bar;

    /// <summary>Builds the splash window and loads its art from embedded resources.</summary>
    public SplashForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = false;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Color.FromArgb(0x0A, 0x0A, 0x0A);
        ClientSize = new Size(420, 300);
        DoubleBuffered = true;

        _art = new PictureBox
        {
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Color.Transparent,
            Bounds = new Rectangle((420 - 132) / 2, 40, 132, 132),
        };
        TryLoadArtFromResources();

        _word = new Label
        {
            Text = "DONUT",
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 20f, FontStyle.Bold),
            TextAlign = ContentAlignment.MiddleCenter,
            Bounds = new Rectangle(0, 190, 420, 34),
            BackColor = Color.Transparent,
        };

        _status = new Label
        {
            Text = "Starting up…",
            ForeColor = Color.FromArgb(0x9A, 0x9A, 0x9A),
            Font = new Font("Segoe UI", 10.5f),
            TextAlign = ContentAlignment.MiddleLeft,
            Bounds = new Rectangle(44, 240, 250, 20),
            BackColor = Color.Transparent,
        };

        _pct = new Label
        {
            Text = "",
            ForeColor = Violet,
            Font = new Font("Consolas", 10.5f),
            TextAlign = ContentAlignment.MiddleRight,
            Bounds = new Rectangle(286, 240, 90, 20),
            BackColor = Color.Transparent,
        };

        _bar = new SmoothProgressBar
        {
            Bounds = new Rectangle(44, 268, 332, 10),
            FillColor = Violet,
        };

        Controls.Add(_art);
        Controls.Add(_word);
        Controls.Add(_status);
        Controls.Add(_pct);
        Controls.Add(_bar);
    }

    // Loads the splash art from embedded resources: the spinning-donut GIF if present,
    // otherwise the static logo. GIFs animate automatically in a PictureBox.
    private void TryLoadArtFromResources()
    {
        foreach (string logical in new[] { "assets/Images/loading.gif",
                                           "assets/Images/logo yellow arrow.png" })
        {
            Image? img = EmbeddedAssets.LoadImage(logical);
            if (img != null) { _art.Image = img; return; }
        }
    }

    // Rounded window corners (borderless form).
    protected override void OnHandleCreated(EventArgs e)
    {
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

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var pen = new Pen(Color.FromArgb(90, Violet), 2);
        e.Graphics.DrawLine(pen, 0, 1, Width, 1);   // hairline accent along the top edge
    }

    // --- invoked on the UI thread via StartupProgress ---

    /// <summary>Moves the bar to a determinate value and updates the status line.</summary>
    /// <param name="percent">Completion 0–100.</param>
    /// <param name="status">Status line shown under the bar.</param>
    public void SetProgress(int percent, string status)
    {
        _status.Text = status;
        _bar.Value = percent;               // leaves the indeterminate phase
        _pct.Text = percent + "%";
    }

    /// <summary>Fills the bar to 100%, then dismisses the splash after a brief settle.</summary>
    public void CompleteAndClose()
    {
        if (IsDisposed) return;
        _bar.Value = 100;
        _pct.Text = "100%";
        _status.Text = "Ready";
        // Let the bar visibly settle at 100% before dismissing.
        var t = new Timer { Interval = 220 };
        t.Tick += (s, e) =>
        {
            t.Stop();
            t.Dispose();
            Close();
        };
        t.Start();
    }
}
