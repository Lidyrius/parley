using System.Text.Json;
using System.Text.Json.Serialization;

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
        public string BaseLabel = "";     // the label its hook / mod report (.parley.json)
        public string? Name;              // Sir's name for this one session (POST /rename, /dispatch name)
        public string Cwd = "";           // its folder, as last reported (routing, POST /dispatch)
        public DateTime FirstSeen;
        public DateTime? PresenceAt;      // last /presence (null = never sent, e.g. Codex)
        public string PresenceState = "idle";   // the mod's last state: working | background | idle
        public List<BackgroundTask> Tasks = new();   // its in-flight background tasks, as last reported
        public string? Host;              // desktop app session id (local_…): the mod opens it by deep link
        public DateTime HookAt;           // last /turn, /wake or turn reply
        public bool Queued;               // a /turn (or resume dialog) waits at the gate
        public DateTime? WaitUntil;       // "Warte X Minuten": the hook sleeps until then
        public bool AfterWait;            // its turn comes after Sir's "Warte X Minuten": rings at once
        public string? WaitResume;        // what the hook injects when the wait is over (Fortsetzen: now)
        public bool HostWait;             // hookless (docs/HOOKLESS.md): the host's timer delivers WaitResume
        public DateTime? CallbackAt;      // its call was put off: rings again then (MaxValue = Sir calls back)
        public DateTime? ClosedAt;        // POST /close ended it: a dying mod's last presence is ignored
        public bool Parked;               // answered with park; its hook polls /wake
        public DateTime? WakeAt;          // last /wake poll
        public DateTime? InjectedAt;      // a reply was fed back → the agent is working on it
        public DateTime? ExpectWorkUntil; // …shown as working until the mod confirms (max 15 s)
        public List<Handoff> Pending = new();   // deliveries for the mod's /presence, oldest first
        public bool Async;                // its mod carries turns itself (presence `async`)
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

    // One delivery (docs/HOOKLESS.md): handed out on /presence until the mod acks its id; an
    // `async` mod gets it again 10 s after it went out unacked, an older mod exactly once.
    private sealed class Handoff { public string Id = "", Text = ""; public DateTime? SentAt; }
    private static readonly TimeSpan ResendAfter = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan ModLiveTtl = TimeSpan.FromSeconds(5);

    private readonly object _gate = new();
    private readonly Dictionary<string, Entry> _entries = new();
    private string? _activeId;                 // the turn being voiced right now
    private List<RateLimit> _rateLimits = new();   // latest reported by any session
    private readonly Func<DateTime> _now;
    private readonly Func<string> _phase;      // phase of the active turn (LiveStatus)
    private readonly DailyStats _daily;

    // A session's label appeared or changed → pre-render its clips. Set once at startup.
    public Action<string>? OnLabel;

    // Items of a session still waiting at the server's gate (its /turn, resume dialog, permission
    // question): its queued flag follows them, so a finished dialog never hides a queued /turn.
    public Func<string, bool> Waiting = _ => false;

    public SessionRegistry(Func<DateTime>? now = null, Func<string>? phase = null, DailyStats? daily = null)
    {
        _now = now ?? (() => DateTime.UtcNow);
        _phase = phase ?? (() => LiveStatus.Phase());
        _daily = daily ?? DailyStats.Shared;
    }

    // ---- signals ---------------------------------------------------------------------

    // The mod's heartbeat. `ack`: the delivery it fed in last — done. NextDelivery hands out the next.
    public void Presence(string id, string label, string project, string state,
        PresenceUsage? usage = null, List<BackgroundTask>? tasks = null, string? host = null, string? cwd = null,
        bool async = false, string? ack = null)
    {
        lock (_gate)
            if (_entries.TryGetValue(id, out var c) && c.ClosedAt is { } at && _now() - at < PresenceTtl) return;
        DateTime? startedAt = null;
        Update(id, label, project, (e, t) =>
        {
            if (!string.IsNullOrEmpty(cwd)) e.Cwd = cwd;
            e.PresenceAt = t;
            e.PresenceState = state;
            e.Async = async;
            if (!string.IsNullOrEmpty(ack)) e.Pending.RemoveAll(d => d.Id == ack);
            e.Tasks = tasks ?? new List<BackgroundTask>();
            if (!string.IsNullOrEmpty(host)) e.Host = host;
            if (state == "working") e.ExpectWorkUntil = null;
            if (usage is not null)
            {
                if (usage.StartedAt is { } s) e.StartedAt = DateTime.UnixEpoch.AddMilliseconds(s);
                e.ContextPercent = usage.ContextPercent ?? e.ContextPercent;
                e.CostUsd = usage.CostUsd ?? e.CostUsd;
            }
            startedAt = e.StartedAt;
        });
        if (usage?.CostUsd is { } cost && !string.IsNullOrEmpty(id))
            _daily.AddCost(id, cost, startedAt);
        if (usage?.RateLimits is { Count: > 0 } limits)
            lock (_gate) _rateLimits = limits;
    }

    // The delivery for this presence's answer, or null: the oldest open one, unless it went out
    // to an `async` mod less than 10 s ago (it acks it then). An older mod has no ack: once.
    public (string Text, string Id)? NextDelivery(string id, bool async)
    {
        (string, string)? next = null;
        lock (_gate)
        {
            if (!_entries.TryGetValue(id, out var c) || c.Pending.Count == 0
                || c.ClosedAt is { } at && _now() - at < PresenceTtl) return null;
            Update(id, "", "", (e, t) =>
            {
                var d = e.Pending[0];
                if (async && d.SentAt is { } sent && t - sent < ResendAfter) return;
                if (d.SentAt is null) Inject(e, t);
                d.SentAt = t;
                if (!async) e.Pending.RemoveAt(0);
                next = (d.Text, d.Id);
            });
        }
        return next;
    }

    // GET /mod: a mod that carries turns itself, heard from in the last 5 s (stop-hook.sh steps aside).
    public bool ModLive(string id)
    {
        lock (_gate)
            return _entries.TryGetValue(id, out var e) && e.Async
                && e.PresenceAt is { } p && _now() - p < ModLiveTtl && !(e.ClosedAt is { } at && _now() - at < PresenceTtl);
    }

    // The mod's session.end (POST /close {session_id}): what waits for it is gone.
    public void DropDeliveries(string id)
    {
        lock (_gate) if (_entries.TryGetValue(id, out var e)) e.Pending.Clear();
    }

    // A /turn arrived; it waits at the gate until it's this session's turn to speak.
    public void Queued(string id, string label, string project, string? cwd = null) =>
        Update(id, label, project, (e, t) =>
        {
            if (!string.IsNullOrEmpty(cwd)) e.Cwd = cwd;
            e.HookAt = t;
            e.Queued = true;
            e.AfterWait = e.WaitUntil is not null;
            e.WaitUntil = null;
            e.Parked = false;
            e.InjectedAt = null;
            e.ExpectWorkUntil = null;
            e.HostWait = false;
            e.Pending.Clear();   // the session moved on by itself — drop a stale resume
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

    // A permission question for it waits at the gate: shown queued until it is asked. As macOS.
    public void MarkQueued(string id) => Update(id, "", "", (e, _) => e.Queued = true);

    // An item left the gate without being voiced (a permission question nobody waits for any more).
    public void Unqueued(string id)
    {
        lock (_gate)
            if (_entries.ContainsKey(id)) Update(id, "", "", (e, _) => e.Queued = Waiting(id));
    }

    // The session now holds the voice: its turn (`speak` = the line) or its resume dialog (null).
    public void Activate(string id, string? speak)
    {
        lock (_gate)
        {
            _activeId = id;
            Update(id, "", "", (e, t) =>
            {
                e.Queued = Waiting(id);
                if (speak is null) return;
                e.HookAt = t;
                e.Turns++;
                e.LastLine = speak;
            });
        }
    }

    // The turn's reply went back to the hook: wait, park, inject a transcript, or end.
    // `hostWait`: a hookless turn — no hook sleeps through the wait, the server's timer delivers it.
    public void Finished(string id, string transcript, bool park, int waitSeconds, string resume = "", bool hostWait = false)
    {
        lock (_gate)
        {
            if (_activeId == id) _activeId = null;
            Update(id, "", "", (e, t) =>
            {
                e.HookAt = t;
                e.Queued = Waiting(id);
                e.AfterWait = false;
                e.WaitUntil = waitSeconds > 0 ? t.AddSeconds(waitSeconds) : null;
                e.WaitResume = waitSeconds > 0 ? resume : null;
                e.HostWait = waitSeconds > 0 && hostWait;
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
                e.Queued = Waiting(id);
                if (replied) e.Replies++;
            });
        }
    }

    // A resume instruction was handed to the parked hook (its next /wake poll injects it).
    public void WakeQueued(string id) => Update(id, "", "", (e, t) => { e.Parked = false; Inject(e, t); });

    // An instruction for a session, delivered on its next /presence (in turn after any still
    // open). Unknown sessions are ignored.
    public void SetPending(string id, string instruction)
    {
        lock (_gate)
        {
            if (!_entries.ContainsKey(id)) return;
            Update(id, "", "", (e, _) => e.Pending.Add(new Handoff { Id = Guid.NewGuid().ToString("N"), Text = instruction }));
        }
    }

    // A parked hook polled /wake. `resumed` = it was handed an instruction and goes on working.
    public void WakePoll(string id, string label, string project, bool resumed, string? cwd = null) =>
        Update(id, label, project, (e, t) =>
        {
            if (!string.IsNullOrEmpty(cwd)) e.Cwd = cwd;
            e.HookAt = t;
            e.WakeAt = t;
            e.Parked = !resumed;
            if (resumed) { e.Pending.Clear(); Inject(e, t); }   // the hook took it: not the mod too
        });

    // An instruction rode back on this session's presence (pending by folder, POST /dispatch or
    // a routed wake) → it is working on it now.
    public void MarkInjected(string id) => Update(id, "", "", (e, t) => Inject(e, t));

    // A permission question for this session ended: the voice is free again; its state is its own.
    public void Released(string id)
    {
        lock (_gate)
        {
            if (_activeId == id) _activeId = null;
            Refresh();
        }
    }

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

    // Parked or with work in the background, and reachable: a live mod submits the instruction
    // (Claude Code takes a prompt while its background agents run), or its hook polls /wake. As macOS.
    // A timer ("Warte X Minuten") whose hook polls /wake: Fortsetzen ends it early.
    private bool Resumable(Entry e) =>
        (e.State is "parked" or "background" && (e.PresenceAt is not null || HookParked(e)))
        || (e.State == "waiting" && (e.Parked || e.HostWait) && e.WaitResume is not null);

    private bool HookParked(Entry e) => e.Parked && e.WakeAt is { } w && _now() - w < ParkTtl;

    /// Fortsetzen during Sir's timer: the wait is over now — what the session continues with
    /// (null when it isn't waiting). As macOS.
    public string? EndWait(string id)
    {
        lock (_gate)
        {
            Refresh();
            // Only while its hook polls /wake (it picks the text up there) or the host's timer holds
            // the wait (a delivery); an older hook just sleeps.
            if (!_entries.TryGetValue(id, out var e) || e.State != "waiting" || !(e.Parked || e.HostWait) || e.WaitResume is not { } resume) return null;
            e.WaitUntil = null;
            e.WaitResume = null;
            Refresh();
            return "[Parley] Sir hat die Wartezeit mit „Fortsetzen“ vorzeitig beendet.\n\n" + resume;
        }
    }

    // A hookless wait still runs (neither over by Fortsetzen nor by a new turn).
    public bool HostWaiting(string id)
    {
        lock (_gate) return _entries.TryGetValue(id, out var e) && e.HostWait && e.WaitResume is not null;
    }

    // The host's timer ran out: what the session continues with, taken once (null: ended already).
    public string? TakeWaitResume(string id)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(id, out var e) || !e.HostWait || e.WaitResume is not { } resume) return null;
            e.HostWait = false;
            e.WaitResume = null;
            return resume;
        }
    }

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

    // A session an instruction can reach right now (docs/IPHONE.md, v2: wake routing and POST
    // /dispatch): alive, and either parked (its hook polls /wake) or with a live mod (it submits
    // a pending prompt). A hook-only session that is working has no way to take one.
    public sealed record RouteTarget(string Id, string Label, string Cwd);

    private bool Deliverable(Entry e) =>
        e.State != "stopped" && (HookParked(e) || e.PresenceAt is not null);

    public List<RouteTarget> RouteTargets()
    {
        lock (_gate)
        {
            Refresh();
            return _entries.Values.Where(Deliverable)
                .OrderBy(e => e.Label, StringComparer.OrdinalIgnoreCase)
                .Select(e => new RouteTarget(e.Id, e.Label, e.Cwd))
                .ToList();
        }
    }

    // The deliverable session working in `cwd` (Windows paths: case-insensitive), most recently
    // heard from first; null if none.
    // Session `id`: running at all (not stopped), and able to take an instruction now.
    public (bool Alive, bool Deliverable) Running(string id)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.TryGetValue(id, out var e) && e.State != "stopped" ? (true, Deliverable(e)) : (false, false);
        }
    }

    // A session in `cwd` that showed up at or after `since` (a start has arrived).
    public bool SeenSince(string cwd, DateTime since)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.Values.Any(e => CwdPath.Same(e.Cwd, cwd) && e.FirstSeen >= since.AddSeconds(-2));
        }
    }

    public string? DeliverableIn(string cwd)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.Values
                .Where(e => Deliverable(e) && CwdPath.Same(e.Cwd, cwd))
                .OrderByDescending(e => e.PresenceAt ?? e.HookAt)
                .Select(e => e.Id)
                .FirstOrDefault();
        }
    }

    // The session's parked hook is still polling /wake (regardless of a running dialog).
    public bool ParkedHookAlive(string id)
    {
        lock (_gate)
            return _entries.TryGetValue(id, out var e) && HookParked(e);
    }

    // Answered with park (or polling through a wait), however long ago its last /wake was.
    public bool IsParked(string id)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.TryGetValue(id, out var e) && e.Parked;
        }
    }

    // Any session besides `id` that isn't stopped → the turn gets announced.
    /// The phone's tile for this session: Parley rings again at `at`, or (MaxValue) waits for Sir's
    /// call back; null clears it.
    public void SetCallback(string id, DateTime? at)
    {
        lock (_gate) if (_entries.TryGetValue(id, out var e)) e.CallbackAt = at;
    }

    // Sir's own timer ran out ("ruf mich in 2 Minuten zurück"): this session's turn, or one
    // waiting at the gate — it rings at once, no Fragerunde.
    public bool AfterWait(string id)
    {
        lock (_gate) return _entries.TryGetValue(id, out var e) && e.AfterWait;
    }

    public bool TimerQueued()
    {
        lock (_gate) return _entries.Values.Any(e => e.Queued && e.AfterWait);
    }

    // Another session is still at work — an update may follow soon (a Fragerunde waits for it).
    public bool OthersWorking(string id)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.Values.Any(e => e.Id != id && e.State is "working" or "background");
        }
    }

    public bool OthersAlive(string id)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.Values.Any(e => e.Id != id && e.State != "stopped");
        }
    }

    // ---- its own name ----------------------------------------------------------------

    // Kept across restarts: a session keeps its name when Parley updates (null file = none).
    public string? NamesFile;
    private Dictionary<string, string>? _names;
    private Dictionary<string, string> Names => _names ??= LoadNames();

    private Dictionary<string, string> LoadNames()
    {
        try
        {
            return NamesFile is not null && File.Exists(NamesFile)
                ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(NamesFile)) ?? new()
                : new();
        }
        catch { return new(); }
    }

    public string? Name(string id)
    {
        lock (_gate) return _entries.TryGetValue(id, out var e) ? e.Name : null;
    }

    public DateTime? FirstSeen(string id)
    {
        lock (_gate) return _entries.TryGetValue(id, out var e) ? e.FirstSeen : null;
    }

    /// Gives one session its own name (null / blank → back to its project's). Also for a session
    /// not seen yet (a resumed one): it carries the name once it shows up. Returns its label now
    /// (null when it isn't listed yet).
    public string? Rename(string id, string? raw)
    {
        var name = string.IsNullOrWhiteSpace(raw) ? null : raw.Trim();
        if (name is { Length: > 60 }) name = name[..60];
        string? label = null;
        lock (_gate)
        {
            if (name is null) Names.Remove(id); else Names[id] = name;
            try
            {
                if (NamesFile is not null)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(NamesFile)!);
                    File.WriteAllText(NamesFile, JsonSerializer.Serialize(Names));
                }
            }
            catch (Exception e) { Log.Write($"rename: not saved ({e.Message})"); }
            if (!_entries.ContainsKey(id)) return null;
        }
        Update(id, "", "", (e, _) =>
        {
            e.Name = name;
            e.Label = name ?? (e.BaseLabel.Length > 0 ? e.BaseLabel : e.Project);
            label = e.Label;
        });
        return label;
    }

    /// A running session in `cwd` with this name (any case).
    public string? Named(string name, string cwd)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.Values.FirstOrDefault(e => e.State != "stopped" && CwdPath.Same(e.Cwd, cwd)
                && string.Equals(e.Label, name, StringComparison.OrdinalIgnoreCase))?.Id;
        }
    }

    // POST /close: label, folder and state of a known session, or null.
    public (string Label, string Cwd, string State)? Info(string id)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.TryGetValue(id, out var e) ? (e.Label, e.Cwd, e.State) : null;
        }
    }

    // A session's state and since when (Wiedervorlage "after").
    public (string State, DateTime Since)? StateSince(string id)
    {
        lock (_gate)
        {
            Refresh();
            return _entries.TryGetValue(id, out var e) ? (e.State, e.Since) : null;
        }
    }

    // A session by label or folder name (any case): a running one first, else a stopped one.
    public string? Named(string name)
    {
        lock (_gate)
        {
            Refresh();
            bool Same(string a) => string.Equals(a, name, StringComparison.OrdinalIgnoreCase);
            return _entries.Values.Where(e => Same(e.Label) || Same(e.Project))
                .OrderBy(e => e.State == "stopped").ThenBy(e => e.Id, StringComparer.Ordinal).FirstOrDefault()?.Id;
        }
    }

    // The Wiedervorlagen, as /sessions lists them for the phone (the server's store).
    public Func<List<object>>? ReminderRows;
    // The snapshots, likewise.
    public Func<List<object>>? SnapshotRows;

    // The sessions running now (not stopped, with a folder): what a snapshot keeps. As macOS.
    public List<(string Id, string Label, string Cwd)> Live()
    {
        lock (_gate)
        {
            Refresh();
            return _entries.Values.Where(e => e.State != "stopped" && e.Cwd.Length > 0)
                .OrderBy(e => e.Label, StringComparer.CurrentCultureIgnoreCase)
                .Select(e => (e.Id, e.Label, e.Cwd)).ToList();
        }
    }

    // Running sessions whose label or folder name is `name` (any case) — POST /close by project.
    public List<string> RunningNamed(string name)
    {
        lock (_gate)
        {
            Refresh();
            bool Same(string a) => string.Equals(a, name, StringComparison.OrdinalIgnoreCase);
            return _entries.Values.Where(e => e.State != "stopped" && (Same(e.Label) || Same(e.Project)))
                .Select(e => e.Id).OrderBy(i => i, StringComparer.Ordinal).ToList();
        }
    }

    // POST /close ended its process: stopped now (no waiting for the presence to go stale),
    // kept in the list like any stopped session. A presence after PresenceTtl revives it
    // (the kill did not take); earlier ones are the dying mod's last heartbeat.
    public void Closed(string id)
    {
        lock (_gate) if (!_entries.ContainsKey(id)) return;
        Update(id, "", "", (e, t) =>
        {
            e.ClosedAt = t;
            e.PresenceAt = t - PresenceTtl;
            e.HookAt = t - HookTtl;
            e.Queued = false; e.Parked = false; e.WaitUntil = null; e.CallbackAt = null;
            e.Pending.Clear(); e.ExpectWorkUntil = null; e.InjectedAt = null; e.HostWait = false;
        });
    }

    // Label + project of a known session (for the resume dialog), or null.
    public (string label, string project)? Describe(string id)
    {
        lock (_gate)
            return _entries.TryGetValue(id, out var e) ? (e.Label, e.Project) : null;
    }

    // ---- shared sessions (Shares.cs keeps these current) ----------------------------------

    // One guest of a session, as its row shows him.
    public sealed record ShareTag(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("role")] string Role);

    private Dictionary<string, List<ShareTag>> _shared = new();   // by session: who it is shared with
    private readonly Dictionary<string, string> _asking = new();  // by session: a question waits for this guest

    public void SetShared(Dictionary<string, List<ShareTag>> tags)
    {
        lock (_gate) _shared = tags;
    }

    public void SetAsking(string id, string? guest)
    {
        lock (_gate)
        {
            if (guest is null) _asking.Remove(id);
            else _asking[id] = guest;
        }
    }

    // The guest of session `id` called `name` (any case), if it is shared with him.
    public ShareTag? SharedGuest(string id, string name)
    {
        lock (_gate)
            return _shared.TryGetValue(id, out var list)
                ? list.FirstOrDefault(g => string.Equals(g.Name, name, StringComparison.OrdinalIgnoreCase)) : null;
    }

    private sealed record Row(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("label")] string Label,
        [property: JsonPropertyName("project")] string Project,
        [property: JsonPropertyName("state")] string State,
        [property: JsonPropertyName("since")] long Since,
        [property: JsonPropertyName("until")] long? Until,
        [property: JsonPropertyName("callback")] long? Callback,
        [property: JsonPropertyName("voice")] bool Voice,
        [property: JsonPropertyName("resumable")] bool Resumable,
        [property: JsonPropertyName("tasks")] List<BackgroundTask> Tasks,
        [property: JsonPropertyName("host")] string? Host,
        [property: JsonPropertyName("shared"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] List<ShareTag>? Shared,
        [property: JsonPropertyName("asking"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Asking,
        [property: JsonPropertyName("stats")] object Stats);

    // GET /sessions — by status group (needs input, working, halted, stopped), newest change
    // first within a group, then label, then id. As macOS.
    // `only`: a guest's view (Shares.cs) — that one session, nothing else of Sir's.
    public string Json(string? only = null)
    {
        lock (_gate)
        {
            Refresh();
            var active = _activeId;
            int Rank(Entry e) =>
                e.State == "stopped" ? 3
                : e.Id == active || e.CallbackAt is not null
                    || e.State is "speaking" or "listening" or "transcribing" or "queued" ? 0
                : e.State is "working" or "background" ? 1
                : 2;
            var rows = _entries.Values
                .Where(e => only is null || e.Id == only)
                .OrderBy(Rank)
                .ThenByDescending(e => e.Since)
                .ThenBy(e => e.Label, StringComparer.OrdinalIgnoreCase)
                .ThenBy(e => e.Id, StringComparer.Ordinal)
                .Select(e => new Row(
                    e.Id, e.Label, e.Project, e.State, Ms(e.Since),
                    e.State == "waiting" && e.WaitUntil is { } u ? Ms(u) : null,
                    only is null && e.CallbackAt is { } cb ? (cb == DateTime.MaxValue ? 0 : Ms(cb)) : null,   // Sir's put-off call is not the guest's
                    e.Id == active,
                    only is null && Resumable(e),
                    e.Tasks,
                    only is null ? DesktopSessions.Resolve(e.Id, e.Host) : null,
                    _shared.TryGetValue(e.Id, out var tags) && tags.Count > 0 ? tags : null,
                    _asking.TryGetValue(e.Id, out var asking) ? asking : null,
                    new
                    {
                        startedAt = (long?)Ms(e.StartedAt ?? e.FirstSeen),
                        contextPercent = e.ContextPercent,
                        costUsd = e.CostUsd,
                        turns = e.Turns,
                        replies = e.Replies,
                        lastLine = e.LastLine,
                    }))
                .ToList();
            if (only is not null)
                return JsonSerializer.Serialize(new
                {
                    sessions = rows,
                    today = new { costUsd = 0.0, turns = 0, spokenSeconds = 0, rateLimits = new List<RateLimit>() },
                    reminders = new List<object>(),
                    snapshots = new List<object>(),
                });
            var day = _daily.Snapshot();
            var today = new
            {
                costUsd = Math.Round(day.CostUsd, 4),
                turns = day.Turns,
                spokenSeconds = (int)Math.Round(day.SpokenSeconds),
                rateLimits = _rateLimits,
            };
            return JsonSerializer.Serialize(new
            {
                sessions = rows,
                today,
                reminders = ReminderRows?.Invoke() ?? new List<object>(),
                snapshots = SnapshotRows?.Invoke() ?? new List<object>(),
            });
        }
    }

    private static long Ms(DateTime d) => (long)Math.Round((d - DateTime.UnixEpoch).TotalMilliseconds);

    // ---- state derivation ------------------------------------------------------------

    // Precedence high→low: the voiced turn's phase, queued, waiting, parked, working,
    // background, stopped. A finished session is parked — whether its hook polls /wake, its mod
    // waits for a prompt, or (Codex, hook ended) it just waits for Sir. As macOS.
    private string StateOf(Entry e, DateTime t)
    {
        if (e.Id == _activeId)
        {
            var p = _phase();
            return (p is "speaking" or "listening" or "transcribing" or "queued") ? p : "speaking";   // queued: a Fragerunde gathers
        }
        if (e.Queued) return "queued";
        if (e.WaitUntil is { } u && t < u) return "waiting";
        if (e.Parked && e.WakeAt is { } w && t - w < ParkTtl) return "parked";
        if (e.PresenceAt is { } pa)
        {
            if (t - pa >= PresenceTtl) return "stopped";
            // A resume instruction waiting for / just handed to the mod counts as working.
            var landing = e.Pending.Count > 0 || (e.ExpectWorkUntil is { } x && t < x);
            if (e.PresenceState == "working" || landing) return "working";
            return e.PresenceState == "background" ? "background" : "parked";
        }
        // No presence (e.g. Codex): only the hook's traffic tells. A finished wait counts as
        // hook activity + injection — the hook woke up and fed the resume prompt back.
        var hook = Max(e.HookAt, e.WaitUntil);
        if (t - hook >= HookTtl) return "stopped";
        var injected = Max(e.InjectedAt ?? DateTime.MinValue, e.WaitUntil);
        return t - injected < HookTtl ? "working" : "parked";
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
            if (e.WaitUntil is { } u && t >= u) e.Parked = false;   // the wait is over: its hook goes on, not parked
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
                e = new Entry { Id = id, FirstSeen = t, HookAt = t, Since = t, Name = Names.GetValueOrDefault(id) };
                _entries[id] = e;
            }
            var before = e.Label;
            if (project.Length > 0) e.Project = project;
            if (label.Length > 0) e.BaseLabel = label;
            e.Label = e.Name ?? (e.BaseLabel.Length > 0 ? e.BaseLabel : e.Project);
            change(e, t);
            Refresh();
            if (e.Label != before && e.Label.Length > 0) changedLabel = e.Label;
        }
        if (changedLabel is not null) OnLabel?.Invoke(changedLabel);
    }
}

