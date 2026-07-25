using System.Drawing.Drawing2D;
using System.Text.Json;

namespace Parley;

// First-run onboarding — a pixel-match of the macOS OnboardingView, fully owner-drawn:
// dark background, segmented progress, a tinted rounded hero tile with a vector icon, a big
// bold title + muted subtitle, card-style notification choices with live previews, and pill
// Back/Continue buttons. Writes the shared credentials.json and marks onboarding complete.
public sealed class OnboardingForm : Form
{
    private static readonly string[] Langs = { "Deutsch", "English", "Français", "Español", "Italiano", "Nederlands" };
    private static readonly string[] Voices = { "Alnilam", "Aoede", "Charon", "Kore", "Puck", "Fenrir" };

    private static readonly Color Bg = Color.FromArgb(28, 28, 32);
    private static readonly Color Accent = Color.FromArgb(56, 132, 255);
    private static readonly Color TextMuted = Color.FromArgb(168, 168, 176);

    private enum Step { Welcome, Keys, Voice, Notify, Mic, Done }
    private static readonly (string title, string sub, string icon)[] Meta =
    {
        ("Willkommen bei Parley", "Deine Sprachschicht für Claude Code. Am Ende jeder Antwort spreche ich die Zusammenfassung, höre deine Antwort und speise sie zurück — freihändig, im Charakter eines ruhigen Butlers.", "wave"),
        ("API-Schlüssel", "Beide sind praktisch kostenlos.", "key"),
        ("Sprache & Stimme", "In welcher Sprache spreche ich, und mit welcher Stimme?", "globe"),
        ("Benachrichtigungen", "Wie soll ich dich informieren, z. B. wenn ein Projekt wartet?", "bell"),
        ("Mikrofon", "Parley braucht dein Mikrofon, um deine Antworten aufzunehmen. Windows fragt beim ersten Sprechen automatisch.", "mic"),
        ("Fertig!", "Starte eine neue Claude-Code-Sitzung und tippe /parley:voice. Ich melde mich.", "check"),
    };
    private static readonly (string title, string sub, string icon)[] NotifyCards =
    {
        ("In der Pill", "Elegante Einblendung unten mittig", "pill"),
        ("System-Mitteilung", "Klassische Windows-Benachrichtigung", "toast"),
        ("Keine", "Ganz ohne Benachrichtigungen", "off"),
    };

    private Step _step;
    private int _notifyIndex;
    private readonly TextBox _google = MakeInput(true);
    private readonly TextBox _groq = MakeInput(true);
    private readonly ComboBox _lang = MakeCombo(Langs);
    private readonly ComboBox _voice = MakeCombo(Voices);

    private Rectangle _nextRect, _backRect;
    private readonly Rectangle[] _cardRects = new Rectangle[3];

    public OnboardingForm()
    {
        Text = "Parley";
        ClientSize = new Size(640, 560);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        BackColor = Bg;
        DoubleBuffered = true;

        var c = Config.Load();
        _google.Text = c.GoogleKey; _groq.Text = c.GroqKey;
        _lang.SelectedItem = c.Language; if (_lang.SelectedIndex < 0) _lang.SelectedIndex = 0;
        _voice.SelectedIndex = 0;
        _notifyIndex = c.NotifyMode switch { "system" => 1, "none" => 2, _ => 0 };

        foreach (Control ctl in new Control[] { _google, _groq, _lang, _voice })
        {
            ctl.Visible = false;
            Controls.Add(ctl);
        }
        _google.TextChanged += (_, _) => Invalidate();
        _groq.TextChanged += (_, _) => Invalidate();

        MouseClick += OnClick;
        Layout1();
    }

    // ----- layout / navigation --------------------------------------------------------

