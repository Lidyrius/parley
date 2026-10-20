using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parley;

// Wire payloads from the Claude Code plugin hooks — identical to the macOS contract.
// A predicted answer to a listen turn: `on` describes it, `say` is spoken the moment the
// user's reply matches it (pre-rendered — no latency); `listen` = `say` asks back, so the
// mic opens again and both answers go to the session.
public sealed class Reply
{
    [JsonPropertyName("on")] public string On { get; set; } = "";
    [JsonPropertyName("say")] public string Say { get; set; } = "";
    [JsonPropertyName("listen")] public bool? Listen { get; set; }
}

public sealed class TurnPayload
{
    [JsonPropertyName("event")] public string Event { get; set; } = "";
    [JsonPropertyName("session_id")] public string SessionId { get; set; } = "";
    [JsonPropertyName("cwd")] public string Cwd { get; set; } = "";
    [JsonPropertyName("project")] public string Project { get; set; } = "";
    [JsonPropertyName("tmux_pane")] public string TmuxPane { get; set; } = "";
    [JsonPropertyName("speak")] public string Speak { get; set; } = "";
    [JsonPropertyName("label")] public string? Label { get; set; }
    [JsonPropertyName("listen")] public bool? Listen { get; set; }
    // Predicted answers (<reply on="…">), each with its spoken reaction.
    [JsonPropertyName("replies")] public List<Reply>? Replies { get; set; }
    // <slide …/> markers for a phone call (docs/CALL-SLIDES.md).
    [JsonPropertyName("slides")] public List<SlideSpec>? Slides { get; set; }
    // v7: <speak to="Max"> — a guest of the shared session is asked (Shares.cs).
    [JsonPropertyName("to")] public string? To { get; set; }
    // Hookless (docs/HOOKLESS.md): the mod carries the turn — queued, its reply delivered later.
    [JsonPropertyName("async"), JsonConverter(typeof(LooseBool))] public bool Async { get; set; }
    [JsonPropertyName("turn_id")] public string? TurnId { get; set; }

    [JsonIgnore] public bool WantsListen => Listen ?? true;
    [JsonIgnore] public string SpokenLabel => string.IsNullOrEmpty(Label) ? Project : Label!;
    // Host-side only: a permission question past this has no one waiting for its answer.
    [JsonIgnore] public DateTime? Deadline { get; set; }

    public static TurnPayload? Decode(string body)
    {
        try { return JsonSerializer.Deserialize<TurnPayload>(body); }
        catch { return null; }
    }

    // A shallow copy (a guest's question handed on to Sir gets its own `speak` / `to`).
    public TurnPayload Copy() => (TurnPayload)MemberwiseClone();
}

// POST /presence — the Claude Code mod's heartbeat (~2 s per session).
// state: working | background (turn over, its background tasks still run) | idle.
public sealed class PresencePayload
{
    [JsonPropertyName("session_id")] public string SessionId { get; set; } = "";
    [JsonPropertyName("label")] public string? Label { get; set; }
    [JsonPropertyName("project")] public string? Project { get; set; }
    [JsonPropertyName("cwd")] public string? Cwd { get; set; }
    [JsonPropertyName("state")] public string? State { get; set; }
    [JsonPropertyName("usage")] public PresenceUsage? Usage { get; set; }
    // In-flight background tasks (subagents, shell jobs, monitors).
    [JsonPropertyName("tasks")] public List<BackgroundTask>? Tasks { get; set; }
    // The desktop app's id for the session (local_…), for claude:// deep links.
    [JsonPropertyName("host")] public string? Host { get; set; }
    // Hookless (docs/HOOKLESS.md): this mod carries turns itself; the turn it waits for; the
    // delivery it fed in last.
    [JsonPropertyName("async"), JsonConverter(typeof(LooseBool))] public bool Async { get; set; }
    [JsonPropertyName("awaiting")] public string? Awaiting { get; set; }
    [JsonPropertyName("ack")] public string? Ack { get; set; }

