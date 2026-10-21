using System.Drawing.Drawing2D;
using System.Text.Json;

namespace Parley;

// A left click on the tray icon: the iPhone app's overview on the PC (as macOS MenuBarView) —
// title and status pills, today's numbers, the sessions with their one action, "Anrufen", and
// the buttons for pairing, stats, settings and setup. The right-click menu keeps every option.
public sealed class TrayPanel : Form
{
    public sealed class Hooks
    {
        public required Func<string> Sessions;          // GET /sessions
        public required Action Call;                    // "Anrufen": the wake dialog on the PC
        public required Action<string> Resume;
        public required Func<bool> Muted;
        public required Action ToggleMute;
        public required Func<bool?> Relay;              // null: no phone paired
        public required Action Pair, Stats, Settings, Setup, Quit;
    }

    // The Claude palette (ios/ParleyMobile/Theme.swift), dark.
    private static readonly Color Bg = Color.FromArgb(0x19, 0x19, 0x18);
    private static readonly Color Card = Color.FromArgb(0x26, 0x26, 0x24);
    private static readonly Color Raised = Color.FromArgb(0x30, 0x30, 0x2E);
    private static readonly Color Accent = Color.FromArgb(0xD9, 0x77, 0x57);
    private static readonly Color Waiting = Color.FromArgb(0xD9, 0xA4, 0x3B);
    private static readonly Color Working = Color.FromArgb(0x5B, 0x8D, 0xEF);
    private static readonly Color Purple = Color.FromArgb(0x9B, 0x87, 0xF5);
    private static readonly Color Idle = Color.FromArgb(0x4E, 0xBA, 0x65);
    private static readonly Color Stopped = Color.FromArgb(0x8B, 0x8A, 0x85);
    private static readonly Color Ink = Color.FromArgb(0xF2, 0xF1, 0xEC);
    private static readonly Color Dim = Color.FromArgb(0xA3, 0xA2, 0x9C);

    private const int MaxRows = 7;
    private readonly Hooks _hooks;
    private readonly System.Windows.Forms.Timer _tick = new() { Interval = 100 };
    private readonly List<(Rectangle r, Action a)> _hits = new();
    private JsonElement _board;
    private DateTime _loaded;

    public TrayPanel(Hooks hooks)
    {
        _hooks = hooks;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        BackColor = Bg;
        DoubleBuffered = true;
        Width = S(380);
        Height = S(600);
        _tick.Tick += (_, _) =>
        {
            if (DateTime.UtcNow - _loaded > TimeSpan.FromSeconds(1)) Reload();
            Invalidate();
        };
        Deactivate += (_, _) => Hide();
    }

    private int S(int v) => (int)Math.Round(v * DeviceDpi / 96.0);

    /// Above the tray, at the screen's corner by the taskbar.
    public void Toggle()
    {
        if (Visible) { Hide(); return; }
        Reload();
        Height = Measure();
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        var x = Math.Min(area.Right - Width - S(12), Math.Max(area.Left + S(12), Cursor.Position.X - Width / 2));
        Location = new Point(x, Cursor.Position.Y > area.Top + area.Height / 2 ? area.Bottom - Height - S(12) : area.Top + S(12));
        Show();
        Activate();
        _tick.Start();
    }

    protected override void OnVisibleChanged(EventArgs e)
    {
        base.OnVisibleChanged(e);
        if (!Visible) _tick.Stop();
    }

    protected override CreateParams CreateParams
    {
        get { var p = base.CreateParams; p.ClassStyle |= 0x20000; return p; }   // CS_DROPSHADOW
    }

    private void Reload()
    {
        try { _board = JsonDocument.Parse(_hooks.Sessions()).RootElement.Clone(); }
        catch { _board = default; }
        _loaded = DateTime.UtcNow;
        var h = Measure();
        if (Visible && h != Height) { Top += Height - h; Height = h; }
    }