    private void Layout1()
    {
        var w = ClientSize.Width;
        // Inputs (centered).
        _google.SetBounds((w - 460) / 2, 300, 460, 26);
        _groq.SetBounds((w - 460) / 2, 372, 460, 26);
        _lang.SetBounds((w - 260) / 2, 300, 260, 26);
        _voice.SetBounds((w - 260) / 2, 372, 260, 26);
        for (var i = 0; i < 3; i++) _cardRects[i] = new Rectangle((w - 460) / 2, 268 + i * 74, 460, 62);
        _nextRect = new Rectangle(w - 40 - 140, ClientSize.Height - 66, 140, 40);
        _backRect = new Rectangle(40, ClientSize.Height - 66, 104, 40);
        SetStepControls();
    }

    private void SetStepControls()
    {
        _google.Visible = _groq.Visible = _step == Step.Keys;
        _lang.Visible = _voice.Visible = _step == Step.Voice;
        Invalidate();
    }

    private bool CanContinue => _step != Step.Keys || (_google.Text.Trim().Length > 0 && _groq.Text.Trim().Length > 0);

    private void OnClick(object? s, MouseEventArgs e)
    {
        if (_backRect.Contains(e.Location) && (int)_step > 0) { _step = (Step)((int)_step - 1); SetStepControls(); return; }
        if (_nextRect.Contains(e.Location) && CanContinue)
        {
            if (_step == Step.Done) { Finish(); Close(); return; }
            _step = (Step)((int)_step + 1); SetStepControls(); return;
        }
        if (_step == Step.Notify)
            for (var i = 0; i < 3; i++)
                if (_cardRects[i].Contains(e.Location))
                {
                    _notifyIndex = i;
                    Notifier.Preview(i switch { 1 => "system", 2 => "none", _ => "pill" });
                    Invalidate();
                    return;
                }
    }

    // ----- painting -------------------------------------------------------------------

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        var w = ClientSize.Width;
        var m = Meta[(int)_step];

        // progress dots
        var total = Meta.Length;
        var dotW = 8; var actW = 22; var gap = 6;
        var totalW = (total - 1) * (dotW + gap) + actW;
        var x = (w - totalW) / 2;
        for (var i = 0; i < total; i++)
        {
            var ww = i == (int)_step ? actW : dotW;
            using var b = new SolidBrush(i <= (int)_step ? Accent : Color.FromArgb(70, 70, 78));
            FillRound(g, b, new Rectangle(x, 26, ww, 6), 3);
            x += ww + gap;
        }

        // hero tile + icon
        var tile = new Rectangle((w - 60) / 2, 84, 60, 60);
        using (var tb = new SolidBrush(Color.FromArgb(36, Accent.R, Accent.G, Accent.B)))
            FillRound(g, tb, tile, 17);
        DrawIcon(g, m.icon, new Rectangle(tile.X + 17, tile.Y + 17, 26, 26), Accent);