    public static PresencePayload? Decode(string body)
    {
        try { return JsonSerializer.Deserialize<PresencePayload>(body); }
        catch { return null; }
    }
}

// What the mod knows about its Claude Code session (all optional). startedAt = epoch ms.
public sealed class PresenceUsage
{
    [JsonPropertyName("startedAt")] public double? StartedAt { get; set; }
    [JsonPropertyName("contextPercent")] public double? ContextPercent { get; set; }
    [JsonPropertyName("contextTokens")] public double? ContextTokens { get; set; }
    [JsonPropertyName("contextWindow")] public double? ContextWindow { get; set; }
    [JsonPropertyName("costUsd")] public double? CostUsd { get; set; }   // cumulative for the session
    [JsonPropertyName("rateLimits")] public List<RateLimit>? RateLimits { get; set; }
}

// One background task as the mod reports it; echoed in GET /sessions rows.
public sealed class BackgroundTask
{
    [JsonPropertyName("type")] public string? Type { get; set; }   // "subagent", …
    [JsonPropertyName("description")] public string? Description { get; set; }
}

// One plan limit as the mod reports it; re-emitted as-is in GET /sessions → today.
public sealed class RateLimit
{
    [JsonPropertyName("kind")] public string? Kind { get; set; }             // "five_hour", …
    [JsonPropertyName("percentUsed")] public double? PercentUsed { get; set; }
    [JsonPropertyName("resetsAt")] public string? ResetsAt { get; set; }     // ISO 8601
}

// POST /permission — the plugin's PermissionRequest hook, long-polling ≤ 120 s
// (docs/IPHONE.md, v2). tool_input is the tool's own arguments object.
public sealed class PermissionPayload
{
    [JsonPropertyName("session_id")] public string? SessionId { get; set; }
    [JsonPropertyName("cwd")] public string? Cwd { get; set; }
    [JsonPropertyName("tool_name")] public string? ToolName { get; set; }
    [JsonPropertyName("tool_input")] public JsonElement? ToolInput { get; set; }

    public static PermissionPayload? Decode(string body)
    {
        try { return JsonSerializer.Deserialize<PermissionPayload>(body); }
        catch { return null; }
    }
}

// POST /dispatch — the Zentrale starts / instructs a session in a folder (docs/IPHONE.md, v2).
// start defaults to true.
public sealed class DispatchPayload
{
    [JsonPropertyName("cwd")] public string? Cwd { get; set; }
    [JsonPropertyName("instruction")] public string? Instruction { get; set; }
    [JsonPropertyName("start")] public bool? Start { get; set; }
    // A past session's id: started as `claude --resume <id>` (cwd then defaults to its folder).
    [JsonPropertyName("resume")] public string? Resume { get; set; }
    // That one session's own name ("Literally Apps SEO"); without `resume` a new session beside
    // one already running in the folder.
    [JsonPropertyName("name")] public string? Name { get; set; }

    public static DispatchPayload? Decode(string body)
    {
        try { return JsonSerializer.Deserialize<DispatchPayload>(body); }
        catch { return null; }
    }
}

// POST /resume — resume a parked / idle session by its session_id (as listed by GET /sessions).
public sealed class ResumePayload
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";

    public static ResumePayload? Decode(string body)
    {
        try { return JsonSerializer.Deserialize<ResumePayload>(body); }
        catch { return null; }
    }
}

// `async` comes as 1 (presence) or true (turn): either, or a string, counts — a mod's other
// spelling must not cost the whole payload.
public sealed class LooseBool : JsonConverter<bool>
{
    public override bool Read(ref Utf8JsonReader r, Type type, JsonSerializerOptions options)
    {
        switch (r.TokenType)
        {
            case JsonTokenType.True: return true;
            case JsonTokenType.Number: return r.TryGetDouble(out var d) && d != 0;
            case JsonTokenType.String: return r.GetString() is "1" or "true";
            default: r.Skip(); return false;
        }
    }

    public override void Write(Utf8JsonWriter w, bool value, JsonSerializerOptions options) => w.WriteBooleanValue(value);
}
