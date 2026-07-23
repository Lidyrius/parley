using Windows.Media.Control;

namespace Parley;

// Media pause/resume via the PUBLIC WinRT Global System Media Transport Controls API —
// what took private-framework acrobatics on macOS is a first-class citizen here. We read
// each session's real playback status, pause exactly the ones that are PLAYING, and
// resume exactly those afterwards. Calls (Meet/Teams) don't register media sessions.
public static class MediaControl
{
    /// Pause every session that is actually playing; returns their AppUserModelIds.
    public static async Task<List<string>> PausePlaying()
    {
        var paused = new List<string>();
        try
        {
            var mgr = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            foreach (var session in mgr.GetSessions())
            {
                try
                {
                    if (session.GetPlaybackInfo().PlaybackStatus ==
                        GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
                    {
                        await session.TryPauseAsync();
                        paused.Add(session.SourceAppUserModelId);
                    }
                }
                catch { /* per-session failures are fine */ }
            }
        }
        catch (Exception e) { Log.Write($"media pause error: {e.Message}"); }
        return paused;
    }

    /// Resume exactly the sessions PausePlaying() paused (matched by AppUserModelId).
    public static async Task Resume(List<string> ids)
    {
        if (ids.Count == 0) return;
        try
        {
            var mgr = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            foreach (var session in mgr.GetSessions())
            {
                try
                {
                    if (ids.Contains(session.SourceAppUserModelId) &&
                        session.GetPlaybackInfo().PlaybackStatus ==
                        GlobalSystemMediaTransportControlsSessionPlaybackStatus.Paused)
                        await session.TryPlayAsync();
                }
                catch { }
            }
        }
        catch (Exception e) { Log.Write($"media resume error: {e.Message}"); }
    }
}
