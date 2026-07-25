using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Text.Json;

namespace Parley;

// First-run onboarding wizard — styled to match the macOS OnboardingView 1:1: dark
// background, a tinted rounded icon tile, a big bold title + muted subtitle, segmented
// progress, notification choice cards, and rounded Back/Continue buttons. Writes the
// shared credentials.json and marks onboarding complete.
public sealed class OnboardingForm : Form
{
    private static readonly Color Bg = Color.FromArgb(28, 28, 32);
    private static readonly Color Accent = Color.FromArgb(50, 120, 246);
    private static readonly Color Muted = Color.FromArgb(150, 152, 160);

    private static readonly string[] Langs = { "Deutsch", "English", "Français", "Español", "Italiano", "Nederlands" };
    private static readonly string[] Voices = { "Alnilam", "Aoede", "Charon", "Kore", "Puck", "Fenrir" };

    private static readonly (string icon, string title, string sub)[] Steps =
    {
        ("🎙️", "Willkommen bei Parley", "Deine Sprachschicht für Claude Code. Am Ende jeder Antwort spreche ich die Zusammenfassung, höre deine Antwort und speise sie zurück — freihändig, im Charakter eines ruhigen Butlers."),
        ("🔑", "API-Schlüssel", "Beide sind praktisch kostenlos."),
        ("🌐", "Sprache & Stimme", "In welcher Sprache spreche ich, und mit welcher Stimme?"),
        ("🔔", "Benachrichtigungen", "Wie soll ich dich informieren, z. B. wenn ein Projekt wartet?"),
        ("🎤", "Mikrofon", "Parley braucht dein Mikrofon, um deine Antworten aufzunehmen."),
        ("✅", "Fertig!", "Starte eine neue Claude-Code-Sitzung und tippe /parley:voice. Ich melde mich."),
    };

    private int _step;
    private readonly Panel _dots = new() { BackColor = Bg };
    private readonly Label _iconTile = new() { Font = new Font("Segoe UI Emoji", 22), TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.White, BackColor = Color.Transparent };
    private readonly Label _title = new() { Font = new Font("Segoe UI", 21, FontStyle.Bold), ForeColor = Color.White, TextAlign = ContentAlignment.MiddleCenter, AutoSize = false, BackColor = Bg };
    private readonly Label _sub = new() { Font = new Font("Segoe UI", 10.5f), ForeColor = Muted, TextAlign = ContentAlignment.TopCenter, AutoSize = false, BackColor = Bg };
    private readonly Panel _content = new() { BackColor = Bg };
    private readonly RoundButton _back = new() { Text = "Zurück", Fill = Color.FromArgb(52, 52, 58), Width = 100, Height = 38 };
    private readonly RoundButton _next = new() { Text = "Weiter", Fill = Accent, Width = 130, Height = 38 };

    private readonly TextBox _google = new() { Width = 380, UseSystemPasswordChar = true, BorderStyle = BorderStyle.FixedSingle };
    private readonly TextBox _groq = new() { Width = 380, UseSystemPasswordChar = true, BorderStyle = BorderStyle.FixedSingle };
    private readonly ComboBox _lang = new() { Width = 260, DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat };
    private readonly ComboBox _voice = new() { Width = 260, DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat };
    private string _notifyMode = "pill";
    private readonly Label _googleStatus = new() { AutoSize = true, BackColor = Bg, Font = new Font("Segoe UI", 8.5f) };
    private readonly Label _groqStatus = new() { AutoSize = true, BackColor = Bg, Font = new Font("Segoe UI", 8.5f) };
    private readonly RoundButton _check = new() { Text = "Schlüssel prüfen", Fill = Color.FromArgb(52, 52, 58), Width = 180, Height = 34 };
    private bool _googleOk, _groqOk;

    // Step-transition animation: content slides in from the side (from the right going
    // forward, from the left going back) with a light per-element stagger, easeOutCubic.
    private readonly System.Windows.Forms.Timer _slideTimer = new() { Interval = 16 };
    private double _t = 1;               // 0..1 animation progress
    private int _dir = 1;                // +1 forward, -1 back
    private int _iconBaseX, _titleBaseX, _subBaseX, _contentBaseX;