// The Claude desktop app's own record of its Code sessions, one file per session:
// %APPDATA%\Claude\claude-code-sessions\<org>\<user>\local_<id>.json holding `cliSessionId`
// (the id our hooks and the mod know) and `sessionId` (the desktop's local_…). Lets a tile
// deep-link to any desktop session, whatever mod version it runs. 1:1 with macOS.
// ponytail: rescans at most every 10 s; a handful of small files.
public static class DesktopSessions
{
    private static readonly object Gate = new();
    private static DateTime _at = DateTime.MinValue;
    private static Dictionary<string, string> _map = new();

    public static string Root => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude", "claude-code-sessions");

    // The desktop's own record wins. A reported id that it assigns to another session leaked in
    // through an inherited environment and would open the wrong session. 1:1 with macOS.
    public static string? Resolve(string cliId, string? reported, Dictionary<string, string>? map = null)
    {
        if (map is null) { Host(cliId); lock (Gate) map = _map; }
        if (map.TryGetValue(cliId, out var own)) return own;
        if (string.IsNullOrEmpty(reported)) return null;
        foreach (var kv in map) if (kv.Value == reported && kv.Key != cliId) return null;
        return reported;
    }

    public static string? Host(string cliId)
    {
        lock (Gate)
        {
            if ((DateTime.UtcNow - _at).TotalSeconds > 10) { _map = Load(Root); _at = DateTime.UtcNow; }
            return _map.TryGetValue(cliId, out var id) ? id : null;
        }
    }

    public static Dictionary<string, string> Load(string root)
    {
        var map = new Dictionary<string, string>();
        if (!Directory.Exists(root)) return map;
        foreach (var file in Directory.EnumerateFiles(root, "local_*.json", SearchOption.AllDirectories))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(file));
                var r = doc.RootElement;
                if (r.TryGetProperty("cliSessionId", out var cli) && cli.ValueKind == JsonValueKind.String
                    && r.TryGetProperty("sessionId", out var sid) && sid.ValueKind == JsonValueKind.String
                    && sid.GetString() is { } id && id.StartsWith("local_") && cli.GetString() is { } c)
                    map[c] = id;
            }
            catch (Exception) { /* a half-written or foreign file: skip it */ }
        }
        return map;
    }
}
