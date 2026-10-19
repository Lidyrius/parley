using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parley;

// The Parley Live Activity on the iPhone (docs/LIVE-ACTIVITIES.md) — the same as macOS
// (app/Sources/Parley/LiveActivity.swift): every session at a glance in the Dynamic Island, on
// the Lock Screen, the Watch and in CarPlay. The host starts it by push-to-start while Unterwegs
// is on and a session runs, pushes each state change (the phone's timers count by themselves) and
// ends it. `Content` is the activity's `content-state` (ios/Shared/ParleyActivity.swift).
public static class LiveActivity
{
    public sealed record Row(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("label")] string Label,
        [property: JsonPropertyName("state")] string State,
        [property: JsonPropertyName("since")] double Since,                 // epoch s
        [property: JsonPropertyName("until")] double? Until = null,
        [property: JsonPropertyName("callback")] double? Callback = null);  // epoch s; 0 = waits for Sir's call back

    // Stumm (or a ring not answered): Parley's question, waiting for Sir — answered with a tap on
    // a predicted answer.
    public sealed record Ask(
        [property: JsonPropertyName("id")] string Id,                       // the session
        [property: JsonPropertyName("label")] string Label,
        [property: JsonPropertyName("text")] string Text,
        [property: JsonPropertyName("options")] IReadOnlyList<string> Options)
    {
        // From a voiced turn: the line and its predicted answers (<reply on>), trimmed to fit.
        public static Ask From(string id, string label, string text, IEnumerable<string> options) => new(
            id, label.Length > 32 ? label[..32] : label, text.Length > 160 ? text[..160] : text,
            options.Select(o => o.Trim()).Where(o => o.Length > 0).Select(o => o.Length > 40 ? o[..40] : o).Take(3).ToList());

        public bool SameAs(Ask? o) => o is not null && Id == o.Id && Label == o.Label && Text == o.Text && Options.SequenceEqual(o.Options);
    }

    public sealed record Content(
        [property: JsonPropertyName("sessions")] IReadOnlyList<Row> Sessions,
        [property: JsonPropertyName("alive")] int Alive,
        [property: JsonPropertyName("line")] string? Line = null,
        [property: JsonPropertyName("from")] string? From = null,
        [property: JsonPropertyName("ask")] Ask? Ask = null)
    {
        public static readonly Content Empty = new(Array.Empty<Row>(), 0);

        // Sir is wanted: a question, a call back, a ring to come, Parley talking or wanting to.
        public IReadOnlySet<string> WantsSir
        {
            get
            {
                var ids = Sessions.Where(r => r.Callback is not null || r.State is "speaking" or "listening" or "transcribing" or "queued")
                    .Select(r => r.Id).ToHashSet();
                if (Ask is not null) ids.Add("ask:" + Ask.Id);
                return ids;
            }
        }

        // Records compare lists by reference; the feed needs the values.
        public bool SameAs(Content? o) =>
            o is not null && Alive == o.Alive && Line == o.Line && From == o.From && Sessions.SequenceEqual(o.Sessions)
            && (Ask is null ? o.Ask is null : Ask.SameAs(o.Ask));
    }

    // The latest question (set by the turn, cleared by an answer or when its session moves on).
    private static readonly object AskGate = new();
    private static Ask? _ask;
    public static Ask? CurrentAsk
    {
        get { lock (AskGate) return _ask; }
        set { lock (AskGate) _ask = value; }
    }

    // A question stays while its session waits (parked, paused or in the background
    // after it); once it works again, talks, or stopped, it was answered some other way.
    public static bool IsOpen(Ask ask, string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("sessions", out var list) || list.ValueKind != JsonValueKind.Array) return false;
            foreach (var s in list.EnumerateArray())
                if (s.TryGetProperty("id", out var id) && id.GetString() == ask.Id)
                    return s.TryGetProperty("state", out var st) && st.GetString() is "parked" or "waiting" or "background";
            return false;
        }
        catch (JsonException) { return false; }
    }

    public const int MaxRows = 4;
    public const string AttributesType = "ParleyAttributes";
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(15);

    // The order that matters to Sir: a call back owed, a ring to come, talking, wanting to talk,
    // paused, working, background, parked — newest first within each.
    public static int Rank(Row r)
    {
        if (r.Callback is { } c) return c <= 0 ? 0 : 1;
        return r.State switch
        {
            "speaking" or "listening" or "transcribing" => 2,
            "queued" => 3,
            "waiting" => 4,
            "working" => 5,
            "background" => 6,
            "parked" => 7,
            _ => 8,
        };
    }

    // GET /sessions (times in epoch ms) → the activity's content. Stopped sessions are left out;
    // the line is the most urgent session's last spoken one.
    public static Content FromSessions(string json, Ask? ask = null, int maxRows = MaxRows)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("sessions", out var list) || list.ValueKind != JsonValueKind.Array) return Content.Empty;
            var rows = new List<(Row Row, string? Line)>();
            foreach (var s in list.EnumerateArray())
            {
                string? Str(string k) => s.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
                double? Sec(string k) => s.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() / 1000 : null;
                if (Str("id") is not { Length: > 0 } id || Str("state") is not { } state || state == "stopped") continue;
                var label = Str("label") is { Length: > 0 } l ? l : Str("project") ?? id[..Math.Min(8, id.Length)];
                var line = s.TryGetProperty("stats", out var st) && st.ValueKind == JsonValueKind.Object
                           && st.TryGetProperty("lastLine", out var ll) && ll.ValueKind == JsonValueKind.String ? ll.GetString() : null;
                rows.Add((new Row(id, label.Length > 32 ? label[..32] : label, state, Sec("since") ?? 0, Sec("until"), Sec("callback")), line));
            }
            rows.Sort((a, b) => Rank(a.Row) != Rank(b.Row) ? Rank(a.Row).CompareTo(Rank(b.Row)) : b.Row.Since.CompareTo(a.Row.Since));
            var spoken = rows.FirstOrDefault(r => !string.IsNullOrEmpty(r.Line));
            var text = spoken.Line is { } t ? (t.Length > 120 ? t[..120] : t) : null;
            return new Content(rows.Take(maxRows).Select(r => r.Row).ToList(), rows.Count, text, text is null ? null : spoken.Row.Label, ask);
        }
        catch (JsonException) { return Content.Empty; }
    }

    // ---- the widgets (a silent push the app stores for them) ---------------------------

    // The widgets' picture (ios/Shared/WidgetSnapshot.swift `WidgetPush`): up to 8 sessions, the
    // line, and today's figures from GET /sessions — as macOS.
    public sealed record Widget(
        [property: JsonPropertyName("sessions")] IReadOnlyList<Row> Sessions,
        [property: JsonPropertyName("line")] string? Line,
        [property: JsonPropertyName("from")] string? From,
        [property: JsonPropertyName("cost")] double? Cost,
        [property: JsonPropertyName("updates")] int? Updates,
        [property: JsonPropertyName("limit")] double? Limit,
        [property: JsonPropertyName("week")] double? Week)
    {
        // What makes a push worth it: the sessions, the line, the limit in whole percent — not
        // the cost, which creeps up all the time.
        [JsonIgnore]
        public string Key => string.Join(";", Sessions.Select(r => $"{r.Id}/{r.State}/{r.Since}/{r.Until}/{r.Callback}"))
                             + "|" + (Line ?? "") + "|" + (Limit is { } l ? (int)l : -1);
    }

    public static Widget WidgetFrom(string json)
    {
        var c = FromSessions(json, maxRows: 8);
        double? cost = null, limit = null, week = null;
        int? updates = null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("today", out var today) && today.ValueKind == JsonValueKind.Object)
            {
                if (today.TryGetProperty("costUsd", out var cu) && cu.ValueKind == JsonValueKind.Number) cost = cu.GetDouble();
                if (today.TryGetProperty("turns", out var tu) && tu.ValueKind == JsonValueKind.Number) updates = tu.GetInt32();
                if (today.TryGetProperty("rateLimits", out var rl) && rl.ValueKind == JsonValueKind.Array)
                    foreach (var r in rl.EnumerateArray())
                    {
                        var kind = r.TryGetProperty("kind", out var k) ? k.GetString() : null;
                        double? used = r.TryGetProperty("percentUsed", out var p) && p.ValueKind == JsonValueKind.Number ? p.GetDouble() : null;
                        if (kind == "five_hour") limit = used;
                        if (kind == "seven_day") week = used;
                    }
            }
        }
        catch (JsonException) { }
        return new Widget(c.Sessions, c.Line, c.From, cost, updates, limit, week);
    }

    // {"aps":{"content-available":1},"widget":{…}} — wakes the app, shows nothing.
    public static string WidgetPayload(Widget w) => JsonSerializer.Serialize(new Dictionary<string, object>
    {
        ["aps"] = new Dictionary<string, int> { ["content-available"] = 1 },
        ["widget"] = w,
    }, Json);

    public enum Event { Start, Update, End }

    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public static string Payload(Event e, Content c, DateTimeOffset now)
    {
        var t = now.ToUnixTimeSeconds();
        var aps = new Dictionary<string, object?>
        {
            ["timestamp"] = t,
            ["event"] = e.ToString().ToLowerInvariant(),
            ["content-state"] = c,
        };
        if (e == Event.End) aps["dismissal-date"] = t;
        else
        {
            aps["stale-date"] = t + (long)StaleAfter.TotalSeconds;
            aps["relevance-score"] = c.WantsSir.Count == 0 ? 50.0 : 100.0;
        }
        if (e == Event.Start)
        {
            aps["attributes-type"] = AttributesType;
            aps["attributes"] = new Dictionary<string, object>();
            aps["alert"] = new Dictionary<string, string> { ["title"] = "Parley unterwegs", ["body"] = StartLine(c) };
        }
        return JsonSerializer.Serialize(new Dictionary<string, object> { ["aps"] = aps }, Json);
    }

    // The start's banner: what runs, in one line.
    public static string StartLine(Content c)
    {
        if (c.Sessions.Count == 0) return "Bereit.";
        var top = c.Sessions[0];
        var more = c.Alive > 1 ? $" · {c.Alive} aktiv" : "";
        return $"{top.Label} {(top.State == "working" ? "arbeitet" : "ist dabei")}{more}";
    }
}

