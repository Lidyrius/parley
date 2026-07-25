using System.Drawing.Drawing2D;

namespace Parley;

// Small shared UI helpers for the dark, rounded look shared by the stats, settings and
// onboarding screens.
public sealed class RoundButton : Button
{
    public Color Fill { get; set; } = Color.FromArgb(56, 132, 255);

    public RoundButton()
    {
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        FlatAppearance.MouseOverBackColor = Color.Transparent;
        FlatAppearance.MouseDownBackColor = Color.Transparent;
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 10.5f, FontStyle.Bold);
        BackColor = Color.Transparent;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
            | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var bg = new SolidBrush(Parent?.BackColor ?? Color.Black))
            g.FillRectangle(bg, ClientRectangle);
        var r = new Rectangle(0, 0, Width - 1, Height - 1);
        using (var path = WinUI.Round(r, Height / 2))
        using (var b = new SolidBrush(Fill))
            g.FillPath(b, path);
        TextRenderer.DrawText(g, Text, Font, r, ForeColor,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}

public static class WinUI
{
    public static GraphicsPath Round(Rectangle r, int radius)
    {
        var d = Math.Max(2, radius * 2);
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
