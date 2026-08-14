using System;
using System.ComponentModel;
using System.Drawing;
using System.Windows.Forms;

namespace Donut.Launcher;

/// <summary>
/// Minimal owner-painted progress bar, because the stock <see cref="ProgressBar"/>
/// locks its fill to the theme green. On screen for about two seconds, so it earns no
/// animation machinery: a plain percent fill over a dim track.
/// </summary>
public sealed class SmoothProgressBar : Control
{
    private int _value;

    // Set in code only, not via the designer, so mark them non-serialized (satisfies WFO1000).
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color FillColor { get; set; } = Color.FromArgb(0x8E, 0x51, 0xFF);

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color TrackColor { get; set; } = Color.FromArgb(38, 255, 255, 255);

    /// <summary>Completion 0-100.</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int Value
    {
        get => _value;
        set { _value = Math.Clamp(value, 0, 100); Invalidate(); }
    }

    public SmoothProgressBar()
    {
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        Height = 8;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        using (var track = new SolidBrush(TrackColor))
            e.Graphics.FillRectangle(track, 0, 0, Width, Height);

        int w = (int)Math.Round(Width * _value / 100.0);
        if (w <= 0) return;
        using var fill = new SolidBrush(FillColor);
        e.Graphics.FillRectangle(fill, 0, 0, w, Height);
    }
}
