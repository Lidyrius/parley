using System.Text.Json;

namespace Parley;

// First-run onboarding wizard — Windows counterpart of the macOS OnboardingView: a dark,
// stepped flow (welcome → keys → language+voice → notifications → done) with a progress
// row and Back/Next. Writes the shared credentials.json and marks onboarding complete.
public sealed class OnboardingForm : Form
{
    private static readonly string[] Langs = { "Deutsch", "English", "Français", "Español", "Italiano", "Nederlands" };
    private static readonly string[] Voices = { "Alnilam", "Aoede", "Charon", "Kore", "Puck", "Fenrir" };
    private static readonly (string title, string sub)[] Steps =
    {
        ("Willkommen bei Parley", "Deine Sprachschicht für Claude Code — freihändig, im Charakter eines ruhigen Butlers."),
        ("API-Schlüssel", "Beide sind praktisch kostenlos."),
        ("Sprache & Stimme", "In welcher Sprache spreche ich, und mit welcher Stimme?"),
        ("Benachrichtigungen", "Wie soll ich dich informieren?"),
        ("Fertig!", "Starte eine neue Claude-Code-Sitzung und tippe /parley:voice."),
    };

    private int _step;
    private readonly Panel _body = new() { Dock = DockStyle.Fill, Padding = new Padding(48, 20, 48, 20) };
    private readonly Label _title = new() { AutoSize = false, Dock = DockStyle.Top, Height = 44, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Segoe UI", 20, FontStyle.Bold), ForeColor = Color.White };
    private readonly Label _sub = new() { AutoSize = false, Dock = DockStyle.Top, Height = 44, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Segoe UI", 10), ForeColor = Color.Gainsboro };
    private readonly Panel _content = new() { Dock = DockStyle.Fill };
    private readonly Button _back = new() { Text = "Zurück", Width = 100, Height = 34, FlatStyle = FlatStyle.Flat, ForeColor = Color.White };
    private readonly Button _next = new() { Text = "Weiter", Width = 120, Height = 34, FlatStyle = FlatStyle.Flat, ForeColor = Color.White };
    private readonly FlowLayoutPanel _dots = new() { Height = 22, Dock = DockStyle.Top, FlowDirection = FlowDirection.LeftToRight, Anchor = AnchorStyles.None };

    private readonly TextBox _google = new() { Width = 360, UseSystemPasswordChar = true };
    private readonly TextBox _groq = new() { Width = 360, UseSystemPasswordChar = true };
    private readonly ComboBox _lang = new() { Width = 260, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _voice = new() { Width = 260, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _notify = new() { Width = 260, DropDownStyle = ComboBoxStyle.DropDownList };

    public OnboardingForm()
    {
        Text = "Parley";
        Width = 660; Height = 580;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        BackColor = Color.FromArgb(28, 28, 32);

        _lang.Items.AddRange(Langs);
        _voice.Items.AddRange(Voices);
        _notify.Items.AddRange(new object[] { "In der Pill", "System-Mitteilung", "Keine" });
        var c = Config.Load();
        _google.Text = c.GoogleKey; _groq.Text = c.GroqKey;
        _lang.SelectedItem = c.Language; if (_lang.SelectedIndex < 0) _lang.SelectedIndex = 0;
        _voice.SelectedIndex = 0;
        _notify.SelectedIndex = c.NotifyMode switch { "system" => 1, "none" => 2, _ => 0 };
        _notify.SelectedIndexChanged += (_, _) => Notifier.Preview(_notify.SelectedIndex switch { 1 => "system", 2 => "none", _ => "pill" });

        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 60, Padding = new Padding(40, 12, 40, 12) };
        _back.Click += (_, _) => { if (_step > 0) { _step--; Render(); } };
        _next.Click += (_, _) =>
        {
            if (_step == Steps.Length - 1) { Finish(); Close(); return; }
            if (_step == 1 && (_google.Text.Trim().Length == 0 || _groq.Text.Trim().Length == 0)) return;
            _step++; Render();
        };
        _back.FlatAppearance.BorderColor = Color.Gray;
        _next.BackColor = Color.FromArgb(60, 120, 240);
        _next.FlatAppearance.BorderSize = 0;
        bottom.Controls.Add(_next); bottom.Controls.Add(_back);
        _next.Location = new Point(bottom.Width - 160, 12); _next.Anchor = AnchorStyles.Right | AnchorStyles.Top;
        _back.Location = new Point(0, 12); _back.Anchor = AnchorStyles.Left | AnchorStyles.Top;

        _dots.Padding = new Padding((Width - 6 * 30) / 2, 4, 0, 0);
        Controls.Add(_body);
        Controls.Add(bottom);
        var head = new Panel { Dock = DockStyle.Top, Height = 150 };
        head.Controls.Add(_content); // placeholder to keep order; actual content set in _body
        _body.Controls.Add(_content);
        _body.Controls.Add(_sub);
        _body.Controls.Add(_title);
        _body.Controls.Add(_dots);
        Render();
    }

    private void Render()
    {
        _title.Text = Steps[_step].title;
        _sub.Text = Steps[_step].sub;
        _back.Visible = _step > 0;
        _next.Text = _step == Steps.Length - 1 ? "Los geht's" : "Weiter";

        _dots.Controls.Clear();
        for (var i = 0; i < Steps.Length; i++)
            _dots.Controls.Add(new Panel { Width = i == _step ? 22 : 8, Height = 6, Margin = new Padding(3, 8, 3, 0),
                BackColor = i <= _step ? Color.FromArgb(60, 120, 240) : Color.FromArgb(70, 70, 78) });

        _content.Controls.Clear();
        var stack = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, Dock = DockStyle.Fill, WrapContents = false, Padding = new Padding(60, 20, 60, 0) };
        void Field(string label, Control c)
        {
            stack.Controls.Add(new Label { Text = label, ForeColor = Color.White, AutoSize = true, Font = new Font("Segoe UI", 9.5f, FontStyle.Bold), Margin = new Padding(0, 10, 0, 4) });
            stack.Controls.Add(c);
        }
        switch (_step)
        {
            case 1:
                Field("Google Cloud TTS API-Key  (console.cloud.google.com · 1 Mio/Monat gratis)", _google);
                Field("Groq API-Key  (console.groq.com · kostenlos)", _groq);
                break;
            case 2:
                Field("Sprache", _lang);
                Field("Chirp3-HD-Stimme", _voice);
                break;
            case 3:
                Field("Anzeige", _notify);
                break;
        }
        if (_step is 1 or 2 or 3) _content.Controls.Add(stack);
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
        d["notifyMode"] = _notify.SelectedIndex switch { 1 => "system", 2 => "none", _ => "pill" };
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