    public OnboardingForm()
    {
        Text = "Parley";
        ClientSize = new Size(640, 560);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        BackColor = Bg;
        DoubleBuffered = true;

        _lang.Items.AddRange(Langs);
        _voice.Items.AddRange(Voices);
        var c = Config.Load();
        _google.Text = c.GoogleKey; _groq.Text = c.GroqKey;
        _lang.SelectedItem = c.Language; if (_lang.SelectedIndex < 0) _lang.SelectedIndex = 0;
        _voice.SelectedIndex = 0;
        _notifyMode = c.NotifyMode;
        foreach (var tb in new[] { _google, _groq }) { tb.BackColor = Color.FromArgb(44, 44, 50); tb.ForeColor = Color.White; }
        foreach (var cb in new[] { _lang, _voice }) { cb.BackColor = Color.FromArgb(44, 44, 50); cb.ForeColor = Color.White; }

        _dots.SetBounds(0, 20, ClientSize.Width, 12); _dots.Paint += PaintDots;
        _iconTile.SetBounds(ClientSize.Width / 2 - 30, 58, 60, 60);
        _title.SetBounds(60, 130, ClientSize.Width - 120, 38);
        _sub.SetBounds(70, 172, ClientSize.Width - 140, 62);
        _content.SetBounds(60, 244, ClientSize.Width - 120, 206);
        _back.Location = new Point(40, ClientSize.Height - 58);
        _next.Location = new Point(ClientSize.Width - 40 - _next.Width, ClientSize.Height - 58);
        _iconBaseX = _iconTile.Left; _titleBaseX = _title.Left; _subBaseX = _sub.Left; _contentBaseX = _content.Left;
        _slideTimer.Tick += (_, _) => SlideTick();

        _check.Click += async (_, _) => await CheckKeysAsync();
        _google.TextChanged += (_, _) => { _googleOk = false; _next.Enabled = false; };
        _groq.TextChanged += (_, _) => { _groqOk = false; _next.Enabled = false; };
        _back.Click += (_, _) => { if (_step > 0) { _step--; _dir = -1; Render(); StartSlide(); } };
        _next.Click += (_, _) =>
        {
            if (_step == Steps.Length - 1) { Finish(); Close(); return; }
            if (_step == 1 && (_google.Text.Trim().Length == 0 || _groq.Text.Trim().Length == 0)) return;
            _step++; _dir = 1; Render(); StartSlide();
        };

        Controls.AddRange(new Control[] { _dots, _iconTile, _title, _sub, _content, _back, _next });
        Paint += PaintIconTile;
        Render();
        StartSlide();   // gentle entrance on first show
    }

    private void StartSlide() { _t = 0; ApplyOffset(); _slideTimer.Start(); }

    private void SlideTick()
    {
        _t += 0.07;
        if (_t >= 1) { _t = 1; _slideTimer.Stop(); }
        ApplyOffset();
    }

    // easeOutCubic with a per-element start delay → light stagger.
    private void ApplyOffset()
    {
        const double dist = 46;
        int Off(double delay)
        {
            var x = Math.Max(0, (_t - delay) / (1 - delay));
            var e = 1 - Math.Pow(1 - x, 3);
            return (int)Math.Round((1 - e) * _dir * dist);
        }
        _iconTile.Left = _iconBaseX + Off(0);
        _title.Left = _titleBaseX + Off(0.08);
        _sub.Left = _subBaseX + Off(0.16);
        _content.Left = _contentBaseX + Off(0.12);
        Invalidate();   // repaint tinted icon-tile background at the new position
    }

    private void PaintDots(object? s, PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        int n = Steps.Length, gap = 6, active = 22, dot = 8;
        int total = (n - 1) * (dot + gap) + active;
        int x = (_dots.Width - total) / 2, y = 3;
        for (var i = 0; i < n; i++)
        {
            var w = i == _step ? active : dot;
            using var b = new SolidBrush(i <= _step ? Accent : Color.FromArgb(70, 70, 78));
            e.Graphics.FillRoundedRect(new Rectangle(x, y, w, 6), 3, b);
            x += w + gap;
        }
    }

    private void PaintIconTile(object? s, PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var r = new Rectangle(_iconTile.Left, _iconTile.Top, 60, 60);
        using var b = new SolidBrush(Color.FromArgb(38, Accent.R, Accent.G, Accent.B));
        e.Graphics.FillRoundedRect(r, 17, b);
    }