        // title + subtitle
        using var titleFont = new Font("Segoe UI", 20, FontStyle.Bold);
        using var subFont = new Font("Segoe UI", 10.5f);
        using var white = new SolidBrush(Color.White);
        using var muted = new SolidBrush(TextMuted);
        var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Near };
        g.DrawString(m.title, titleFont, white, new RectangleF(40, 158, w - 80, 40), center);
        g.DrawString(m.sub, subFont, muted, new RectangleF(70, 202, w - 140, 60), center);

        // step content
        using var lblFont = new Font("Segoe UI", 9.5f, FontStyle.Bold);
        switch (_step)
        {
            case Step.Keys:
                g.DrawString("Google Cloud TTS  ·  1 Mio Zeichen/Monat gratis", lblFont, white, _google.Left, _google.Top - 20);
                g.DrawString("Groq  ·  kostenloser Developer-Key", lblFont, white, _groq.Left, _groq.Top - 20);
                break;
            case Step.Voice:
                g.DrawString("Sprache", lblFont, white, _lang.Left, _lang.Top - 20);
                g.DrawString("Chirp3-HD-Stimme", lblFont, white, _voice.Left, _voice.Top - 20);
                break;
            case Step.Notify:
                for (var i = 0; i < 3; i++) DrawCard(g, i);
                break;
        }

        // buttons
        if ((int)_step > 0) DrawButton(g, _backRect, "Zurück", false);
        DrawButton(g, _nextRect, _step == Step.Done ? "Los geht's" : "Weiter", true, enabled: CanContinue);
    }

    private void DrawCard(Graphics g, int i)
    {
        var r = _cardRects[i];
        var on = _notifyIndex == i;
        using (var fill = new SolidBrush(on ? Color.FromArgb(30, Accent.R, Accent.G, Accent.B) : Color.FromArgb(13, 255, 255, 255)))
            FillRound(g, fill, r, 12);
        using (var pen = new Pen(on ? Color.FromArgb(128, Accent.R, Accent.G, Accent.B) : Color.FromArgb(22, 255, 255, 255)))
            DrawRound(g, pen, r, 12);
        DrawIcon(g, NotifyCards[i].icon, new Rectangle(r.X + 16, r.Y + 20, 22, 22), on ? Accent : TextMuted);
        using var tf = new Font("Segoe UI", 11, FontStyle.Bold);
        using var sf = new Font("Segoe UI", 9);
        using var white = new SolidBrush(Color.White);
        using var muted = new SolidBrush(TextMuted);
        g.DrawString(NotifyCards[i].title, tf, white, r.X + 52, r.Y + 12);
        g.DrawString(NotifyCards[i].sub, sf, muted, r.X + 52, r.Y + 34);
        var cc = new Rectangle(r.Right - 34, r.Y + r.Height / 2 - 9, 18, 18);
        if (on) { using var b = new SolidBrush(Accent); g.FillEllipse(b, cc); using var wp = new Pen(Color.White, 2); DrawCheckPath(g, cc, wp); }
        else { using var p = new Pen(Color.FromArgb(90, 255, 255, 255), 1.5f); g.DrawEllipse(p, cc); }
    }

    private void DrawButton(Graphics g, Rectangle r, string text, bool primary, bool enabled = true)
    {
        var fill = primary
            ? (enabled ? Accent : Color.FromArgb(70, Accent.R, Accent.G, Accent.B))
            : Color.FromArgb(16, 255, 255, 255);
        using (var b = new SolidBrush(fill)) FillRound(g, b, r, r.Height / 2);
        using var f = new Font("Segoe UI", 10.5f, FontStyle.Bold);
        using var tb = new SolidBrush(primary ? Color.White : TextMuted);
        var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        g.DrawString(text, f, tb, r, sf);
    }

    // ----- vector icons (match the SF-symbol tiles) -----------------------------------

    private static void DrawIcon(Graphics g, string name, Rectangle r, Color c)
    {
        using var pen = new Pen(c, 2f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        using var brush = new SolidBrush(c);
        float x = r.X, y = r.Y, w = r.Width, h = r.Height, cx = x + w / 2, cy = y + h / 2;
        switch (name)
        {
            case "wave":
                for (var i = 0; i < 5; i++)
                {
                    var bx = x + 2 + i * (w - 4) / 4f;
                    var bh = h * (i % 2 == 0 ? 0.5f : 0.95f);
                    g.DrawLine(pen, bx, cy - bh / 2, bx, cy + bh / 2);
                }
                break;
            case "key":
                g.DrawEllipse(pen, x, y + 2, w * 0.5f, w * 0.5f);
                g.DrawLine(pen, x + w * 0.45f, y + h * 0.45f, x + w, y + h);
                g.DrawLine(pen, x + w * 0.75f, y + h * 0.7f, x + w * 0.9f, y + h * 0.55f);
                break;
            case "globe":
                g.DrawEllipse(pen, x, y, w, h);
                g.DrawEllipse(pen, x + w * 0.32f, y, w * 0.36f, h);
                g.DrawLine(pen, x, cy, x + w, cy);
                break;
            case "bell":
                g.DrawArc(pen, x + w * 0.15f, y + h * 0.1f, w * 0.7f, h * 0.7f, 180, 180);
                g.DrawLine(pen, x + w * 0.15f, y + h * 0.45f, x + w * 0.15f, y + h * 0.7f);
                g.DrawLine(pen, x + w * 0.85f, y + h * 0.45f, x + w * 0.85f, y + h * 0.7f);
                g.DrawLine(pen, x + w * 0.08f, y + h * 0.7f, x + w * 0.92f, y + h * 0.7f);
                g.FillEllipse(brush, cx - 2, y + h * 0.82f, 4, 4);
                break;
            case "mic":
                g.DrawArc(pen, cx - 6, y + 1, 12, 16, 0, 360);
                g.DrawArc(pen, cx - 9, cy - 2, 18, 14, 20, 140);
                g.DrawLine(pen, cx, y + h - 3, cx, y + h);
                break;
            case "check":
                DrawCheckPath(g, r, pen);
                break;
            case "pill":
                using (var p2 = new Pen(c, 2f)) g.DrawArc(p2, x + 2, cy - 5, w - 4, 10, 0, 360);
                break;
            case "toast":
                DrawRound(g, pen, new Rectangle((int)(x + 2), (int)(y + 4), (int)(w - 4), (int)(h - 8)), 4);
                g.FillEllipse(brush, x + w - 7, y + 3, 6, 6);
                break;
            case "off":
                g.DrawArc(pen, x + w * 0.15f, y + h * 0.1f, w * 0.7f, h * 0.7f, 180, 180);
                g.DrawLine(pen, x, y + h, x + w, y);
                break;
        }
    }

    private static void DrawCheckPath(Graphics g, Rectangle r, Pen pen)
    {
        float x = r.X, y = r.Y, w = r.Width, h = r.Height;
        g.DrawLines(pen, new[]
        {
            new PointF(x + w * 0.24f, y + h * 0.52f),
            new PointF(x + w * 0.42f, y + h * 0.70f),
            new PointF(x + w * 0.78f, y + h * 0.30f),
        });
    }

    // ----- helpers --------------------------------------------------------------------

    private static void FillRound(Graphics g, Brush b, Rectangle r, int radius)
    { using var p = Round(r, radius); g.FillPath(b, p); }
    private static void DrawRound(Graphics g, Pen pen, Rectangle r, int radius)
    { using var p = Round(r, radius); g.DrawPath(pen, p); }
    private static GraphicsPath Round(Rectangle r, int radius)
    {
        var d = radius * 2;
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    private static TextBox MakeInput(bool secret) => new()
    {
        BorderStyle = BorderStyle.FixedSingle,
        BackColor = Color.FromArgb(45, 45, 52),
        ForeColor = Color.White,
        Font = new Font("Segoe UI", 11),
        UseSystemPasswordChar = secret,
    };
    private static ComboBox MakeCombo(string[] items)
    {
        var c = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(45, 45, 52),
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 10.5f),
        };
        c.Items.AddRange(items);
        return c;
    }

    // ----- persistence ----------------------------------------------------------------

    private void Finish()
    {
        var lang = _lang.SelectedItem?.ToString() ?? "Deutsch";
        var code = lang switch { "English" => "en-US", "Français" => "fr-FR", "Español" => "es-ES", "Italiano" => "it-IT", "Nederlands" => "nl-NL", _ => "de-DE" };
        Directory.CreateDirectory(Config.Dir);
        Dictionary<string, object> d = new();
        try
        {
            var existing = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(Config.CredentialsPath)) ?? new();
            foreach (var kv in existing) d[kv.Key] = kv.Value.ValueKind == JsonValueKind.String ? kv.Value.GetString()! : kv.Value.ToString();
        }
        catch { }
        d["googleAPIKey"] = _google.Text.Trim();
        d["groqAPIKey"] = _groq.Text.Trim();
        d["language"] = lang;
        d["googleVoice"] = $"{code}-Chirp3-HD-{_voice.SelectedItem}";
        d["notifyMode"] = _notifyIndex switch { 1 => "system", 2 => "none", _ => "pill" };
        d["onboarded"] = "1";
        File.WriteAllText(Config.CredentialsPath, JsonSerializer.Serialize(d, new JsonSerializerOptions { WriteIndented = true }));
    }

    public static bool IsComplete()
    {
        try
        {
            var d = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(Config.CredentialsPath));
            return d != null && d.TryGetValue("onboarded", out var v) && v.GetString() == "1";
        }
        catch { return false; }
    }
}