// When to start, update and end the activity — the macOS feed's rules (LiveActivityFeed).
public sealed class LiveActivityFeed
{
    public abstract record Action(LiveActivity.Content Content);
    public sealed record Start(LiveActivity.Content Content) : Action(Content);
    public sealed record Update(LiveActivity.Content Content, int Priority) : Action(Content);
    public sealed record End(LiveActivity.Content Content) : Action(Content);

    public static readonly TimeSpan EmptyGrace = TimeSpan.FromMinutes(2);    // nothing runs any more: keep it this long
    public static readonly TimeSpan RenewAfter = TimeSpan.FromHours(7.5);    // iOS ends an activity after 8 h
    public static readonly TimeSpan Heartbeat = TimeSpan.FromMinutes(10);    // refresh the stale date while nothing changes
    public static readonly TimeSpan StartRetry = TimeSpan.FromMinutes(1);
    public static readonly TimeSpan MinGap = TimeSpan.FromSeconds(1);
    public static readonly TimeSpan Settle = TimeSpan.FromSeconds(30);       // a phone's "ended" this soon after a start is the old one's

    public bool Running { get; private set; }
    public bool Dismissed { get; private set; }   // Sir swiped it away: not again until Unterwegs goes off
    private DateTime? _startedAt;
    private DateTime _lastStartTry = DateTime.MinValue;
    private LiveActivity.Content? _sent;
    private DateTime _sentAt = DateTime.MinValue;
    private DateTime? _emptySince;

