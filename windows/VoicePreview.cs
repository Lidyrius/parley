using NAudio.Wave;

namespace Parley;

// Plays a short sample of a Chirp3-HD voice while the user picks one in onboarding.
//
// Full quality: on selection we synth the sample live with the user's own key (lossless
// LINEAR16 — identical to how the app will actually speak) and cache it, so a second click
// is instant. The bundled low-quality MP3 (voice-previews/<voice>.mp3) is only an offline /
// no-key fallback. One friendly sentence per language, no Jarvis. macOS counterpart: VoicePreview.
public static class VoicePreview
{
    private static IWavePlayer? _out;
    private static IDisposable? _reader;
    private static int _token;

    private static string HqDir => Path.Combine(Config.Dir, "voice-previews-hq");

    public static string Sentence(string language) => language switch
    {
        "English" => "Hi there! This is my voice. This is how I sound when I read to you.",
        "Français" => "Bonjour ! Voici ma voix. Voilà comment je sonne quand je te fais la lecture.",
        "Español" => "¡Hola! Esta es mi voz. Así sueno cuando te leo en voz alta.",
        "Italiano" => "Ciao! Questa è la mia voce. Ecco come suono quando ti leggo qualcosa.",
        "Nederlands" => "Hoi! Dit is mijn stem. Zo klink ik als ik je iets voorlees.",
        _ => "Hallo! Das ist meine Stimme. So klinge ich, wenn ich dir vorlese.",
    };

    public static async void Play(string voice, string sentence, string key, Action<bool>? onState = null)
    {
        var my = ++_token;
        var cached = Path.Combine(HqDir, voice + ".pcm");
        if (File.Exists(cached)) { PlayPcm(File.ReadAllBytes(cached)); return; }
        if (string.IsNullOrEmpty(key)) { PlayBundled(voice); return; }
        onState?.Invoke(true);
        byte[]? pcm = null;
        try { pcm = await GoogleTts.Synthesize(sentence, new Config { GoogleKey = key, GoogleVoice = voice }); }
        catch { }
        onState?.Invoke(false);
        if (my != _token) return;   // user already picked another voice
        if (pcm is null || pcm.Length < 2) { PlayBundled(voice); return; }
        try { Directory.CreateDirectory(HqDir); File.WriteAllBytes(cached, pcm); } catch { }
        PlayPcm(pcm);
    }

    public static void Stop()
    {
        try { _out?.Stop(); } catch { }
        _out?.Dispose(); _reader?.Dispose();
        _out = null; _reader = null;
    }

    private static void PlayPcm(byte[] pcm)
    {
        Stop();
        try
        {
            var stream = new RawSourceWaveStream(new MemoryStream(pcm), new WaveFormat(GoogleTts.SampleRate, 16, 1));
            var wave = new WaveOutEvent();
            wave.Init(stream);
            wave.Play();
            _out = wave; _reader = stream;
        }
        catch { Stop(); }
    }

    private static void PlayBundled(string voice)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "voice-previews", voice + ".mp3");
        if (!File.Exists(path)) return;
        Stop();
        try
        {
            var reader = new Mp3FileReader(path);
            var wave = new WaveOutEvent();
            wave.Init(reader);
            wave.Play();
            _out = wave; _reader = reader;
        }
        catch { Stop(); }
    }
}
