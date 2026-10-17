namespace Parley;

// The per-turn voice pipeline — full port of the macOS flow:
// TTS prefetch (+ learned timing) → smart media pause → project announcement (another
// session alive) → speak at speaking rate (+beep on listen turns) → record with pill overlay
// (VAD) → transcribe (min-audio guard) → classify → cached ack line + media resume in
// the background (transcript returns immediately) → stats. "" ends the conversation.
// iPhone (docs/IPHONE.md, v2): in a call every step speaks/listens through the phone (AudioOut,
// MicCapture); Unterwegs-Modus rings the phone first; plus the wake greeting and the permission
// question, which ride the same gate as turns.
public sealed class TurnPipeline
{
    public volatile bool Muted;
    // Set once at startup. Ring: Unterwegs-Modus — ring the phone for this label and wait for
    // the call (true = connected). Route: a wake utterance → delivered; returns the line to confirm with.
    public Func<string, Task<bool>>? Ring;
    public Func<string, Config, Task<string>>? Route;
    private readonly MicCapture _mic = new();
    private readonly Func<int> _queuedTurns;
    private readonly PillOverlay? _pill;
    private readonly Func<List<Server.ParkedInfo>>? _resumableList;   // parked / idle-with-mod sessions
    private readonly Action<string, string>? _resume;                 // (id, instruction)
    private readonly Func<string, bool>? _othersAlive;   // any session besides this one not stopped
    private List<string> _pendingResume = new();
    private volatile int _resumeGen;   // bumped per turn; cancels a pending debounced resume
    private Task? _ackTask;

    public TurnPipeline(Func<int> queuedTurns, PillOverlay? pill,
        Func<List<Server.ParkedInfo>>? resumableList = null, Action<string, string>? resume = null,
        Func<string, bool>? othersAlive = null)
    {
        _queuedTurns = queuedTurns;
        _pill = pill;
        _resumableList = resumableList;
        _resume = resume;
        _othersAlive = othersAlive;
    }

    public async Task<(string transcript, bool park, int wait, string resume)> Run(TurnPayload turn)
    {
        LiveStatus.Begin(turn.SessionId);
        try
        {
            if (turn.Event == Server.ResumeEvent) return await RunResume(turn);
            if (turn.Event == Server.WakeEvent) return await RunWake(turn);
            if (turn.Event == Server.PermissionEvent) return await RunPermission(turn);
            return await RunTurn(turn);
        }
        finally { LiveStatus.Set("idle"); }
    }

    // POST /resume (the mod's button): a short voice dialog instead of a hook turn — the
    // pre-recorded "Ich habe die Arbeit an X wieder aufgenommen…" line, then beep → record →
    // transcribe exactly like a listening turn. No "Update zu" announcement. The transcript
    // ("" → the default instruction) goes back to the server, which hands it to the session.
    private async Task<(string transcript, bool park, int wait, string resume)> RunResume(TurnPayload turn)
    {
        var config = Config.Load();
        _resumeGen++;
        Log.Write($"resume dialog start project={turn.Project}");
        if (Muted)
        {
            Log.Write("muted → resuming without dialog");
            return ("", false, 0, "");
        }
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }

        // Cached line, or synthesized live + cached; null → no TTS, just the beep.
        var line = await Clips.ResumeClip(turn.SpokenLabel, config);
        await PauseMediaIfPlaying();
        if (line is not null) await AudioOut.PlayPcm(AudioOut.ApplyRate(line, config.SpeakingRate));

