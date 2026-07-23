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
    private List<string> _pendingResume = new();
    private Task? _ackTask;

    public TurnPipeline(Func<int> queuedTurns, PillOverlay? pill)
    {
        _queuedTurns = queuedTurns;
        _pill = pill;
    }

    public async Task<string> Run(TurnPayload turn)
    {
        var config = Config.Load();
        SessionTracker.Touch(turn.Project);
        Log.Write($"turn start project={turn.Project} listen={turn.WantsListen}");

        if (Muted)
        {
            Log.Write("muted → skipping turn");
            return "";
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
            await MaybeResumeMedia();
            Log.Write("turn end (speak-only)");
            return "";
        }

        await AudioOut.PlayBeep();
        await Task.Delay(100);

        Log.Write("record start");
        ShowPill(true);
        _mic.OnLevel = level => _pill?.BeginInvoke(() => _pill.Push(level));
        var wav = await _mic.Record();
        _mic.OnLevel = null;
        ShowPill(false);
        Log.Write($"record done bytes={wav.Length}");

        // Too little audio → skip Groq (it rejects near-empty files), end cleanly.
        var minBytes = 44 + 16000 * 2 / 5;   // header + ~0.2s
        var text = wav.Length >= minBytes ? await Groq.Transcribe(wav, config) : "";
        Log.Write($"transcribe done chars={text.Length}");

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
            await MaybeResumeMedia();
        });

        if (intent == Groq.Intent.Stop)
        {
            Log.Write("turn end (stop → conversation ends)");
            return "";
        }
        Log.Write("turn end");
        return text;
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

    private async Task MaybeResumeMedia()
    {
        if (_pendingResume.Count == 0) return;
        if (_queuedTurns() > 0)
        {
            Log.Write("media resume deferred (turns queued)");
            return;
        }
        var ids = _pendingResume;
        _pendingResume = new List<string>();
        await AudioOut.WaitForHiFiOutput();
        await MediaControl.Resume(ids);
        Log.Write($"resumed media: {string.Join(",", ids)}");
    }
}
