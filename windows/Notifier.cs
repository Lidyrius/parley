namespace Parley;

// System notifications — Windows counterpart of the macOS Notifier. Uses the tray icon's
// balloon/toast (NotifyIcon.ShowBalloonTip), which shows a real Windows 10/11 toast with
// no package identity or extra dependency. Marshals onto the UI thread.
public static class Notifier
{
    private static NotifyIcon? _tray;

    public static void Init(NotifyIcon tray) => _tray = tray;

    // Example notification in the given mode (onboarding/settings preview), regardless of config.
    public static void Preview(string mode)
    {
        switch (mode)
        {
            case "pill": NotificationPill.Present("Parley", "So sieht die Pill aus, Sir."); break;
            case "system":
                try { _tray?.ShowBalloonTip(4000, "Parley", "So sieht die Mitteilung aus, Sir.", ToolTipIcon.Info); } catch { }
                break;
        }
    }

    public static void Notify(string title, string body)
    {
        switch (Config.Load().NotifyMode)
        {
            case "none": return;
            case "system": break;
            default: NotificationPill.Present(title, body); return;
        }
        var tray = _tray;
        if (tray is null) return;
        void Show()
        {
            try { tray.ShowBalloonTip(4000, title, body, ToolTipIcon.Info); }
            catch { /* notifications must never crash the app */ }
        }
        if (tray.ContextMenuStrip?.InvokeRequired == true)
            tray.ContextMenuStrip.BeginInvoke(Show);
        else
            Show();
    }
}
