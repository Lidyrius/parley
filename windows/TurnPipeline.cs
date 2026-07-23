namespace Parley;

// The per-turn voice pipeline — mirrors the macOS flow:
// TTS prefetch → smart media pause → speak (+beep on listen turns) → record (VAD) →
// transcribe → classify → ack chime (background) → resume media → return transcript.
// "" ends the conversation (hook exits without blocking).
public sealed class TurnPipeline
{
    public volatile bool Muted;
    private readonly MicCapture _mic = new();
    private readonly Func<int> _queuedTurns;
    private List<string> _pendingResume = new();
    private Task? _ackTask;

    public TurnPipeline(Func<int> queuedTurns) => _queuedTurns = queuedTurns;

    public async Task<string> Run(TurnPayload turn)
    {
        var config = Config.Load();
        Log.Write($"turn start project={turn.Project} listen={turn.WantsListen}");

        if (Muted)
        {
            Log.Write("muted → skipping turn");
            return "";
        }

        // Prefetch the sentence synthesis immediately (runs while we wait/pause).
        var prefetch = GoogleTts.Synthesize(turn.Speak, config);

        // Wait out the previous turn's background ack so audio never overlaps.
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }

        // Smart pause: hold media until the TTS is actually ready, then pause.
        var pcm = await prefetch;
        var newlyPaused = await MediaControl.PausePlaying();
        if (newlyPaused.Count > 0)
        {
            foreach (var id in newlyPaused)
                if (!_pendingResume.Contains(id)) _pendingResume.Add(id);
            Log.Write($"paused media: {string.Join(",", newlyPaused)}");
            await Task.Delay(400);
        }

        if (pcm is not null)
        {
            Log.Write($"speak start ({pcm.Length} bytes)");
            await AudioOut.PlayPcm(pcm);
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
        var wav = await _mic.Record();
        Log.Write($"record done bytes={wav.Length}");

        var text = await Groq.Transcribe(wav, config);
        Log.Write($"transcribe done chars={text.Length}");

        var intent = text.Length == 0 ? Groq.Intent.Other : await Groq.Classify(text, config);
        Log.Write($"classified: {intent}");

        // Ack chime + media resume in the background — the transcript returns to the hook
        // immediately so Claude starts working during the ack.
        _ackTask = Task.Run(async () =>
        {
            await Task.Delay(300);
            if (text.Length > 0) await AudioOut.PlayChime();
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
        await MediaControl.Resume(ids);
        Log.Write($"resumed media: {string.Join(",", ids)}");
    }
}
