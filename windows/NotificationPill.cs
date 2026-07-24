using System.Drawing.Drawing2D;

namespace Parley;

// In-app notification pill (bottom-center, styled capsule with title + message) — Windows
// counterpart of the macOS NotificationPill, shown instead of a tray toast when the user
// enables it in Settings. Fade + subtle zoom in, hold, fade out. Queues messages.
public sealed class NotificationPill : Form
{
    private static NotificationPill? _instance;
    private static readonly Queue<(string title, string msg)> Queue = new();
    private static readonly object Gate = new();

    private string _title = "";
    private string _msg = "";
    private readonly System.Windows.Forms.Timer _anim = new() { Interval = 16 };
    private double _phase;          // 0→1 in, hold, 1→0 out
    private int _state;            // 0 in, 1 hold, 2 out
    private DateTime _holdUntil;
    private DateTime _shownAt;     // for the slow sweep
    private double _dwellFrac = 1; // 1→0 during hold
    private double _holdMs = 3000;
    private const double SweepSeconds = 1.4;   // slow, clearly visible

    private NotificationPill()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;
        DoubleBuffered = true;
        Width = 400;
        Height = 96;
        Opacity = 0;
        _anim.Tick += (_, _) => Animate();
    }

    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080; return cp; }
    }

    /// Thread-safe entry point — called from any thread.
    public static void Present(string title, string message)
    {
        lock (Gate) Queue.Enqueue((title, message));
        var inst = _instance;
        if (inst is null) return;
        inst.BeginInvoke(() => inst.Drain());
    }

    // Must run on the UI thread; create the singleton lazily there.
    public static void EnsureCreated()
    {
        _instance ??= new NotificationPill();
        _ = _instance.Handle;
    }

    private void Drain()
    {
        if (_state != 0 && Visible) return;   // busy showing one
        (string, string) next;
        lock (Gate)
        {
            if (Queue.Count == 0) return;
            next = Queue.Dequeue();
        }
        _title = next.Item1;
        _msg = next.Item2;
        Position();
        _phase = 0; _state = 0; _dwellFrac = 1; Opacity = 0;
        _shownAt = DateTime.UtcNow;
        Show();
        _anim.Start();
    }

    private void Position()
    {
        var wa = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
        Location = new Point(wa.Left + (wa.Width - Width) / 2, wa.Bottom - Height - 28);
    }

    private void Animate()
    {
        switch (_state)
        {
            case 0:   // fade + zoom in
                _phase += 0.12;
                if (_phase >= 1) { _phase = 1; _state = 1; _holdMs = Dwell(); _holdUntil = DateTime.UtcNow.AddMilliseconds(_holdMs); }
                break;
            case 1:   // hold — deplete the dwell bar
                var remain = (_holdUntil - DateTime.UtcNow).TotalMilliseconds;
                _dwellFrac = Math.Clamp(remain / _holdMs, 0, 1);
                if (remain <= 0) _state = 2;
                break;
            case 2:   // fade out
                _phase -= 0.09;
                if (_phase <= 0)
                {
                    _phase = 0; _anim.Stop(); Hide();
                    Drain();   // next queued
                    return;
                }
                break;
        }
        var eased = _phase * _phase * (3 - 2 * _phase);   // smoothstep
        Opacity = eased;
        Invalidate();
    }

    private double Dwell() => Math.Min(5000, Math.Max(2600, 1600 + _msg.Length * 36));

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        // subtle zoom: scale the drawn capsule around center by 0.9→1.0
        var scale = 0.9f + 0.1f * (float)_phase;
        var w = Width * scale; var h = Height * scale;
        var ox = (Width - w) / 2f; var oy = (Height - h) / 2f;
        var rect = new RectangleF(ox + 2, oy + 2, w - 5, h - 5);

        using var path = Capsule(rect);
        using var bg = new SolidBrush(Color.FromArgb(235, 20, 20, 24));
        g.FillPath(bg, path);
        using var border = new Pen(Color.FromArgb(50, 255, 255, 255));
        g.DrawPath(border, path);

        // icon dot
        var cy = oy + h / 2f;
        using var iconBg = new SolidBrush(Color.FromArgb(60, 90, 160, 255));
        g.FillEllipse(iconBg, ox + 18, cy - 19, 38, 38);
        using var iconBrush = new SolidBrush(Color.FromArgb(255, 120, 180, 255));
        g.FillEllipse(iconBrush, ox + 30, cy - 7, 14, 14);

        var textX = ox + 70;
        var textW = w - 88;
        using var titleFont = new Font("Segoe UI", 11.5f, FontStyle.Bold);
        using var msgFont = new Font("Segoe UI", 10f);
        using var white = new SolidBrush(Color.White);
        g.DrawString(_title, titleFont, white, new RectangleF(textX, cy - 22, textW, 22));

        // Stagger: message reveals after the title (fade + slight slide).
        var reveal = Smooth(Math.Clamp((_phase - 0.45) / 0.55, 0, 1));
        using var grey = new SolidBrush(Color.FromArgb((int)(210 * reveal), 235, 235, 245));
        g.DrawString(_msg, msgFont, grey,
            new RectangleF(textX + (float)((1 - reveal) * 10), cy - 2, textW, 40),
            new StringFormat { Trimming = StringTrimming.EllipsisCharacter });

        // Slow one-time glass sweep across the capsule.
        var sp = Math.Min(1.0, (DateTime.UtcNow - _shownAt).TotalSeconds / SweepSeconds);
        if (sp < 1)
        {
            var sx = (float)((sp * 1.5 - 0.3) * w) + ox;
            var band = w * 0.4f;
            using var sweepBrush = new LinearGradientBrush(
                new RectangleF(sx, oy, band, h),
                Color.FromArgb(0, 255, 255, 255), Color.FromArgb(70, 255, 255, 255), LinearGradientMode.Horizontal);
            sweepBrush.SetBlendTriangularShape(0.5f);
            var clip = g.Clip; g.SetClip(path);
            g.FillRectangle(sweepBrush, sx, oy, band, h);
            g.Clip = clip;
        }

        // Dwell bar along the bottom.
        var barW = (float)((w - 44) * _dwellFrac);
        using var barBrush = new SolidBrush(Color.FromArgb(230, 90, 160, 255));
        g.FillRectangle(barBrush, ox + 22, oy + h - 8, Math.Max(0, barW), 3);
    }

    private static GraphicsPath Capsule(RectangleF r)
    {
        var d = r.Height;
        var p = new GraphicsPath();
        p.AddArc(r.Left, r.Top, d, d, 90, 180);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 180);
        p.CloseFigure();
        return p;
    }
}
