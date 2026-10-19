using System.Globalization;
using System.Text.Json;

namespace Parley;

// Snapshots (as macOS: app/Sources/Parley/Snapshots.swift; the phone's "Snapshots", the tray): a
// named set of sessions — each one's name, session id and folder — that Sir opens again in one go.
// Opening leaves a session that still runs alone, resumes one whose transcript is still there
// (`claude --resume`), else starts a new one in its folder under the same name. Kept in
// snapshots.json (beside reminders.json, survives restarts and updates); the list rides along in
// /sessions. Protocol: docs/IPHONE.md, v6.
public sealed class Snapshot
{
    public sealed class Item
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string Cwd { get; set; } = "";
    }

    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public double At { get; set; }   // epoch ms, as macOS stores it
    public List<Item> Sessions { get; set; } = new();
}

/// What opening did to one session: "running" (left alone, or its start is on the way),
/// "resumed", "started" (a new one, same name), "missing" (its folder is gone).
public readonly record struct SnapshotOutcome(string Id, string Name, string Result);

public sealed class SnapshotStore
{
    public const int MaxName = 60;
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };

    private readonly string? _file;
    private readonly List<Snapshot> _list;

    public SnapshotStore(string? file)
    {
        _file = file;
        try { _list = file is not null && File.Exists(file) ? JsonSerializer.Deserialize<List<Snapshot>>(File.ReadAllText(file), Json) ?? new() : new(); }
        catch { _list = new(); }
    }

    /// `sessions` under `name` (trimmed, ≤ 60); the same name again (any case) replaces that one.
    /// null: no name, or no session with a folder to keep.
    public Snapshot? Save(string raw, IEnumerable<(string Id, string Name, string Cwd)> sessions, DateTime now)
    {
        var name = raw.Trim();
        var info = new StringInfo(name);
        if (info.LengthInTextElements > MaxName) name = info.SubstringByTextElements(0, MaxName);
        var items = sessions.Where(s => s.Cwd.Length > 0)
            .Select(s => new Snapshot.Item { Id = s.Id, Name = s.Name, Cwd = s.Cwd }).ToList();
        if (name.Length == 0 || items.Count == 0) return null;
        var snap = new Snapshot
        {
            Id = Guid.NewGuid().ToString().ToLowerInvariant(),
            Name = name,
            At = Math.Round((now - DateTime.UnixEpoch).TotalMilliseconds),
            Sessions = items,
        };
        lock (_list)
        {
            _list.RemoveAll(s => string.Equals(s.Name, name, StringComparison.OrdinalIgnoreCase));
            _list.Add(snap);
            Save();
        }
        return snap;
    }

    public Snapshot? Find(string id)
    {
        lock (_list) return _list.FirstOrDefault(s => s.Id == id);
    }

    /// The deleted one, or null when unknown.
    public Snapshot? Delete(string id)
    {
        lock (_list)
        {
            var i = _list.FindIndex(s => s.Id == id);
            if (i < 0) return null;
            var gone = _list[i];
            _list.RemoveAt(i);
            Save();
            return gone;
        }
    }

    /// Newest first (the tray).
    public List<Snapshot> List()
    {
        lock (_list) return _list.OrderByDescending(s => s.At).ToList();
    }

    /// GET /snapshots and the `snapshots` in /sessions (the phone lists them): newest first, `at`
    /// in epoch ms.
    public List<object> Rows() { lock (_list) return Rows(_list); }

    public static List<object> Rows(IEnumerable<Snapshot> list) => list
        .OrderByDescending(s => s.At)
        .Select(s => (object)new
        {
            id = s.Id,
            name = s.Name,
            at = (long)Math.Round(s.At),
            sessions = s.Sessions.Select(i => new { id = i.Id, name = i.Name, cwd = i.Cwd }).ToList(),
        })
        .ToList();

    public static List<object> Results(IEnumerable<SnapshotOutcome> outcomes) =>
        outcomes.Select(o => (object)new { id = o.Id, name = o.Name, result = o.Result }).ToList();

    /// The phone's answer to `{"t":"snapshot","op":"open"}`.
    public static string Frame(Snapshot s, IEnumerable<SnapshotOutcome> outcomes) =>
        JsonSerializer.Serialize(new { t = "snapshot", id = s.Id, name = s.Name, results = Results(outcomes) });

    /// A POST body {id?, name?, ids?}; null when it isn't that — a wrong type anywhere, as the
    /// macOS Decodable.
    public static (string? Id, string? Name, List<string>? Ids)? Request(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return null;
            JsonElement? Get(string k) => r.TryGetProperty(k, out var v) && v.ValueKind != JsonValueKind.Null ? v : null;
            string? id = null, name = null;
            List<string>? ids = null;
            if (Get("id") is { } i) { if (i.ValueKind != JsonValueKind.String) return null; id = i.GetString(); }
            if (Get("name") is { } n) { if (n.ValueKind != JsonValueKind.String) return null; name = n.GetString(); }
            if (Get("ids") is { } a)
            {
                if (a.ValueKind != JsonValueKind.Array || a.EnumerateArray().Any(v => v.ValueKind != JsonValueKind.String)) return null;
                ids = a.EnumerateArray().Select(v => v.GetString()!).ToList();
            }
            return (id, name, ids);
        }
        catch (JsonException) { return null; }
    }

    private void Save()
    {
        if (_file is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            var tmp = _file + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_list, Json));
            File.Move(tmp, _file, overwrite: true);
        }
        catch (Exception e) { Log.Write($"snapshot: not saved ({e.Message})"); }
    }
}
