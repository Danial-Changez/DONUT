using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Windows.Forms;
using Timer = System.Windows.Forms.Timer;   // disambiguate from System.Threading.Timer

namespace Donut.Launcher;

/// <summary>
/// Borderless startup splash shown by <see cref="Program"/> before the PowerShell app
/// graph parses. Displays the spinning-donut art (an animated GIF), the current init
/// milestone, and an owner-drawn brand-yellow progress bar. It lives on the launcher's
/// main (UI) thread while the app builds on the PowerShell worker thread, so it stays
/// responsive while the module-parse blocks that thread.
/// </summary>
public sealed class SplashForm : Form
{
    // Dark splash; loading.gif is keyed transparent so the pink donut floats on it.
    private static readonly Color Yellow = Color.FromArgb(0xF2, 0xB4, 0x17);

    private readonly PictureBox _art;
    private readonly Label _word;
    private readonly Label _status;
    private readonly Label _pct;
    private readonly SmoothProgressBar _bar;

    public SplashForm(string? assetsDir)
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = false;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Color.FromArgb(0x22, 0x1F, 0x18);
        ClientSize = new Size(360, 240);
        DoubleBuffered = true;

        _art = new PictureBox
        {
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Color.Transparent,
            Bounds = new Rectangle((360 - 120) / 2, 26, 120, 120),
        };
        TryLoadArt(assetsDir);

        _word = new Label
        {
            Text = "DONUT",
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 15f, FontStyle.Bold),
            TextAlign = ContentAlignment.MiddleCenter,
            Bounds = new Rectangle(0, 150, 360, 26),
            BackColor = Color.Transparent,
        };

        _status = new Label
        {
            Text = "Starting up…",
            ForeColor = Color.FromArgb(0xC4, 0xBB, 0xA3),
            Font = new Font("Segoe UI", 9f),
            TextAlign = ContentAlignment.MiddleLeft,
            Bounds = new Rectangle(40, 188, 200, 18),
            BackColor = Color.Transparent,
        };

        _pct = new Label
        {
            Text = "",
            ForeColor = Yellow,
            Font = new Font("Consolas", 9f),
            TextAlign = ContentAlignment.MiddleRight,
            Bounds = new Rectangle(240, 188, 80, 18),
            BackColor = Color.Transparent,
        };

        _bar = new SmoothProgressBar
        {
            Bounds = new Rectangle(40, 212, 280, 8),
            FillColor = Yellow,
        };

        Controls.Add(_art);
        Controls.Add(_word);
        Controls.Add(_status);
        Controls.Add(_pct);
        Controls.Add(_bar);
    }

    // Loads the splash art: the spinning-donut GIF if present, otherwise the existing
    // static logo, otherwise nothing. GIFs animate automatically in a PictureBox.
    private void TryLoadArt(string? assetsDir)
    {
        foreach (string name in new[] { "loading.gif", "logo yellow arrow.png" })
        {
            var candidates = new List<string>();
            if (!string.IsNullOrEmpty(assetsDir))
                candidates.Add(Path.Combine(assetsDir, name));
            candidates.Add(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "Bakery", "DONUT", "assets", "Images", name));

            foreach (string path in candidates)
            {
                try
                {
                    if (!File.Exists(path)) continue;
                    // Copy into memory so the source file isn't left locked.
                    using var fs = new FileStream(path, FileMode.Open, FileAccess.Read);
                    var ms = new MemoryStream();
                    fs.CopyTo(ms);
                    ms.Position = 0;
                    _art.Image = Image.FromStream(ms);
                    return;
                }
                catch { /* try the next candidate; a missing/broken asset is non-fatal */ }
            }
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
        using var pen = new Pen(Color.FromArgb(90, Yellow), 2);
        e.Graphics.DrawLine(pen, 0, 1, Width, 1);   // hairline accent along the top edge
    }

    // --- invoked on the UI thread via StartupProgress ---

    public void SetProgress(int percent, string status)
    {
        _status.Text = status;
        _bar.Value = percent;               // leaves the indeterminate phase
        _pct.Text = percent + "%";
    }

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
