using System.Drawing.Drawing2D;

namespace Parley;

// Floating always-on-top waveform "pill" shown while recording — Windows counterpart of
// the macOS HUD: rounded capsule bottom-center, scrolling level bars, pulsing orb.
public sealed class PillOverlay : Form
{
    private const int BarCount = 36;
    private readonly float[] _bars = new float[BarCount];
    private readonly System.Windows.Forms.Timer _timer;
    private float _level;
    private float _orbPulse;

    public PillOverlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;
        DoubleBuffered = true;
        Width = 320;
        Height = 64;
        var screen = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
        Location = new Point(screen.Left + (screen.Width - Width) / 2, screen.Bottom - Height - 24);

        _timer = new System.Windows.Forms.Timer { Interval = 33 };
        _timer.Tick += (_, _) => Tick();
    }

    protected override bool ShowWithoutActivation => true;   // never steal focus

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 /*WS_EX_NOACTIVATE*/ | 0x00000080 /*WS_EX_TOOLWINDOW*/;
            return cp;
        }
    }

    public void Push(float level) => _level = Math.Clamp(level, 0f, 1f);

    public void ShowPill()
    {
        Array.Clear(_bars);
        _level = 0;
        Show();
        _timer.Start();
    }

    public void HidePill()
    {
        _timer.Stop();
        Hide();
    }

    private void Tick()
    {
        Array.Copy(_bars, 1, _bars, 0, BarCount - 1);   // scroll left
        _bars[BarCount - 1] = _level;
        _level *= 0.75f;                                 // decay between mic callbacks
        _orbPulse = _orbPulse * 0.85f + _bars[BarCount - 1] * 0.15f;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        // capsule
        var rect = new Rectangle(0, 0, Width - 1, Height - 1);
        using var path = Capsule(rect);
        using var bg = new SolidBrush(Color.FromArgb(235, 28, 28, 32));
        g.FillPath(bg, path);
        using var border = new Pen(Color.FromArgb(60, 255, 255, 255));
        g.DrawPath(border, path);

        // pulsing orb (left)
        var orbBase = 14f;
        var orb = orbBase + _orbPulse * 10f;
        var cx = 30f; var cy = Height / 2f;
        using var orbBrush = new SolidBrush(Color.FromArgb(255, 90, 160, 255));
        using var glow = new SolidBrush(Color.FromArgb(60, 90, 160, 255));
        g.FillEllipse(glow, cx - orb, cy - orb, orb * 2, orb * 2);
        g.FillEllipse(orbBrush, cx - orbBase / 2, cy - orbBase / 2, orbBase, orbBase);

        // waveform bars (right of orb)
        var x0 = 56f;
        var avail = Width - x0 - 20f;
        var step = avail / BarCount;
        using var bar = new SolidBrush(Color.FromArgb(230, 235, 235, 245));
        for (var i = 0; i < BarCount; i++)
        {
            var h = 3f + _bars[i] * (Height - 24f);
            var x = x0 + i * step;
            g.FillRectangle(bar, x, Height / 2f - h / 2f, Math.Max(2f, step - 2f), h);
        }
    }

    private static GraphicsPath Capsule(Rectangle r)
    {
        var d = r.Height;
        var p = new GraphicsPath();
        p.AddArc(r.Left, r.Top, d, d, 90, 180);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 180);
        p.CloseFigure();
        return p;
    }
}
