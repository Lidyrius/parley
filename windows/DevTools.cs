using System.Diagnostics;

namespace Parley;

// Developer tools (tray "Entwickler" submenu) — Windows counterpart. Statistics
// (stats.json) are NEVER touched by any of these.
public static class DevTools
{
    // Fresh-install simulation: wipe credentials, cached clips and the onboarded flag so
    // onboarding runs again — but KEEP stats.json (and the log). Then reopen onboarding.
    public static void ResetKeepingStats()
    {
        try { File.Delete(Config.CredentialsPath); } catch { }
        try { Directory.Delete(Path.Combine(Config.Dir, "clips"), true); } catch { }
        Log.Write("devtools: reset (kept stats), reopening onboarding");
        new OnboardingForm().Show();
    }

    public static void ShowOnboarding() => new OnboardingForm().Show();

    public static void TestNotification() =>
        Notifier.Notify("Parley · Test", "So sieht eine Benachrichtigung aus, Sir.");

    public static void RerenderClips()
    {
        try { Directory.Delete(Path.Combine(Config.Dir, "clips"), true); } catch { }
        Log.Write("devtools: cleared cached clips");
    }

    public static void RevealLog()
    {
        var log = Path.Combine(Config.Dir, "debug.log");
        try { Process.Start("explorer.exe", $"/select,\"{log}\""); } catch { }
    }
}
