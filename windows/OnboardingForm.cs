using System.Drawing.Drawing2D;
using System.Globalization;
using System.Text.Json;
using Microsoft.Win32;
using NAudio.CoreAudioApi;

namespace Parley;

// First-run onboarding in ten steps, "logo with echo" (docs/design/screens/macos/01-willkommen),
// 1:1 with the macOS OnboardingView: warm dark, a round badge with three clay rings, one-line
// subtitles, ten progress dots. Clients, the two API keys (checked as they are pasted), language +
// voice, notifications, the Windows permissions in one list, the relay for the phone, pairing it in
// the window, a short tutorial. Owner-drawn on a 660×580 canvas (scaled to the screen's DPI); only
// the text fields and pickers are real controls. Writes the shared credentials.json.
public sealed class OnboardingForm : Form
{
    private static readonly string[] Langs = { "Deutsch", "English", "Français", "Español", "Italiano", "Nederlands" };
    private static readonly string[] DefaultVoices = { "Alnilam", "Aoede", "Charon", "Kore", "Puck", "Fenrir" };

    // The look: warm dark, clay accent (macOS: Color(0.851, 0.467, 0.341)).
    private static readonly Color Clay = Color.FromArgb(217, 119, 87);
    private static readonly Color BgTop = Color.FromArgb(43, 38, 36);
    private static readonly Color BgBottom = Color.FromArgb(28, 26, 26);
    private static readonly Color Field = Color.FromArgb(30, 28, 27);
    private static readonly Color CardBg = Color.FromArgb(46, 43, 41);   // a card's fill over the background, for the pickers
    private static readonly Color TextPrimary = Color.FromArgb(236, 233, 230);
    private static readonly Color TextMuted = Color.FromArgb(160, 155, 151);
    private static readonly Color TextFaint = Color.FromArgb(108, 104, 101);
    private static readonly Color Green = Color.FromArgb(48, 209, 88);
    private static readonly Color Red = Color.FromArgb(255, 69, 58);
    private static readonly Color Orange = Color.FromArgb(255, 159, 10);
    private const float W = 660, H = 580, ContentW = 540, ContentX = (W - ContentW) / 2;

