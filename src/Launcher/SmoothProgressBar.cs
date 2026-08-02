using System;
using System.ComponentModel;
using System.Drawing;
using System.Windows.Forms;

namespace Donut.Launcher;

/// <summary>
/// Minimal owner-painted progress bar - the stock <see cref="ProgressBar"/> locks its
/// fill to the theme green, and this bar is on screen for ~2 seconds, so it earns no
/// animation machinery. Starts indeterminate (a dim full-width tint of the fill color,
/// for the module-parse phase that reports no percentage); the first <see cref="Value"/>
/// assignment switches to a plain percent fill.
/// </summary>
public sealed class SmoothProgressBar : Control
{
    private int _value;
    private bool _indeterminate = true;

    // Set in code only, not via the designer, so mark them non-serialized (satisfies WFO1000).
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color FillColor { get; set; } = Color.FromArgb(0x8E, 0x51, 0xFF);

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color TrackColor { get; set; } = Color.FromArgb(38, 255, 255, 255);

    /// <summary>Completion 0-100. Assigning leaves the indeterminate phase.</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int Value
    {
        get => _value;
        set { _value = Math.Clamp(value, 0, 100); _indeterminate = false; Invalidate(); }
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

        int w = _indeterminate ? Width : (int)Math.Round(Width * _value / 100.0);
        if (w <= 0) return;
        using var fill = new SolidBrush(_indeterminate ? Color.FromArgb(70, FillColor) : FillColor);
        e.Graphics.FillRectangle(fill, 0, 0, w, Height);
    }
}