    private void Render()
    {
        _iconTile.Text = Steps[_step].icon;
        _title.Text = Steps[_step].title;
        _sub.Text = Steps[_step].sub;
        _back.Visible = _step > 0;
        _next.Text = _step == Steps.Length - 1 ? "Los geht's" : "Weiter";
        _next.Enabled = _step != 1 || (_googleOk && _groqOk);   // step 1 requires verified keys
        Invalidate();

        _content.Controls.Clear();
        switch (_step)
        {
            case 1:
                AddKeyField(0, "Google Cloud TTS API-Key", "1 Mio Zeichen/Monat gratis", _google, _googleStatus,
                    "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com");
                AddKeyField(96, "Groq API-Key", "kostenloser Developer-Key", _groq, _groqStatus,
                    "https://console.groq.com/keys");
                _check.Left = (_content.Width - _check.Width) / 2; _check.Top = 196;
                _content.Controls.Add(_check);
                break;
            case 2:
                AddInput(10, "Sprache", _lang);
                AddInput(74, "Chirp3-HD-Stimme", _voice);
                break;
            case 3:
                _content.Controls.Add(Card(0, "In der Pill", "Elegante Einblendung unten mittig", "🔔", "pill"));
                _content.Controls.Add(Card(64, "System-Mitteilung", "Klassische Windows-Benachrichtigung", "🪟", "system"));
                _content.Controls.Add(Card(128, "Keine", "Ganz ohne Benachrichtigungen", "🔕", "none"));
                break;
        }
    }

    private void AddKeyField(int y, string label, string hint, Control input, Label status, string consoleUrl)
    {
        var x = (_content.Width - input.Width) / 2;
        input.Left = x; input.Top = y + 22;
        _content.Controls.Add(new Label { Text = label, ForeColor = Color.White, BackColor = Bg, Font = new Font("Segoe UI", 9.5f, FontStyle.Bold), AutoSize = true, Left = x, Top = y });
        var link = new LinkLabel { Text = "Konsole öffnen ↗", AutoSize = true, BackColor = Bg, LinkColor = Color.FromArgb(90, 160, 255), Font = new Font("Segoe UI", 8.5f), Top = y + 1 };
        link.Left = x + input.Width - 110;
        link.LinkClicked += (_, _) => { try { Process.Start(new ProcessStartInfo(consoleUrl) { UseShellExecute = true }); } catch { } };
        _content.Controls.Add(link);
        _content.Controls.Add(input);
        status.Left = x; status.Top = y + 48; status.Text = hint; status.ForeColor = Muted;
        _content.Controls.Add(status);
    }

    private async Task CheckKeysAsync()
    {
        _check.Enabled = false; _check.Text = "Prüfe…";
        _googleStatus.Text = "prüfe…"; _googleStatus.ForeColor = Muted;
        _groqStatus.Text = "prüfe…"; _groqStatus.ForeColor = Muted;
        var lang = _lang.SelectedItem?.ToString() ?? "Deutsch";
        var code = lang switch { "English" => "en-US", "Français" => "fr-FR", "Español" => "es-ES", "Italiano" => "it-IT", "Nederlands" => "nl-NL", _ => "de-DE" };
        var voice = $"{code}-Chirp3-HD-{_voice.SelectedItem ?? "Alnilam"}";
        var g = await KeyCheck.Google(_google.Text.Trim(), voice);
        var q = await KeyCheck.Groq(_groq.Text.Trim());
        _googleOk = g.ok; _groqOk = q.ok;
        _googleStatus.Text = g.msg; _googleStatus.ForeColor = g.ok ? Color.FromArgb(70, 200, 120) : Color.FromArgb(230, 90, 90);
        _groqStatus.Text = q.msg; _groqStatus.ForeColor = q.ok ? Color.FromArgb(70, 200, 120) : Color.FromArgb(230, 90, 90);
        _check.Enabled = true; _check.Text = "Schlüssel prüfen";
        _next.Enabled = _googleOk && _groqOk;
    }

    private void AddInput(int y, string label, Control input)
    {
        input.Left = (_content.Width - input.Width) / 2; input.Top = y + 22;
        _content.Controls.Add(new Label { Text = label, ForeColor = Color.White, BackColor = Bg, Font = new Font("Segoe UI", 9.5f, FontStyle.Bold), AutoSize = true, Left = input.Left, Top = y });
        _content.Controls.Add(input);
    }

