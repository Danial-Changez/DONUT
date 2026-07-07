using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Donut.Launcher;

/// <summary>
/// Owner-drawn progress bar with a rounded track and a brand-yellow fill. The stock
/// WinForms <see cref="ProgressBar"/> renders through the Windows visual styles, which
/// ignore ForeColor and lock the fill to the theme green; this control paints its own
/// colour, eases toward the target value for a smooth fill, and offers an indeterminate
/// sweep for the pre-progress module-parse phase.
/// </summary>
public sealed class SmoothProgressBar : Control
{
    private int _value;
    private int _maximum = 100;
    private double _display;        // eased fill position (px) for smooth motion
    private bool _indeterminate = true;
    private int _sweepX;
    private readonly Timer _anim;

    public Color FillColor { get; set; } = Color.FromArgb(0xF2, 0xB4, 0x17);
    public Color TrackColor { get; set; } = Color.FromArgb(38, 255, 255, 255);

    public SmoothProgressBar()
    {
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        Height = 8;
        _anim = new Timer { Interval = 33 };
        _anim.Tick += OnTick;
        _anim.Start();
    }

    public bool Indeterminate
    {
        get => _indeterminate;
        set { _indeterminate = value; Invalidate(); }
    }

    public int Maximum
    {
        get => _maximum;
        set { _maximum = Math.Max(1, value); Invalidate(); }
    }

    // Setting a value implicitly leaves the indeterminate phase (the first real
    // milestone proves the parse finished).
    public int Value
    {
        get => _value;
        set
        {
            _value = Math.Max(0, Math.Min(_maximum, value));
            _indeterminate = false;
            Invalidate();
        }
    }

    private void OnTick(object? sender, EventArgs e)
    {
        if (_indeterminate)
        {
            _sweepX += Math.Max(4, Width / 40);
            if (_sweepX > Width + Width / 3) _sweepX = -Width / 3;
            Invalidate();
        }
        else
        {
            double target = (double)_value / _maximum * Width;
            if (Math.Abs(_display - target) > 0.5)
            {
                _display += (target - _display) * 0.22;   // ease toward target
                Invalidate();
            }
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        float r = Height / 2f;
        var rect = new RectangleF(0, 0, Width - 1, Height - 1);
        using GraphicsPath track = RoundedRect(rect, r);
        using (var tb = new SolidBrush(TrackColor))
            g.FillPath(tb, track);

        g.SetClip(track);
        if (_indeterminate)
        {
            int bandW = Math.Max(40, Width / 3);
            var band = new Rectangle(_sweepX, 0, bandW, Height);
            using var lg = new LinearGradientBrush(band, Color.Transparent, FillColor,
                LinearGradientMode.Horizontal)
            {
                // symmetric fade in/out so the band reads as a moving highlight
                Blend = new Blend
                {
                    Positions = new[] { 0f, 0.5f, 1f },
                    Factors = new[] { 0f, 1f, 0f },
                },
            };
            g.FillRectangle(lg, band);
        }
        else
        {
            float w = (float)Math.Round(_display);
            if (w > 0)
            {
                var fillRect = new RectangleF(0, 0, Math.Max(w, r * 2), Height - 1);
                using GraphicsPath fill = RoundedRect(fillRect, r);
                using var fb = new SolidBrush(FillColor);
                g.FillPath(fb, fill);
            }
        }
        g.ResetClip();
    }

    private static GraphicsPath RoundedRect(RectangleF b, float r)
    {
        var p = new GraphicsPath();
        float d = r * 2;
        if (d > b.Height) d = b.Height;
        if (d > b.Width) d = b.Width;
        p.AddArc(b.X, b.Y, d, d, 180, 90);
        p.AddArc(b.Right - d, b.Y, d, d, 270, 90);
        p.AddArc(b.Right - d, b.Bottom - d, d, d, 0, 90);
        p.AddArc(b.X, b.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _anim.Dispose();
        base.Dispose(disposing);
    }
}
