using System.Globalization;
using System.Runtime.Versioning;
using System.Text.Json;

[assembly: SupportedOSPlatform("linux")]

namespace Parley;

// parley — the headless Linux host (pilot).
//   run                   the daemon, in the foreground, its log on stdout (also debug.log)
//   pair                  make the relay room if there is none, print the parley://pair?… link
//   status                is the daemon up, its sessions, the Überwachungsmodus
//   selftest              the Unix-specific parts (paths, app-data folder, file modes) — exit 1 on a failure
//   sim-phone <link> …    a stand-in phone on the relay (SimPhone.cs)
internal static class Program
{
    private const UnixFileMode OwnerDir = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;
    private const UnixFileMode OwnerFile = UnixFileMode.UserRead | UnixFileMode.UserWrite;

    private static async Task<int> Main(string[] args)
    {
        // Started from inside a Claude Code session, Parley would inherit its CLAUDE_CODE_*
        // variables and pass them on to every session it starts. As the Windows Main.
        foreach (var key in Environment.GetEnvironmentVariables().Keys.Cast<object>().Select(k => k.ToString() ?? ""))
            if (key.StartsWith("CLAUDE_CODE_", StringComparison.OrdinalIgnoreCase)) Environment.SetEnvironmentVariable(key, null);

        var verb = args.FirstOrDefault() ?? "";
        if (verb == "selftest") return SelfTest();   // in a folder of its own, never the real one
        if (verb is "run" or "pair" or "status" or "sim-phone") OwnFolder();
        switch (verb)
        {
            case "run": return Host.Run();
            case "pair": return Pair();
            case "status": return await Status();
            case "sim-phone": return await SimPhone.Run(args[1..]);
            default:
                Console.Error.WriteLine("usage: parley run | pair | status | selftest | sim-phone <parley://pair?…> [--seconds N] [--say <session id or name> <text>] [--answer]");
                return 2;
        }
    }

    // The app-data folder ($XDG_CONFIG_HOME or ~/.config, then /Parley) is the user's alone:
    // credentials.json holds the API keys, the relay's key and the APNs key.
    private static void OwnFolder()
    {
        Directory.CreateDirectory(Config.Dir, OwnerDir);
        File.SetUnixFileMode(Config.Dir, OwnerDir);
        if (File.Exists(Config.CredentialsPath)) File.SetUnixFileMode(Config.CredentialsPath, OwnerFile);
    }

    // The relay: credentials.json "relayUrl", else PARLEY_RELAY_URL (kept), else the public one.
    private static int Pair()
    {
        if (Environment.GetEnvironmentVariable("PARLEY_RELAY_URL") is { Length: > 0 } url)
            Config.Merge(new Dictionary<string, string> { ["relayUrl"] = RelayLink.Normalize(url) });
        if (RelayConfig.Pair() is not { } c)
        {
            Console.Error.WriteLine("pair: the relay address must be http(s) — and credentials.json writable");
            return 1;
        }
        Console.WriteLine(RelayLink.Pairing(c));
        Console.Error.WriteLine($"Relay {c.Url}. Paste the link above into the phone app (\"QR-Code scannen\" → link), or open this page for the QR code:");
        Console.Error.WriteLine(RelayLink.PairPage(c));
        Console.Error.WriteLine("The link is the key to this host's sessions — treat it like a password. A running `parley run` connects within seconds.");
        return 0;
    }

    private static async Task<int> Status()
    {
        using var http = new HttpClient { BaseAddress = new Uri("http://127.0.0.1:8787"), Timeout = TimeSpan.FromSeconds(3) };
        string sessions, supervisor, starting;
        try
        {
            sessions = await http.GetStringAsync("/sessions");
            supervisor = await http.GetStringAsync("/supervisor");
            starting = await http.GetStringAsync("/starting");
        }
        catch (Exception e)
        {
            Console.WriteLine($"parley: not running on 127.0.0.1:8787 ({e.Message})");
            return 1;
        }
        var relay = RelayConfig.Load();
        Console.WriteLine($"parley: running · app data {Config.Dir} · relay {(relay.IsComplete ? "paired with " + relay.Url : "not paired (parley pair)")}");
        using var doc = JsonDocument.Parse(sessions);
        var rows = doc.RootElement.TryGetProperty("sessions", out var list) ? list.EnumerateArray().ToList() : new List<JsonElement>();
        Console.WriteLine($"sessions: {rows.Count}");
        foreach (var s in rows)
            Console.WriteLine($"  {s.GetProperty("state").GetString(),-10} {s.GetProperty("label").GetString(),-24} {s.GetProperty("id").GetString()}");
        Console.WriteLine($"supervisor: {supervisor}");
        Console.WriteLine($"starting: {starting}");
        return 0;
    }

