using System.Text.Json;

namespace Parley;

// Which Parley sessions exist and what each one is doing — for GET /sessions (the Claude
// Code mod's overview), POST /resume and the "Update zu <Name>" announcement. 1:1 with the
// macOS SessionRegistry. Three signals feed it: /presence heartbeats from the mod (~5 s,
// Claude Code only), the Stop hook's /turn + /wake traffic, and the reply handed back for
// each turn. The state itself is derived from timestamps on every read, so a session that
// goes silent ages into `stopped` on its own — there is no clean "session ended" signal.
// Requests run concurrently → every entry point takes the lock.
public sealed class SessionRegistry
{
    private sealed class Entry
    {
        public string Id = "", Label = "", Project = "";   // session_id, spoken label, cwd basename
        public DateTime? PresenceAt;      // last /presence (null = never sent, e.g. Codex)
        public bool PresenceWorking;      // the mod reported "working"
        public DateTime HookAt;           // last /turn, /wake or turn reply
        public bool Queued;               // a /turn waits at the gate
        public DateTime? WaitUntil;       // "Warte X Minuten": the hook sleeps until then
        public bool Parked;               // answered with park; its hook polls /wake
        public DateTime? WakeAt;          // last /wake poll
        public DateTime? InjectedAt;      // a reply was fed back → the agent is working on it
        public string State = "";
        public DateTime Since;
    }

    // Windows from the contract: presence goes stale after 20 s, a parked hook after 30 s
    // without a /wake poll, a hook-only session (no presence) after 5 min.
    private static readonly TimeSpan PresenceTtl = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan ParkTtl = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan HookTtl = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan KeepStopped = TimeSpan.FromMinutes(10);

    private readonly object _gate = new();
    private readonly Dictionary<string, Entry> _entries = new();
    private string? _activeId;                 // the turn being voiced right now
    private readonly Func<DateTime> _now;
    private readonly Func<string> _phase;      // phase of the active turn (LiveStatus)

    public SessionRegistry(Func<DateTime>? now = null, Func<string>? phase = null)
    {
        _now = now ?? (() => DateTime.UtcNow);
        _phase = phase ?? (() => LiveStatus.Phase());
    }

    // ---- signals ---------------------------------------------------------------------

    public void Presence(string id, string label, string project, bool working) =>
        Update(id, label, project, (e, t) => { e.PresenceAt = t; e.PresenceWorking = working; });

    // A /turn arrived; it waits at the gate until it's this session's turn to speak.
    public void Queued(string id, string label, string project) =>
        Update(id, label, project, (e, t) =>
        {
            e.HookAt = t;
            e.Queued = true;
            e.WaitUntil = null;
            e.Parked = false;
            e.InjectedAt = null;
        });

    // The session's turn is now the one being voiced.
    public void Activate(string id)
    {
        lock (_gate)
        {
            _activeId = id;
            Update(id, "", "", (e, t) => { e.HookAt = t; e.Queued = false; });
        }
    }

    // The turn's reply went back to the hook: wait, park, inject a transcript, or end.
    public void Finished(string id, string transcript, bool park, int waitSeconds)
    {
        lock (_gate)
        {
            if (_activeId == id) _activeId = null;
            Update(id, "", "", (e, t) =>
            {
                e.HookAt = t;
                e.Queued = false;
                e.WaitUntil = waitSeconds > 0 ? t.AddSeconds(waitSeconds) : null;
                e.Parked = park;
                e.WakeAt = park ? t : null;
                e.InjectedAt = transcript.Length > 0 ? t : null;
            });
        }
    }

    // A parked hook polled /wake. `resumed` = it was handed an instruction and goes on working.
    public void WakePoll(string id, string label, string project, bool resumed) =>
        Update(id, label, project, (e, t) =>
        {
            e.HookAt = t;
            e.WakeAt = t;
            e.Parked = !resumed;
            if (resumed) e.InjectedAt = t;
        });

