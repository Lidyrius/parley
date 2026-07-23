namespace Parley;

// Statistics dashboard — functional Windows counterpart of the macOS Liquid Glass view:
// session/total toggle, time-saved hero, intent mix, tiles, top projects, TTS-character
// accounting (1M/month free, then $30/1M).
public sealed class StatsForm : Form
{
    private bool _sessionScope = true;
    private readonly Panel _content = new() { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(16) };

    public StatsForm()
    {
        Text = "Parley — Statistiken";
        Width = 480;
        Height = 640;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(24, 24, 28);
        ForeColor = Color.White;

        var toggle = new Button
        {
            Text = "Diese Sitzung / Gesamt",
            Dock = DockStyle.Top,
            Height = 34,
            FlatStyle = FlatStyle.Flat,
            ForeColor = Color.White,
        };
        toggle.Click += (_, _) => { _sessionScope = !_sessionScope; Render(); };
        Controls.Add(_content);
        Controls.Add(toggle);
        Render();
    }

    private void Render()
    {
        var d = _sessionScope ? StatsStore.Session : StatsStore.Total;
        _content.Controls.Clear();
        var y = 8;

        void Line(string label, string value, float size = 10f, bool accent = false)
        {
            var l = new Label
            {
                Text = $"{label}: {value}",
                AutoSize = true,
                Location = new Point(8, y),
                Font = new Font("Segoe UI", size, accent ? FontStyle.Bold : FontStyle.Regular),
                ForeColor = accent ? Color.FromArgb(120, 180, 255) : Color.White,
            };
            _content.Controls.Add(l);
            y += l.PreferredHeight + 6;
        }

        Line(_sessionScope ? "Diese Sitzung" : "Gesamt", "", 12f, true);
        Line("Zeit gespart", Duration(d.TimeSavedSeconds), 16f, true);
        Line("Turns", d.Turns.ToString());
        Line("Sitzungen", d.Sessions.ToString());
        Line("Wörter gesprochen (du)", d.UserWords.ToString());
        Line("Wörter von Parley", d.ParleyWords.ToString());
        Line("Deine Sprechzeit", Duration(d.UserSpeakingSeconds));
        Line("Zeichen (TTS)", d.CharsSpoken.ToString("N0"));
        y += 8;
        Line("Intents", "", 11f, true);
        foreach (var kv in d.Intents.OrderByDescending(k => k.Value))
            Line("  " + kv.Key, kv.Value.ToString());
        y += 8;
        Line("Top-Projekte", "", 11f, true);
        foreach (var kv in d.ProjectTurns.OrderByDescending(k => k.Value).Take(3))
            Line("  " + kv.Key, kv.Value.ToString());
        y += 8;
        var total = StatsStore.Total;
        Line("Google TTS diesen Monat",
            $"{total.CharsThisMonth:N0} / {StatsData.FreeCharsPerMonth:N0} Zeichen frei", 11f, true);
        Line("Kosten", total.EstimatedDollarsThisMonth == 0 ? "gratis" : $"≈ ${total.EstimatedDollarsThisMonth:F2}");
    }

    private static string Duration(double seconds)
    {
        var t = TimeSpan.FromSeconds(seconds);
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}h {t.Minutes}m" : $"{t.Minutes}m {t.Seconds}s";
    }
}
