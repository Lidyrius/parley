using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
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
    private static Image? _claudeBrandIcon;
    private static Image? _codexBrandIcon;

    private enum Step { Welcome, Integrations, Keys, Voice, Notify, Mic, Tutorial, Done }
    private static readonly (string title, string sub, string icon)[] Meta =
    {
        ("Willkommen bei Parley", "Deine Sprachschicht für Claude Code und Codex. Am Ende jeder Antwort spreche ich die Zusammenfassung, höre deine Antwort und speise sie zurück — freihändig, im Charakter eines ruhigen Butlers.", "wave"),
        ("Wo soll Parley laufen?", "Erkannte Coding-Clients sind vorausgewählt. Du kannst die Verbindung jederzeit im Setup ändern.", "stack"),
        ("API-Schlüssel", "Beide sind praktisch kostenlos.", "key"),
        ("Sprache & Stimme", "In welcher Sprache spreche ich, und mit welcher Stimme?", "globe"),
        ("Benachrichtigungen", "Wie soll ich dich informieren, z. B. wenn ein Projekt wartet?", "bell"),
        ("Mikrofon", "Parley braucht dein Mikrofon, um deine Antworten aufzunehmen. Windows fragt beim ersten Sprechen automatisch.", "mic"),
        ("Kurz-Tutorial", "Das Wichtigste in einer Minute.", "wave"),
        ("Fertig!", "Diese Befehle gehören zu den aktivierten Clients.", "check"),
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
    private readonly bool _detectedClaude;
    private readonly bool _detectedCodex;
    private bool _installClaude;
    private bool _installCodex;

    // Tutorial: one spoken line per step; expect 0=none 1=stop 2=wait.
    private static readonly (string title, string line, int expect, string icon)[] TutDe =
    {
        ("So funktioniert's", "Willkommen bei Parley. Am Ende jeder Antwort spreche ich dir die Zusammenfassung vor, und du antwortest einfach mit deiner Stimme — ganz freihändig.", 0, "wave"),
        ("Halt mich an", "Wann immer ich aufhören soll, sag es einfach in deinen Worten — ob „stopp“, „lass uns hier aufhören“ oder „das reicht erst mal“. Auf ein bestimmtes Wort kommt es nicht an. Probier es: sag mir, dass ich anhalten soll.", 1, "stop"),
        ("Lass mich warten", "Brauchst du eine Pause, sag mir einfach, ich soll warten — „warte zehn Minuten“, „gib mir eine Viertelstunde“, die Zeit bestimmst du frei. Ich melde mich dann von selbst zurück. Probier es ruhig aus.", 2, "clock"),
        ("Parallele Projekte", "Läuft nebenbei ein anderes Projekt, sag mir einfach von hier aus: nimm das Projekt Soundso wieder auf. Das klappt aus jeder Sitzung.", 0, "stack"),
        ("Einfach fragen", "Und wenn du etwas wissen willst, frag einfach — ich antworte dir sofort.", 0, "quest"),
        ("Fertig!", "Das war's. Starte jetzt eine neue Clode-Code-Sitzung und tippe Parley Voice, dann bin ich für dich da.", 0, "check"),
    };
    private bool _previewLoading;
    private int _tutIndex;
    private bool _tutTrying;
    private bool? _tutResult;
    private Rectangle _tryRect;
    private bool TutLast => _tutIndex >= TutDe.Length - 1;

    private Rectangle _nextRect, _backRect;
    private readonly Rectangle[] _cardRects = new Rectangle[3];
    private readonly Rectangle[] _integrationRects = new Rectangle[2];
    private Rectangle _downloadClaudeRect, _downloadCodexRect;
    // Key-step links: [google guide, google console, groq guide, groq console].
    private Rectangle _gGuideRect, _gConsoleRect, _qGuideRect, _qConsoleRect;
    private readonly bool _tutorialOnly;

    private const string GoogleConsoleUrl = "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com";
    private const string GroqConsoleUrl = "https://console.groq.com/keys";
    private const string GoogleGuideUrl = "https://lidyrius.github.io/parley/keys/google.html";
    private const string GroqGuideUrl = "https://lidyrius.github.io/parley/keys/groq.html";

    private static void Open(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }

    public OnboardingForm(bool tutorialOnly = false)
    {
        Text = "Parley";
        _tutorialOnly = tutorialOnly;
        if (tutorialOnly) _step = Step.Tutorial;
        ClientSize = new Size(640, 560);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        BackColor = Bg;
        DoubleBuffered = true;

        var c = Config.Load();
        _detectedClaude = c.DetectedClaudeCode;
        _detectedCodex = c.DetectedCodex;
        _installClaude = c.ClaudeCodeEnabled ?? _detectedClaude;
        _installCodex = c.CodexEnabled ?? _detectedCodex;
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
        // Hear the voice on pick — full quality via the user's key, cached; bundled fallback.
        _voice.SelectedIndexChanged += (_, _) => PreviewSelected();
        _lang.SelectedIndexChanged += (_, _) => { if (_step == Step.Voice) PreviewSelected(); };

        MouseClick += OnClick;
        Shown += (_, _) => { if (_step == Step.Tutorial) PlayTutLine(); };
        FormClosed += (_, _) => VoicePreview.Stop();
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
        for (var i = 0; i < 2; i++) _integrationRects[i] = new Rectangle((w - 460) / 2, 268 + i * 74, 460, 62);
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

    // Full voice name for the current language + voice selection, e.g. "de-DE-Chirp3-HD-Alnilam".
    private string SelectedVoice()
    {
        var lang = _lang.SelectedItem?.ToString() ?? "Deutsch";
        var code = lang switch { "English" => "en-US", "Français" => "fr-FR", "Español" => "es-ES", "Italiano" => "it-IT", "Nederlands" => "nl-NL", _ => "de-DE" };
        var star = _voice.SelectedItem as string ?? "Alnilam";
        return $"{code}-Chirp3-HD-{star}";
    }

    private void PreviewSelected()
    {
        var lang = _lang.SelectedItem?.ToString() ?? "Deutsch";
        VoicePreview.Play(SelectedVoice(), VoicePreview.Sentence(lang), _google.Text.Trim(),
            loading => { _previewLoading = loading; Invalidate(); });
    }

    private void OnClick(object? s, MouseEventArgs e)
    {
        if (_backRect.Contains(e.Location) && (int)_step > 0) { _step = (Step)((int)_step - 1); SetStepControls(); return; }
        if (_step == Step.Keys)
        {
            if (_gGuideRect.Contains(e.Location)) { Open(GoogleGuideUrl); return; }
            if (_gConsoleRect.Contains(e.Location)) { Open(GoogleConsoleUrl); return; }
            if (_qGuideRect.Contains(e.Location)) { Open(GroqGuideUrl); return; }
            if (_qConsoleRect.Contains(e.Location)) { Open(GroqConsoleUrl); return; }
        }
        if (_step == Step.Integrations)
        {
            if (_integrationRects[0].Contains(e.Location) && _detectedClaude) { _installClaude = !_installClaude; Invalidate(); return; }
            if (_integrationRects[1].Contains(e.Location) && _detectedCodex) { _installCodex = !_installCodex; Invalidate(); return; }
            if (_downloadClaudeRect.Contains(e.Location)) { Open("https://docs.anthropic.com/en/docs/claude-code/overview"); return; }
            if (_downloadCodexRect.Contains(e.Location)) { Open("https://developers.openai.com/codex/cli"); return; }
        }
        if (_step == Step.Tutorial && _tryRect.Contains(e.Location) && !_tutTrying) { TryTut(); return; }
        if (_nextRect.Contains(e.Location) && CanContinue)
        {
            if (_step == Step.Done) { Finish(); Close(); return; }
            if (_step == Step.Tutorial) { TutForward(); return; }
            if (_step == Step.Voice) VoicePreview.Stop();   // don't bleed into the tutorial
            _step = (Step)((int)_step + 1); SetStepControls();
            if (_step == Step.Tutorial) PlayTutLine();
            return;
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
        var m = _step == Step.Tutorial ? (title: TutDe[_tutIndex].title, sub: TutDe[_tutIndex].line.Replace("Clode", "Claude"), icon: TutDe[_tutIndex].icon) : Meta[(int)_step];

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
                // right-aligned links per field: [Anleitung]  [Konsole öffnen]
                _gConsoleRect = DrawLink(g, "Konsole öffnen", _google.Right, _google.Top - 20, true);
                _gGuideRect = DrawLink(g, "Anleitung", _gConsoleRect.Left - 14, _google.Top - 20, true);
                _qConsoleRect = DrawLink(g, "Konsole öffnen", _groq.Right, _groq.Top - 20, true);
                _qGuideRect = DrawLink(g, "Anleitung", _qConsoleRect.Left - 14, _groq.Top - 20, true);
                if (!CanContinue)
                    using (var warn = new SolidBrush(Color.FromArgb(232, 152, 48)))
                    using (var wf = new Font("Segoe UI", 9.5f, FontStyle.Bold))
                        g.DrawString("⚠  Bitte beide Schlüssel eingeben, um fortzufahren.", wf, warn,
                            new RectangleF(_groq.Left, _groq.Bottom + 12, _groq.Width, 24));
                break;
            case Step.Integrations:
                DrawIntegrationCard(g, 0, "Claude Code", "Stop-Hook und /parley:voice", "claude-code");
                DrawIntegrationCard(g, 1, "Codex", "Plugin und $parley-voice-Skill", "codex");
                if (!_detectedClaude && !_detectedCodex)
                {
                    _downloadClaudeRect = DrawLink(g, "Claude Code installieren", (w / 2) - 8, 425, true);
                    _downloadCodexRect = DrawLink(g, "Codex installieren", (w / 2) + 8, 425, false);
                }
                break;
            case Step.Done:
            {
                var commandY = 278;
                if (_installClaude)
                {
                    DrawCommandCard(g, commandY, "Claude Code", "/parley:voice", "claude-code");
                    commandY += 74;
                }
                if (_installCodex)
                {
                    DrawCommandCard(g, commandY, "Codex", "$parley-voice", "codex");
                    commandY += 74;
                }
                if (!_installClaude && !_installCodex)
                {
                    using var noneFont = new Font("Segoe UI", 9.5f);
                    g.DrawString("Du kannst die Clients später im Setup verbinden.", noneFont, muted,
                        new RectangleF(40, 286, w - 80, 28), center);
                }
                break;
            }
            case Step.Voice:
                g.DrawString("Sprache", lblFont, white, _lang.Left, _lang.Top - 20);
                g.DrawString("Chirp3-HD-Stimme", lblFont, white, _voice.Left, _voice.Top - 20);
                var note = _previewLoading ? "Erzeuge Vorschau…"
                    : "Erste Wiedergabe wird kurz in deiner echten Stimme erzeugt — danach sofort.";
                using (var noteFont = new Font("Segoe UI", 9f))
                    g.DrawString(note, noteFont, muted,
                        new RectangleF(_voice.Left, _voice.Bottom + 8, _voice.Width, 32));
                break;
            case Step.Notify:
                for (var i = 0; i < 3; i++) DrawCard(g, i);
                break;
        }

        // buttons
        if ((int)_step > 0) DrawButton(g, _backRect, "Zurück", false);
        if (_step == Step.Tutorial) DrawTutorialExtras(g);
        var nextLabel = _step == Step.Done ? "Los geht's" : (_step == Step.Tutorial && TutLast ? "Fertig" : "Weiter");
        DrawButton(g, _nextRect, nextLabel, true, enabled: CanContinue);
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

    private void DrawIntegrationCard(Graphics g, int i, string title, string subtitle, string icon)
    {
        var r = _integrationRects[i];
        var detected = i == 0 ? _detectedClaude : _detectedCodex;
        var on = i == 0 ? _installClaude : _installCodex;
        using (var fill = new SolidBrush(on ? Color.FromArgb(30, Accent.R, Accent.G, Accent.B) : Color.FromArgb(13, 255, 255, 255)))
            FillRound(g, fill, r, 12);
        using (var pen = new Pen(on ? Color.FromArgb(128, Accent.R, Accent.G, Accent.B) : Color.FromArgb(22, 255, 255, 255)))
            DrawRound(g, pen, r, 12);
        DrawBrandIcon(g, icon, new Rectangle(r.X + 16, r.Y + 20, 22, 22), detected ? 1f : 0.45f);
        using var tf = new Font("Segoe UI", 11, FontStyle.Bold);
        using var sf = new Font("Segoe UI", 9);
        using var white = new SolidBrush(Color.White);
        using var muted = new SolidBrush(TextMuted);
        g.DrawString(title, tf, white, r.X + 52, r.Y + 12);
        g.DrawString(detected ? subtitle + "  ·  gefunden" : "Nicht gefunden — später verbinden", sf, muted, r.X + 52, r.Y + 34);
        var cc = new Rectangle(r.Right - 34, r.Y + r.Height / 2 - 9, 18, 18);
        if (on) { using var b = new SolidBrush(Accent); g.FillEllipse(b, cc); using var wp = new Pen(Color.White, 2); DrawCheckPath(g, cc, wp); }
        else { using var p = new Pen(Color.FromArgb(90, 255, 255, 255), 1.5f); g.DrawEllipse(p, cc); }
    }

    private void DrawCommandCard(Graphics g, int y, string title, string command, string icon)
    {
        var r = new Rectangle((ClientSize.Width - 460) / 2, y, 460, 62);
        using (var fill = new SolidBrush(Color.FromArgb(30, Accent.R, Accent.G, Accent.B)))
            FillRound(g, fill, r, 12);
        using (var pen = new Pen(Color.FromArgb(72, Accent.R, Accent.G, Accent.B)))
            DrawRound(g, pen, r, 12);
        DrawBrandIcon(g, icon, new Rectangle(r.X + 16, r.Y + 18, 26, 26), 1f);
        using var tf = new Font("Segoe UI", 9.5f, FontStyle.Bold);
        using var cf = new Font("Consolas", 12, FontStyle.Bold);
        using var white = new SolidBrush(Color.White);
        using var muted = new SolidBrush(TextMuted);
        g.DrawString(title, tf, muted, r.X + 56, r.Y + 10);
        g.DrawString(command, cf, white, r.X + 56, r.Y + 31);
    }

    private Rectangle DrawLink(Graphics g, string text, int x, int y, bool rightAlign)
    {
        using var f = new Font("Segoe UI", 9.5f);
        var sz = g.MeasureString(text, f);
        var rect = new Rectangle(rightAlign ? x - (int)sz.Width : x, y, (int)sz.Width, (int)sz.Height);
        using var b = new SolidBrush(Accent);
        g.DrawString(text, f, b, rect.Location);
        return rect;
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
            case "stop":
                DrawRound(g, pen, new Rectangle((int)(x + 3), (int)(y + 3), (int)(w - 6), (int)(h - 6)), 5);
                break;
            case "clock":
                g.DrawEllipse(pen, x + 1, y + 1, w - 2, h - 2);
                g.DrawLine(pen, cx, cy, cx, y + h * 0.28f);
                g.DrawLine(pen, cx, cy, x + w * 0.72f, cy);
                break;
            case "stack":
                DrawRound(g, pen, new Rectangle((int)(x + 5), (int)y, (int)(w - 8), (int)(h - 8)), 3);
                DrawRound(g, pen, new Rectangle((int)x, (int)(y + 6), (int)(w - 8), (int)(h - 8)), 3);
                break;
            case "bubble":
                DrawRound(g, pen, new Rectangle((int)x, (int)y + 1, (int)(w * 0.72f), (int)(h * 0.62f)), 4);
                DrawRound(g, pen, new Rectangle((int)(x + w * 0.28f), (int)(y + h * 0.34f), (int)(w * 0.72f), (int)(h * 0.62f)), 4);
                break;
            case "terminal":
                DrawRound(g, pen, new Rectangle((int)x, (int)y + 2, (int)w, (int)(h - 4)), 3);
                g.DrawLine(pen, x + 5, cy - 2, x + 9, cy);
                g.DrawLine(pen, x + 9, cy, x + 5, cy + 2);
                g.DrawLine(pen, x + 12, cy + 3, x + w - 5, cy + 3);
                break;
            case "quest":
                g.DrawEllipse(pen, x + 1, y + 1, w - 2, h - 2);
                using (var qf = new Font("Segoe UI", h * 0.5f, FontStyle.Bold))
                    g.DrawString("?", qf, brush, new RectangleF(x, y - 1, w, h),
                        new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
                break;
            case "off":
                g.DrawArc(pen, x + w * 0.15f, y + h * 0.1f, w * 0.7f, h * 0.7f, 180, 180);
                g.DrawLine(pen, x, y + h, x + w, y);
                break;
        }
    }

    private static void DrawBrandIcon(Graphics g, string name, Rectangle r, float opacity)
    {
        var image = name switch
        {
            "claude-code" => _claudeBrandIcon ??= LoadBrandIcon("claude-code.png"),
            "codex" => _codexBrandIcon ??= LoadBrandIcon("codex.png"),
            _ => null,
        };
        if (image is null)
        {
            DrawIcon(g, name == "claude-code" ? "terminal" : "stack", r, TextMuted);
            return;
        }

        using var attributes = new ImageAttributes();
        attributes.SetColorMatrix(new ColorMatrix { Matrix33 = opacity });
        g.DrawImage(image, r, 0, 0, image.Width, image.Height, GraphicsUnit.Pixel, attributes);
    }

    private static Image? LoadBrandIcon(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "branding", fileName);
        try { return File.Exists(path) ? Image.FromFile(path) : null; }
        catch { return null; }
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

    // ----- tutorial ------------------------------------------------------------------

    private void DrawTutorialExtras(Graphics g)
    {
        var w = ClientSize.Width;
        // sub-progress dots
        var n = TutDe.Length; var gap = 6; var d = 7;
        var tw = n * d + (n - 1) * gap; var x = (w - tw) / 2;
        for (var i = 0; i < n; i++)
        {
            using var b = new SolidBrush(i <= _tutIndex ? Accent : Color.FromArgb(70, 70, 78));
            g.FillEllipse(b, x, 250, d, d); x += d + gap;
        }
        // interactive "Ausprobieren" for stop/wait steps
        _tryRect = Rectangle.Empty;
        if (TutDe[_tutIndex].expect != 0)
        {
            _tryRect = new Rectangle((w - 170) / 2, 285, 170, 36);
            using (var b = new SolidBrush(Color.FromArgb(16, 255, 255, 255))) FillRound(g, b, _tryRect, 18);
            using var f = new Font("Segoe UI", 10.5f, FontStyle.Bold);
            using var tb = new SolidBrush(TextMuted);
            var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString(_tutTrying ? "Höre zu…" : "Ausprobieren", f, tb, _tryRect, sf);
            if (_tutResult is bool ok)
            {
                using var rf = new Font("Segoe UI", 9.5f);
                using var rb = new SolidBrush(ok ? Color.FromArgb(120, 220, 130) : TextMuted);
                var msg = ok ? "Genau so, Sir." : "Nicht erkannt — kein Problem, weiter geht's.";
                g.DrawString(msg, rf, rb, new RectangleF(40, 330, w - 80, 22),
                    new StringFormat { Alignment = StringAlignment.Center });
            }
        }
    }

    private void TutForward()
    {
        if (TutLast) { _step = Step.Done; SetStepControls(); return; }
        _tutIndex++; _tutResult = null; Invalidate(); PlayTutLine();
    }

    private async void PlayTutLine()
    {
        var cfg = Config.Load();
        // Use the voice picked in this onboarding, not the old saved one (matches macOS).
        if (_voice.SelectedItem is string star && star.Length > 0)
        {
            var lang = _lang.SelectedItem?.ToString() ?? "Deutsch";
            var code = lang switch { "English" => "en-US", "Français" => "fr-FR", "Español" => "es-ES", "Italiano" => "it-IT", "Nederlands" => "nl-NL", _ => "de-DE" };
            cfg.GoogleVoice = $"{code}-Chirp3-HD-{star}";
        }
        var text = TutDe[_tutIndex].line;
        try
        {
            var pcm = await GoogleTts.Synthesize(text, cfg);
            if (pcm is not null)
            {
                await AudioOut.WaitForHiFiOutput();
                await AudioOut.PlayPcm(AudioOut.ApplyRate(pcm, cfg.SpeakingRate));
            }
        }
        catch { }
    }

    private async void TryTut()
    {
        _tutTrying = true; _tutResult = null; Invalidate();
        var cfg = Config.Load();
        var expect = TutDe[_tutIndex].expect;
        try
        {
            var wav = await new MicCapture().Record();
            var text = wav.Length >= 44 + 16000 * 2 / 5 ? await Groq.Transcribe(wav, cfg) : "";
            bool ok;
            if (expect == 1) ok = (await Groq.Classify(text, cfg)) == Groq.Intent.Stop;
            else if (expect == 2) ok = (await Groq.ClassifyWait(text, cfg)) > 0;
            else ok = true;
            _tutResult = ok;
        }
        catch { _tutResult = false; }
        _tutTrying = false; Invalidate();
    }

    public static bool NeedsTutorial()
    {
        try
        {
            var d = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(Config.CredentialsPath));
            var seen = d != null && d.TryGetValue("tutorialSeen", out var v) ? (int.TryParse(v.GetString(), out var n) ? n : 0) : 0;
            return seen < 3;   // TutorialVersion
        }
        catch { return true; }
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
        // Tutorial-only re-show has no config fields — only mark the tutorial seen, keep the rest.
        if (!_tutorialOnly)
        {
            d["googleAPIKey"] = _google.Text.Trim();
            d["groqAPIKey"] = _groq.Text.Trim();
            d["language"] = lang;
            d["googleVoice"] = $"{code}-Chirp3-HD-{_voice.SelectedItem}";
            d["notifyMode"] = _notifyIndex switch { 1 => "system", 2 => "none", _ => "pill" };
            d["onboarded"] = "1";
        }
        d["claudeCodeEnabled"] = _installClaude ? "1" : "0";
        d["codexEnabled"] = _installCodex ? "1" : "0";
        d["tutorialSeen"] = "3";   // TutorialVersion
        File.WriteAllText(Config.CredentialsPath, JsonSerializer.Serialize(d, new JsonSerializerOptions { WriteIndented = true }));
        IntegrationSync.Apply();
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