    private ChoiceCard Card(int y, string title, string sub, string icon, string value)
    {
        var card = new ChoiceCard(title, sub, icon, value == _notifyMode) { Width = _content.Width, Height = 56, Top = y, Left = 0 };
        card.Clicked += () =>
        {
            _notifyMode = value;
            foreach (Control ctl in _content.Controls) if (ctl is ChoiceCard cc) cc.SetSelected(cc.Value == value);
            Notifier.Preview(value);   // live example on select
        };
        return card;
    }

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
        d["notifyMode"] = _notifyMode;
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

// Rounded, flat, filled capsule button matching the macOS onboarding buttons.
internal sealed class RoundButton : Button
{
    public Color Fill = Color.FromArgb(50, 120, 246);
    public RoundButton()
    {
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
        ForeColor = Color.White; Font = new Font("Segoe UI", 10, FontStyle.Bold);
        BackColor = Color.FromArgb(28, 28, 32);
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.Clear(Parent?.BackColor ?? BackColor);
        var fill = Enabled ? Fill : Color.FromArgb(70, Fill.R, Fill.G, Fill.B);
        using var b = new SolidBrush(fill);
        e.Graphics.FillRoundedRect(new Rectangle(0, 0, Width - 1, Height - 1), Height / 2, b);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle,
            Enabled ? ForeColor : Color.Gainsboro,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
}

// Selectable notification card matching the macOS onboarding choice rows.
internal sealed class ChoiceCard : Panel
{
    public string Value { get; }
    public event Action? Clicked;
    private bool _selected;
    private readonly string _title, _sub, _icon;
    private static readonly Color Accent = Color.FromArgb(50, 120, 246);

    public ChoiceCard(string title, string sub, string icon, bool selected)
    {
        _title = title; _sub = sub; _icon = icon; _selected = selected; Value = title;
        BackColor = Color.FromArgb(28, 28, 32); Cursor = Cursors.Hand;
        Click += (_, _) => Clicked?.Invoke();
        DoubleBuffered = true;
    }

    public void SetSelected(bool on) { _selected = on; Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Parent?.BackColor ?? BackColor);
        var r = new Rectangle(0, 0, Width - 1, Height - 1);
        using var bg = new SolidBrush(_selected ? Color.FromArgb(34, Accent.R, Accent.G, Accent.B) : Color.FromArgb(14, 255, 255, 255));
        g.FillRoundedRect(r, 12, bg);
        using var pen = new Pen(_selected ? Accent : Color.FromArgb(24, 255, 255, 255));
        g.DrawRoundedRect(r, 12, pen);

        using var iconFont = new Font("Segoe UI Emoji", 15);
        g.DrawString(_icon, iconFont, Brushes.White, 14, Height / 2 - 15);
        using var tFont = new Font("Segoe UI", 10.5f, FontStyle.Bold);
        using var sFont = new Font("Segoe UI", 8.5f);
        g.DrawString(_title, tFont, Brushes.White, 52, 9);
        using var sBrush = new SolidBrush(Color.FromArgb(160, 162, 170));
        g.DrawString(_sub, sFont, sBrush, 52, 30);

        var cy = Height / 2 - 9;
        var cr = new Rectangle(Width - 34, cy, 18, 18);
        if (_selected)
        {
            using var cb = new SolidBrush(Accent); g.FillEllipse(cb, cr);
            using var cp = new Pen(Color.White, 2);
            g.DrawLines(cp, new[] { new Point(Width - 30, cy + 9), new Point(Width - 27, cy + 12), new Point(Width - 21, cy + 5) });
        }
        else { using var cp = new Pen(Color.FromArgb(90, 255, 255, 255)); g.DrawEllipse(cp, cr); }
    }
}

internal static class GraphicsRoundedExtensions
{
    public static void FillRoundedRect(this Graphics g, Rectangle r, int radius, Brush b)
    { using var p = Path(r, radius); g.FillPath(b, p); }
    public static void DrawRoundedRect(this Graphics g, Rectangle r, int radius, Pen pen)
    { using var p = Path(r, radius); g.DrawPath(pen, p); }
    private static GraphicsPath Path(Rectangle r, int radius)
    {
        int d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
