using System.Text.Json;

namespace Parley;

// Which Parley sessions exist and what each one is doing — for GET /sessions (the Claude
// Code mod's overview), POST /resume and the "Update zu <Name>" announcement. 1:1 with the
// macOS SessionRegistry. Three signals feed it: /presence heartbeats from the mod (~2 s,
// Claude Code only), the Stop hook's /turn + /wake traffic, and the reply handed back for
// each turn. The state itself is derived from timestamps on every read, so a session that
// goes silent ages into `stopped` on its own — there is no clean "session ended" signal.
// Requests run concurrently → every entry point takes the lock.
public sealed class SessionRegistry
{
    private sealed class Entry
    {
        public string Id = "", Label = "", Project = "";   // session_id, spoken label, cwd basename
        public DateTime FirstSeen;
        public DateTime? PresenceAt;      // last /presence (null = never sent, e.g. Codex)
        public string PresenceState = "idle";   // the mod's last state: working | background | idle
        public List<BackgroundTask> Tasks = new();   // its in-flight background tasks, as last reported
        public DateTime HookAt;           // last /turn, /wake or turn reply
        public bool Queued;               // a /turn (or resume dialog) waits at the gate
        public DateTime? WaitUntil;       // "Warte X Minuten": the hook sleeps until then
        public bool Parked;               // answered with park; its hook polls /wake
        public DateTime? WakeAt;          // last /wake poll
        public DateTime? InjectedAt;      // a reply was fed back → the agent is working on it
        public DateTime? ExpectWorkUntil; // …shown as working until the mod confirms (max 15 s)
        public string? Pending;           // resume instruction for the mod's next /presence
        public DateTime? StartedAt;       // from the mod's usage
        public double? ContextPercent;
        public double? CostUsd;           // cumulative, as last reported
        public int Turns;                 // voiced turns since the app saw the session
        public int Replies;               // transcripts injected back
        public string? LastLine;          // last <speak> line voiced for it
        public string State = "";
        public DateTime Since;
    }

    // Windows from the contract: presence goes stale after 20 s, a parked hook after 30 s
    // without a /wake poll, a hook-only session (no presence) after 5 min.
    private static readonly TimeSpan PresenceTtl = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan ParkTtl = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan HookTtl = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan KeepStopped = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan LandingTtl = TimeSpan.FromSeconds(15);

    private readonly object _gate = new();
    private readonly Dictionary<string, Entry> _entries = new();
    private string? _activeId;                 // the turn being voiced right now
    private List<RateLimit> _rateLimits = new();   // latest reported by any session
    private readonly Func<DateTime> _now;
    private readonly Func<string> _phase;      // phase of the active turn (LiveStatus)
    private readonly DailyStats _daily;

    // A session's label appeared or changed → pre-render its clips. Set once at startup.
    public Action<string>? OnLabel;

    public SessionRegistry(Func<DateTime>? now = null, Func<string>? phase = null, DailyStats? daily = null)
    {
        _now = now ?? (() => DateTime.UtcNow);
        _phase = phase ?? (() => LiveStatus.Phase());
        _daily = daily ?? DailyStats.Shared;
    }

    // ---- signals ---------------------------------------------------------------------

    // The mod's heartbeat. Returns a pending resume instruction — exactly once — for the mod
    // to submit as a prompt in its session.
    public string? Presence(string id, string label, string project, string state,
        PresenceUsage? usage = null, List<BackgroundTask>? tasks = null)
    {
        string? delivered = null;
        DateTime? startedAt = null;
        Update(id, label, project, (e, t) =>
        {
            e.PresenceAt = t;
            e.PresenceState = state;
            e.Tasks = tasks ?? new List<BackgroundTask>();
            if (state == "working") e.ExpectWorkUntil = null;
            if (usage is not null)
            {
                if (usage.StartedAt is { } s) e.StartedAt = DateTime.UnixEpoch.AddMilliseconds(s);
                e.ContextPercent = usage.ContextPercent ?? e.ContextPercent;
                e.CostUsd = usage.CostUsd ?? e.CostUsd;
            }
            if (e.Pending is { } p) { delivered = p; e.Pending = null; Inject(e, t); }
            startedAt = e.StartedAt;
        });
        if (usage?.CostUsd is { } cost && !string.IsNullOrEmpty(id))
            _daily.AddCost(id, cost, startedAt);
        if (usage?.RateLimits is { Count: > 0 } limits)
            lock (_gate) _rateLimits = limits;
        return delivered;
    }

    // A /turn arrived; it waits at the gate until it's this session's turn to speak.
    public void Queued(string id, string label, string project) =>
        Update(id, label, project, (e, t) =>
        {
            e.HookAt = t;
            e.Queued = true;
            e.WaitUntil = null;
            e.Parked = false;
            e.InjectedAt = null;
            e.ExpectWorkUntil = null;
            e.Pending = null;   // the session moved on by itself — drop a stale resume
        });

    // POST /resume: if the session is resumable, mark its dialog queued (its other state is
    // kept) and return true — atomically, so a double click can't start two dialogs.
    public bool TryQueueResume(string id)
    {
        lock (_gate)
        {
            Refresh();
            if (!_entries.TryGetValue(id, out var e) || !Resumable(e)) return false;
            Update(id, "", "", (x, _) => x.Queued = true);
            return true;
        }
    }