        var (_, text) = await ListenOnce(config);
        Log.Write($"resume dialog done chars={text.Length}");
        StartAck(Groq.Intent.Other, text.Length > 0, config);
        return (text, false, 0, "");
    }

    // "Hey Parley" during a call: cached greeting → beep → listen on the phone → route the
    // utterance (a running session by name, else the Zentrale) → a short spoken confirmation.
    private async Task<(string transcript, bool park, int wait, string resume)> RunWake(TurnPayload turn)
    {
        var config = Config.Load();
        _resumeGen++;
        Log.Write("wake: greeting");
        if (Muted)
        {
            Log.Write("muted → ignoring the wake word");
            return ("", false, 0, "");
        }
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }

        var greeting = await Clips.GreetClip(config);
        if (greeting is not null) await AudioOut.PlayPcm(AudioOut.ApplyRate(greeting, config.SpeakingRate));
        var (_, text) = await ListenOnce(config);
        if (text.Length == 0)
        {
            Log.Write("wake: nothing said");
            return ("", false, 0, "");
        }
        string line;
        try { line = Route is null ? "" : await Route(text, config); }
        catch (Exception e)
        {
            Log.Write($"wake: routing failed ({e.Message})");
            line = "Das konnte ich leider nicht weitergeben, Sir.";
        }
        if (line.Length > 0) await SpeakLine(line, config);
        Log.Write($"wake: done chars={text.Length}");
        return (text, false, 0, "");
    }

    // POST /permission: "<Projekt> möchte … — erlauben?" → beep → listen. The transcript goes back;
    // the server maps it to allow / deny / ask. No TTS (nothing could be asked) or past the
    // request's deadline → "" (= ask: the on-screen prompt decides).
    private async Task<(string transcript, bool park, int wait, string resume)> RunPermission(TurnPayload turn)
    {
        var config = Config.Load();
        _resumeGen++;
        Log.Write($"permission question project={turn.Project}");
        if (Muted)
        {
            Log.Write("muted → permission left to the screen");
            return ("", false, 0, "");
        }
        var synth = GoogleTts.Synthesize(turn.Speak, config);
        if (Ring is not null) await Ring(turn.SpokenLabel);
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }
        var pcm = await synth;
        if (pcm is null || DateTime.UtcNow >= (turn.Deadline ?? DateTime.MaxValue))
        {
            Log.Write(pcm is null ? "permission: no TTS → left to the screen" : "permission: too late to ask → left to the screen");
            return ("", false, 0, "");
        }
        await PauseMediaIfPlaying();
        await AudioOut.PlayPcm(AudioOut.ApplyRate(pcm, config.SpeakingRate));
        var (_, text) = await ListenOnce(config);
        ScheduleResume();
        Log.Write($"permission answer chars={text.Length}");
        return (text, false, 0, "");
    }

    private async Task<(string transcript, bool park, int wait, string resume)> RunTurn(TurnPayload turn)
    {
        var config = Config.Load();
        Log.Write($"turn start project={turn.Project} listen={turn.WantsListen}");
        _resumeGen++;

        if (Muted)
        {
            Log.Write("muted → skipping turn");
            // Stumm: nicht sprechen, aber die Zusammenfassung als Notification zeigen.
            Notifier.Notify($"Parley · {turn.SpokenLabel}", turn.Speak);
            return ("", false, 0, "");
        }

        // Prefetch the sentence synthesis immediately; observed duration feeds TtsTiming.
        var synthStart = DateTime.UtcNow;
        var prefetch = Task.Run(async () =>
        {
            var pcm = await GoogleTts.Synthesize(turn.Speak, config);
            if (pcm is not null)
                TtsTiming.Record(turn.Speak.Length, (DateTime.UtcNow - synthStart).TotalSeconds);
            return pcm;
        });

        // Unterwegs-Modus (docs/IPHONE.md, v2): no call yet → ring the phone and wait for it
        // (≤ 45 s) while the synthesis runs; unanswered, the turn plays on the speaker.
        if (Ring is not null) await Ring(turn.SpokenLabel);

        // Wait out the previous turn's background ack so audio never overlaps.
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }

        // Another session alive (any state but stopped) → cached "Update zu <Name>"
        // announcement (instant audio → pause right away).
        byte[]? announcement = _othersAlive?.Invoke(Server.SessionKey(turn)) == true
            ? Clips.Announcement(turn.SpokenLabel, config)
            : null;

        // Smart pause: with no announcement, hold media until the synthesis is done or
        // ~1s before its predicted completion.
        if (announcement is null)
        {
            var target = Math.Max(0, TtsTiming.Predict(turn.Speak.Length) - 1.0);
            while (!prefetch.IsCompleted && (DateTime.UtcNow - synthStart).TotalSeconds < target)
                await Task.Delay(50);
        }
        await PauseMediaIfPlaying();

        if (announcement is not null)
        {
            Log.Write($"multi-instance → announcing {turn.SpokenLabel}");
            await AudioOut.PlayPcm(AudioOut.ApplyRate(announcement, config.SpeakingRate));
        }

        var pcm = await prefetch;
        if (pcm is not null)
        {
            Log.Write($"speak start ({pcm.Length} bytes, rate {config.SpeakingRate:0.00})");
            await AudioOut.PlayPcm(AudioOut.ApplyRate(pcm, config.SpeakingRate));
        }
        else Log.Write("no TTS audio (missing key or synth failed)");

        if (!turn.WantsListen)
        {
            ScheduleResume();
            // Ich melde mich selbst zurück — Notification fängt dich, falls du weg bist.
            Notifier.Notify($"Parley · {turn.SpokenLabel}", turn.Speak);
            Log.Write("turn end (speak-only)");
            return ("", false, 0, "");
        }

        // Record → transcribe. A CONTROL command (resume a parked / idle project by voice) is
        // handled here and we re-record for THIS session's real answer. Capped to 4 hops.
        byte[] wav = Array.Empty<byte>();
        var text = "";
        for (var hop = 0; hop < 4; hop++)
        {
            (wav, text) = await ListenOnce(config);

            var parked = _resumableList?.Invoke() ?? new List<Server.ParkedInfo>();
            if (text.Length == 0 || parked.Count == 0 || hop >= 3) break;
            var cmd = await Groq.DetectControlCommand(text, parked.Select(p => p.Label).ToList(), config);
            if (cmd is not { Resume: true }) break;
            var target = MatchParked(cmd.Value.Target, parked);
            if (target is null) break;

            var instruction = string.IsNullOrWhiteSpace(cmd.Value.Instruction) ? Server.ResumeInstruction : cmd.Value.Instruction;
            _resume?.Invoke(target.Value.Id, instruction);
            Log.Write($"control: resume {target.Value.Label} → \"{instruction}\"");
            await SpeakLine($"Verstanden, Sir — ich nehme {target.Value.Label} wieder auf. Und für dieses Projekt?", config);
            // loop: listen again for the current session's actual reply
        }

        // "Warte X Minuten" — pause before continuing (checked before STOP, which also
        // matches "warte"). Confirm, resume media for the wait, tell the hook to sleep then
        // re-inject a resume prompt so Claude picks up automatically.
        if (text.Length > 0)
        {
            var wait = await Groq.ClassifyWait(text, config);
            if (wait > 0)
            {
                var human = HumanDuration(wait);
                Log.Write($"wait requested: {wait}s");
                StatsStore.RecordTurn(turn.Speak, text, 0, "WAIT", turn.Project);
                await SpeakLine($"Verstanden, Sir. Ich warte {human} und melde mich dann.", config);
                ScheduleResume();
                var resume = $"[Parley] Die vom Nutzer angeforderte Wartezeit von {human} ist vorbei. " +
                    "Fahre jetzt fort: prüfe, ob alles wie erwartet funktioniert hat, und berichte kurz.";
                return ("", false, wait, resume);
            }
        }

        var intent = text.Length == 0 ? Groq.Intent.Other : await Groq.Classify(text, config);
        Log.Write($"classified: {intent}");

        var recordSeconds = Math.Max(0, wav.Length - 44) / 2.0 / 16000.0;
        StatsStore.RecordTurn(turn.Speak, text, recordSeconds, intent.ToString().ToUpperInvariant(), turn.Project);

        StartAck(intent, text.Length > 0, config);

        // "Stop heißt Stop" — reply isn't fed back, but the session PARKS (stays resumable
        // by voice/tray) instead of ending. A silent turn parks too.
        if (intent == Groq.Intent.Stop)
        {
            Log.Write("turn end (stop → parked, resumable)");
            return ("", true, 0, "");
        }
        if (text.Length == 0)
        {
            Log.Write("turn end (silence → parked, resumable)");
            return ("", true, 0, "");
        }
        Log.Write("turn end");
        return (text, false, 0, "");
    }

    // Beep → record (pill + VAD) → transcribe (min-audio guard): one listening pass.
    private async Task<(byte[] wav, string text)> ListenOnce(Config config)
    {
        await AudioOut.PlayBeep();
        await Task.Delay(100);

        LiveStatus.Set("listening");
        Log.Write("record start");
        ShowPill(true);
        _mic.OnLevel = level => { LiveStatus.Push(level); _pill?.BeginInvoke(() => _pill.Push(level)); };
        var wav = await _mic.Record();
        _mic.OnLevel = null;
        ShowPill(false);
        Log.Write($"record done bytes={wav.Length}");
        LiveStatus.Set("transcribing");

        var minBytes = 44 + 16000 * 2 / 5;   // header + ~0.2s
        var text = wav.Length >= minBytes ? await Groq.Transcribe(wav, config) : "";
        Log.Write($"transcribe done chars={text.Length}");
        return (wav, text);
    }

    // Ack (cached Jarvis line, chime fallback) + media resume in the background — the
    // transcript returns immediately so Claude starts working during the ack. Order:
    // hi-fi restored → ack → resume (never video over the acknowledgment).
    private void StartAck(Groq.Intent intent, bool hasText, Config config)
    {
        // Taken now, before the turn's own hold ends: the phone never sees `idle` (and listens
        // for the wake word) in the gap before the ack plays.
        var hold = PhoneCall.Hold();
        _ackTask = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(300);
                await AudioOut.WaitForHiFiOutput();
                if (hasText)
                {
                    var clip = Clips.AckClip(intent, config);
                    if (clip is not null) await AudioOut.PlayPcm(AudioOut.ApplyRate(clip, config.SpeakingRate));
                    else await AudioOut.PlayChime();
                }
                ScheduleResume();
            }
            finally { hold.Dispose(); }
        });
    }

    private static string HumanDuration(int seconds)
    {
        if (seconds % 60 == 0) { var m = seconds / 60; return m == 1 ? "eine Minute" : $"{m} Minuten"; }
        if (seconds < 60) return $"{seconds} Sekunden";
        return $"{seconds / 60} Minuten und {seconds % 60} Sekunden";
    }

    // Speak a short dynamic line (no mic) — used to confirm a resume before re-listening.
    private static async Task SpeakLine(string text, Config config)
    {
        var pcm = await GoogleTts.Synthesize(text, config);
        if (pcm is null) return;
        // Settle after the mic teardown + wait for hi-fi output, else it renders silent.
        await Task.Delay(300);
        await AudioOut.WaitForHiFiOutput();
        await AudioOut.PlayPcm(AudioOut.ApplyRate(pcm, config.SpeakingRate));
    }

    // Fuzzy-match a spoken project name to a parked session (either contains the other).
    private static Server.ParkedInfo? MatchParked(string spoken, List<Server.ParkedInfo> parked)
    {
        var t = spoken.Trim().ToLowerInvariant();
        if (t.Length == 0) return null;
        foreach (var p in parked)
        {
            var l = p.Label.ToLowerInvariant();
            if (l == t || l.Contains(t) || t.Contains(l)) return p;
        }
        return null;
    }

    private void ShowPill(bool show)
    {
        try { _pill?.BeginInvoke(() => { if (show) _pill.ShowPill(); else _pill.HidePill(); }); }
        catch { }
    }

    private async Task PauseMediaIfPlaying()
    {
        // In a call the voice goes to the phone — the PC's music/video can keep playing.
        if (PhoneCall.Active) return;
        var newly = await MediaControl.PausePlaying();
        if (newly.Count == 0) return;
        foreach (var id in newly)
            if (!_pendingResume.Contains(id)) _pendingResume.Add(id);
        Log.Write($"paused media: {string.Join(",", newly)}");
        await Task.Delay(400);
    }

    // Debounced, fire-and-forget: waits a short grace so a following clip/turn can pre-empt
    // the resume, then resumes only if the whole audio cue is idle (nothing queued and no
    // newer turn started). _resumeGen is bumped at each turn start to cancel a stale resume.
    private void ScheduleResume()
    {
        if (_pendingResume.Count == 0) return;
        var gen = _resumeGen;
        _ = Task.Run(async () =>
        {
            await Task.Delay(1500);
            if (gen != _resumeGen || _queuedTurns() > 0 || _pendingResume.Count == 0)
            {
                Log.Write("media resume skipped (cue continued)");
                return;
            }
            var ids = _pendingResume;
            _pendingResume = new List<string>();
            await AudioOut.WaitForHiFiOutput();
            await MediaControl.Resume(ids);
            Log.Write($"resumed media: {string.Join(",", ids)}");
        });
    }
}
