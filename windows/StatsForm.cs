using System.Drawing.Drawing2D;

namespace Parley;

// Statistics dashboard styled to match the macOS Liquid Glass view: a Session/Gesamt
// toggle, a "Zeit gespart" hero, the classifier Intent-Mix bar with a legend, a tile grid,
// top-project bars, and the monthly TTS-character cost card — all on dark rounded cards.
public sealed class StatsForm : Form
{
    private static readonly Color Bg = Color.FromArgb(24, 24, 28);
    private static readonly Color Accent = Color.FromArgb(70, 150, 255);
    private static readonly Color Card = Color.FromArgb(18, 255, 255, 255);
    private static readonly Color Muted = Color.FromArgb(150, 152, 160);

    private static readonly string[] IntentOrder =
        { "FEATURE", "BUG", "RESEARCH", "QUESTION", "CONTINUE", "STOP", "FEATURE_RESEARCH", "BUG_FEATURE", "OTHER" };

    private bool _session = true;
    private readonly RoundButton _tSession = new() { Text = "Diese Sitzung", Width = 150, Height = 32, Fill = Accent };
    private readonly RoundButton _tTotal = new() { Text = "Gesamt", Width = 110, Height = 32, Fill = Color.FromArgb(52, 52, 58) };
    private readonly Panel _board = new() { Dock = DockStyle.Fill, BackColor = Bg };

    public StatsForm()
    {
        Text = "Parley — Statistiken";
        ClientSize = new Size(460, 680);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        BackColor = Bg;
        DoubleBuffered = true;

        var head = new Panel { Dock = DockStyle.Top, Height = 96, BackColor = Bg };
        var title = new Label { Text = "Statistiken", ForeColor = Color.White, Font = new Font("Segoe UI", 16, FontStyle.Bold), AutoSize = true, Location = new Point(20, 16) };
        _tSession.Location = new Point(20, 52);
        _tTotal.Location = new Point(178, 52);
        _tSession.Click += (_, _) => SetScope(true);
        _tTotal.Click += (_, _) => SetScope(false);
        head.Controls.AddRange(new Control[] { title, _tSession, _tTotal });

        _board.Paint += PaintBoard;
        Controls.Add(_board);
        Controls.Add(head);
    }

    private void SetScope(bool session)
    {
        _session = session;
        _tSession.Fill = session ? Accent : Color.FromArgb(52, 52, 58);
        _tTotal.Fill = session ? Color.FromArgb(52, 52, 58) : Accent;
        _tSession.Invalidate(); _tTotal.Invalidate(); _board.Invalidate();
    }

    private static Color IntentColor(string i) => i switch
    {
        "FEATURE" => Color.FromArgb(60, 130, 246),
        "BUG" => Color.FromArgb(240, 150, 50),
        "RESEARCH" => Color.FromArgb(60, 200, 170),
        "QUESTION" => Color.FromArgb(70, 190, 220),
        "CONTINUE" => Color.FromArgb(70, 200, 120),
        "STOP" => Color.FromArgb(140, 140, 150),
        "FEATURE_RESEARCH" => Color.FromArgb(110, 100, 230),
        "BUG_FEATURE" => Color.FromArgb(230, 110, 170),
        _ => Color.FromArgb(150, 110, 220),
    };

    private static string IntentLabel(string i) => i switch
    {
        "FEATURE" => "Feature", "BUG" => "Bug", "RESEARCH" => "Research", "QUESTION" => "Frage",
        "CONTINUE" => "Weiter", "STOP" => "Stopp", "FEATURE_RESEARCH" => "Feat+Rech", "BUG_FEATURE" => "Bug+Feat", _ => "Sonstiges",
    };