    // One self-check for what differs from Windows: folders as Unix spells them, the app-data
    // folder, who may read the secrets, German dates (ICU), and that nothing here reaches for a
    // sound device. In a temporary XDG_CONFIG_HOME — the real app data is not touched.
    private static int SelfTest()
    {
        var failed = 0;
        void Check(string what, object? got, object? want)
        {
            var ok = Equals(got, want);
            if (!ok) failed++;
            Console.WriteLine($"{(ok ? "ok  " : "FAIL")} {what}{(ok ? "" : $": got {got ?? "null"}, want {want ?? "null"}")}");
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var tmp = Directory.CreateTempSubdirectory("parley-selftest-").FullName;
        Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", null);
        Check("app data: ~/.config/Parley", Config.Dir, home + "/.config/Parley");
        Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", tmp);   // from here on nothing touches the real one
        Check("app data: $XDG_CONFIG_HOME/Parley", Config.Dir, tmp + "/Parley");
        Check("path: trailing slash", CwdPath.Normalize("/srv/work/shirts/"), "/srv/work/shirts");
        Check("path: .. resolved", CwdPath.Normalize("/srv/work/x/../shirts"), "/srv/work/shirts");
        Check("path: ~ expanded", CwdPath.Normalize("~/work"), home + "/work");
        Check("path: /c/… is no drive", CwdPath.Normalize("/c/Users/sir"), "/c/Users/sir");
        Check("path: a backslash is a character", CwdPath.Normalize("/srv/a\\b"), "/srv/a\\b");
        Check("path: the root stays", CwdPath.Normalize("/"), "/");
        Check("path: same folder", CwdPath.Same("/srv/work/shirts/", "/srv/work/shirts"), true);
        Check("path: case matters", CwdPath.Same("/srv/work/Shirts", "/srv/work/shirts"), false);
        Check("path: a bare name lives under projectsDir", CwdPath.Resolve("shirts", "/srv/work/"), "/srv/work/shirts");
        Check("path: absolute as is", CwdPath.Resolve("/srv/else/x", "/srv/work"), "/srv/else/x");
        var pending = new PendingByCwd();
        pending.Add("/srv/work/Shirts", "x");
        Check("pending: another folder's spelling takes nothing", pending.Take("/srv/work/shirts"), null);
        Check("pending: its own folder takes it", pending.Take("/srv/work/Shirts/"), "x");
        using (var input = JsonDocument.Parse("{\"file_path\":\"/srv/work/shirts/src/app.ts\"}"))
            Check("permission: the file's name, not its path", Permission.Describe("Write", input.RootElement), "die Datei app.ts schreiben");
        Check("start check: a default-No question", Delivery.DefaultNo("Add '/srv/x' to Gas Town? [y/N/never]\n\n") is not null, true);
        Check("start check: anything else", Delivery.DefaultNo("Welcome to Claude Code\n> "), null);
        var rcIdle = RemoteControl.Parse("{\"pid\":7,\"sessionId\":\"a\",\"status\":\"idle\"}");
        Check("remote control: state file", rcIdle, new RemoteControl.State(7, "a", "idle", false));
        Check("remote control: bridge = connected", RemoteControl.Parse("{\"pid\":7,\"sessionId\":\"a\",\"status\":\"busy\",\"bridgeSessionId\":\"s\"}")?.Connected, true);
        Check("remote control: idle + parked → type", RemoteControl.Decide(rcIdle, "parked"), RemoteControl.Step.Type);
        Check("remote control: a voiced turn → later", RemoteControl.Decide(rcIdle, "listening"), RemoteControl.Step.Later);
        Check("remote control: busy → later", RemoteControl.Decide(rcIdle! with { Status = "busy" }, "parked"), RemoteControl.Step.Later);
        Check("remote control: only the chosen Enable", RemoteControl.EnableSelected("  1. Enable Remote Control\n❯ 2. Never mind"), false);
        Check("remote control: the flag last", string.Join(' ', SessionStarter.ClaudeArgs(null, true)), "claude /parley:voice --remote-control");

        try
        {
            OwnFolder();
            Check("app data: created 0700", File.GetUnixFileMode(Config.Dir), OwnerDir);
            Check("credentials.json: written", Config.Merge(new Dictionary<string, string> { ["language"] = "Deutsch" }), true);
            Check("credentials.json: 0600", File.GetUnixFileMode(Config.CredentialsPath), OwnerFile);
            Check("credentials.json: read back", Config.Load().Language, "Deutsch");
            Shares.Save(new List<Share>(), Shares.File);
            Check("shares.json: 0600", File.GetUnixFileMode(Shares.File), OwnerFile);

            Check("dates: German (ICU)", new DateTime(2026, 10, 19).ToString("dddd", new CultureInfo("de-DE")), "Montag");
            var reminder = ReminderStore.Instruction(new Reminder { Text = "Tests", Created = DateTime.UtcNow });
            Check("reminder: spoken in German", reminder.StartsWith("Wiedervorlage von Sir (gesprochen ", StringComparison.Ordinal), true);

            // Always Unterwegs: playing and recording return at once, without a device.
            PhoneCall.SetLockedAway(true);
            Check("audio: nothing played here", AudioOut.PlayPcm(AudioOut.Beep()).GetAwaiter().GetResult(), false);
            Check("audio: nothing recorded here", new MicCapture().Record().GetAwaiter().GetResult().Length, 0);
            AudioOut.WaitForHiFiOutput().GetAwaiter().GetResult();
            Check("audio: the voice's speed (SoundTouch)", AudioOut.ApplyRate(AudioOut.Beep(880, 0.5), 1.25).Length is > 15000 and < 22000, true);
            Check("images: skipped", Transcript.Jpeg(new byte[] { 1, 2, 3 }), null);
        }
        catch (Exception e)
        {
            failed++;
            Console.WriteLine($"FAIL {e.GetType().Name}: {e.Message}");
        }
        finally { try { Directory.Delete(tmp, true); } catch { } }
        Console.WriteLine(failed == 0 ? "selftest: ok" : $"selftest: {failed} failed");
        return failed == 0 ? 0 : 1;
    }
}