    private List<JsonElement> Rows() =>
        _board.ValueKind == JsonValueKind.Object && _board.TryGetProperty("sessions", out var s) && s.ValueKind == JsonValueKind.Array
            ? s.EnumerateArray().ToList() : new();

    private int Measure()
    {
        var rows = Rows().Take(MaxRows).Sum(RowHeight) + GuestHub.Shares.Sum(GuestHeight);
        return S(16 + 44 + 46 + 120 + 14 + 44) + Math.Max(S(56), rows) + (Rows().Count > MaxRows ? S(24) : 0)
            + (GuestHub.Notice is null ? 0 : S(24)) + S(14 + 40 + 16);
    }

    private int GuestHeight(GuestShare s) =>
        S(48) + (!s.Active || GuestLine(s) is not null ? S(22) : 0) + (s.Active ? S(38) : 0);

    private static string? GuestLine(GuestShare s) => GuestHub.Row(s.Id) is { } r ? LastLine(r) : null;

    private int RowHeight(JsonElement r) =>
        S(48) + (LastLine(r) is not null && !Live(r) ? S(22) : 0) + (RowAction(r) is not null ? S(38) : 0);

    // ---- painting -------------------------------------------------------------------------

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        _hits.Clear();
        var pad = S(16);
        var w = Width - 2 * pad;
        var y = pad;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        using var title = new Font("Segoe UI", 20f, FontStyle.Bold);
        using var head = new Font("Segoe UI Semibold", 11.5f);
        using var body = new Font("Segoe UI", 9.5f);
        using var bodyBold = new Font("Segoe UI Semibold", 10f);
        using var small = new Font("Segoe UI", 8.5f);
        using var quote = new Font("Segoe UI", 9.5f, FontStyle.Italic);
        using var big = new Font("Segoe UI", 15f, FontStyle.Bold);

        // Title + settings
        Text(g, "Parley", title, Ink, pad, y);
        var gear = new Rectangle(Width - pad - S(32), y + S(4), S(32), S(32));
        Fill(g, gear, Card, gear.Height / 2);
        Text(g, "⚙", head, Accent, gear, center: true);
        Hit(gear, _hooks.Settings);
        y += S(44);

        // Pills: connection, Unterwegs, Stumm
        var relay = _hooks.Relay();
        var (status, dot) = PhoneCall.Active ? ("Im Anruf", Idle) : relay == true ? ("Verbunden", Idle)
            : relay == false ? ("Offline", Stopped) : ("Kein iPhone", Stopped);
        var sw = (int)g.MeasureString(status, body).Width + S(34);
        var pill = new Rectangle(pad, y, sw, S(30));
        Fill(g, pill, Color.FromArgb(40, dot), pill.Height / 2);
        using (var b = new SolidBrush(dot)) g.FillEllipse(b, pill.X + S(12), pill.Y + S(12), S(7), S(7));
        Text(g, status, body, Ink, pill.X + S(24), pill.Y + S(6));
        var right = Width - pad;
        var muted = _hooks.Muted();
        right = PillRight(g, "Stumm", muted, right, y, body, _hooks.ToggleMute);
        if (PhoneCall.Away) PillRight(g, "Unterwegs", true, right - S(8), y, body, null);
        y += S(46);