    private void PaintBoard(object? s, PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        var d = _session ? StatsStore.Session : StatsStore.Total;
        var total = StatsStore.Total;
        int x = 20, w = ClientSize.Width - 40, y = 12;

        // Hero — time saved
        y = DrawCard(g, x, y, w, 92);
        DrawCenter(g, "Zeit gespart", new Font("Segoe UI", 9), Muted, x, 20, w);
        DrawCenter(g, Duration(d.TimeSavedSeconds), new Font("Segoe UI", 30, FontStyle.Bold), Accent, x, 34, w);
        DrawCenter(g, "gegenüber Tippen (⌀ 40 WPM)", new Font("Segoe UI", 7.5f), Color.FromArgb(120, 122, 130), x, 78, w);
        y += 12;

        // Intent mix
        var items = IntentOrder.Select(k => (k, n: d.Intents.GetValueOrDefault(k))).ToArray();
        var sum = Math.Max(1, items.Sum(i => i.n));
        var top = y;
        y = DrawCard(g, x, y, w, 92);
        using (var lf = new Font("Segoe UI", 9)) g.DrawString("Was du gesagt hast", lf, new SolidBrush(Muted), x + 16, top + 12);
        var barY = top + 36; var barX = x + 16; var barW = w - 32;
        var cx = (float)barX;
        foreach (var it in items.Where(i => i.n > 0))
        {
            var seg = Math.Max(3, barW * it.n / (float)sum);
            using var b = new SolidBrush(IntentColor(it.k));
            g.FillRectangle(b, cx, barY, seg, 12);
            cx += seg + 2;
        }
        if (items.All(i => i.n == 0))
            using (var eb = new SolidBrush(Color.FromArgb(40, 255, 255, 255))) g.FillRectangle(eb, barX, barY, barW, 12);
        // legend
        var lx = barX; var ly = barY + 22;
        using (var f = new Font("Segoe UI", 8))
            foreach (var it in items.Where(i => i.n > 0))
            {
                using var dot = new SolidBrush(IntentColor(it.k));
                g.FillEllipse(dot, lx, ly + 2, 8, 8);
                var t = $"{IntentLabel(it.k)} {it.n}";
                g.DrawString(t, f, new SolidBrush(Muted), lx + 11, ly);
                lx += 11 + (int)g.MeasureString(t, f).Width + 12;
                if (lx > x + w - 70) { lx = barX; ly += 18; }
            }
        y += 12;

        // Tiles grid (2 columns)
        (string, string)[] tiles =
        {
            ("Turns", Int(d.Turns)), ("Sitzungen", Int(d.Sessions)),
            ("Wörter du", Int(d.UserWords)), ("Wörter Parley", Int(d.ParleyWords)),
            ("Deine Sprechzeit", Duration(d.UserSpeakingSeconds)), ("Zeichen (TTS)", Int(d.CharsSpoken)),
        };
        var tw = (w - 12) / 2;
        for (var i = 0; i < tiles.Length; i++)
        {
            var col = i % 2; var row = i / 2;
            var tx = x + col * (tw + 12); var ty = y + row * 64;
            using var p = Round(new Rectangle(tx, ty, tw, 56), 12);
            using var cb = new SolidBrush(Card); g.FillPath(cb, p);
            using var vf = new Font("Segoe UI", 15, FontStyle.Bold);
            using var lf = new Font("Segoe UI", 8);
            g.DrawString(tiles[i].Item2, vf, Brushes.White, tx + 12, ty + 8);
            g.DrawString(tiles[i].Item1, lf, new SolidBrush(Muted), tx + 12, ty + 34);
        }
        y += 3 * 64 + 8;

        // Top projects
        var projects = d.ProjectTurns.OrderByDescending(k => k.Value).Take(3).ToArray();
        if (projects.Length > 0)
        {
            var maxN = Math.Max(1, projects[0].Value);
            var ptop = y;
            var ph = 28 + projects.Length * 22;
            y = DrawCard(g, x, y, w, ph);
            using (var lf = new Font("Segoe UI", 9)) g.DrawString("Top-Projekte", lf, new SolidBrush(Muted), x + 16, ptop + 10);
            var ry = ptop + 32;
            using var nf = new Font("Segoe UI", 9);
            foreach (var p in projects)
            {
                g.DrawString(p.Key, nf, Brushes.White, x + 16, ry);
                var bw = 90f * p.Value / maxN + 4;
                using var bb = new SolidBrush(Color.FromArgb(120, Accent.R, Accent.G, Accent.B));
                using var cap = Round(new Rectangle(x + w - 120, ry + 4, (int)bw, 6), 3);
                g.FillPath(bb, cap);
                g.DrawString(Int(p.Value), nf, new SolidBrush(Muted), x + w - 26, ry);
                ry += 22;
            }
            y += 12;
        }

        // Cost card
        var ctop = y;
        DrawCard(g, x, y, w, 60);
        using (var lf = new Font("Segoe UI", 9)) g.DrawString("Google TTS diesen Monat", lf, new SolidBrush(Muted), x + 16, ctop + 12);
        using (var vf = new Font("Segoe UI", 10, FontStyle.Bold))
            g.DrawString($"{Int(total.CharsThisMonth)} / {Int(StatsData.FreeCharsPerMonth)} Zeichen frei", vf, Brushes.White, x + 16, ctop + 32);
        var cost = total.EstimatedDollarsThisMonth == 0 ? "gratis" : $"≈ ${total.EstimatedDollarsThisMonth:F2}";
        using (var cf = new Font("Segoe UI", 14, FontStyle.Bold))
        {
            var sz = g.MeasureString(cost, cf);
            g.DrawString(cost, cf, new SolidBrush(Accent), x + w - sz.Width - 16, ctop + 18);
        }
    }

    // Draws a rounded card background at (x,y,w,h); returns y+h for the cursor.
    private static int DrawCard(Graphics g, int x, int y, int w, int h)
    {
        using var p = Round(new Rectangle(x, y, w, h), 14);
        using var b = new SolidBrush(Card);
        g.FillPath(b, p);
        return y + h;
    }

    private static void DrawCenter(Graphics g, string text, Font f, Color c, int x, int dy, int w)
    {
        var sz = g.MeasureString(text, f);
        using var b = new SolidBrush(c);
        g.DrawString(text, f, b, x + (w - sz.Width) / 2, dy);
    }

    private static GraphicsPath Round(Rectangle r, int radius)
    {
        int dd = radius * 2;
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, dd, dd, 180, 90);
        p.AddArc(r.Right - dd, r.Y, dd, dd, 270, 90);
        p.AddArc(r.Right - dd, r.Bottom - dd, dd, dd, 0, 90);
        p.AddArc(r.X, r.Bottom - dd, dd, dd, 90, 90);
        p.CloseFigure();
        return p;
    }

    private static string Int(int n) => n.ToString("N0");
    private static string Duration(double seconds)
    {
        var t = TimeSpan.FromSeconds(seconds);
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}h {t.Minutes}m" : $"{t.Minutes}m {t.Seconds}s";
    }
}
