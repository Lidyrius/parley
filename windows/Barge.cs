using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Windows.Media.SpeechRecognition;

namespace Parley;

// Barge-in at the PC (the phone: ios/ParleyMobile/WakeWord.swift, the Mac: app/Sources/Parley/Barge.swift):
// while Parley speaks a line, Windows speech recognition listens; only what can't be Parley's
// own echo counts — a stop word Parley didn't just say, or two words not in its line.
public static class Barge
{
    private static readonly HashSet<string> StopWords = new() { "stopp", "stop", "halt", "moment", "warte", "warten", "parley" };

    public static bool IsInterruption(string transcript, IReadOnlySet<string> spoken)
    {
        var words = Tokens(transcript).Where(w => w.Length >= 2 && !spoken.Contains(w)).ToList();
        if (words.Any(StopWords.Contains)) return true;
        return spoken.Count > 0 && words.Count >= 2;
    }

    /// Lowercased, diacritics folded, split on anything that is not a letter.
    public static List<string> Tokens(string text)
    {
        var folded = new StringBuilder(text.Length);
        foreach (var c in text.Normalize(NormalizationForm.FormD))
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) folded.Append(char.ToLowerInvariant(c));
        return Regex.Split(folded.ToString(), @"[^\p{L}]+").Where(w => w.Length > 0).ToList();
    }
}

// One line's watch: the recognizer (its own mic) decides, a WASAPI capture keeps the last 2 s as
// 16 kHz frames — the recording's pre-roll, so Sir's first words count. `Heard` cancels the playback.
// ponytail: no echo cancellation on the PC — the word rule is the guard; add the Voice Capture DSP
// if speakers trigger it falsely.
public sealed class BargeWatch
{
    private const double Settle = 0.6;   // the line's first words are still ringing in the room
    private const int PrerollFrames = 100;   // 2 s of 20 ms frames

    private readonly HashSet<string> _spoken;
    private readonly DateTime _started = DateTime.UtcNow;
    private readonly CancellationTokenSource _heard = new();
    private readonly Queue<byte[]> _preroll = new();
    private readonly List<short> _pending = new();
    private readonly WasapiCapture? _capture;
    private SpeechRecognizer? _recognizer;
    private Task _starting = Task.CompletedTask;
    private volatile bool _stopped;
    private double _resamplePos;
    private float _prev;

    public CancellationToken Heard => _heard.Token;
    public bool Barged => _heard.IsCancellationRequested;

    public BargeWatch(string line)
    {
        _spoken = Barge.Tokens(line).ToHashSet();
        try
        {
            _capture = new WasapiCapture();
            var fmt = _capture.WaveFormat;
            _capture.DataAvailable += (_, e) => Keep(MicCapture.ToMonoFloats(e.Buffer, e.BytesRecorded, fmt, fmt.Channels), fmt.SampleRate);
            _capture.StartRecording();
        }
        catch (Exception e)
        {
            Log.Write($"barge: no pre-roll ({e.Message})");
            _capture?.Dispose();
            _capture = null;
        }
        _starting = Recognize();
    }

    private async Task Recognize()
    {
        try
        {
            var de = SpeechRecognizer.SupportedTopicLanguages.FirstOrDefault(l => l.LanguageTag.StartsWith("de", StringComparison.OrdinalIgnoreCase));
            if (de is null) { Log.Write("barge: no German speech recognition installed"); return; }
            var recognizer = new SpeechRecognizer(de);
            recognizer.Constraints.Add(new SpeechRecognitionTopicConstraint(SpeechRecognitionScenario.Dictation, "barge"));
            var compiled = await recognizer.CompileConstraintsAsync();
            if (compiled.Status != SpeechRecognitionResultStatus.Success)
            {
                Log.Write($"barge: recognizer not ready ({compiled.Status})");
                recognizer.Dispose();
                return;
            }
            recognizer.HypothesisGenerated += (_, e) => OnText(e.Hypothesis.Text);
            recognizer.ContinuousRecognitionSession.ResultGenerated += (_, e) => OnText(e.Result.Text);
            _recognizer = recognizer;
            if (_stopped) return;
            await recognizer.ContinuousRecognitionSession.StartAsync();
            Log.Write("barge: listening");
        }
        catch (Exception e)
        {
            // Typically "Online-Spracherkennung" off in the privacy settings, or no mic access.
            Log.Write($"barge: speech recognition unavailable ({e.Message})");
        }
    }

    private void OnText(string text)
    {
        if (Barged || (DateTime.UtcNow - _started).TotalSeconds < Settle || !Barge.IsInterruption(text, _spoken)) return;
        Log.Write("barge-in at the PC: Parley stops");
        _heard.Cancel();
    }

    // The mic, resampled to 16 kHz, into 20 ms frames; only the newest 2 s stay.
    private void Keep(float[] mono, int rate)
    {
        var ratio = rate / (double)PhoneAudio.SampleRate;
        lock (_preroll)
        {
            foreach (var f in mono)
            {
                while (_resamplePos < 1.0)
                {
                    var v = _prev + (f - _prev) * (float)_resamplePos;
                    _pending.Add((short)Math.Clamp(v * short.MaxValue, short.MinValue, short.MaxValue));
                    _resamplePos += ratio;
                }
                _resamplePos -= 1.0;
                _prev = f;
            }
            while (_pending.Count >= PhoneAudio.FrameSamples)
            {
                _preroll.Enqueue(PhoneAudio.ToBytes(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(_pending)[..PhoneAudio.FrameSamples]));
                _pending.RemoveRange(0, PhoneAudio.FrameSamples);
                if (_preroll.Count > PrerollFrames) _preroll.Dequeue();
            }
        }
    }

    /// Ends the watch; the last 2 s of mic as 16 kHz frames (the phone's frame shape).
    public async Task<IReadOnlyList<byte[]>> Stop()
    {
        _stopped = true;
        try { _capture?.StopRecording(); } catch { }
        _capture?.Dispose();
        try { await _starting; } catch { }
        if (_recognizer is { } r)
        {
            try { await r.ContinuousRecognitionSession.CancelAsync(); } catch { }
            r.Dispose();
        }
        lock (_preroll) return _preroll.ToList();
    }
}