    // The phone told us whether one runs (its update token arrived, or "" = it ended). An end we
    // did not push is Sir's (swiped away) — unless it is the replaced one right after a start.
    public void PhoneReports(bool running, DateTime t)
    {
        if (running)
        {
            if (!Running) { Running = true; _startedAt ??= t; }
            return;
        }
        if (_startedAt is { } s && t - s < Settle) return;
        if (Running) Dismissed = true;
        Running = false;
        _startedAt = null;
        _sent = null;
    }

    public Action? Step(LiveActivity.Content content, bool away, bool canStart, bool canUpdate, DateTime now)
    {
        if (!away) Dismissed = false;
        if (content.Alive > 0) _emptySince = null; else _emptySince ??= now;
        var idleTooLong = _emptySince is { } e && now - e >= EmptyGrace;
        var wanted = away && !idleTooLong;

        if (!wanted || (Running && _startedAt is { } st && now - st >= RenewAfter))
        {
            if (!Running) return null;
            Running = false;
            _startedAt = null;
            _sent = null;
            _lastStartTry = DateTime.MinValue;   // a renewal starts again right away
            return canUpdate ? new End(content) : null;
        }
        if (content.Alive == 0 && !Running) return null;

        if (!Running)
        {
            if (!canStart || Dismissed || now - _lastStartTry < StartRetry) return null;
            Running = true;
            _startedAt = now;
            _lastStartTry = now;
            _sent = content;
            _sentAt = now;
            return new Start(content);
        }

        if (!canUpdate || now - _sentAt < MinGap) return null;
        if (content.SameAs(_sent) && now - _sentAt < Heartbeat) return null;
        var newlyWanted = content.WantsSir.Except(_sent?.WantsSir ?? new HashSet<string>()).Any();
        _sent = content;
        _sentAt = now;
        return new Update(content, newlyWanted ? 10 : 5);
    }
}

// When the widgets get a silent push: iOS throttles them (a few an hour), so at most every
// 20 min, and only when what they show changed — as macOS (WidgetPushFeed).
public sealed class WidgetPushFeed
{
    public static readonly TimeSpan Every = TimeSpan.FromMinutes(20);
    private string? _sent;
    private DateTime _sentAt = DateTime.MinValue;

    public bool Due(LiveActivity.Widget w, DateTime now)
    {
        if (w.Key == _sent || now - _sentAt < Every) return false;
        _sent = w.Key;
        _sentAt = now;
        return true;
    }
}