        // Today
        var card = new Rectangle(pad, y, w, S(120));
        Fill(g, card, Card, S(16));
        if (_board.ValueKind == JsonValueKind.Object && _board.TryGetProperty("today", out var today))
        {
            var cx = card.X + S(14);
            var col = (card.Width - S(28)) / 3;
            Fact(g, $"${Num(today, "costUsd"):0.00}", "Kosten heute", cx, card.Y + S(12), big, small);
            Fact(g, $"{Num(today, "turns"):0}", "Updates", cx + col, card.Y + S(12), big, small);
            Fact(g, $"{Math.Round(Num(today, "spokenSeconds") / 60):0} min", "gesprochen", cx + 2 * col, card.Y + S(12), big, small);
            var ly = card.Y + S(66);
            if (today.TryGetProperty("rateLimits", out var limits) && limits.ValueKind == JsonValueKind.Array)
            {
                foreach (var l in limits.EnumerateArray())
                {
                    var kind = l.TryGetProperty("kind", out var k) ? k.GetString() : null;
                    var name = kind == "five_hour" ? "5-h-Limit" : kind == "seven_day" ? "Woche" : null;
                    if (name is null || !l.TryGetProperty("percentUsed", out var p) || p.ValueKind != JsonValueKind.Number) continue;
                    var pct = p.GetDouble();
                    Text(g, name, small, Dim, cx, ly - S(2));
                    var bar = new Rectangle(cx + S(70), ly + S(4), card.Width - S(28) - S(70) - S(46), S(6));
                    Fill(g, bar, Raised, bar.Height / 2);
                    Fill(g, bar with { Width = (int)(bar.Width * Math.Clamp(pct / 100, 0, 1)) }, Accent, bar.Height / 2);
                    Text(g, $"{Math.Round(pct)} %", small, Ink, new Rectangle(bar.Right, ly - S(2), S(46), S(18)), alignRight: true);
                    ly += S(22);
                }
            }
        }
        y += S(120 + 14);

        // Sessions + Anrufen
        var rows = Rows();
        Text(g, "Sessions", head, Ink, pad, y + S(8));
        var guests = GuestHub.Shares;
        Text(g, $"{rows.Count + guests.Count}", head, Dim, pad + (int)g.MeasureString("Sessions", head).Width, y + S(8));
        var call = new Rectangle(Width - pad - S(100), y + S(4), S(100), S(32));
        Fill(g, call, PhoneCall.Away ? Color.FromArgb(100, Accent) : Accent, call.Height / 2);
        Text(g, "Anrufen", bodyBold, Color.White, call, center: true);
        if (!PhoneCall.Away) Hit(call, _hooks.Call);
        y += S(44);

        var listH = Math.Max(S(56), rows.Take(MaxRows).Sum(RowHeight) + guests.Sum(GuestHeight));
        var list = new Rectangle(pad, y, w, listH);
        Fill(g, list, Card, S(16));
        if (rows.Count == 0 && guests.Count == 0)
            Text(g, "Keine Session. Starte /parley:voice in Claude Code.", body, Dim, list.X + S(14), list.Y + S(18));
        var ry = y;
        foreach (var (r, i) in rows.Take(MaxRows).Select((r, i) => (r, i)))
        {
            var h = RowHeight(r);
            DrawRow(g, r, new Rectangle(pad, ry, w, h), i > 0, now, head, body, quote, bodyBold);
            ry += h;
        }
        foreach (var (gs, i) in guests.Select((gs, i) => (gs, i)))
        {
            var h = GuestHeight(gs);
            DrawGuest(g, gs, new Rectangle(pad, ry, w, h), i > 0 || rows.Count > 0, now, head, body, quote, bodyBold);
            ry += h;
        }
        y += listH;
        if (rows.Count > MaxRows)
        {
            Text(g, $"+ {rows.Count - MaxRows} weitere", small, Dim, pad + S(4), y + S(4));
            y += S(24);
        }
        if (GuestHub.Notice is { } note)
        {
            Text(g, note, small, Dim, new Rectangle(pad, y + S(6), w, S(18)));
            y += S(24);
        }
        y += S(14);

