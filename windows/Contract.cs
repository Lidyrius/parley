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

    public static TurnPayload? Decode(string body)
    {
        try { return JsonSerializer.Deserialize<TurnPayload>(body); }
        catch { return null; }
    }
}

// POST /presence — the Claude Code mod's heartbeat (~5 s per session). state: working|idle.
public sealed class PresencePayload
{
    [JsonPropertyName("session_id")] public string SessionId { get; set; } = "";
    [JsonPropertyName("label")] public string? Label { get; set; }
    [JsonPropertyName("project")] public string? Project { get; set; }
    [JsonPropertyName("cwd")] public string? Cwd { get; set; }
    [JsonPropertyName("state")] public string? State { get; set; }

    public static PresencePayload? Decode(string body)
    {
        try { return JsonSerializer.Deserialize<PresencePayload>(body); }
        catch { return null; }
    }
}

// POST /resume — wake a parked session by its session_id (as listed by GET /sessions).
public sealed class ResumePayload
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";

    public static ResumePayload? Decode(string body)
    {
        try { return JsonSerializer.Deserialize<ResumePayload>(body); }
        catch { return null; }
    }
}
