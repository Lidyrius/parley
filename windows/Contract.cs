using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parley;

// Wire payloads from the Claude Code plugin hooks — identical to the macOS contract.
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

    [JsonIgnore] public bool WantsListen => Listen ?? true;
    [JsonIgnore] public string SpokenLabel => string.IsNullOrEmpty(Label) ? Project : Label!;
    // Host-side only: a permission question past this has no one waiting for its answer.
    [JsonIgnore] public DateTime? Deadline { get; set; }

    public static TurnPayload? Decode(string body)
    {
        try { return JsonSerializer.Deserialize<TurnPayload>(body); }
        catch { return null; }
    }
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