    // The session now holds the voice: its turn (`speak` = the line) or its resume dialog (null).
    public void Activate(string id, string? speak)
    {
        lock (_gate)
        {
            _activeId = id;
            Update(id, "", "", (e, t) =>
            {
                e.Queued = false;
                if (speak is null) return;
                e.HookAt = t;
                e.Turns++;
                e.LastLine = speak;
            });
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
                e.InjectedAt = null;
                e.ExpectWorkUntil = null;
                if (transcript.Length > 0) { e.Replies++; Inject(e, t); }
            });
        }
    }

    // The resume dialog ended; the server hands its instruction over next.
    public void ResumeFinished(string id, bool replied)
    {
        lock (_gate)
        {
            if (_activeId == id) _activeId = null;
            Update(id, "", "", (e, _) =>
            {
                e.Queued = false;
                if (replied) e.Replies++;
            });
        }
    }

    // A resume instruction was handed to the parked hook (its next /wake poll injects it).
    public void WakeQueued(string id) => Update(id, "", "", (e, t) => { e.Parked = false; Inject(e, t); });

    // A resume instruction for an idle session, delivered on its next /presence. Unknown
    // sessions are ignored.
    public void SetPending(string id, string instruction)
    {
        lock (_gate)
        {
            if (!_entries.ContainsKey(id)) return;
            Update(id, "", "", (e, _) => e.Pending = instruction);
        }
    }

    // A parked hook polled /wake. `resumed` = it was handed an instruction and goes on working.
    public void WakePoll(string id, string label, string project, bool resumed) =>
        Update(id, label, project, (e, t) =>
        {
            e.HookAt = t;
            e.WakeAt = t;
            e.Parked = !resumed;
            if (resumed) Inject(e, t);
        });

    private static void Inject(Entry e, DateTime t)
    {
        e.InjectedAt = t;
        e.ExpectWorkUntil = t + LandingTtl;
    }

    // ---- queries ---------------------------------------------------------------------

    // Parked, or idle with a live mod (it can submit the instruction). A Codex session
    // (no presence) is only resumable while parked; a `background` one wakes on its own.
    public bool CanResume(string id)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.TryGetValue(id, out var e) && Resumable(e);
        }
    }

    private static bool Resumable(Entry e) =>
        e.State == "parked" || (e.State == "idle" && e.PresenceAt is not null);

    // Resumable sessions for the tray and the voice resume command.
    public List<Server.ParkedInfo> ResumableList()
    {
        lock (_gate)
        {
            Refresh();
            return _entries.Values.Where(Resumable)
                .Select(e => new Server.ParkedInfo(e.Id, e.Label, e.Project))
                .OrderBy(p => p.Label, StringComparer.Ordinal).ToList();
        }
    }

    // The session's parked hook is still polling /wake (regardless of a running dialog).
    public bool ParkedHookAlive(string id)
    {
        lock (_gate)
            return _entries.TryGetValue(id, out var e) && e.Parked && e.WakeAt is { } w && _now() - w < ParkTtl;
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

    // Label + project of a known session (for the resume dialog), or null.
    public (string label, string project)? Describe(string id)
    {
        lock (_gate)
            return _entries.TryGetValue(id, out var e) ? (e.Label, e.Project) : null;
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
                    resumable = Resumable(e),
                    tasks = e.Tasks,
                    stats = new
                    {
                        startedAt = (long?)Ms(e.StartedAt ?? e.FirstSeen),
                        contextPercent = e.ContextPercent,
                        costUsd = e.CostUsd,
                        turns = e.Turns,
                        replies = e.Replies,
                        lastLine = e.LastLine,
                    },
                })
                .ToList();
            var day = _daily.Snapshot();
            var today = new
            {
                costUsd = Math.Round(day.CostUsd, 4),
                turns = day.Turns,
                spokenSeconds = (int)Math.Round(day.SpokenSeconds),
                rateLimits = _rateLimits,
            };
            return JsonSerializer.Serialize(new { sessions = rows, today });
        }
    }

    private static long Ms(DateTime d) => (long)Math.Round((d - DateTime.UnixEpoch).TotalMilliseconds);

    // ---- state derivation ------------------------------------------------------------

    // Precedence high→low: the voiced turn's phase, queued, waiting, parked, working,
    // background, idle, stopped.
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
            // A resume instruction waiting for / just handed to the mod counts as working.
            var landing = e.Pending is not null || (e.ExpectWorkUntil is { } x && t < x);
            if (e.PresenceState == "working" || landing) return "working";
            return e.PresenceState == "background" ? "background" : "idle";
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
        string? changedLabel = null;
        lock (_gate)
        {
            var t = _now();
            if (!_entries.TryGetValue(id, out var e))
            {
                e = new Entry { Id = id, FirstSeen = t, HookAt = t, Since = t };
                _entries[id] = e;
            }
            var before = e.Label;
            if (project.Length > 0) e.Project = project;
            if (label.Length > 0) e.Label = label;
            else if (e.Label.Length == 0) e.Label = e.Project;
            change(e, t);
            Refresh();
            if (e.Label != before && e.Label.Length > 0) changedLabel = e.Label;
        }
        if (changedLabel is not null) OnLabel?.Invoke(changedLabel);
    }
}