    // ---- queries ---------------------------------------------------------------------

    public bool IsParked(string id)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.TryGetValue(id, out var e) && e.State == "parked";
        }
    }

    // Any session besides `id` that isn't stopped → the turn gets announced.
    public bool OthersAlive(string id)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.Values.Any(e => e.Id != id && e.State != "stopped");
        }
    }

    // GET /sessions — voice holder first, then alive sessions by label, stopped last.
    public string Json()
    {
        lock (_gate)
        {
            Refresh();
            var active = _activeId;
            int Rank(Entry e) => e.Id == active ? 0 : e.State == "stopped" ? 2 : 1;
            var rows = _entries.Values
                .OrderBy(Rank)
                .ThenBy(e => e.Label, StringComparer.OrdinalIgnoreCase)
                .ThenBy(e => e.Id, StringComparer.Ordinal)
                .Select(e => new
                {
                    id = e.Id,
                    label = e.Label,
                    project = e.Project,
                    state = e.State,
                    since = Ms(e.Since),
                    until = e.State == "waiting" && e.WaitUntil is { } u ? Ms(u) : (long?)null,
                    voice = e.Id == active,
                })
                .ToList();
            return JsonSerializer.Serialize(new { sessions = rows });
        }
    }

    private static long Ms(DateTime d) => (long)Math.Round((d - DateTime.UnixEpoch).TotalMilliseconds);

    // ---- state derivation ------------------------------------------------------------

    // Precedence high→low: the voiced turn's phase, queued, waiting, parked, working, idle,
    // stopped.
    private string StateOf(Entry e, DateTime t)
    {
        if (e.Id == _activeId)
        {
            var p = _phase();
            return (p is "speaking" or "listening" or "transcribing") ? p : "speaking";
        }
        if (e.Queued) return "queued";
        if (e.WaitUntil is { } u && t < u) return "waiting";
        if (e.Parked && e.WakeAt is { } w && t - w < ParkTtl) return "parked";
        if (e.PresenceAt is { } pa)
        {
            if (t - pa >= PresenceTtl) return "stopped";
            return e.PresenceWorking ? "working" : "idle";
        }
        // No presence (e.g. Codex): only the hook's traffic tells. A finished wait counts as
        // hook activity + injection — the hook woke up and fed the resume prompt back.
        var hook = Max(e.HookAt, e.WaitUntil);
        if (t - hook >= HookTtl) return "stopped";
        var injected = Max(e.InjectedAt ?? DateTime.MinValue, e.WaitUntil);
        return t - injected < HookTtl ? "working" : "idle";
    }

    private static DateTime Max(DateTime a, DateTime? b) => b is { } v && v > a ? v : a;

    private static DateTime LastSignal(Entry e) =>
        new[] { e.PresenceAt, e.WakeAt, e.WaitUntil }.Aggregate(e.HookAt, (m, d) => Max(m, d));

    // Re-derive every state (stamping `since` on change) and forget sessions that have been
    // silent for 10 min. Caller holds the lock.
    private void Refresh()
    {
        var t = _now();
        foreach (var e in _entries.Values.ToList())
        {
            var s = StateOf(e, t);
            if (s == "stopped" && e.Id != _activeId && t - LastSignal(e) > KeepStopped)
            {
                _entries.Remove(e.Id);
                continue;
            }
            if (s != e.State) { e.State = s; e.Since = t; }
        }
    }

    private void Update(string id, string label, string project, Action<Entry, DateTime> change)
    {
        if (string.IsNullOrEmpty(id)) return;
        lock (_gate)
        {
            var t = _now();
            if (!_entries.TryGetValue(id, out var e))
            {
                e = new Entry { Id = id, HookAt = t, Since = t };
                _entries[id] = e;
            }
            if (project.Length > 0) e.Project = project;
            if (label.Length > 0) e.Label = label;
            else if (e.Label.Length == 0) e.Label = e.Project;
            change(e, t);
            Refresh();
        }
    }
}
