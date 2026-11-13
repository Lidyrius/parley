using System.Runtime.InteropServices;
using System.Text.Json;

namespace Parley;

// The headless host: what TrayApp (windows/Program.cs) wires up, without the tray — the
// loopback server, the turn pipeline, the relay to the phone, shares, reminders, the Wachhund
// and the Live Activity. Always "Unterwegs": this machine has no speaker and no microphone, so
// Parley's voice is a call on the phone (or a notification there).
// ponytail: duplicated from TrayApp for the pilot; lift into a shared host file when Linux ships
internal sealed class Host
{
    private readonly TurnPipeline _pipeline;
    private readonly Server _server;
    private readonly ShareHub _shares;
    private readonly object _relayGate = new();
    private RelayClient? _relay;
    private System.Threading.Timer? _activityTimer, _watchdogTimer;

    // `parley run`: until SIGINT / SIGTERM. 1 = the port is taken (Parley already runs).
    public static int Run()
    {
        Log.Echo = Console.WriteLine;
        var host = new Host();
        try { host._server.Start(); }
        catch (Exception e)
        {
            Log.Write($"server start failed: {e.Message} — is Parley already running?");
            return 1;
        }
        host.Start();
        using var stop = new ManualResetEventSlim();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop.Set(); };
        using var term = PosixSignalRegistration.Create(PosixSignal.SIGTERM, c => { c.Cancel = true; stop.Set(); });
        stop.Wait();
        host._relay?.Stop();
        Log.Write("host: stopped");
        return 0;
    }

    private Host()
    {
        Server? serverRef = null;
        _pipeline = new TurnPipeline(() => serverRef?.QueuedTurns ?? 0, null,
            () => serverRef?.ResumableList() ?? new List<Server.ParkedInfo>(),
            (id, instr) => serverRef?.Resume(id, instr),
            id => serverRef?.Sessions.OthersAlive(id) ?? false);
        _server = new Server(turn => _pipeline.Run(turn), () => StatsStore.StartSession(), Tmux.Start);
        _server.Sessions.NamesFile = Path.Combine(Config.Dir, "session-names.json");
        serverRef = _server;
        _server.AbandonTurn = _pipeline.Abandon;   // POST /turn/cancel (docs/HOOKLESS.md)
        // Sessions live in tmux here: closed there, and their starts can be read and answered.
        _server.Closer = id => Tmux.Close(id, _server.Sessions.Info(id)?.Cwd);
        _server.Delivery.StartScreen = Tmux.Screen;
        _server.Delivery.StartAnswer = Tmux.Answer;
        RemoteControl.CatchUp = Tmux.RemoteControlOn;   // tmux can be typed into (Windows can't)
        _server.Sessions.OnLabel = label => Clips.Prerender(label, Config.Load());
        RelayFrame.OffersClips = !Config.Load().PlainCalls;   // credentials.json "plainCalls": "1" = calls as before v8
        _pipeline.Ring = label => Ringer.Ring(label);
        _pipeline.OthersWorking = id => serverRef?.Sessions.OthersWorking(id) ?? false;
        _pipeline.AfterWait = id => serverRef?.Sessions.AfterWait(id) ?? false;
        _pipeline.TimerQueued = () => serverRef?.TimerQueued() ?? false;
        _pipeline.SetCallback = (id, at) => _server.Sessions.SetCallback(id, at);
        _server.OnReminded = r => Notifier.Notify("Parley · Wiedervorlage", $"An {r.Label}: {r.Text}");
        _server.OnPalette = (name, frame) =>
        {
            Log.Write($"palette: {name} → the phone");
            _pendingPalette = (name, frame);
            _ = PhoneCall.Reply(frame);
        };
        _pipeline.Route = (text, config) => _server.Delivery.Route(text, config, _server.SupervisorOn());
        _pipeline.Host = _server;   // what Sir missed (a call of the Zentrale he didn't take)
        PhoneCall.LoadSettings(Config.Load());
        // No speaker, no microphone: the same switch as "the PC is locked" — whatever the phone's
        // own Unterwegs setting says, nothing is ever voiced or heard on this machine.
        PhoneCall.SetLockedAway(true);
        Log.Write("host: headless — always Unterwegs (voice and microphone are the phone's)");
        _shares = new ShareHub(_server)
        {
            ToSir = frame => _ = PhoneCall.Reply(frame),
            Notify = (title, body) => { Notifier.Notify(title, body); _ = Apns.SendAlert(title, body, ""); },
            Push = (token, env, title, body, session) => _ = Apns.SendAlertTo(token, env, title, body, session),
            CallGuest = (line, turn, share) => CallGuest(line, turn, share),
            WelcomeGuest = (line, text, share) => WelcomeGuest(line, text, share),
            GuestCalled = (line, share) => GuestCalled(line, share),
        };
        _server.AskGuest = (id, turn) => _shares.AskGuest(id, turn);
        RelayHost.Start = StartRelay;
    }

    private void Start()
    {
        StartRelay();
        _shares.Start();
        // Every 2 s: `parley pair` (another process) may have written a room — connect to it; the
        // Live Activity. Every 30 s: the Wachhund, reminders, shares. A tick never ends the host.
        _activityTimer = new System.Threading.Timer(_ => { Safely("relay", StartRelay); Safely("live activity", TickLiveActivity); },
            null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        _watchdogTimer = new System.Threading.Timer(_ => { Safely("watchdog", TickWatchdog); Safely("reminders", _server.TickReminders); Safely("shares", _shares.Tick); },
            null, TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));
    }

    private static void Safely(string what, Action step)
    {
        try { step(); }
        catch (Exception e) { Log.Write($"{what}: {e.Message}"); }
    }

    // Sir called in: Parley greets him at once and listens — no "Hey Parley" needed. As TrayApp.
    private async Task GreetCaller()
    {
        // He calls back after a call he didn't take: what waits for him plays at once — only a
        // Fortsetzen's `resume` gets its moment (the phone sends it right behind `call start`).
        await Task.Delay(_server.MissedCount > 0 ? 250 : 1200);
        if (!PhoneCall.Active || _server.ResumedRecently()) return;
        if (_server.MissedCount > 0) _server.CallBack(); else _server.StartWake();
    }

    // ---- a guest's call line (Shares.cs) — as TrayApp --------------------------------------

    private static async Task<string?> CallGuest(PhoneLine line, TurnPayload turn, Share share)
    {
        var name = share.Guest?.Name ?? "Gast";
        using var hold = line.Hold();   // held to the end: the line going idle hangs his phone up
        if (!await RingGuest(line, $"Rückfrage · {share.Label}", share)) return null;
        var config = Config.Load();
        line.SetSpeaker(share.Label);
        var beeped = await SpeakToGuest(line, turn.Speak, config, turn.Slides, Server.SessionKey(turn), beep: true);
        if (await ListenToGuest(line, config, beeped) is not { } text) return null;
        Log.Write($"share: {name} answered on the phone ({text.Length} chars)");
        if (line.Active)
        {
            line.TakeBarge();
            await SpeakToGuest(line, text.Trim().Length == 0 ? "Ich gebe die Frage weiter." : "Danke, ich gebe es weiter.", config, last: true);
        }
        return text;
    }

    private static async Task<string?> GuestCalled(PhoneLine line, Share share)
    {
        if (!line.Active || share.Guest is not { } g) return null;
        using var hold = line.Hold();
        var config = Config.Load();
        line.SetSpeaker(share.Label);
        if (g.Listen)
        {
            await SpeakToGuest(line, $"Hallo {g.Name}. Bei {share.Label} hören Sie nur zu – ich kann nichts weitergeben.", config, last: true);
            line.TakeBarge();
            return null;
        }
        var beeped = await SpeakToGuest(line, $"Ja, {g.Name}? Was soll ich {share.Label} sagen?", config, beep: true);
        if (await ListenToGuest(line, config, beeped) is not { } text) return null;
        Log.Write($"share: {g.Name} called in for {share.Label} ({text.Length} chars)");
        if (line.Active)
        {
            line.TakeBarge();
            await SpeakToGuest(line, text.Trim().Length == 0 ? "Gut, dann bis später." : "Danke, ich gebe es weiter.", config, last: true);
        }
        return text.Trim().Length == 0 ? null : text.Trim();
    }

    private static async Task<bool> SpeakToGuest(PhoneLine line, string text, Config config, IReadOnlyList<SlideSpec>? slides = null,
                                                 string session = "", bool last = false, bool beep = false)
    {
        if (await GoogleTts.Synthesize(text, config) is not { } raw) return false;
        var pcm = AudioOut.ApplyRate(raw, config.SpeakingRate);
        var timed = Captions.Timings(text, pcm, GoogleTts.SampleRate);
        if (timed is not null) await line.Reply(Captions.Frame(timed, last));
        if (slides is { Count: > 0 }) await Slides.Send(slides, timed, session, line);
        return (await line.SpeakAsync(pcm, GoogleTts.SampleRate, beep)).Beeped;
    }

    private static async Task<string?> ListenToGuest(PhoneLine line, Config config, bool beeped = false)
    {
        var barged = line.TakeBarge();
        if (!barged && !beeped && !await line.BeepClip())
        {
            await line.PlayAsync(AudioOut.Beep(), GoogleTts.SampleRate);
            await Task.Delay(100);
        }
        if (!line.Active) return null;
        var wav = await new MicCapture().RecordFromPhone(line, barged ? line.RecentMic() : Array.Empty<byte[]>()) ?? Array.Empty<byte>();
        var minBytes = 44 + 16000 * 2 / 5;   // header + ~0.2s
        return wav.Length >= minBytes ? await Groq.Transcribe(wav, config) : "";
    }

    private static async Task WelcomeGuest(PhoneLine line, string text, Share share)
    {
        using var hold = line.Hold();
        if (!await RingGuest(line, $"Willkommen · {share.Label}", share)) return;
        var config = Config.Load();
        line.SetSpeaker(share.Label);
        await SpeakToGuest(line, text, config, last: true);
        line.TakeBarge();
    }

    private static async Task<bool> RingGuest(PhoneLine line, string label, Share share)
    {
        var name = share.Guest?.Name ?? "Gast";
        line.TakeLater(out _);
        line.TakeDeclined();
        if (line.Active) return true;
        _ = line.SendRing(label);
        var (token, env) = line.PushTarget;
        if (token.Length > 0) _ = Apns.SendVoipTo(token, env, label, share.Id);
        Log.Write($"share: ringing {name} for {share.Label}");
        var until = DateTime.UtcNow + Ringer.AnswerWait;
        while (!line.Active)
        {
            if (line.TakeLater(out _)) { Log.Write($"share: {name} can't talk now"); return false; }
            if (line.TakeDeclined() || DateTime.UtcNow >= until) { Log.Write($"share: {name} didn't pick up"); return false; }
            await Task.Delay(100);
        }
        return true;
    }

    // ---- the Wachhund (Watchdog.cs) — as TrayApp -------------------------------------------

    private readonly WatchdogMemory _watchdogMemory = new();

    private void TickWatchdog()
    {
        using var doc = JsonDocument.Parse(_server.Sessions.Json());
        if (!doc.RootElement.TryGetProperty("sessions", out var list) || list.ValueKind != JsonValueKind.Array) return;
        var now = DateTime.UtcNow;
        foreach (var s in list.EnumerateArray())
        {
            string? Str(string k) => s.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            if (Str("state") != "working" || Str("id") is not { Length: > 0 } id || Transcript.File(id) is not { } file) continue;
            var since = DateTime.UnixEpoch.AddMilliseconds(s.TryGetProperty("since", out var sv) && sv.ValueKind == JsonValueKind.Number ? sv.GetDouble() : 0);
            var tail = Transcript.TailLines(file, 256 * 1024).ToList();
            if (Watchdog.TurnEnded(tail)) continue;   // it waits for Sir, it doesn't hang
            var calls = Watchdog.Calls(tail);
            var finding = Watchdog.Check("working", since, File.GetLastWriteTimeUtc(file), calls, now);
            if (finding is null || !_watchdogMemory.ShouldReport(id, finding, now)) continue;
            var label = Str("label") is { Length: > 0 } l ? l : Str("project") ?? "Eine Session";
            var question = Watchdog.Question(label, finding);
            Log.Write($"watchdog: {label} — {finding.Kind}");
            if (PhoneCall.Away && !PhoneCall.Active) _ = Apns.SendAlert($"Parley · {label}", question, id);
            else _server.Watchdog(id, label, question, Watchdog.Hint(finding));
        }
    }

    // ---- the iPhone's Live Activity (docs/LIVE-ACTIVITIES.md) — as TrayApp -------------------

    private readonly LiveActivityFeed _activityFeed = new();
    private readonly WidgetPushFeed _widgetFeed = new();
    private (string Name, string Frame)? _pendingPalette;
    private string? _seenActivityToken;
    private int _activityTicking;

    private void TickLiveActivity()
    {
        if (Interlocked.Exchange(ref _activityTicking, 1) == 1) return;   // a slow push: skip, never overlap
        try
        {
            var now = DateTime.UtcNow;
            var update = PhoneCall.Activity;
            if (update.Token != _seenActivityToken)
            {
                _seenActivityToken = update.Token;
                _activityFeed.PhoneReports(update.Token.Length > 0, now);
            }
            var c = Config.Load();
            if (c.ApnsKeyId.Length == 0 || c.ApnsKeyP8.Length == 0) return;
            var start = PhoneCall.ActivityStart;
            var sessions = _server.Sessions.Json();
            if (LiveActivity.CurrentAsk is { } ask && !LiveActivity.IsOpen(ask, sessions)) LiveActivity.CurrentAsk = null;
            var content = LiveActivity.FromSessions(sessions, LiveActivity.CurrentAsk);
            var alert = PhoneCall.Alert;
            if (alert.Token.Length > 0)
            {
                var widget = LiveActivity.WidgetFrom(sessions);
                if (_widgetFeed.Due(widget, now))
                {
                    var (ws, _) = Apns.SendBackground(alert.Token, alert.Env, LiveActivity.WidgetPayload(widget)).GetAwaiter().GetResult();
                    Log.Write($"widgets: silent push → {ws}");
                }
            }
            var action = _activityFeed.Step(content, PhoneCall.Away, start.Token.Length > 0, update.Token.Length > 0, now);
            if (action is null) return;
            var (target, ev, priority) = action switch
            {
                LiveActivityFeed.Start => (start, LiveActivity.Event.Start, 10),
                LiveActivityFeed.Update u => (update, LiveActivity.Event.Update, u.Priority),
                _ => (update, LiveActivity.Event.End, 10),
            };
            var body = LiveActivity.Payload(ev, action.Content, DateTimeOffset.UtcNow);
            var (status, reply) = Apns.SendActivity(target.Token, target.Env, body, priority).GetAwaiter().GetResult();
            Log.Write($"live activity: {ev.ToString().ToLowerInvariant()} → {status}");
            if (status == 410 || reply.Contains("BadDeviceToken"))
            {
                if (ev == LiveActivity.Event.Start) PhoneCall.SetActivityStart("", target.Env);
                else PhoneCall.SetActivity("", target.Env);
            }
        }
        finally { Volatile.Write(ref _activityTicking, 0); }
    }

    // ---- the relay to the phone — as TrayApp -------------------------------------------------

    // Connect to the relay when it is configured (launch, `parley pair`); a no-op on unchanged settings.
    private void StartRelay()
    {
        lock (_relayGate)
        {
            var config = RelayConfig.Load().WithKey();
            if (_relay is not null && _relay.Config == config) return;
            if (_relay is null && !config.IsComplete) return;   // not paired yet: nothing to log every 2 s
            _relay?.Stop();
            _relay = RelayClient.Create(config, () => _server.Sessions.Json(), OnPhone, PhoneCall.OnAudio);
            if (_relay is not null) _relay.OnConnected = PhoneCall.Resync;
            PhoneCall.Attach(_relay);
            _relay?.Start();
            if (_relay is not null) Clips.PrerenderGreet(Config.Load());
        }
    }

    // A phone's message (docs/IPHONE.md), on the relay's receive task.
    private void OnPhone(PhoneMessage message)
    {
        switch (message)
        {
            case PhoneResume r: _server.StartResume(r.Id); break;
            case PhoneCallState c:
                var wasInCall = PhoneCall.Active;
                PhoneCall.OnCall(c.Started, c.Down, c.Clips);
                if (c.Started && !wasInCall) _ = GreetCaller();
                break;
            case PhoneCallIdle or PhoneClipStatus: PhoneCall.Line.Handle(message); break;
            case PhoneWake _: _server.StartWake(); break;
            case PhonePush p: PhoneCall.SetPush(p.Token, p.Env); break;
            case PhoneAway a: PhoneCall.SetAway(a.On); break;   // kept as the phone's setting; this host stays Unterwegs either way
            case PhoneLater l: PhoneCall.SetLater(l.After); break;
            case PhoneSilent s: PhoneCall.SetSilent(s.On); break;
            case PhoneSupervisor sup:
                Log.Write($"phone: Überwachungsmodus {(sup.On ? "an" : "aus")}");
                _server.SetSupervisor(sup.On);
                break;
            case PhoneBrief b:
                if (Config.Load().Brief != b.On)
                {
                    Config.Merge(new Dictionary<string, string> { ["brief"] = b.On ? "1" : "" });
                    Log.Write($"phone: Ohne Floskeln {(b.On ? "an" : "aus")}");
                }
                break;
            case PhoneRound r:
                var secs = Math.Clamp(r.Seconds, 0, 600);
                if (Config.Load().RoundSeconds != secs)
                {
                    Config.Merge(new Dictionary<string, string> { ["roundSeconds"] = secs.ToString() });
                    Log.Write($"phone: Fragerunde {(secs == 0 ? "aus" : $"bis {secs} s")}");
                }
                break;
            case PhoneAlert a: PhoneCall.SetAlert(a.Token, a.Env); break;
            case PhoneActivityStart s: PhoneCall.SetActivityStart(s.Token, s.Env); break;
            case PhoneBarge: PhoneCall.OnBarge(); break;
            case PhoneHello hello:
                RelayHost.SayHello(hello.Device);
                Log.Write($"phone: hello from {(hello.Device.Length == 0 ? "a phone" : hello.Device)}");
                if (_pendingPalette is { } pending) _ = PhoneCall.Reply(pending.Frame);
                foreach (var s in _shares.List().Where(s => s.State == "asking")) _ = PhoneCall.Reply(Shares.JoinFrame(s));
                break;
            case PhonePaletteSaved saved:
                Log.Write($"palette: the phone saved {saved.Name}");
                if (_pendingPalette?.Name == saved.Name) _pendingPalette = null;
                break;
            case PhoneActivity a: PhoneCall.SetActivity(a.Token, a.Env); break;
            case PhoneHistory h:
                _ = Task.Run(() =>
                {
                    var (items, more) = Transcript.File(h.Id) is { } path ? Transcript.Page(path, h.Before) : (new List<Transcript.Item>(), false);
                    return PhoneCall.Reply(Transcript.HistoryFrame(h.Id, items, h.Before, more));
                });
                break;
            case PhoneImage i:
                _ = Task.Run(() => PhoneCall.Reply(Transcript.ImageFrame(i.Key,
                    Transcript.File(i.Id) is { } path ? Transcript.Image(path, i.Key) : null)));
                break;
            case PhoneSay s:
                Log.Write($"phone: typed message for {s.Id} ({s.Text.Length} chars)");
                if (LiveActivity.CurrentAsk?.Id == s.Id) LiveActivity.CurrentAsk = null;
                _server.Resume(s.Id, s.Text);
                break;
            case PhoneSnapshotSave save:
                _server.SaveSnapshot(save.Name, save.Ids);
                break;
            case PhoneSnapshotOpen open:
                _ = Task.Run(() => _server.OpenSnapshot(open.Id) is { } opened
                    ? PhoneCall.Reply(SnapshotStore.Frame(opened.Snapshot, opened.Results)) : Task.CompletedTask);
                break;
            case PhoneSnapshotDelete delete:
                _server.DeleteSnapshot(delete.Id);
                break;
            case PhoneShareCreate create:
                if (_shares.Create(create.Session) is { } made) _ = PhoneCall.Reply(Shares.LinkFrame(made.Share, made.Link));
                break;
            case PhoneShareApprove approve:
                _shares.Approve(approve.Id, approve.Role, approve.Listen, approve.Full, approve.Mine);
                break;
            case PhoneShareRemove remove:
                _shares.Remove(remove.Id);
                break;
        }
    }
}