    private const string GoogleConsoleUrl = "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com";
    private const string GroqConsoleUrl = "https://console.groq.com/keys";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };
    private static Image? _claudeBrandIcon;
    private static Image? _codexBrandIcon;
    private static Image? _appIcon;

    // docs/design/screens/macos/01-willkommen/AUFTRAG.md — ten steps in the "logo with echo" look.
    private enum Step { Welcome, Integrations, Keys, Voice, Notify, Permissions, Relay, Pair, Tutorial, Done }
    private enum Check { Idle, Checking, Ok, Fail }
    private enum Grant { Granted, Asking, Needed, Denied }
    private enum Perm { Mic, Notifications }
    private enum RelayChoice { Public, Own, Address }

    private Step _step;
    private readonly float _s;   // logical → device pixels

    // Real controls: the keys, the pickers, the relay address.
    private readonly TextBox _google = MakeInput(true, 9.75f, "Einfügen");
    private readonly TextBox _groq = MakeInput(true, 9.75f, "Einfügen");
    private readonly ComboBox _lang = MakeCombo(Langs);
    private readonly ComboBox _voice = MakeCombo(DefaultVoices);
    private readonly TextBox _relayAddress = MakeInput(false, 8.25f, "https://…workers.dev");
    private bool _quietVoice;   // the voice list is being refilled: no preview

    private readonly bool _detectedClaude;
    private readonly bool _detectedCodex;
    private bool _installClaude;
    private bool _installCodex;

    // Keys: checked by themselves once pasted (debounced) — no button.
    private (Check State, string Msg) _googleCheck = (Check.Idle, "");
    private (Check State, string Msg) _groqCheck = (Check.Idle, "");
    private readonly System.Windows.Forms.Timer _keyTimer = new() { Interval = 700 };

    private bool _previewLoading;
    private string _notifyMode;

    // Permissions (step 6): Windows has the microphone and notifications (speech recognition,
    // Terminal automation and music, the other macOS rows, don't exist here).
    private readonly Dictionary<Perm, Grant> _perms = new();
    private bool _micAsked;   // the probe ran: Windows had its chance to ask

    // Relay (step 7) and pairing (step 8).
    private RelayChoice _relayChoice = RelayChoice.Public;
    private bool _phoneLater;
    private bool?[] _ownSteps = new bool?[3];   // signed in · deployed · checked
    private bool _ownBusy;
    private string? _ownNote;
    private (Check State, string Msg) _addressCheck = (Check.Idle, "");
    private string? _pairLink;
    private Bitmap? _qr;
    private string? _paired;   // the phone's name once it came onto the relay
    private DateTime _pairShown = DateTime.MaxValue;
    private bool _phonePaired;

    // Tutorial sub-state (the Tutorial step walks TutSteps).
    private int _tutIndex;
    private bool _tutTrying;
    private bool? _tutResult;
    private CancellationTokenSource? _tutorialAudio;
    private int _tutorialGeneration;

    // Clickable areas, collected while painting (logical coordinates).
    private readonly List<(RectangleF Rect, Action Act)> _hits = new();
    private readonly System.Windows.Forms.Timer _tick = new() { Interval = 50 };   // spinners and the pulse

    private static void Open(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }

    // `tutorialOnly`: already onboarded, but the tutorial changed → start at the tutorial.
    public OnboardingForm(bool tutorialOnly = false)
    {
        Text = "Parley";
        AutoScaleMode = AutoScaleMode.None;   // scaled by hand: the canvas below, the controls in PlaceControls
        _s = DeviceDpi / 96f;
        ClientSize = new Size((int)Math.Round(W * _s), (int)Math.Round(H * _s));
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        BackColor = BgBottom;
        DoubleBuffered = true;

        var c = Config.Load();
        var firstRun = !IsComplete();
        _detectedClaude = c.DetectedClaudeCode;
        _detectedCodex = c.DetectedCodex;
        _installClaude = firstRun ? _detectedClaude : c.ClaudeCodeEnabled ?? _detectedClaude;
        _installCodex = firstRun ? _detectedCodex : c.CodexEnabled ?? _detectedCodex;
        _google.Text = c.GoogleKey; _groq.Text = c.GroqKey;
        _lang.SelectedItem = c.Language; if (_lang.SelectedIndex < 0) _lang.SelectedIndex = 0;
        // Star name; seeded from the saved voice so a tutorial-only re-show uses the real voice.
        var star = c.GoogleVoice.Split('-').Last();
        if (star.Length > 0 && !_voice.Items.Contains(star)) _voice.Items.Add(star);
        _voice.SelectedItem = star.Length > 0 ? star : "Alnilam";
        if (_voice.SelectedIndex < 0) _voice.SelectedIndex = 0;
        _notifyMode = c.NotifyMode;
        if (c.RelayUrl.Length > 0 && RelayLink.Normalize(c.RelayUrl) != RelayLink.PublicRelay)
        {
            _relayChoice = RelayChoice.Address;
            _relayAddress.Text = c.RelayUrl;
        }
        _phonePaired = c.PhonePushToken.Length > 0;
        if (tutorialOnly) _step = Step.Tutorial;

        foreach (Control ctl in new Control[] { _google, _groq, _lang, _voice, _relayAddress })
        {
            ctl.Visible = false;
            Controls.Add(ctl);
        }
        _google.TextChanged += (_, _) => { _googleCheck = (Check.Idle, ""); ScheduleCheck(); };
        _groq.TextChanged += (_, _) => { _groqCheck = (Check.Idle, ""); ScheduleCheck(); };
        _keyTimer.Tick += (_, _) => { _keyTimer.Stop(); CheckKeys(); };
        _lang.SelectedIndexChanged += (_, _) => { LoadVoices(); Changed(); };
        _voice.SelectedIndexChanged += (_, _) => { if (!_quietVoice) PreviewVoice(); Changed(); };
        _relayAddress.TextChanged += (_, _) => { _addressCheck = (Check.Idle, ""); Changed(); };
        _relayAddress.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            e.SuppressKeyPress = true;
            CheckAddress();
        };
        _tick.Tick += (_, _) => { if (Animating) Invalidate(); };
        _tick.Start();

        RelayHost.PhoneHelloChanged += OnPhoneHello;
        Activated += (_, _) => RefreshPermissions();
        Shown += (_, _) => { if (_step == Step.Tutorial) PlayTutLine(); };
        FormClosed += (_, _) =>
        {
            RelayHost.PhoneHelloChanged -= OnPhoneHello;
            _tick.Stop(); _keyTimer.Stop();
            StopTutorialAudio();
            VoicePreview.Stop();
            _qr?.Dispose(); _qr = null;
        };
        RefreshPermissions();
        LoadVoices();
        Changed();
    }

    // ----- state ----------------------------------------------------------------------

    private string Lang => _lang.SelectedItem?.ToString() ?? "Deutsch";
    private string Star => _voice.SelectedItem as string ?? "Alnilam";

    private static string LangCode(string lang) => lang switch
    {
        "English" => "en-US", "Français" => "fr-FR", "Español" => "es-ES", "Italiano" => "it-IT", "Nederlands" => "nl-NL", _ => "de-DE",
    };

    // The Chirp3-HD voice picked here (not yet saved), e.g. "de-DE-Chirp3-HD-Alnilam".
    private string SelectedVoice() => $"{LangCode(Lang)}-Chirp3-HD-{Star}";

    private bool CanContinue => _step switch
    {
        Step.Keys => _googleCheck.State == Check.Ok && _groqCheck.State == Check.Ok,   // must verify to proceed
        Step.Permissions => _perms.GetValueOrDefault(Perm.Mic, Grant.Needed) == Grant.Granted,
        Step.Relay => RelayReady,
        Step.Pair => _paired is not null,
        _ => true,
    };

    private bool RelayReady => _relayChoice switch
    {
        RelayChoice.Public => true,
        RelayChoice.Own => _ownSteps[2] == true,
        _ => _addressCheck.State == Check.Ok,
    };

    private bool Animating =>
        _googleCheck.State == Check.Checking || _groqCheck.State == Check.Checking || _ownBusy
        || _addressCheck.State == Check.Checking || _previewLoading || _tutTrying
        || _step == Step.Pair && _paired is null && _pairLink is not null;

    // Unterwegs only once a phone is paired.
    private TutorialStep[] TutSteps =>
        Tutorial.All.Where(s => s != TutorialStep.Away || _paired is not null || _phonePaired).ToArray();
    private TutorialStep TutStep { get { var steps = TutSteps; return steps[Math.Min(_tutIndex, steps.Length - 1)]; } }
    private bool TutLast => _tutIndex >= TutSteps.Length - 1;

    private void Changed()
    {
        if (IsDisposed) return;
        PlaceControls();
        Invalidate();
    }

    // ----- navigation -----------------------------------------------------------------

    private void Next()
    {
        if (_step == Step.Done) return;
        var s = _step + 1;
        // Voice just chosen → render the tutorial in that voice, before anything else needs it.
        if (_step == Step.Voice) { VoicePreview.Stop(); PrepareTutorial(); }
        if (s == Step.Pair && _phoneLater) s = Step.Tutorial;   // no relay set up: no pairing
        Go(s);
    }

    private void Back()
    {
        if (_step == Step.Welcome) return;
        var s = _step - 1;
        if (s == Step.Pair && _phoneLater) s = Step.Relay;
        Go(s);
    }

    private void Later()
    {
        if (_step == Step.Relay) _phoneLater = true;
        Next();
    }

    // What macOS does in the steps' onAppear / onDisappear.
    private void Go(Step s)
    {
        if (_step == Step.Tutorial && s != Step.Tutorial) StopTutorialAudio();
        _step = s;
        switch (s)
        {
            case Step.Keys:
                // Keys already there (setup run again): check them now, not only once edited.
                if (_googleCheck.State == Check.Idle || _groqCheck.State == Check.Idle) CheckKeys();
                break;
            case Step.Permissions: RefreshPermissions(); break;
            case Step.Pair: PreparePairing(); break;
            case Step.Tutorial:
                _phonePaired = Config.Load().PhonePushToken.Length > 0;
                PlayTutLine();
                break;
        }
        Changed();
    }

    // ----- keys -----------------------------------------------------------------------

    private void ScheduleCheck()
    {
        _keyTimer.Stop();
        _keyTimer.Start();
        Changed();
    }

    // Verify the keys present with a tiny live request; updates the per-key status.
    private void CheckKeys()
    {
        var voice = SelectedVoice();
        var google = _google.Text.Trim();
        var groq = _groq.Text.Trim();
        if (google.Length > 0 && _googleCheck.State != Check.Ok) _ = CheckGoogle(google, voice);
        if (groq.Length > 0 && _groqCheck.State != Check.Ok) _ = CheckGroq(groq);
    }

    private async Task CheckGoogle(string key, string voice)
    {
        _googleCheck = (Check.Checking, "");
        Changed();
        var (ok, msg) = await KeyCheck.Google(key, voice);
        if (IsDisposed || key != _google.Text.Trim()) return;
        _googleCheck = (ok ? Check.Ok : Check.Fail, msg);
        if (ok) LoadVoices();
        Changed();
    }

    private async Task CheckGroq(string key)
    {
        _groqCheck = (Check.Checking, "");
        Changed();
        var (ok, msg) = await KeyCheck.Groq(key);
        if (IsDisposed || key != _groq.Text.Trim()) return;
        _groqCheck = (ok ? Check.Ok : Check.Fail, msg);
        Changed();
    }

    // ----- voice ----------------------------------------------------------------------

    // Preview the selected voice — full quality via the user's key, cached; bundled fallback.
    private void PreviewVoice()
    {
        VoicePreview.Play(SelectedVoice(), VoicePreview.Sentence(Lang), _google.Text.Trim(),
            loading => { _previewLoading = loading; Changed(); });
    }

    // Fetch the Chirp3-HD voice list for the chosen language (best-effort).
    private async void LoadVoices()
    {
        var key = _google.Text.Trim();
        if (key.Length == 0) return;
        var code = LangCode(Lang);
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"https://texttospeech.googleapis.com/v1/voices?languageCode={code}");
            req.Headers.Add("X-Goog-Api-Key", key);
            using var r = await Http.SendAsync(req);
            if (!r.IsSuccessStatusCode) return;
            using var doc = JsonDocument.Parse(await r.Content.ReadAsStringAsync());
            if (!doc.RootElement.TryGetProperty("voices", out var arr) || arr.ValueKind != JsonValueKind.Array) return;
            var names = arr.EnumerateArray()
                .Select(v => v.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() ?? "" : "")
                .Where(n => n.Contains("Chirp3-HD"))
                .Select(n => n.Split('-').Last())
                .Where(n => n.Length > 0)
                .Distinct()
                .OrderBy(n => n, StringComparer.Ordinal)
                .ToList();
            if (names.Count == 0 || IsDisposed || code != LangCode(Lang)) return;
            var current = Star;
            _quietVoice = true;
            _voice.BeginUpdate();
            _voice.Items.Clear();
            foreach (var n in names) _voice.Items.Add(n);
            _voice.SelectedItem = names.Contains(current) ? current : names[0];
            _voice.EndUpdate();
            _quietVoice = false;
            Changed();
        }
        catch { _quietVoice = false; }
    }

    // Render the tutorial in the CHOSEN voice — right after the voice step.
    private void PrepareTutorial()
    {
        string lang = Lang, key = _google.Text.Trim(), voice = SelectedVoice();
        _ = Task.Run(() => TutorialClips.Render(lang, key, voice));
    }

    private void ChooseNotify(string mode)
    {
        _notifyMode = mode;
        Notifier.Preview(mode);   // live example on select
        RefreshPermissions();
    }

    // ----- permissions (step 6) ---------------------------------------------------------

    // The rows shown: notifications only when Parley sends any.
    private Perm[] PermissionRows => _notifyMode == "system" ? new[] { Perm.Mic, Perm.Notifications } : new[] { Perm.Mic };

    private void RefreshPermissions()
    {
        if (_perms.GetValueOrDefault(Perm.Mic, Grant.Needed) != Grant.Asking) _perms[Perm.Mic] = MicGrant();
        if (_perms.GetValueOrDefault(Perm.Notifications, Grant.Needed) != Grant.Asking) _perms[Perm.Notifications] = NotificationGrant();
        Changed();
    }

    private const string MicStore = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    private static string? RegValue(RegistryKey root, string path, string name)
    {
        try { using var k = root.OpenSubKey(path); return k?.GetValue(name)?.ToString(); }
        catch { return null; }
    }

    // Settings → Datenschutz → Mikrofon: off for the device, for this user, or for desktop apps =
    // denied. Windows 11 24H2 asks desktop apps once too: until Parley has its own entry there
    // (or the probe ran), it still needs asking.
    private Grant MicGrant()
    {
        if (RegValue(Registry.LocalMachine, MicStore, "Value") == "Deny"
            || RegValue(Registry.CurrentUser, MicStore, "Value") == "Deny"
            || RegValue(Registry.CurrentUser, MicStore + @"\NonPackaged", "Value") == "Deny") return Grant.Denied;
        var exe = Environment.ProcessPath;
        var mine = exe is null ? null : RegValue(Registry.CurrentUser, MicStore + @"\NonPackaged\" + exe.Replace('\\', '#'), "Value");
        if (mine == "Deny") return Grant.Denied;
        if (mine == "Allow" || _micAsked || Environment.OSVersion.Version.Build < 26100) return Grant.Granted;
        return Grant.Needed;
    }

    // Toasts switched off for everything (Settings → System → Benachrichtigungen) = denied.
    private static Grant NotificationGrant()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\PushNotifications");
            return k?.GetValue("ToastEnabled") is int on && on == 0 ? Grant.Denied : Grant.Granted;
        }
        catch { return Grant.Granted; }
    }

    private async Task Request(Perm p)
    {
        _perms[p] = Grant.Asking;
        Changed();
        if (p == Perm.Mic) { await ProbeMic(); _micAsked = true; }
        else Notifier.Preview("system");
        _perms.Remove(p);
        RefreshPermissions();
    }

    // "Alle erlauben": one after the other.
    private async void AllowAll()
    {
        foreach (var p in PermissionRows)
            if (_perms.GetValueOrDefault(p, Grant.Granted) == Grant.Needed) await Request(p);
    }

    private static void OpenSettings(Perm p) => Open(p == Perm.Mic ? "ms-settings:privacy-microphone" : "ms-settings:notifications");

    // Open the microphone briefly — the moment Windows asks a desktop app, if it does.
    private static async Task ProbeMic()
    {
        WasapiCapture? capture = null;
        try
        {
            capture = new WasapiCapture();
            var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            capture.RecordingStopped += (_, _) => stopped.TrySetResult();
            capture.StartRecording();
            await Task.Delay(700);
            capture.StopRecording();
            await Task.WhenAny(stopped.Task, Task.Delay(1000));
        }
        catch (Exception e) { Log.Write($"onboarding: mic probe: {e.Message}"); }
        finally { try { capture?.Dispose(); } catch { } }
    }

    // ----- relay (step 7) and pairing (step 8) -------------------------------------------

    private void ChoosePublicRelay()
    {
        _relayChoice = RelayChoice.Public;
        _phoneLater = false;
        SaveRelayUrl("");   // empty = the public relay (end-to-end encrypted)
        Changed();
    }

    private static void SaveRelayUrl(string url) => Config.Merge(new Dictionary<string, string> { ["relayUrl"] = url });

    private async void OwnRelay()
    {
        _relayChoice = RelayChoice.Own;
        _phoneLater = false;
        if (_ownBusy || _ownSteps[2] == true) { Changed(); return; }
        _ownBusy = true;
        _ownNote = null;
        _ownSteps = new bool?[3];
        Changed();
        try
        {
            if (!await RelaySetup.HasNode())
            {
                _ownNote = "Dafür braucht es Node.js (nodejs.org). Oder fügen Sie rechts die Adresse eines Relais ein.";
                return;
            }
            var dir = await Task.Run(() => RelaySetup.WorkDir());
            if (dir is null) { _ownNote = "Das Relais fehlt in dieser Parley-Version."; return; }
            _ownSteps[0] = await RelaySetup.Login(dir);
            Changed();
            if (_ownSteps[0] != true) { _ownNote = "Die Anmeldung bei Cloudflare hat nicht geklappt."; return; }
            var url = await RelaySetup.Deploy(dir);
            if (url is null)
            {
                _ownSteps[1] = false;
                _ownNote = "Bereitstellen hat nicht geklappt – „Deploy to Cloudflare“ in der Anleitung geht auch.";
                return;
            }
            _ownSteps[1] = true;
            if (!IsDisposed) _relayAddress.Text = url;
            Changed();
            _ownSteps[2] = await RelaySetup.Check(url);
            if (_ownSteps[2] == true) SaveRelayUrl(url);
            else _ownNote = "Das Relais antwortet noch nicht – gleich noch einmal.";
        }
        finally
        {
            _ownBusy = false;
            Changed();
        }
    }

    private void ChooseAddress()
    {
        _relayChoice = RelayChoice.Address;
        _phoneLater = false;
        Changed();
        if (!IsDisposed) _relayAddress.Focus();
    }

    private async void CheckAddress()
    {
        _relayChoice = RelayChoice.Address;
        _phoneLater = false;
        var url = RelayLink.Normalize(_relayAddress.Text);
        if (url.Length == 0) { _addressCheck = (Check.Idle, ""); Changed(); return; }
        _addressCheck = (Check.Checking, "");
        Changed();
        var ok = await RelaySetup.Check(url);
        _addressCheck = ok ? (Check.Ok, "") : (Check.Fail, "kein Parley-Relais");
        if (ok) SaveRelayUrl(url);
        Changed();
    }

    // The QR code for step 8: the relay's pairing page, so a phone without Parley lands there.
    private void PreparePairing()
    {
        _qr?.Dispose(); _qr = null;
        _pairLink = null;
        var c = RelayConfig.Pair();
        if (c is null) return;
        RelayHost.Start?.Invoke();
        _pairLink = RelayLink.PairPage(c);
        _qr = QrCode.Make(_pairLink)?.ToBitmap(0);
        _pairShown = DateTime.UtcNow;
    }

    private void OnPhoneHello()   // on the relay's receive task
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(() => PhoneSaidHello()); } catch { }
    }

    private async void PhoneSaidHello()
    {
        if (_step != Step.Pair || _paired is not null || RelayHost.PhoneHello is not { } hello || hello.At < _pairShown) return;
        _paired = hello.Device;
        Changed();
        await Task.Delay(1400);
        if (!IsDisposed && _step == Step.Pair) Next();
    }

    // ----- tutorial -------------------------------------------------------------------

    // Play the current tutorial step's pre-rendered line.
    private async void PlayTutLine()
    {
        StopTutorialAudio();
        _tutResult = null;
        Changed();
        var generation = ++_tutorialGeneration;
        using var audio = new CancellationTokenSource();
        _tutorialAudio = audio;
        var step = TutStep;
        string lang = Lang, key = _google.Text.Trim(), voice = SelectedVoice();
        try
        {
            var pcm = await TutorialClips.Clip(step, lang, key, voice, audio.Token);
            if (pcm is not null && generation == _tutorialGeneration && !audio.IsCancellationRequested)
            {
                await AudioOut.WaitForHiFiOutput(audio.Token);
                if (!audio.IsCancellationRequested && generation == _tutorialGeneration)
                    await AudioOut.PlayPcm(AudioOut.ApplyRate(pcm, Config.Load().SpeakingRate), cancellationToken: audio.Token);
            }
        }
        catch (OperationCanceledException) { }
        catch { }
        finally
        {
            if (ReferenceEquals(_tutorialAudio, audio)) _tutorialAudio = null;
        }
    }

    private void StopTutorialAudio()
    {
        _tutorialGeneration++;
        _tutorialAudio?.Cancel();
        _tutorialAudio = null;
    }

    private void SkipTutorial()
    {
        if (_step != Step.Tutorial) return;
        StopTutorialAudio();
        Go(Step.Done);
    }

    // Interactive "Ausprobieren": record + check the expected action (with the keys typed here).
    private async void TryTut()
    {
        if (_tutTrying) return;
        StopTutorialAudio();
        _tutTrying = true; _tutResult = null;
        Changed();
        var cfg = new Config { GoogleKey = _google.Text.Trim(), GroqKey = _groq.Text.Trim(), Language = Lang, GoogleVoice = SelectedVoice() };
        var expect = TutStep.Expect();
        try
        {
            var wav = await new MicCapture().Record();
            var text = wav.Length >= 44 + 16000 * 2 / 5 ? await Groq.Transcribe(wav, cfg) : "";
            _tutResult = expect switch
            {
                TutorialExpect.Stop => await Groq.Classify(text, cfg) == Groq.Intent.Stop,
                TutorialExpect.Wait => await Groq.ClassifyWait(text, cfg) > 0,
                _ => true,
            };
        }
        catch { _tutResult = false; }
        _tutTrying = false;
        Changed();
    }

    // Advance within the tutorial; on the last step, continue to the final screen.
    private void TutForward()
    {
        if (TutLast) { StopTutorialAudio(); Next(); return; }
        _tutIndex++;
        PlayTutLine();
    }

    // ----- finish ---------------------------------------------------------------------

    private void Finish()
    {
        StopTutorialAudio();
        VoicePreview.Stop();
        Config.Merge(new Dictionary<string, string>
        {
            ["googleAPIKey"] = _google.Text.Trim(),
            ["groqAPIKey"] = _groq.Text.Trim(),
            ["language"] = Lang,
            ["googleVoice"] = SelectedVoice(),
            ["notifyMode"] = _notifyMode,
            ["claudeCodeEnabled"] = _installClaude ? "1" : "0",
            ["codexEnabled"] = _installCodex ? "1" : "0",
            ["onboarded"] = "1",
            ["tutorialSeen"] = TutorialClips.Version.ToString(CultureInfo.InvariantCulture),
        });
        IntegrationSync.Apply();
        RelayHost.Start?.Invoke();
    }

    public static bool NeedsTutorial()
    {
        try
        {
            var d = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(Config.CredentialsPath));
            var seen = d != null && d.TryGetValue("tutorialSeen", out var v) && v.ValueKind == JsonValueKind.String
                ? (int.TryParse(v.GetString(), out var n) ? n : 0) : 0;
            return seen < TutorialClips.Version;
        }
        catch { return true; }
    }

    public static bool IsComplete()
    {
        try
        {
            var d = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(Config.CredentialsPath));
            return d != null && d.TryGetValue("onboarded", out var v) && v.ValueKind == JsonValueKind.String && v.GetString() == "1";
        }
        catch { return false; }
    }

    // ----- layout of the real controls (same numbers as the painting) ---------------------

    private Rectangle Px(float x, float y, float w, float h) =>
        Rectangle.Round(new RectangleF(x * _s, y * _s, w * _s, h * _s));

    private const float HeroSymbolH = 216, HeroIconH = 248;   // echo + title + subtitle
    private static float CenterTop(float height) => 275 - height / 2;   // between the dots and the buttons

    private static float KeysTop => CenterTop(HeroSymbolH + 16 + 72 * 2 + 10);
    private static RectangleF KeyCard(int i) => new(ContentX, KeysTop + HeroSymbolH + 16 + i * 82, ContentW, 72);
    private static float KeyStatusW((Check State, string Msg) c) => c.State == Check.Fail ? 190 : 76;

    private static float VoiceTop => CenterTop(HeroSymbolH + 18 + 136);
    private static RectangleF VoiceCard => new(ContentX, VoiceTop + HeroSymbolH + 18, ContentW, 136);

    private const float RelayTop = 56;   // fixed: the cards grow downwards as the setup reports
    private static RectangleF PublicCard => new(ContentX, RelayTop + HeroSymbolH + 16, ContentW, 56);
    private static float RelayRowY => PublicCard.Bottom + 10;
    private const float HalfW = (ContentW - 10) / 2;

    private void PlaceControls()
    {
        _google.Visible = _groq.Visible = _step == Step.Keys;
        _lang.Visible = _voice.Visible = _step == Step.Voice;
        _relayAddress.Visible = _step == Step.Relay && _relayChoice == RelayChoice.Address;
        if (_step == Step.Keys)
        {
            var g = KeyCard(0);
            _google.Bounds = Px(g.X + 12, g.Y + 38, g.Width - 24 - KeyStatusW(_googleCheck) - 10, 24);
            var q = KeyCard(1);
            _groq.Bounds = Px(q.X + 12, q.Y + 38, q.Width - 24 - KeyStatusW(_groqCheck) - 10, 24);
        }
        if (_step == Step.Voice)
        {
            var c = VoiceCard;
            _lang.Bounds = Px(c.X + 90, c.Y + 8, c.Width - 104, 24);
            _voice.Bounds = Px(c.X + 90, c.Y + 49, c.Width - 104, 24);
        }
        if (_relayAddress.Visible)
            _relayAddress.Bounds = Px(ContentX + HalfW + 10 + 12, RelayRowY + 57, HalfW - 24, 24);
    }

    // ----- painting -------------------------------------------------------------------

    protected override void OnPaintBackground(PaintEventArgs e) { }   // OnPaint covers it all

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        g.ScaleTransform(_s, _s);
        _hits.Clear();

        using (var bg = new LinearGradientBrush(new RectangleF(0, 0, W, H + 1), BgTop, BgBottom, LinearGradientMode.Vertical))
            g.FillRectangle(bg, 0, 0, W, H + 1);
        PaintProgress(g);
        switch (_step)
        {
            case Step.Welcome:
                Hero(g, CenterTop(HeroIconH), null, "Guten Tag, Sir.", "Parley spricht Claude Codes Antworten – und hört Ihre.");
                break;
            case Step.Integrations: PaintIntegrations(g); break;
            case Step.Keys: PaintKeys(g); break;
            case Step.Voice: PaintVoice(g); break;
            case Step.Notify: PaintNotify(g); break;
            case Step.Permissions: PaintPermissions(g); break;
            case Step.Relay: PaintRelay(g); break;
            case Step.Pair: PaintPair(g); break;
            case Step.Tutorial: PaintTutorial(g); break;
            case Step.Done: PaintDone(g); break;
        }
        PaintBottomBar(g);
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (e.Button != MouseButtons.Left) return;
        var p = new PointF(e.X / _s, e.Y / _s);
        for (var i = _hits.Count - 1; i >= 0; i--)
            if (_hits[i].Rect.Contains(p)) { _hits[i].Act(); return; }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var p = new PointF(e.X / _s, e.Y / _s);
        var hand = _hits.Any(h => h.Rect.Contains(p));
        Cursor = hand ? Cursors.Hand : Cursors.Default;
    }

    private void Hit(RectangleF r, Action act) => _hits.Add((r, act));

    // Ten dots: the current one long, the done ones in muted clay.
    private void PaintProgress(Graphics g)
    {
        const int total = 10;
        var cur = (int)_step;
        var width = (total - 1) * 6 + 18 + (total - 1) * 5f;
        var x = (W - width) / 2;
        for (var i = 0; i < total; i++)
        {
            var w = i == cur ? 18f : 6f;
            var c = i == cur ? Clay : i < cur ? A(Clay, 0.45f) : A(Color.White, 0.16f);
            using var b = new SolidBrush(c);
            FillRound(g, b, new RectangleF(x, 20, w, 6), 3);
            x += w + 5;
        }
    }

    // The echo: a round badge with three concentric clay rings; null symbol = the app's icon.
    private static float Echo(Graphics g, float top, string? symbol)
    {
        var inner = symbol is null ? 92f : 60f;
        var height = inner + 86;
        float cx = W / 2, cy = top + height / 2;
        for (var i = 0; i < 3; i++)
        {
            var d = inner + 30 + i * 28;
            using var pen = new Pen(A(Clay, 0.32f - i * 0.09f), 1.2f);
            g.DrawEllipse(pen, cx - d / 2, cy - d / 2, d, d);
        }
        if (symbol is not null)
        {
            using (var fill = new SolidBrush(A(Clay, 0.14f))) g.FillEllipse(fill, cx - inner / 2, cy - inner / 2, inner, inner);
            using (var ring = new Pen(A(Clay, 0.35f), 1f)) g.DrawEllipse(ring, cx - inner / 2, cy - inner / 2, inner, inner);
            DrawIcon(g, symbol, new RectangleF(cx - 12, cy - 12, 24, 24), Clay, 2f);
        }
        else if (AppIconImage() is { } icon)
        {
            var side = inner * 0.82f;   // the macOS icon keeps a margin inside its frame
            var state = g.Save();
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(icon, cx - side / 2, cy - side / 2, side, side);
            g.Restore(state);
        }
        return height;
    }

    private static float Hero(Graphics g, float top, string? symbol, string title, string subtitle)
    {
        var y = top + Echo(g, top, symbol) + 10;
        CenterText(g, title, F(26, FontStyle.Bold), TextPrimary, y, 34);
        y += 34 + 8;
        // One line: shrink a little rather than wrap (macOS: minimumScaleFactor 0.85).
        var font = F(13);
        var width = g.MeasureString(subtitle, font).Width;
        if (width > ContentW) font = F(Math.Max(13 * 0.85f, 13 * ContentW / width));
        CenterText(g, subtitle, font, TextMuted, y, 18);
        return y + 18;
    }

    private void PaintIntegrations(Graphics g)
    {
        var none = !_detectedClaude && !_detectedCodex;
        var top = CenterTop(HeroSymbolH + 18 + 122 + (none ? 30 : 0));
        var y = Hero(g, top, "swap", "Wo soll Parley laufen?", "Erkannte Clients sind schon ausgewählt.") + 18;
        IntegrationCard(g, new RectangleF(ContentX, y, ContentW, 56), true, "Claude Code", "Stop-Hook und /parley:voice");
        IntegrationCard(g, new RectangleF(ContentX, y + 66, ContentW, 56), false, "Codex", "Plugin und $parley-voice");
        if (none)
        {
            var ly = y + 122 + 14;
            var f = F(11);
            var parts = new[] { "Kein Client gefunden.", "Claude Code installieren", "Codex installieren" };
            var widths = parts.Select(p => g.MeasureString(p, f).Width).ToArray();
            var x = (W - (widths.Sum() + 20)) / 2;
            Write(g, parts[0], f, TextMuted, x, ly);
            x += widths[0] + 10;
            Write(g, parts[1], f, Clay, x, ly);
            Hit(new RectangleF(x, ly, widths[1], 16), () => Open("https://docs.anthropic.com/en/docs/claude-code/overview"));
            x += widths[1] + 10;
            Write(g, parts[2], f, Clay, x, ly);
            Hit(new RectangleF(x, ly, widths[2], 16), () => Open("https://developers.openai.com/codex/cli"));
        }
    }

    private void IntegrationCard(Graphics g, RectangleF r, bool claude, string title, string subtitle)
    {
        var detected = claude ? _detectedClaude : _detectedCodex;
        var on = claude ? _installClaude : _installCodex;
        ChoiceCard(g, r, on);
        var cy = r.Y + r.Height / 2;
        DrawBrandIcon(g, claude ? "claude-code" : "codex", new RectangleF(r.X + 12, cy - 13, 26, 26));
        var tf = Semi(14);
        Write(g, title, tf, TextPrimary, r.X + 48, cy - 20);
        if (detected) Badge(g, "erkannt", r.X + 48 + g.MeasureString(title, tf).Width + 2, cy - 17);
        Write(g, detected ? subtitle : "Nicht gefunden – später verbinden", F(11), TextMuted, r.X + 48, cy + 1);
        var dot = new RectangleF(r.Right - 12 - 16, cy - 8, 16, 16);
        if (on) using (var b = new SolidBrush(Clay)) g.FillEllipse(b, dot);
        using (var pen = new Pen(on ? Clay : A(Color.White, 0.3f), 1.5f)) g.DrawEllipse(pen, dot.X + 0.75f, dot.Y + 0.75f, 14.5f, 14.5f);
        if (!detected)
        {
            using var dim = new SolidBrush(Color.FromArgb(115, 36, 32, 31));   // opacity 0.55
            g.FillRectangle(dim, RectangleF.Inflate(r, 1, 1));
            return;
        }
        Hit(r, () =>
        {
            if (claude) _installClaude = !_installClaude; else _installCodex = !_installCodex;
            Changed();
        });
    }

    private void PaintKeys(Graphics g)
    {
        Hero(g, KeysTop, "key", "Zwei Schlüssel", "Beide praktisch gratis. Einfügen – Parley prüft sofort.");
        KeyCardPaint(g, KeyCard(0), "Google Cloud TTS", "1 Mio. Zeichen gratis", _googleCheck, () => Open(GoogleConsoleUrl));
        KeyCardPaint(g, KeyCard(1), "Groq", "Developer-Key", _groqCheck, () => Open(GroqConsoleUrl));
    }

    private void KeyCardPaint(Graphics g, RectangleF r, string label, string hint, (Check State, string Msg) check, Action open)
    {
        Card(g, r);
        var lf = Semi(13);
        Write(g, label, lf, TextPrimary, r.X + 12, r.Y + 11);
        Write(g, "· " + hint, F(11), TextMuted, r.X + 12 + g.MeasureString(label, lf).Width, r.Y + 13);
        var link = Semi(11);
        var lw = g.MeasureString("Konsole öffnen", link).Width;
        var lr = new RectangleF(r.Right - 12 - lw, r.Y + 12, lw, 16);
        Write(g, "Konsole öffnen", link, Clay, lr.X, lr.Y);
        Hit(lr, open);
        Status(g, check, "", new RectangleF(r.Right - 12 - KeyStatusW(check), r.Y + 38, KeyStatusW(check), 24), StringAlignment.Far);
    }

    // idle / "prüfe …" / "gültig" / the reason, with its mark — right- or left-aligned in `r`.
    private void Status(Graphics g, (Check State, string Msg) check, string idle, RectangleF r, StringAlignment align)
    {
        var cy = r.Y + r.Height / 2;
        string text;
        Color color;
        Font font;
        switch (check.State)
        {
            case Check.Idle:
                if (idle.Length == 0) return;
                Write(g, idle, F(10), TextFaint, align == StringAlignment.Far ? r.Right - g.MeasureString(idle, F(10)).Width : r.X, cy - 7);
                return;
            case Check.Checking: text = "prüfe …"; color = TextMuted; font = F(10); break;
            case Check.Ok: text = "gültig"; color = Green; font = Semi(10); break;
            default: text = check.Msg; color = Red; font = F(10); break;
        }
        var tw = g.MeasureString(text, font).Width;
        var x = align == StringAlignment.Far ? r.Right - tw - 16 : r.X;
        var mark = new RectangleF(x, cy - 6, 12, 12);
        if (check.State == Check.Checking) Spinner(g, mark);
        else DrawIcon(g, check.State == Check.Ok ? "checkcircle" : "xcircle", mark, color, 1.5f);
        Write(g, text, font, color, x + 15, cy - 7);
    }

    private void PaintVoice(Graphics g)
    {
        Hero(g, VoiceTop, "globe", "Sprache & Stimme", "Worin spreche ich, und mit welcher Stimme?");
        var c = VoiceCard;
        Card(g, c);
        var label = F(12);
        Write(g, "Sprache", label, TextMuted, c.X + 14, c.Y + 12);
        Divider(g, c.X, c.Y + 40, c.Width);
        Write(g, "Stimme", label, TextMuted, c.X + 14, c.Y + 53);
        Divider(g, c.X, c.Y + 81, c.Width);
        var cy = c.Y + 82 + 27;
        var play = new RectangleF(c.X + 14, cy - 15, 30, 30);
        using (var b = new SolidBrush(_previewLoading ? A(Clay, 0.6f) : Clay)) g.FillEllipse(b, play);
        DrawIcon(g, _previewLoading ? "dots" : "play", RectangleF.Inflate(play, -9, -9), Color.White, 2f);
        if (!_previewLoading) Hit(play, PreviewVoice);
        var hw = g.MeasureString("Hörprobe", F(11)).Width;
        Write(g, "Hörprobe", F(11), TextMuted, c.Right - 14 - hw, cy - 8);
        Waveform(g, new RectangleF(play.Right + 12, cy - 11, c.Right - 14 - hw - 12 - (play.Right + 12), 22));
    }

    // A still waveform for the voice preview row.
    private static void Waveform(Graphics g, RectangleF r)
    {
        using var b = new SolidBrush(Clay);
        var n = (int)(r.Width / 4);
        for (var i = 0; i < n; i++)
        {
            var h = Math.Max(3f, r.Height * (float)(0.25 + 0.75 * Math.Abs(Math.Sin(i * 0.9) * Math.Cos(i * 0.23))));
            FillRound(g, b, new RectangleF(r.X + i * 4, r.Y + (r.Height - h) / 2, 2, h), 1);
        }
    }

    private void PaintNotify(Graphics g)
    {
        var y = Hero(g, CenterTop(HeroSymbolH + 18 + 120), "bellbadge", "Benachrichtigungen", "Wie sage ich Bescheid, wenn ein Projekt wartet?") + 18;
        var w = (ContentW - 20) / 3;
        NotifyCard(g, new RectangleF(ContentX, y, w, 120), "In der Pill", "Unten mittig", "pill");
        NotifyCard(g, new RectangleF(ContentX + w + 10, y, w, 120), "Mitteilung", "Windows-Standard", "system");
        NotifyCard(g, new RectangleF(ContentX + 2 * (w + 10), y, w, 120), "Keine", "Ganz still", "none");
    }

    private void NotifyCard(Graphics g, RectangleF r, string title, string subtitle, string value)
    {
        ChoiceCard(g, r, _notifyMode == value);
        var preview = new RectangleF(r.X + 10, r.Y + 10, r.Width - 20, 56);
        using (var b = new SolidBrush(A(Color.Black, 0.35f))) FillRound(g, b, preview, 7);
        if (value == "pill")
            using (var b = new SolidBrush(Clay)) FillRound(g, b, new RectangleF(preview.X + (preview.Width - 64) / 2, preview.Bottom - 9 - 9, 64, 9), 4.5f);
        else if (value == "system")
            using (var b = new SolidBrush(A(Color.White, 0.22f))) FillRound(g, b, new RectangleF(preview.Right - 7 - 52, preview.Y + 7, 52, 15), 4);
        DrawIcon(g, value == "pill" ? "wave" : value == "system" ? "bell" : "off", new RectangleF(r.X + 10, r.Y + 76, 13, 13), TextPrimary, 1.4f);
        Write(g, title, Semi(12), TextPrimary, r.X + 27, r.Y + 74);
        Write(g, subtitle, F(10), TextMuted, r.X + 10, r.Y + 95);
        Hit(r, () => ChooseNotify(value));
    }

    private void PaintPermissions(Graphics g)
    {
        var rows = PermissionRows;
        var y = Hero(g, CenterTop(HeroSymbolH + 16 + 50 * rows.Length), "hand", "Berechtigungen", "Einmal erlauben – danach fragt Parley nie wieder.") + 16;
        var card = new RectangleF(ContentX, y, ContentW, 50 * rows.Length);
        Card(g, card);
        for (var i = 0; i < rows.Length; i++)
        {
            if (i > 0) Divider(g, card.X, card.Y + 50 * i, card.Width);
            PermissionRow(g, new RectangleF(card.X, card.Y + 50 * i, card.Width, 50), rows[i]);
        }
    }

    private void PermissionRow(Graphics g, RectangleF r, Perm p)
    {
        var (symbol, title, subtitle) = p == Perm.Mic
            ? ("mic", "Mikrofon", "Ihre Antworten aufnehmen")
            : ("bell", "Mitteilungen", "Wenn ein Projekt wartet");
        var cy = r.Y + r.Height / 2;
        var tile = new RectangleF(r.X + 12, cy - 14, 28, 28);
        using (var b = new SolidBrush(A(Color.White, 0.06f))) FillRound(g, b, tile, 7);
        DrawIcon(g, symbol, RectangleF.Inflate(tile, -7, -7), Clay, 1.5f);
        Write(g, title, Semi(13), TextPrimary, r.X + 52, cy - 18);
        Write(g, subtitle, F(11), TextMuted, r.X + 52, cy + 1);
        var right = r.Right - 12;
        switch (_perms.GetValueOrDefault(p, Grant.Needed))
        {
            case Grant.Granted:
            {
                var f = Semi(11);
                var tw = g.MeasureString("erlaubt", f).Width;
                Write(g, "erlaubt", f, Green, right - tw, cy - 8);
                DrawIcon(g, "checkcircle", new RectangleF(right - tw - 15, cy - 6, 12, 12), Green, 1.5f);
                break;
            }
            case Grant.Asking:
            {
                var f = F(11);
                Write(g, "Windows fragt …", f, TextMuted, right - g.MeasureString("Windows fragt …", f).Width, cy - 8);
                break;
            }
            case Grant.Denied:
                LinkRight(g, "Einstellungen öffnen", right, cy, () => OpenSettings(p));
                break;
            default:
                LinkRight(g, "Erlauben", right, cy, () => _ = Request(p));
                break;
        }
    }

    private void LinkRight(Graphics g, string text, float right, float cy, Action act)
    {
        var f = Semi(11);
        var tw = g.MeasureString(text, f).Width;
        var r = new RectangleF(right - tw, cy - 9, tw, 18);
        Write(g, text, f, Clay, r.X, cy - 8);
        Hit(r, act);
    }

    private void PaintRelay(Graphics g)
    {
        Hero(g, RelayTop, "antenna", "Parley aufs Handy", "Unterwegs klingelt Parley auf Ihrem Handy – über ein kleines Relais.");

        // Parleys Relais
        var pub = PublicCard;
        ChoiceCard(g, pub, _relayChoice == RelayChoice.Public);
        var cy = pub.Y + pub.Height / 2;
        DrawIcon(g, "shield", new RectangleF(pub.X + 12, cy - 7, 14, 14), Clay, 1.5f);
        Write(g, "Parleys Relais", Semi(13), TextPrimary, pub.X + 34, cy - 18);
        Write(g, "Sofort bereit · Ende-zu-Ende verschlüsselt", F(11), TextMuted, pub.X + 34, cy + 1);
        var bw = g.MeasureString("empfohlen", Semi(10)).Width + 8;
        Badge(g, "empfohlen", pub.Right - 12 - bw, cy - 8);
        Hit(pub, ChoosePublicRelay);

        // Eigenes Relais · 1 Klick
        var y = RelayRowY;
        var inner = HalfW - 24;
        var own = _relayChoice == RelayChoice.Own;
        float ownH = 12 + 18 + 6;
        var noteH = 0f;
        if (own)
        {
            ownH += 3 * 15 + 2 * 6;
            if (_ownNote is { } note) { noteH = g.MeasureString(note, F(10), (int)inner).Height; ownH += 6 + noteH; }
            if (_relayAddress.Text.Length > 0 && _ownSteps[1] == true) ownH += 6 + 13;
        }
        else ownH += g.MeasureString("Ihr Cloudflare-Konto, kostenlos. Sie bestätigen nur im Browser.", F(11), (int)inner).Height;
        ownH += 12;
        var oc = new RectangleF(ContentX, y, HalfW, ownH);
        ChoiceCard(g, oc, own);
        DrawIcon(g, "cloud", new RectangleF(oc.X + 12, oc.Y + 14, 15, 15), Clay, 1.5f);
        Write(g, "Eigenes Relais", Semi(13), TextPrimary, oc.X + 32, oc.Y + 11);
        var kw = g.MeasureString("1 Klick", Semi(10)).Width;
        Write(g, "1 Klick", Semi(10), Clay, oc.Right - 12 - kw, oc.Y + 14);
        var ly = oc.Y + 12 + 18 + 6;
        if (own)
        {
            CheckLine(g, "Bei Cloudflare angemeldet", _ownSteps[0], oc.X + 12, ly);
            CheckLine(g, "Relais bereitgestellt", _ownSteps[1], oc.X + 12, ly + 21);
            CheckLine(g, "Verbindung geprüft", _ownSteps[2], oc.X + 12, ly + 42);
            ly += 3 * 15 + 2 * 6;
            if (_ownNote is { } note)
            {
                using var b = new SolidBrush(Orange);
                g.DrawString(note, F(10), b, new RectangleF(oc.X + 12, ly + 6, inner, noteH + 2));
                ly += 6 + noteH;
            }
            if (_relayAddress.Text.Length > 0 && _ownSteps[1] == true)
                Write(g, _relayAddress.Text.Replace("https://", ""), F(10, FontStyle.Regular, "Consolas"), TextMuted, oc.X + 12, ly + 6);
        }
        else
        {
            using var b = new SolidBrush(TextMuted);
            g.DrawString("Ihr Cloudflare-Konto, kostenlos. Sie bestätigen nur im Browser.", F(11), b, new RectangleF(oc.X + 12, ly, inner, 40));
        }
        Hit(oc, OwnRelay);

        // Adresse einfügen
        var address = _relayChoice == RelayChoice.Address;
        var ac = new RectangleF(ContentX + HalfW + 10, y, HalfW, address ? 113 : 63);
        ChoiceCard(g, ac, address);
        DrawIcon(g, "link", new RectangleF(ac.X + 12, ac.Y + 14, 14, 14), Clay, 1.5f);
        Write(g, "Adresse einfügen", Semi(13), TextPrimary, ac.X + 32, ac.Y + 11);
        Write(g, "Sie haben schon ein Relais.", F(11), TextMuted, ac.X + 12, ac.Y + 36);
        if (address) Status(g, _addressCheck, "Eingabe drücken zum Prüfen", new RectangleF(ac.X + 12, ac.Y + 87, inner, 14), StringAlignment.Near);
        Hit(ac, ChooseAddress);
    }

    private void CheckLine(Graphics g, string text, bool? done, float x, float y)
    {
        var mark = new RectangleF(x + 1, y + 1.5f, 12, 12);
        switch (done)
        {
            case true: DrawIcon(g, "checkcircle", mark, Green, 1.5f); break;
            case false: DrawIcon(g, "xcircle", mark, Red, 1.5f); break;
            default:
                if (_ownBusy) Spinner(g, mark);
                else using (var pen = new Pen(TextFaint, 1.2f)) g.DrawEllipse(pen, mark);
                break;
        }
        Write(g, text, F(11), TextPrimary, x + 20, y);
    }

    private void PaintPair(Graphics g)
    {
        const float cx = 194, cy = 275;
        for (var i = 0; i < 3; i++)
        {
            var d = 230 + i * 46f;
            using var pen = new Pen(A(Clay, 0.28f - i * 0.08f), 1.2f);
            g.DrawEllipse(pen, cx - d / 2, cy - d / 2, d, d);
        }
        var box = new RectangleF(cx - 97, cy - 97, 194, 194);
        if (_qr is not null)
        {
            using (var white = new SolidBrush(Color.White)) FillRound(g, white, box, 16);
            var state = g.Save();
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.SmoothingMode = SmoothingMode.None;
            g.DrawImage(_qr, new RectangleF(box.X + 12, box.Y + 12, 170, 170));
            g.Restore(state);
        }
        else
        {
            using (var dim = new SolidBrush(A(Color.White, 0.06f))) FillRound(g, dim, box, 16);
            CenterTextIn(g, "Kein Relais", F(13), TextMuted, box);
        }

        const float x = 335;
        var y = cy - 153 / 2f;
        Write(g, "Handy koppeln", F(24, FontStyle.Bold), TextPrimary, x - 2, y);
        y += 32 + 6;
        Write(g, "Mit der Kamera scannen – fertig.", F(13), TextMuted, x, y);
        y += 18 + 10;
        foreach (var (icon, hint) in new[] { ("phone", "Öffnet Parley oder führt zum Download"), ("lock", "Verschlüsselt, nur Ihr Raum"), ("antenna", "Android genauso") })
        {
            DrawIcon(g, icon, new RectangleF(x + 1, y + 2, 13, 13), Clay, 1.4f);
            Write(g, hint, F(12), TextPrimary, x + 22, y);
            y += 18 + 7;
        }
        y += 7;
        if (_paired is { } name)
        {
            DrawIcon(g, "checkcircle", new RectangleF(x + 1, y + 2, 13, 13), Green, 1.5f);
            Write(g, $"Verbunden mit {name}", Semi(12), Green, x + 22, y);
        }
        else
        {
            // The pulse (macOS: symbolEffect(.pulse)) while the code is up.
            var pulse = _pairLink is null ? 1f : 0.55f + 0.45f * (float)Math.Abs(Math.Sin(Environment.TickCount64 / 450.0));
            DrawIcon(g, "antenna", new RectangleF(x + 1, y + 2, 13, 13), A(Clay, pulse), 1.4f);
            Write(g, "Warte auf Ihr Handy …", Semi(12), A(Clay, pulse), x + 22, y);
        }
    }

    private void PaintTutorial(Graphics g)
    {
        var step = TutStep;
        var steps = TutSteps;
        var quote = $"„{step.DisplayLine(Lang)}“";
        var qf = F(16, FontStyle.Italic);
        using var center = new StringFormat { Alignment = StringAlignment.Center };
        var qh = g.MeasureString(quote, qf, (int)ContentW, center).Height;
        var tries = step.Expect() != TutorialExpect.None;
        var top = CenterTop(146 + 16 + 16 + 16 + qh + (tries ? 16 + 32 : 0));
        var y = top + Echo(g, top, "speaker") + 16;
        var label = $"PROBE {_tutIndex + 1} VON {steps.Length} · {step.Title(Lang).ToUpper(CultureInfo.GetCultureInfo("de-DE"))}";
        CenterText(g, label, F(11, FontStyle.Bold), Clay, y, 16);
        y += 16 + 16;
        using (var b = new SolidBrush(TextPrimary)) g.DrawString(quote, qf, b, new RectangleF(ContentX, y, ContentW, qh + 2), center);
        y += qh + 16;
        if (!tries) return;
        var bf = Semi(13);
        var bText = _tutTrying ? "Höre zu …" : "Ausprobieren";
        var bw = 14 + 6 + g.MeasureString(bText, bf).Width + 28;
        string? result = _tutResult is bool ok ? (ok ? "Genau so, Sir." : "Nicht erkannt – kein Problem.") : null;
        var rf = Semi(12);
        var rw = result is null ? 0 : 10 + 17 + g.MeasureString(result, rf).Width;
        var x = (W - bw - rw) / 2;
        var button = new RectangleF(x, y, bw, 32);
        using (var b = new SolidBrush(A(Color.White, 0.08f))) FillRound(g, b, button, 8);
        DrawIcon(g, "mic", new RectangleF(x + 14, y + 9, 14, 14), _tutTrying ? TextMuted : TextPrimary, 1.5f);
        Write(g, bText, bf, _tutTrying ? TextMuted : TextPrimary, x + 14 + 18, y + 7);
        if (!_tutTrying) Hit(button, TryTut);
        if (result is not null && _tutResult is bool good)
        {
            var color = good ? Green : TextMuted;
            var rx = button.Right + 10;
            DrawIcon(g, good ? "checkcircle" : "info", new RectangleF(rx, y + 10, 12, 12), color, 1.5f);
            Write(g, result, rf, color, rx + 17, y + 8);
        }
    }

    private void PaintDone(Graphics g)
    {
        var clients = (_installClaude ? 1 : 0) + (_installCodex ? 1 : 0);
        var listH = clients == 0 ? 16 : clients * 48 + (clients - 1) * 10;
        var y = Hero(g, CenterTop(HeroIconH + 16 + listH), null, "Bereit, Sir.", "Tippen Sie das in einer neuen Session – dann bin ich da.") + 16;
        if (_installClaude) { CommandCard(g, y, "claude-code", "Claude Code", "/parley:voice"); y += 58; }
        if (_installCodex) { CommandCard(g, y, "codex", "Codex", "$parley-voice"); y += 58; }
        if (clients == 0) CenterText(g, "Die Clients lassen sich später im Setup verbinden.", F(12), TextMuted, y, 16);
    }

    private void CommandCard(Graphics g, float y, string icon, string name, string command)
    {
        var r = new RectangleF(ContentX, y, ContentW, 48);
        Card(g, r);
        var cy = r.Y + r.Height / 2;
        DrawBrandIcon(g, icon, new RectangleF(r.X + 14, cy - 13, 26, 26));
        Write(g, name, Semi(13), TextPrimary, r.X + 52, cy - 9);
        var lf = Semi(11);
        var lw = g.MeasureString("Kopieren", lf).Width;
        var copy = new RectangleF(r.Right - 14 - lw, cy - 9, lw, 18);
        Write(g, "Kopieren", lf, Clay, copy.X, cy - 8);
        Hit(copy, () => { try { Clipboard.SetText(command); } catch { } });
        var cf = F(13, FontStyle.Bold, "Consolas");
        var cw = g.MeasureString(command, cf).Width;
        var pill = new RectangleF(copy.X - 12 - cw - 12, cy - 12, cw + 12, 24);
        using (var b = new SolidBrush(A(Color.Black, 0.3f))) FillRound(g, b, pill, 6);
        Write(g, command, cf, TextPrimary, pill.X + 6, cy - 9);
    }

    private void PaintBottomBar(Graphics g)
    {
        const float y = H - 24 - 32;
        if (_step != Step.Welcome) PillButton(g, 36, y, "Zurück", false, true, Back, leftAligned: true);
        var buttons = new List<(string Label, bool Primary, bool Enabled, Action Act)>();
        switch (_step)
        {
            case Step.Welcome: buttons.Add(("Einrichten · 2 Min.", true, true, Next)); break;
            case Step.Done: buttons.Add(("Los geht's", true, true, () => { Finish(); Close(); })); break;
            case Step.Tutorial:
                buttons.Add(("Überspringen", false, true, SkipTutorial));
                buttons.Add((TutLast ? "Fertig" : "Weiter", true, true, TutForward));
                break;
            case Step.Permissions:
                if (PermissionRows.Any(p => _perms.GetValueOrDefault(p, Grant.Granted) == Grant.Needed))
                    buttons.Add(("Alle erlauben", false, true, AllowAll));
                buttons.Add(("Weiter", true, CanContinue, Next));
                break;
            case Step.Relay:
            case Step.Pair:
                buttons.Add(("Später", false, true, Later));
                buttons.Add(("Weiter", true, CanContinue, Next));
                break;
            default: buttons.Add(("Weiter", true, CanContinue, Next)); break;
        }
        var right = W - 36;
        for (var i = buttons.Count - 1; i >= 0; i--)
        {
            var b = buttons[i];
            right = PillButton(g, right, y, b.Label, b.Primary, b.Enabled, b.Act, leftAligned: false) - 10;
        }
    }

    // A rounded button at `x` (its left edge, or its right edge); returns the far edge.
    private float PillButton(Graphics g, float x, float y, string label, bool primary, bool enabled, Action act, bool leftAligned)
    {
        var f = Semi(13);
        var w = g.MeasureString(label, f).Width + (primary ? 36 : 28);
        var r = new RectangleF(leftAligned ? x : x - w, y, w, 32);
        var fill = primary ? (enabled ? Clay : Blend(Clay, 0.35f)) : A(Color.White, 0.08f);
        using (var b = new SolidBrush(fill)) FillRound(g, b, r, 8);
        var color = primary ? (enabled ? Color.White : A(Color.White, 0.45f)) : TextPrimary;
        CenterTextIn(g, label, f, color, r);
        if (enabled) Hit(r, act);
        return leftAligned ? r.Right : r.X;
    }

    // ----- building blocks ------------------------------------------------------------

    private static Color A(Color c, float alpha) => Color.FromArgb((int)Math.Clamp(alpha * 255, 0, 255), c.R, c.G, c.B);

    // `c` at `alpha` over the (darker) background — for fills that must stay opaque.
    private static Color Blend(Color c, float alpha) => Color.FromArgb(
        (int)(c.R * alpha + BgBottom.R * (1 - alpha)), (int)(c.G * alpha + BgBottom.G * (1 - alpha)), (int)(c.B * alpha + BgBottom.B * (1 - alpha)));

    private static readonly Dictionary<(string, float, FontStyle), Font> Fonts = new();

    // Fonts in logical pixels: the DPI scale comes from the Graphics transform.
    private static Font F(float px, FontStyle style = FontStyle.Regular, string family = "Segoe UI")
    {
        var key = (family, px, style);
        if (!Fonts.TryGetValue(key, out var f)) Fonts[key] = f = new Font(family, px, style, GraphicsUnit.Pixel);
        return f;
    }

    private static Font Semi(float px) => F(px, FontStyle.Regular, "Segoe UI Semibold");

    private static void Write(Graphics g, string s, Font f, Color c, float x, float y)
    {
        using var b = new SolidBrush(c);
        g.DrawString(s, f, b, x, y);
    }

    private static void CenterText(Graphics g, string s, Font f, Color c, float y, float h) =>
        CenterTextIn(g, s, f, c, new RectangleF(0, y, W, h));

    private static void CenterTextIn(Graphics g, string s, Font f, Color c, RectangleF r)
    {
        using var b = new SolidBrush(c);
        using var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center, FormatFlags = StringFormatFlags.NoWrap };
        g.DrawString(s, f, b, r, sf);
    }

    private static void Card(Graphics g, RectangleF r)
    {
        using (var b = new SolidBrush(A(Color.White, 0.05f))) FillRound(g, b, r, 12);
        using (var p = new Pen(A(Color.White, 0.08f), 1f)) DrawRound(g, p, RectangleF.Inflate(r, -0.5f, -0.5f), 12);
    }

    private static void ChoiceCard(Graphics g, RectangleF r, bool selected)
    {
        using (var b = new SolidBrush(selected ? A(Clay, 0.12f) : A(Color.White, 0.05f))) FillRound(g, b, r, 12);
        using (var p = new Pen(selected ? A(Clay, 0.6f) : A(Color.White, 0.08f), 1f)) DrawRound(g, p, RectangleF.Inflate(r, -0.5f, -0.5f), 12);
    }

    private static void Divider(Graphics g, float x, float y, float w)
    {
        using var p = new Pen(A(Color.White, 0.06f), 1f);
        g.DrawLine(p, x, y, x + w, y);
    }

    private static void Badge(Graphics g, string text, float x, float y)
    {
        var f = Semi(10);
        var w = g.MeasureString(text, f).Width + 8;
        var r = new RectangleF(x, y, w, 16);
        using (var b = new SolidBrush(A(Green, 0.14f))) FillRound(g, b, r, 8);
        CenterTextIn(g, text, f, Green, r);
    }

    private void Spinner(Graphics g, RectangleF r)
    {
        var angle = Environment.TickCount64 / 3 % 360;
        using var p = new Pen(TextMuted, 1.5f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        g.DrawArc(p, RectangleF.Inflate(r, -1, -1), angle, 270);
    }

    private static void FillRound(Graphics g, Brush b, RectangleF r, float radius)
    { using var p = Round(r, radius); g.FillPath(b, p); }
    private static void DrawRound(Graphics g, Pen pen, RectangleF r, float radius)
    { using var p = Round(r, radius); g.DrawPath(pen, p); }
    private static GraphicsPath Round(RectangleF r, float radius)
    {
        var d = Math.Max(0.5f, Math.Min(radius * 2, Math.Min(r.Width, r.Height)));
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    private static TextBox MakeInput(bool secret, float points, string placeholder) => new()
    {
        BorderStyle = BorderStyle.FixedSingle,
        BackColor = Field,
        ForeColor = TextPrimary,
        Font = new Font("Segoe UI", points),
        UseSystemPasswordChar = secret,
        PlaceholderText = placeholder,
    };

    private static ComboBox MakeCombo(string[] items)
    {
        var c = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            FlatStyle = FlatStyle.Flat,
            BackColor = CardBg,
            ForeColor = TextPrimary,
            Font = new Font("Segoe UI Semibold", 9.75f),
        };
        c.Items.AddRange(items);
        return c;
    }

    private static Image? AppIconImage()
    {
        if (_appIcon is not null) return _appIcon;
        foreach (var id in new[] { Config.Load().AppIcon, "graphit" })
        {
            var path = Path.Combine(AppContext.BaseDirectory, "branding", $"icon-{id}.png");
            try { if (File.Exists(path)) return _appIcon = Image.FromFile(path); } catch { }
        }
        return null;
    }

    private static void DrawBrandIcon(Graphics g, string name, RectangleF r)
    {
        var image = name switch
        {
            "claude-code" => _claudeBrandIcon ??= LoadBrandIcon("claude-code.png"),
            "codex" => _codexBrandIcon ??= LoadBrandIcon("codex.png"),
            _ => null,
        };
        if (image is null)
        {
            DrawIcon(g, name == "claude-code" ? "terminal" : "sparkle", RectangleF.Inflate(r, -3, -3), TextMuted, 1.6f);
            return;
        }
        var state = g.Save();
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.DrawImage(image, r);
        g.Restore(state);
    }

    private static Image? LoadBrandIcon(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "branding", fileName);
        try { return File.Exists(path) ? Image.FromFile(path) : null; }
        catch { return null; }
    }

    // ----- vector icons (stand-ins for the SF Symbols), proportional to `r` -----------------

    private static void DrawIcon(Graphics g, string name, RectangleF r, Color c, float stroke)
    {
        using var pen = new Pen(c, stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        using var brush = new SolidBrush(c);
        float x = r.X, y = r.Y, w = r.Width, h = r.Height, cx = x + w / 2, cy = y + h / 2;
        switch (name)
        {
            case "wave":
                for (var i = 0; i < 5; i++)
                {
                    var bx = x + w * 0.1f + i * w * 0.2f;
                    var bh = h * (i % 2 == 0 ? 0.45f : 0.9f);
                    g.DrawLine(pen, bx, cy - bh / 2, bx, cy + bh / 2);
                }
                break;
            case "swap":   // rectangle.2.swap
                DrawRound(g, pen, new RectangleF(x + w * 0.04f, y + h * 0.1f, w * 0.44f, h * 0.32f), w * 0.07f);
                DrawRound(g, pen, new RectangleF(x + w * 0.52f, y + h * 0.58f, w * 0.44f, h * 0.32f), w * 0.07f);
                g.DrawLines(pen, new[] { new PointF(x + w * 0.6f, y + h * 0.26f), new PointF(x + w * 0.8f, y + h * 0.26f), new PointF(x + w * 0.8f, y + h * 0.46f) });
                g.DrawLines(pen, new[] { new PointF(x + w * 0.71f, y + h * 0.38f), new PointF(x + w * 0.8f, y + h * 0.47f), new PointF(x + w * 0.89f, y + h * 0.38f) });
                g.DrawLines(pen, new[] { new PointF(x + w * 0.4f, y + h * 0.74f), new PointF(x + w * 0.2f, y + h * 0.74f), new PointF(x + w * 0.2f, y + h * 0.54f) });
                g.DrawLines(pen, new[] { new PointF(x + w * 0.11f, y + h * 0.62f), new PointF(x + w * 0.2f, y + h * 0.53f), new PointF(x + w * 0.29f, y + h * 0.62f) });
                break;
            case "key":
                g.FillEllipse(brush, cx - w * 0.22f, y, w * 0.44f, h * 0.44f);
                g.DrawLine(pen, cx, y + h * 0.4f, cx, y + h * 0.95f);
                g.DrawLine(pen, cx, y + h * 0.7f, cx + w * 0.16f, y + h * 0.7f);
                g.DrawLine(pen, cx, y + h * 0.84f, cx + w * 0.12f, y + h * 0.84f);
                using (var hole = new SolidBrush(A(Color.Black, 0.45f))) g.FillEllipse(hole, cx - w * 0.06f, y + h * 0.1f, w * 0.12f, h * 0.12f);
                break;
            case "globe":
                g.DrawEllipse(pen, x, y, w, h);
                g.DrawEllipse(pen, x + w * 0.3f, y, w * 0.4f, h);
                g.DrawLine(pen, x, cy, x + w, cy);
                g.DrawArc(pen, x + w * 0.1f, y - h * 0.25f, w * 0.8f, h * 0.55f, 30, 120);
                g.DrawArc(pen, x + w * 0.1f, y + h * 0.7f, w * 0.8f, h * 0.55f, 210, 120);
                break;
            case "bell":
            case "bellbadge":
            case "off":
            {
                using var path = new GraphicsPath();
                path.AddArc(x + w * 0.2f, y + h * 0.08f, w * 0.6f, h * 0.6f, 180, 180);
                path.AddLine(x + w * 0.8f, y + h * 0.38f, x + w * 0.88f, y + h * 0.76f);
                path.AddLine(x + w * 0.12f, y + h * 0.76f, x + w * 0.2f, y + h * 0.38f);
                path.CloseFigure();
                g.DrawPath(pen, path);
                g.DrawArc(pen, cx - w * 0.12f, y + h * 0.74f, w * 0.24f, h * 0.2f, 0, 180);
                if (name == "off") g.DrawLine(pen, x + w * 0.05f, y + h * 0.05f, x + w * 0.95f, y + h * 0.95f);
                if (name == "bellbadge") g.FillEllipse(brush, x + w * 0.66f, y - h * 0.02f, w * 0.3f, h * 0.3f);
                break;
            }
            case "hand":   // hand.raised.fill
                FillRound(g, brush, new RectangleF(x + w * 0.22f, y + h * 0.42f, w * 0.6f, h * 0.56f), w * 0.22f);
                for (var i = 0; i < 4; i++)
                {
                    var top = y + h * (i == 1 ? 0.02f : i == 3 ? 0.18f : 0.08f);
                    FillRound(g, brush, new RectangleF(x + w * (0.24f + i * 0.145f), top, w * 0.12f, y + h * 0.6f - top), w * 0.06f);
                }
                using (var thumb = new Pen(c, w * 0.12f) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawLine(thumb, x + w * 0.28f, y + h * 0.7f, x + w * 0.1f, y + h * 0.48f);
                break;
            case "antenna":   // antenna.radiowaves.left.and.right
                g.FillEllipse(brush, cx - w * 0.09f, cy - h * 0.2f, w * 0.18f, h * 0.18f);
                g.DrawLine(pen, cx, cy - h * 0.05f, cx, y + h * 0.95f);
                g.DrawArc(pen, cx - w * 0.28f, cy - h * 0.39f, w * 0.56f, h * 0.56f, 140, 80);
                g.DrawArc(pen, cx - w * 0.28f, cy - h * 0.39f, w * 0.56f, h * 0.56f, -40, 80);
                g.DrawArc(pen, cx - w * 0.47f, cy - h * 0.58f, w * 0.94f, h * 0.94f, 140, 80);
                g.DrawArc(pen, cx - w * 0.47f, cy - h * 0.58f, w * 0.94f, h * 0.94f, -40, 80);
                break;
            case "speaker":   // speaker.wave.2.fill
                g.FillPolygon(brush, new[]
                {
                    new PointF(x, y + h * 0.36f), new PointF(x + w * 0.2f, y + h * 0.36f), new PointF(x + w * 0.44f, y + h * 0.12f),
                    new PointF(x + w * 0.44f, y + h * 0.88f), new PointF(x + w * 0.2f, y + h * 0.64f), new PointF(x, y + h * 0.64f),
                });
                g.DrawArc(pen, x + w * 0.38f, y + h * 0.3f, w * 0.28f, h * 0.4f, -55, 110);
                g.DrawArc(pen, x + w * 0.38f, y + h * 0.12f, w * 0.52f, h * 0.76f, -55, 110);
                break;
            case "mic":
                FillRound(g, brush, new RectangleF(cx - w * 0.18f, y, w * 0.36f, h * 0.62f), w * 0.18f);
                g.DrawArc(pen, cx - w * 0.33f, y + h * 0.2f, w * 0.66f, h * 0.6f, 0, 180);
                g.DrawLine(pen, cx, y + h * 0.8f, cx, y + h);
                break;
            case "shield":   // lock.shield.fill
            {
                using var path = new GraphicsPath();
                path.AddLine(cx, y, x + w * 0.92f, y + h * 0.18f);
                path.AddBezier(x + w * 0.92f, y + h * 0.18f, x + w * 0.92f, y + h * 0.65f, x + w * 0.7f, y + h * 0.88f, cx, y + h);
                path.AddBezier(cx, y + h, x + w * 0.3f, y + h * 0.88f, x + w * 0.08f, y + h * 0.65f, x + w * 0.08f, y + h * 0.18f);
                path.CloseFigure();
                g.FillPath(brush, path);
                using var dark = new SolidBrush(A(Color.Black, 0.5f));
                g.FillRectangle(dark, cx - w * 0.15f, cy - h * 0.02f, w * 0.3f, h * 0.24f);
                using var shackle = new Pen(A(Color.Black, 0.5f), Math.Max(1, w * 0.08f));
                g.DrawArc(shackle, cx - w * 0.1f, cy - h * 0.18f, w * 0.2f, h * 0.3f, 180, 180);
                break;
            }
            case "cloud":
                g.FillEllipse(brush, x, y + h * 0.42f, w * 0.42f, h * 0.42f);
                g.FillEllipse(brush, x + w * 0.2f, y + h * 0.14f, w * 0.56f, h * 0.56f);
                g.FillEllipse(brush, x + w * 0.52f, y + h * 0.34f, w * 0.48f, h * 0.48f);
                g.FillRectangle(brush, x + w * 0.2f, y + h * 0.5f, w * 0.6f, h * 0.34f);
                break;
            case "link":
            {
                var state = g.Save();
                g.TranslateTransform(cx, cy);
                g.RotateTransform(-45);
                DrawRound(g, pen, new RectangleF(-w * 0.5f, -h * 0.16f, w * 0.55f, h * 0.32f), h * 0.16f);
                DrawRound(g, pen, new RectangleF(-w * 0.05f, -h * 0.16f, w * 0.55f, h * 0.32f), h * 0.16f);
                g.Restore(state);
                break;
            }
            case "lock":
                FillRound(g, brush, new RectangleF(x + w * 0.15f, y + h * 0.42f, w * 0.7f, h * 0.56f), w * 0.1f);
                g.DrawArc(pen, cx - w * 0.22f, y + h * 0.05f, w * 0.44f, h * 0.6f, 180, 180);
                g.DrawLine(pen, cx - w * 0.22f, y + h * 0.35f, cx - w * 0.22f, y + h * 0.45f);
                g.DrawLine(pen, cx + w * 0.22f, y + h * 0.35f, cx + w * 0.22f, y + h * 0.45f);
                break;
            case "phone":
                DrawRound(g, pen, new RectangleF(x + w * 0.22f, y, w * 0.56f, h), w * 0.12f);
                g.DrawLine(pen, cx - w * 0.08f, y + h * 0.88f, cx + w * 0.08f, y + h * 0.88f);
                break;
            case "play":
                g.FillPolygon(brush, new[] { new PointF(x + w * 0.2f, y), new PointF(x + w, cy), new PointF(x + w * 0.2f, y + h) });
                break;
            case "dots":
                for (var i = 0; i < 3; i++) g.FillEllipse(brush, x + i * w * 0.38f, cy - w * 0.12f, w * 0.24f, w * 0.24f);
                break;
            case "check":
                DrawCheckPath(g, r, pen);
                break;
            case "checkcircle":
            case "xcircle":
            case "info":
            {
                g.FillEllipse(brush, r);
                using var white = new Pen(name == "info" ? BgBottom : Color.White, Math.Max(1.2f, w * 0.13f)) { StartCap = LineCap.Round, EndCap = LineCap.Round };
                if (name == "checkcircle") DrawCheckPath(g, r, white);
                else if (name == "xcircle")
                {
                    g.DrawLine(white, x + w * 0.32f, y + h * 0.32f, x + w * 0.68f, y + h * 0.68f);
                    g.DrawLine(white, x + w * 0.68f, y + h * 0.32f, x + w * 0.32f, y + h * 0.68f);
                }
                else
                {
                    g.DrawLine(white, cx, y + h * 0.45f, cx, y + h * 0.74f);
                    using var dot = new SolidBrush(BgBottom);
                    g.FillEllipse(dot, cx - w * 0.07f, y + h * 0.22f, w * 0.14f, h * 0.14f);
                }
                break;
            }
            case "terminal":
                DrawRound(g, pen, new RectangleF(x, y + h * 0.1f, w, h * 0.8f), w * 0.12f);
                g.DrawLines(pen, new[] { new PointF(x + w * 0.2f, cy - h * 0.12f), new PointF(x + w * 0.36f, cy), new PointF(x + w * 0.2f, cy + h * 0.12f) });
                g.DrawLine(pen, x + w * 0.45f, cy + h * 0.15f, x + w * 0.75f, cy + h * 0.15f);
                break;
            case "sparkle":
                g.DrawLine(pen, cx, y, cx, y + h);
                g.DrawLine(pen, x, cy, x + w, cy);
                g.DrawLine(pen, x + w * 0.22f, y + h * 0.22f, x + w * 0.78f, y + h * 0.78f);
                g.DrawLine(pen, x + w * 0.78f, y + h * 0.22f, x + w * 0.22f, y + h * 0.78f);
                break;
        }
    }

    private static void DrawCheckPath(Graphics g, RectangleF r, Pen pen)
    {
        float x = r.X, y = r.Y, w = r.Width, h = r.Height;
        g.DrawLines(pen, new[]
        {
            new PointF(x + w * 0.26f, y + h * 0.52f),
            new PointF(x + w * 0.43f, y + h * 0.69f),
            new PointF(x + w * 0.75f, y + h * 0.33f),
        });
    }
}
