namespace Parley;

// What the shared sources (windows/*.cs) expect from a desktop, on a host that has none: no
// notification area, no media keys, no microphone or speaker, no pill window. The host is
// always "Unterwegs" (Host.cs), so Parley's voice and ears are the phone's.

public static class Notifier
{
    // A notification is a log line here. An error (its title carries "—": "Parley — Fehler",
    // "Parley — Kosten") has no other way to Sir, so it also goes to the phone when an APNs key
    // is set; the "·" ones (an update, a reminder) already send their own alert where it matters.
    public static void Notify(string title, string body)
    {
        Log.Write($"notify: {title}: {body}");
        if (!title.Contains('—')) return;
        var c = Config.Load();
        if (c.ApnsKeyId.Length > 0 && c.ApnsKeyP8.Length > 0) _ = Apns.SendAlert(title, body, "");
    }
}

public static class MediaControl
{
    public static Task<List<string>> PausePlaying() => Task.FromResult(new List<string>());
    public static Task Resume(List<string> ids) => Task.CompletedTask;
}

// Barge-in at the PC's microphone. Never made here (TurnPipeline only watches when not
// Unterwegs); in a call the phone watches itself.
public sealed class BargeWatch
{
    public BargeWatch(string line) { }
    public CancellationToken Heard => default;
    public bool Barged => false;
    public Task<IReadOnlyList<byte[]>> Stop() => Task.FromResult<IReadOnlyList<byte[]>>(Array.Empty<byte[]>());
}

// The recording pill: TurnPipeline takes one — null here; only its shape is needed.
public sealed class PillOverlay
{
    public void BeginInvoke(Action action) { }
    public void Push(float level) { }
    public void ShowPill() { }
    public void HidePill() { }
}
