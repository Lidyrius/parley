using System.Text.Json;

namespace Parley;

// Settings: API keys, language, speaking rate — writes the shared credentials.json.
public sealed class SettingsForm : Form
{
    private readonly TextBox _google = new() { Width = 320, UseSystemPasswordChar = true };
    private readonly TextBox _groq = new() { Width = 320, UseSystemPasswordChar = true };
    private readonly ComboBox _lang = new() { Width = 200, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TrackBar _rate = new() { Minimum = 2, Maximum = 8, TickFrequency = 1, Width = 200 };
    private readonly Label _rateLabel = new() { AutoSize = true };
    private readonly ComboBox _notify = new() { Width = 200, DropDownStyle = ComboBoxStyle.DropDownList };

    public SettingsForm()
    {
        Text = "Parley — Einstellungen";
        Width = 420;
        Height = 370;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;

        _lang.Items.AddRange(new object[] { "Deutsch", "English", "Français", "Español", "Italiano", "Nederlands" });
        _notify.Items.AddRange(new object[] { "In der Pill", "System-Mitteilung", "Keine" });
        _notify.SelectedIndexChanged += (_, _) => Notifier.Preview(_notify.SelectedIndex switch { 1 => "system", 2 => "none", _ => "pill" });

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(12) };
        void Row(string label, Control c)
        {
            layout.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left });
            layout.Controls.Add(c);
        }
        Row("Google TTS Key", _google);
        Row("Groq Key", _groq);
        Row("Sprache", _lang);
        var ratePanel = new FlowLayoutPanel { AutoSize = true };
        ratePanel.Controls.Add(_rate);
        ratePanel.Controls.Add(_rateLabel);
        Row("Sprechtempo", ratePanel);
        _rate.ValueChanged += (_, _) => _rateLabel.Text = $"{_rate.Value / 4.0:0.00}×";
        Row("Benachrichtigungen", _notify);

        var save = new Button { Text = "Speichern", AutoSize = true };
        save.Click += (_, _) => { Save(); Close(); };
        Row("", save);
        Controls.Add(layout);
        LoadValues();
    }

    private void LoadValues()
    {
        var c = Config.Load();
        _google.Text = c.GoogleKey;
        _groq.Text = c.GroqKey;
        _lang.SelectedItem = c.Language;
        if (_lang.SelectedIndex < 0) _lang.SelectedIndex = 0;
        _rate.Value = Math.Clamp((int)Math.Round(c.SpeakingRate * 4), _rate.Minimum, _rate.Maximum);
        _notify.SelectedIndex = c.NotifyMode switch { "system" => 1, "none" => 2, _ => 0 };
        _rateLabel.Text = $"{_rate.Value / 4.0:0.00}×";
    }

    private void Save()
    {
        var lang = _lang.SelectedItem?.ToString() ?? "Deutsch";
        var code = lang switch
        {
            "English" => "en-US", "Français" => "fr-FR", "Español" => "es-ES",
            "Italiano" => "it-IT", "Nederlands" => "nl-NL", _ => "de-DE",
        };
        Directory.CreateDirectory(Config.Dir);
        // merge onto the existing file so unknown keys survive
        Dictionary<string, object> d = new();
        try
        {
            var existing = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(
                File.ReadAllText(Config.CredentialsPath)) ?? new();
            foreach (var kv in existing) d[kv.Key] = kv.Value.ValueKind == JsonValueKind.String ? kv.Value.GetString()! : kv.Value.ToString();
        }
        catch { }
        d["googleAPIKey"] = _google.Text.Trim();
        d["groqAPIKey"] = _groq.Text.Trim();
        d["language"] = lang;
        d["googleVoice"] = $"{code}-Chirp3-HD-Alnilam";
        d["speakingRate"] = (_rate.Value / 4.0).ToString(System.Globalization.CultureInfo.InvariantCulture);
        d["notifyMode"] = _notify.SelectedIndex switch { 1 => "system", 2 => "none", _ => "pill" };
        File.WriteAllText(Config.CredentialsPath, JsonSerializer.Serialize(d, new JsonSerializerOptions { WriteIndented = true }));
    }
}
