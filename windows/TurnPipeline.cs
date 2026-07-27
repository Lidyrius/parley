namespace Parley;

// The per-turn voice pipeline — full port of the macOS flow:
// TTS prefetch (+ learned timing) → smart media pause → project announcement (multi-
// instance) → speak at speaking rate (+beep on listen turns) → record with pill overlay
// (VAD) → transcribe (min-audio guard) → classify → cached ack line + media resume in
// the background (transcript returns immediately) → stats. "" ends the conversation.
public sealed class TurnPipeline
{
    public volatile bool Muted;
    private readonly MicCapture _mic = new();
    private readonly Func<int> _queuedTurns;
    private readonly PillOverlay? _pill;
    private readonly Func<List<Server.ParkedInfo>>? _parkedList;
    private readonly Action<string, string>? _wake;
    private List<string> _pendingResume = new();
    private volatile int _resumeGen;   // bumped per turn; cancels a pending debounced resume
    private Task? _ackTask;

    public TurnPipeline(Func<int> queuedTurns, PillOverlay? pill,
        Func<List<Server.ParkedInfo>>? parkedList = null, Action<string, string>? wake = null)
    {
        _queuedTurns = queuedTurns;
        _pill = pill;
        _parkedList = parkedList;
        _wake = wake;
    }

    public async Task<(string transcript, bool park, int wait, string resume)> Run(TurnPayload turn)
    {
        var config = Config.Load();
        SessionTracker.Touch(turn.Project);
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

        // Wait out the previous turn's background ack so audio never overlaps.
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }

        // Multi-instance → cached project announcement (instant audio → pause right away).
        byte[]? announcement = SessionTracker.LiveProjectCount() > 1
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

        // Record → transcribe. A CONTROL command (resume a paused project by voice) is
        // handled here and we re-record for THIS session's real answer. Capped to 4 hops.
        var minBytes = 44 + 16000 * 2 / 5;   // header + ~0.2s
        byte[] wav = Array.Empty<byte>();
        var text = "";
        for (var hop = 0; hop < 4; hop++)
        {
            await AudioOut.PlayBeep();
            await Task.Delay(100);

            Log.Write("record start");
            ShowPill(true);
            _mic.OnLevel = level => _pill?.BeginInvoke(() => _pill.Push(level));
            wav = await _mic.Record();
            _mic.OnLevel = null;
            ShowPill(false);
            Log.Write($"record done bytes={wav.Length}");

            text = wav.Length >= minBytes ? await Groq.Transcribe(wav, config) : "";
            Log.Write($"transcribe done chars={text.Length}");

            var parked = _parkedList?.Invoke() ?? new List<Server.ParkedInfo>();
            if (text.Length == 0 || parked.Count == 0 || hop >= 3) break;
            var cmd = await Groq.DetectControlCommand(text, parked.Select(p => p.Label).ToList(), config);
            if (cmd is not { Resume: true }) break;
            var target = MatchParked(cmd.Value.Target, parked);
            if (target is null) break;

            var instruction = string.IsNullOrWhiteSpace(cmd.Value.Instruction) ? "Wir machen weiter." : cmd.Value.Instruction;
            _wake?.Invoke(target.Value.Id, instruction);
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

        // Ack (cached Jarvis line, chime fallback) + media resume in the background — the
        // transcript returns immediately so Claude starts working during the ack. Order:
        // hi-fi restored → ack → resume (never video over the acknowledgment).
        var hasText = text.Length > 0;
        _ackTask = Task.Run(async () =>
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
        });

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