        // Footer
        var fx = pad;
        foreach (var (label, act) in new (string, Action)[] { ("iPhone", _hooks.Pair), ("Statistik", _hooks.Stats), ("Beitreten", GuestHub.AskToJoin), ("Setup", _hooks.Setup) })
        {
            var bw = (int)g.MeasureString(label, body).Width + S(22);
            var r = new Rectangle(fx, y, bw, S(30));
            Fill(g, r, Card, r.Height / 2);
            Text(g, label, body, Ink, r, center: true);
            Hit(r, act);
            fx += bw + S(6);
        }
        var quit = new Rectangle(Width - pad - S(30), y, S(30), S(30));
        Text(g, "⏻", head, Dim, quit, center: true);
        Hit(quit, _hooks.Quit);
    }

    private void DrawRow(Graphics g, JsonElement r, Rectangle box, bool divider, long now,
                         Font head, Font body, Font quote, Font bold)
    {
        var state = Str(r, "state") ?? "stopped";
        var color = StateColor(state);
        if (Live(r)) using (var b = new SolidBrush(Color.FromArgb(28, Accent))) g.FillRectangle(b, box);
        if (divider) using (var p = new Pen(Raised)) g.DrawLine(p, box.X + S(52), box.Y, box.Right, box.Y);
        Ring(g, state, color, new Rectangle(box.X + S(14), box.Y + S(12), S(24), S(24)), now);

        var x = box.X + S(52);
        var y = box.Y + S(12);
        var name = Str(r, "label") is { Length: > 0 } l ? l : Str(r, "project") ?? "";
        var corner = Corner(r, state, now);
        var cw = (int)g.MeasureString(corner, body).Width;
        var nameW = Math.Min((int)g.MeasureString(name, head).Width, box.Right - x - cw - S(90));
        Text(g, name, head, state == "stopped" ? Dim : Ink, new Rectangle(x, y - S(2), nameW, S(24)));
        var callback = Long(r, "callback");
        Text(g, StateText(r, state, now), body, callback is not null ? Waiting : color,
             new Rectangle(x + nameW + S(4), y + S(1), box.Right - S(14) - cw - x - nameW - S(8), S(22)));
        Text(g, corner, body, Dim, new Rectangle(box.Right - S(14) - cw - S(4), y + S(1), cw + S(4), S(22)), alignRight: true);
        y += S(28);
        if (LastLine(r) is { } line && !Live(r))
        {
            Text(g, $"„{line}“", quote, Dim, new Rectangle(x, y, box.Right - S(14) - x, S(20)));
            y += S(22);
        }
        if (RowAction(r) is { } act)
        {
            var bw = S(104);
            var b = new Rectangle(x, y + S(2), bw, S(28));
            Fill(g, b, Accent, b.Height / 2);
            Text(g, "Fortsetzen", bold, Color.White, b, center: true);
            Hit(b, act);
        }
    }

    // Someone else's session this PC joined (Guest.cs): its row once in, "Anrufen" / "Annehmen" +
    // "Ablehnen" / "Auflegen", "Verlassen"; while Sir decides, the join's check code.
    private void DrawGuest(Graphics g, GuestShare s, Rectangle box, bool divider, long now,
                           Font head, Font body, Font quote, Font bold)
    {
        var row = GuestHub.Row(s.Id);
        var state = !s.Active ? "queued" : row is { } r ? Str(r, "state") ?? "idle" : "idle";
        if (divider) using (var p = new Pen(Raised)) g.DrawLine(p, box.X + S(52), box.Y, box.Right, box.Y);
        Ring(g, state, StateColor(state), new Rectangle(box.X + S(14), box.Y + S(12), S(24), S(24)), now);

        var x = box.X + S(52);
        var y = box.Y + S(12);
        var name = row is { } rr && Str(rr, "label") is { Length: > 0 } l ? l : s.Label;
        var leave = new Rectangle(box.Right - S(14) - S(70), y, S(70), S(22));
        Text(g, "Verlassen", body, Dim, leave, alignRight: true);
        Hit(leave, () => GuestHub.Leave(s.Id));
        var nameW = Math.Min((int)g.MeasureString(name, head).Width, leave.X - x - S(110));
        Text(g, name, head, Ink, new Rectangle(x, y - S(2), nameW, S(24)));
        Text(g, s.Active ? $"geteilt von {s.Host}" : $"wartet auf {s.Host}", body, Dim,
             new Rectangle(x + nameW + S(4), y + S(1), leave.X - x - nameW - S(8), S(22)));
        y += S(28);
        if (!s.Active)
        {
            Text(g, $"Code {s.Code} — schick ihn {s.Host}, damit er dich hereinlässt.", body, Dim, new Rectangle(x, y, box.Right - S(14) - x, S(20)));
            return;
        }
        if (GuestLine(s) is { } line)
        {
            Text(g, $"„{line}“", quote, Dim, new Rectangle(x, y, box.Right - S(14) - x, S(20)));
            y += S(22);
        }
        var b = new Rectangle(x, y + S(2), S(104), S(28));
        if (GuestHub.InCall == s.Id)
        {
            Fill(g, b, Color.FromArgb(0xE5, 0x48, 0x4D), b.Height / 2);
            Text(g, "Auflegen", bold, Color.White, b, center: true);
            Hit(b, GuestHub.EndCall);
        }
        else if (GuestHub.Ringing(s.Id))
        {
            Fill(g, b, Idle, b.Height / 2);
            Text(g, "Annehmen", bold, Color.White, b, center: true);
            Hit(b, () => GuestHub.Call(s.Id));
            var no = new Rectangle(b.Right + S(10), b.Y, S(80), b.Height);
            Text(g, "Ablehnen", body, Dim, no, center: true);
            Hit(no, () => GuestHub.Decline(s.Id));
        }
        else
        {
            var usable = GuestHub.InCall is null && !s.Listen;
            Fill(g, b, usable ? Accent : Color.FromArgb(100, Accent), b.Height / 2);
            Text(g, "Anrufen", bold, Color.White, b, center: true);
            if (usable) Hit(b, () => GuestHub.Call(s.Id));
        }
    }

    private void Ring(Graphics g, string state, Color color, Rectangle r, long now)
    {
        using var track = new Pen(Color.FromArgb(50, color), S(3));
        using var pen = new Pen(color, S(3)) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        using var fill = new SolidBrush(color);
        g.DrawEllipse(track, r);
        var t = now / 1000.0;
        switch (state)
        {
            case "speaking" or "listening" or "transcribing":
                g.DrawEllipse(pen, r);
                var d = S(10) + (float)(S(5) * (0.5 - 0.5 * Math.Cos(2 * Math.PI * t / 1.4)));
                g.FillEllipse(fill, r.X + r.Width / 2f - d / 2, r.Y + r.Height / 2f - d / 2, d, d);
                break;
            case "working" or "queued":
                g.DrawArc(pen, r, (float)(360 * (t / (state == "working" ? 1.2 : 3) % 1)), 110);
                break;
            case "background":
                var a = 2 * Math.PI * (t / 2.4 % 1);
                var dot = S(6);
                g.FillEllipse(fill, r.X + r.Width / 2f + (float)(Math.Sin(a) * r.Width / 2) - dot / 2f,
                              r.Y + r.Height / 2f - (float)(Math.Cos(a) * r.Height / 2) - dot / 2f, dot, dot);
                g.FillEllipse(fill, r.X + r.Width / 2f - dot / 2f, r.Y + r.Height / 2f - dot / 2f, dot, dot);
                break;
            case "parked" or "stopped":
                g.FillRectangle(fill, r.X + r.Width / 2 - S(4), r.Y + S(7), S(3), S(10));
                g.FillRectangle(fill, r.X + r.Width / 2 + S(1), r.Y + S(7), S(3), S(10));
                break;
            default:
                g.DrawEllipse(pen, r);
                break;
        }
    }

    // ---- row data (as macOS MenuBarView / the iPhone's SessionCard) ------------------------

    private static bool Live(JsonElement r) => Str(r, "state") is "speaking" or "listening" or "transcribing";

    private static string? LastLine(JsonElement r) =>
        r.TryGetProperty("stats", out var s) && s.ValueKind == JsonValueKind.Object && s.TryGetProperty("lastLine", out var l)
        && l.ValueKind == JsonValueKind.String && l.GetString() is { Length: > 0 } line ? line : null;

    private Action? RowAction(JsonElement r)
    {
        if (Long(r, "callback") is not null) return null;
        if (!r.TryGetProperty("resumable", out var res) || res.ValueKind != JsonValueKind.True) return null;
        var id = Str(r, "id") ?? "";
        return () => _hooks.Resume(id);
    }

    private static string StateText(JsonElement r, string state, long now)
    {
        if (Long(r, "callback") is { } cb) return cb == 0 ? "wartet auf Rückruf" : $"ruft in {Clock(Math.Max(0, cb - now))} an";
        if (Str(r, "asking") is { } name) return $"Rückfrage an {name}";
        return state switch
        {
            "speaking" => "spricht",
            "listening" => "hört zu",
            "transcribing" => "transkribiert",
            "queued" => "Warteschlange",
            "working" => "arbeitet",
            "background" => r.TryGetProperty("tasks", out var t) && t.GetArrayLength() > 1 ? $"{t.GetArrayLength()} im Hintergrund" : "Agent im Hintergrund",
            "waiting" => "pausiert",
            "parked" => "geparkt",
            "idle" => "bereit",
            _ => "gestoppt",
        };
    }

    private static string Corner(JsonElement r, string state, long now)
    {
        var since = Long(r, "since") ?? now;
        if (state == "waiting" && Long(r, "until") is { } until) return Clock(until - now);
        if (state == "stopped") return $"vor {Math.Max(1, (int)Math.Round((now - since) / 60_000.0))} min";
        return Clock(now - since);
    }

    private static string Clock(long ms)
    {
        var s = Math.Max(0, ms / 1000);
        return s >= 3600 ? $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}" : $"{s / 60}:{s % 60:00}";
    }

    private static Color StateColor(string s) => s switch
    {
        "speaking" or "listening" or "transcribing" => Accent,
        "queued" or "waiting" => Waiting,
        "working" => Working,
        "background" => Purple,
        "idle" => Idle,
        _ => Stopped,
    };

    private static string? Str(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static long? Long(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;

    private static double Num(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : 0;

    // ---- drawing helpers -------------------------------------------------------------------

    private int PillRight(Graphics g, string label, bool on, int right, int y, Font font, Action? act)
    {
        var pw = (int)g.MeasureString(label, font).Width + S(26);
        var r = new Rectangle(right - pw, y, pw, S(30));
        Fill(g, r, on ? Accent : Card, r.Height / 2);
        Text(g, label, font, on ? Color.White : Ink, r, center: true);
        if (act is not null) Hit(r, act);
        return r.X;
    }

    private void Fact(Graphics g, string value, string label, int x, int y, Font big, Font small)
    {
        Text(g, value, big, Ink, x, y);
        Text(g, label, small, Dim, x, y + S(30));
    }

    private static void Fill(Graphics g, Rectangle r, Color c, int radius)
    {
        if (r.Width <= 0 || r.Height <= 0) return;
        using var path = WinUI.Round(r, radius);
        using var b = new SolidBrush(c);
        g.FillPath(b, path);
    }

    private static void Text(Graphics g, string s, Font f, Color c, int x, int y) =>
        TextRenderer.DrawText(g, s, f, new Point(x, y), c, TextFormatFlags.NoPadding);

    private static void Text(Graphics g, string s, Font f, Color c, Rectangle r, bool center = false, bool alignRight = false) =>
        TextRenderer.DrawText(g, s, f, r, c, TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine
            | (center ? TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter : alignRight ? TextFormatFlags.Right : 0));

    private void Hit(Rectangle r, Action a) => _hits.Add((r, a));

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Cursor = _hits.Any(h => h.r.Contains(e.Location)) ? Cursors.Hand : Cursors.Default;
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (e.Button != MouseButtons.Left) return;
        foreach (var (r, a) in _hits.ToList())
        {
            if (!r.Contains(e.Location)) continue;
            a();
            Reload();
            Invalidate();
            return;
        }
    }
}
