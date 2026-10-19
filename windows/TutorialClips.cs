namespace Parley;

// The setup's short tutorial (step 9), 1:1 with the macOS TutorialClips.swift: one spoken line per
// step, pre-rendered in the chosen voice and cached under %APPDATA%\Parley\tutorial\v<version>\
// <voice>, so it plays at once. German + English authored; other languages hear German.
public enum TutorialStep { Principle, Stop, Wait, Remind, Projects, Questions, Away, Finish }

public enum TutorialExpect { None, Stop, Wait }

public static class Tutorial
{
    public static readonly TutorialStep[] All = Enum.GetValues<TutorialStep>();

    public static TutorialExpect Expect(this TutorialStep s) => s switch
    {
        TutorialStep.Stop => TutorialExpect.Stop,
        TutorialStep.Wait or TutorialStep.Remind => TutorialExpect.Wait,
        _ => TutorialExpect.None,
    };

    public static string Title(this TutorialStep s, string lang)
    {
        var en = lang == "English";
        return s switch
        {
            TutorialStep.Principle => en ? "How it works" : "So funktioniert's",
            TutorialStep.Stop => en ? "Tell me to stop" : "Halt mich an",
            TutorialStep.Wait => en ? "Ask me to wait" : "Lass mich warten",
            TutorialStep.Remind => en ? "Call me back" : "Wiedervorlage",
            TutorialStep.Away => en ? "On the go" : "Unterwegs",
            TutorialStep.Projects => en ? "Parallel projects" : "Parallele Projekte",
            TutorialStep.Questions => en ? "Just ask" : "Einfach fragen",
            _ => en ? "You're all set" : "Fertig!",
        };
    }

    // The spoken line — "Clode" is the phonetic spelling, so the voice says "Claude".
    public static string Line(this TutorialStep s, string lang) => (lang == "English" ? En : De)[(int)s];

    // The same line on screen: spelled "Claude".
    public static string DisplayLine(this TutorialStep s, string lang) => s.Line(lang).Replace("Clode", "Claude");

    // Written to be HEARD as a flowing, friendly conversation (du-form).
    private static readonly string[] De =
    {
        "Willkommen bei Parley. Am Ende jeder Antwort spreche ich dir die Zusammenfassung vor, und du antwortest einfach mit deiner Stimme — ganz freihändig.",
        "Wann immer ich aufhören soll, sag es einfach in deinen Worten — ob „stopp“, „lass uns hier aufhören“ oder „das reicht erst mal“. Auf ein bestimmtes Wort kommt es nicht an. Probier es: sag mir, dass ich anhalten soll.",
        "Brauchst du eine Pause, sag mir einfach, ich soll warten — „warte zehn Minuten“, „gib mir eine Viertelstunde“, die Zeit bestimmst du frei. Ich melde mich dann von selbst zurück. Probier es ruhig aus.",
        "Soll ich später nachhaken, sag einfach: „ruf mich in zwei Minuten zurück“. Dann melde ich mich genau dann wieder — mit dem, was die Sitzung bis dahin geschafft hat. Probier es aus.",
        "Läuft nebenbei ein anderes Projekt, sag mir einfach von hier aus: nimm das Projekt Soundso wieder auf. Das klappt aus jeder Sitzung.",
        "Und wenn du etwas wissen willst, frag einfach — ich antworte dir sofort.",
        "Bist du unterwegs, schalte auf dem Handy „Unterwegs“ ein. Dann klingle ich dich an, statt am Computer zu sprechen — auch im Auto.",
        "Das war's. Starte jetzt eine neue Clode-Code-Sitzung und tippe Parley Voice, dann bin ich für dich da.",
    };
    private static readonly string[] En =
    {
        "Welcome to Parley. At the end of every turn I speak you the summary, and you just reply with your voice — completely hands-free.",
        "Whenever I should stop, just say it in your own words — “stop”, “let's wrap up here”, or “that's enough for now”. It doesn't hinge on a magic word. Try it: tell me to stop.",
        "Need a break? Just tell me to wait — “wait ten minutes”, “give me a quarter hour”, you pick the time. I'll come back to you on my own. Give it a try.",
        "Want me to check back later? Just say “call me back in two minutes” — and I'll come back right then, with what the session got done. Try it.",
        "If another project is running, just tell me from here: resume the such-and-such project. It works from any session.",
        "And whenever you want to know something, just ask — I answer right away.",
        "On the go? Turn on “Unterwegs” on your phone, and I'll call you instead of speaking at the computer — in the car, too.",
        "That's it. Now start a new Clode Code session and type Parley Voice, and I'm here for you.",
    };
}

public static class TutorialClips
{
    public const int Version = 4;   // bump when the tutorial changes → shown again (and re-rendered)

    private static int _rendering;

    // One folder per voice (e.g. "de-DE-Chirp3-HD-Alnilam") so a voice change re-renders.
    private static string Dir(string voice) => Path.Combine(Config.Dir, "tutorial", $"v{Version}", voice);
    private static string PathFor(TutorialStep step, string voice) => Path.Combine(Dir(voice), $"step_{(int)step}.pcm");

    // Cached PCM for a step; rendered now when it isn't yet (null if that fails). key/voice come
    // from the onboarding selection, not the saved config.
    public static async Task<byte[]?> Clip(TutorialStep step, string lang, string key, string voice, CancellationToken cancellationToken = default)
    {
        var file = PathFor(step, voice);
        try { if (File.Exists(file)) return await File.ReadAllBytesAsync(file, cancellationToken); }
        catch (OperationCanceledException) { return null; }
        catch { }
        if (key.Length == 0) return null;
        var pcm = await GoogleTts.Synthesize(step.Line(lang), new Config { GoogleKey = key, GoogleVoice = voice }, cancellationToken);
        if (pcm is null || pcm.Length < 2) return null;
        Save(file, pcm);
        return pcm;
    }

    // Render every step in the background (right after the voice step), skipping cached ones.
    public static async Task Render(string lang, string key, string voice)
    {
        if (key.Length == 0 || Interlocked.Exchange(ref _rendering, 1) == 1) return;
        try
        {
            foreach (var step in Tutorial.All)
            {
                var file = PathFor(step, voice);
                if (File.Exists(file)) continue;
                var pcm = await GoogleTts.Synthesize(step.Line(lang), new Config { GoogleKey = key, GoogleVoice = voice });
                if (pcm is not null && pcm.Length >= 2) Save(file, pcm);
            }
        }
        finally { Volatile.Write(ref _rendering, 0); }
    }

    private static void Save(string file, byte[] pcm)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var tmp = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllBytes(tmp, pcm);
            File.Move(tmp, file, overwrite: true);
        }
        catch { /* a cache miss only costs a request next time */ }
    }
}
