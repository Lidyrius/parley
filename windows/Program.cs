using System.Text.Json;

namespace Parley;

// Entry point: single-instance guard, system-tray icon (mute, stats, settings, quit),
// waveform pill overlay, and the loopback server driving the voice pipeline.
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(true, "de.developaway.parley", out var createdNew);
        if (!createdNew) return;   // already running

        // Started from inside a Claude Code session, Parley would inherit its CLAUDE_CODE_*
        // variables and pass them on to every session it starts.
        foreach (var key in Environment.GetEnvironmentVariables().Keys.Cast<object>().Select(k => k.ToString() ?? ""))
            if (key.StartsWith("CLAUDE_CODE_", StringComparison.OrdinalIgnoreCase)) Environment.SetEnvironmentVariable(key, null);

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayApp());
    }
}

internal sealed class TrayApp : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly TurnPipeline _pipeline;
    private readonly Server _server;
    private readonly PillOverlay _pill = new();
    private readonly ToolStripMenuItem _relayStatus = new() { Enabled = false, Visible = false };
    private readonly ToolStripMenuItem _callStatus = new("iPhone: Anruf aktiv") { Enabled = false, Visible = false };
    private readonly ToolStripMenuItem _awayStatus = new("Unterwegs-Modus an") { Enabled = false, Visible = false };
    private readonly ToolStripMenuItem _snapshots = new("Snapshots");
    private RelayClient? _relay;
    private readonly ShareHub _shares;   // v7: sessions shared with a guest (Shares.cs)

    public TrayApp()
    {
        _ = _pill.Handle;   // create the handle on the UI thread so BeginInvoke works

        Server? serverRef = null;
        _pipeline = new TurnPipeline(() => serverRef?.QueuedTurns ?? 0, _pill,
            () => serverRef?.ResumableList() ?? new List<Server.ParkedInfo>(),
            (id, instr) => serverRef?.Resume(id, instr),
            id => serverRef?.Sessions.OthersAlive(id) ?? false);
        _server = new Server(turn => _pipeline.Run(turn), () => StatsStore.StartSession());
        _server.Sessions.NamesFile = Path.Combine(Config.Dir, "session-names.json");
        serverRef = _server;
        // A session's label appeared → pre-render its "Update zu" + resume lines in the
        // background, so the first announcement / resume click is instant.
        _server.Sessions.OnLabel = label => Clips.Prerender(label, Config.Load());
        // iPhone (docs/IPHONE.md, v2): Unterwegs-Modus rings before a turn; a wake utterance is
        // routed to a session or the Zentrale. The phone's settings survive restarts.
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
        _pipeline.Route = (text, config) => _server.Delivery.Route(text, config);
        PhoneCall.LoadSettings(Config.Load());
        // v7: shared sessions — Sir's phone hears who asks to join; a guest's question
        // (<speak to="Max">) goes to him, and unanswered comes back to Sir's voice.
        _shares = new ShareHub(_server)
        {
            ToSir = frame => _ = PhoneCall.Reply(frame),
            Notify = Notifier.Notify,
            Push = (token, env, title, body, session) => _ = Apns.SendAlertTo(token, env, title, body, session),
            CallGuest = (line, turn, share) => CallGuest(line, turn, share),
        };
        _server.AskGuest = (id, turn) => _shares.AskGuest(id, turn);

        var menu = new ContextMenuStrip();
        // Resumable (parked) sessions are inserted at the top on open.
        menu.Opening += (_, _) => { RefreshParkedMenu(menu); RefreshSnapshotsMenu(); RefreshSharesMenu(menu); RefreshRelayStatus(); };
        // Snapshots (Snapshots.cs), below the parked ones: rebuilt on open.
        menu.Items.Add(_snapshots);
        menu.Items.Add(new ToolStripSeparator());
        var mute = new ToolStripMenuItem("Stumm schalten") { CheckOnClick = true };
        mute.CheckedChanged += (_, _) =>
        {
            _pipeline.Muted = mute.Checked;
            _tray!.Text = mute.Checked ? "Parley (stumm)" : "Parley";
        };
        menu.Items.Add(mute);
        // App-Symbol: the tray shows the chosen icon at once (as the macOS / iPhone settings).
        var icons = new ToolStripMenuItem("App-Symbol");
        foreach (var (id, name) in AppIcon.Choices)
        {
            var item = new ToolStripMenuItem(name) { Checked = Config.Load().AppIcon == id };
            item.Click += (_, _) =>
            {
                Config.Merge(new Dictionary<string, string> { ["appIcon"] = id });
                foreach (ToolStripMenuItem other in icons.DropDownItems) other.Checked = other == item;
                _tray.Icon = AppIcon.For(id);
            };
            icons.DropDownItems.Add(item);
        }
        menu.Items.Add(icons);
        // iPhone (docs/IPHONE.md): pairing opens the relay's QR page; the status line is set on open.
        var pair = new ToolStripMenuItem("Handy verbinden…");
        pair.Click += (_, _) => PairIPhone();
        menu.Items.Add(pair);
        menu.Items.Add(_relayStatus);
        menu.Items.Add(_callStatus);
        menu.Items.Add(_awayStatus);
        // The PC locked for a minute counts as Unterwegs (off by default: nothing rings at night unasked).
        var lockAway = new ToolStripMenuItem("Unterwegs, wenn der PC gesperrt ist") { CheckOnClick = true, Checked = Config.Load().AutoAwayOnLock };
        lockAway.CheckedChanged += (_, _) =>
        {
            Config.Merge(new Dictionary<string, string> { ["autoAwayOnLock"] = lockAway.Checked ? "1" : "0" });
            PhoneCall.SetLockedAway(lockAway.Checked && _pcLocked);
        };
        menu.Items.Add(lockAway);
        var barge = new ToolStripMenuItem("Parley unterbrechen (einfach reinreden)") { CheckOnClick = true, Checked = Config.Load().BargeIn };
        barge.CheckedChanged += (_, _) => Config.Merge(new Dictionary<string, string> { ["bargeIn"] = barge.Checked ? "1" : "0" });
        menu.Items.Add(barge);
        Microsoft.Win32.SystemEvents.SessionSwitch += (_, e) =>
        {
            if (e.Reason == Microsoft.Win32.SessionSwitchReason.SessionLock) ScreenLocked(true);
            else if (e.Reason == Microsoft.Win32.SessionSwitchReason.SessionUnlock) ScreenLocked(false);
        };
        // The APNs key that lets Parley ring the phone (Unterwegs-Modus).
        var pushKey = new ToolStripMenuItem("Push-Schlüssel wählen…");
        pushKey.Click += (_, _) => ChoosePushKey();
        menu.Items.Add(pushKey);
        var stats = new ToolStripMenuItem("Statistiken…");
        stats.Click += (_, _) => new StatsForm().Show();
        menu.Items.Add(stats);
        var settings = new ToolStripMenuItem("Einstellungen…");
        settings.Click += (_, _) => new SettingsForm().Show();
        menu.Items.Add(settings);
        var setup = new ToolStripMenuItem("Setup…");
        setup.Click += (_, _) => new OnboardingForm().Show();
        menu.Items.Add(setup);
        var dev = new ToolStripMenuItem("Entwickler");
        var devReset = new ToolStripMenuItem("Zurücksetzen (Onboarding testen) — Statistiken bleiben");
        devReset.Click += (_, _) => DevTools.ResetKeepingStats();
        var devOnboard = new ToolStripMenuItem("Onboarding zeigen");
        devOnboard.Click += (_, _) => DevTools.ShowOnboarding();
        var devNotif = new ToolStripMenuItem("Test-Benachrichtigung");
        devNotif.Click += (_, _) => DevTools.TestNotification();
        var devPill = new ToolStripMenuItem("Aufnahme-Pill testen");
        devPill.Click += (_, _) => TestRecordingPill();
        var devClips = new ToolStripMenuItem("Clips neu rendern");
        devClips.Click += (_, _) => DevTools.RerenderClips();
        var devLog = new ToolStripMenuItem("Log anzeigen");
        devLog.Click += (_, _) => DevTools.RevealLog();
        dev.DropDownItems.AddRange(new ToolStripItem[] { devReset, devOnboard, new ToolStripSeparator(), devNotif, devPill, devClips, devLog });
        menu.Items.Add(dev);

        menu.Items.Add(new ToolStripSeparator());
        var quit = new ToolStripMenuItem("Beenden");
        quit.Click += (_, _) => { _relay?.Stop(); _tray!.Visible = false; Application.Exit(); };
        menu.Items.Add(quit);

        _tray = new NotifyIcon
        {
            Icon = AppIcon.For(Config.Load().AppIcon),
            Text = "Parley",
            Visible = true,
            ContextMenuStrip = menu,
        };
        Notifier.Init(_tray);
        NotificationPill.EnsureCreated();   // create the pill on the UI thread

        if (!OnboardingForm.IsComplete()) new OnboardingForm().Show();
        else if (OnboardingForm.NeedsTutorial()) new OnboardingForm(true).Show();

        try { _server.Start(); }
        catch (Exception e)
        {
            Log.Write($"server start failed: {e.Message}");
            MessageBox.Show($"Parley konnte Port 8787 nicht öffnen: {e.Message}", "Parley");
        }
        StartRelay();
        _shares.Start();
        _activityTimer = new System.Threading.Timer(_ => TickLiveActivity(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        _watchdogTimer = new System.Threading.Timer(_ => { TickWatchdog(); _server.TickReminders(); _shares.Tick(); }, null, TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));
    }

    // ---- Unterwegs when the PC is locked ------------------------------------------------

    private bool _pcLocked;
    private CancellationTokenSource? _lockWait;

    // Locked → after a minute (not for a quick lock) updates ring the phone; unlocked → back at once.
    private void ScreenLocked(bool locked)
    {
        _pcLocked = locked;
        _lockWait?.Cancel();
        if (!locked) { PhoneCall.SetLockedAway(false); return; }
        var cts = _lockWait = new CancellationTokenSource();
        _ = Task.Delay(TimeSpan.FromMinutes(1), cts.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled && _pcLocked) PhoneCall.SetLockedAway(Config.Load().AutoAwayOnLock);
        }, TaskScheduler.Default);
    }

    // Sir called in: Parley greets him at once and listens — no "Hey Parley" needed. Only when
    // nothing else runs (a call answering a ring or calling back a waiting line has its turn;
    // Fortsetzen sends its resume right after the call starts). As macOS.
    private async Task GreetCaller()
    {
        await Task.Delay(1200);
        if (PhoneCall.Active && !_server.ResumedRecently()) _server.StartWake();
    }

    // v7 part 3: a guest's question on his own call line (Shares.cs) — ring his phone (his
    // room's `ring` + a VoIP push naming the share), ask in Parley's voice, listen, transcribe.
    // Runs beside Sir's own line; null = he didn't pick up (his Rückfrage screen stays open). As macOS.
    private static async Task<string?> CallGuest(PhoneLine line, TurnPayload turn, Share share)
    {
        var name = share.Guest?.Name ?? "Gast";
        var label = $"Rückfrage · {share.Label}";
        line.TakeLater(out _);
        line.TakeDeclined();
        // Held to the end: the line going idle is what hangs his phone up.
        using var hold = line.Hold();
        if (!line.Active)
        {
            _ = line.SendRing(label);
            var (token, env) = line.PushTarget;
            if (token.Length > 0) _ = Apns.SendVoipTo(token, env, label, share.Id);
            Log.Write($"share: ringing {name} for {share.Label}");
            var until = DateTime.UtcNow + Ringer.AnswerWait;
            while (!line.Active)
            {
                if (line.TakeLater(out _)) { Log.Write($"share: {name} can't talk now"); return null; }
                if (line.TakeDeclined() || DateTime.UtcNow >= until) { Log.Write($"share: {name} didn't pick up"); return null; }
                await Task.Delay(100);
            }
        }
        var config = Config.Load();
        line.SetSpeaker(share.Label);
        if (await GoogleTts.Synthesize(turn.Speak, config) is { } pcm)
            await line.PlayAsync(AudioOut.ApplyRate(pcm, config.SpeakingRate), GoogleTts.SampleRate);
        // He talked over the question: listen at once, with what he already said (as Sir's turns).
        var barged = line.TakeBarge();
        if (!barged)
        {
            await line.PlayAsync(AudioOut.Beep(), GoogleTts.SampleRate);
            await Task.Delay(100);
        }
        if (!line.Active) return null;
        var wav = await new MicCapture().RecordFromPhone(line, barged ? line.RecentMic() : Array.Empty<byte[]>()) ?? Array.Empty<byte>();
        var minBytes = 44 + 16000 * 2 / 5;   // header + ~0.2s
        var text = wav.Length >= minBytes ? await Groq.Transcribe(wav, config) : "";
        Log.Write($"share: {name} answered on the phone ({text.Length} chars)");
        if (line.Active)
        {
            var bye = text.Trim().Length == 0 ? "Ich gebe die Frage weiter." : "Danke, ich gebe es weiter.";
            line.TakeBarge();
            if (await GoogleTts.Synthesize(bye, config) is { } byePcm)
                await line.PlayAsync(AudioOut.ApplyRate(byePcm, config.SpeakingRate), GoogleTts.SampleRate);
        }
        return text;   // the hold ends here: the line goes idle and his phone hangs up
    }

    // ---- the Wachhund (Watchdog.cs) ---------------------------------------------------

    private readonly WatchdogMemory _watchdogMemory = new();
    private System.Threading.Timer? _watchdogTimer;

    // Every 30 s: each working session's transcript tail → a finding → Sir is asked (at the PC /
    // on a call), or told by notification (Unterwegs without a call) — once per kind per 30 min.
    private void TickWatchdog()
    {
        try
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
        catch (Exception e) { Log.Write($"watchdog: {e.Message}"); }
    }

    // ---- the iPhone's Live Activity (docs/LIVE-ACTIVITIES.md) --------------------------

    private readonly LiveActivityFeed _activityFeed = new();
    private readonly WidgetPushFeed _widgetFeed = new();
    // A palette made by voice: sent at once and again on every (re)connect until the phone has it.
    private (string Name, string Frame)? _pendingPalette;
    private System.Threading.Timer? _activityTimer;
    private string? _seenActivityToken;
    private int _activityTicking;

    // Every 2 s: the sessions as the activity shows them → start / update / end by push.
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
            // The widgets: a silent push now and then, which the app stores for them.
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
            // A token APNs no longer knows: that activity (or the phone's start token) is gone.
            if (status == 410 || reply.Contains("BadDeviceToken"))
            {
                if (ev == LiveActivity.Event.Start) PhoneCall.SetActivityStart("", target.Env);
                else PhoneCall.SetActivity("", target.Env);
            }
        }
        catch (Exception e) { Log.Write($"live activity: {e.Message}"); }
        finally { Volatile.Write(ref _activityTicking, 0); }
    }

    // "Handy verbinden…": with a relay configured, make sure room + secret exist, connect, and
    // open the relay's pairing page (QR code) in the browser; without one, say how to set it.
    private void PairIPhone()
    {
        var config = RelayConfig.Pair();
        if (config is null) { ShowRelayHint(); return; }
        StartRelay();
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(RelayLink.PairPage(config)) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write($"relay: could not open the pairing page: {e.Message}"); }
    }

    // Connect to the relay when it is configured (launch, pairing); a no-op on unchanged settings.
    private void StartRelay()
    {
        var config = RelayConfig.Load().WithKey();
        if (_relay is not null && _relay.Config == config) return;
        _relay?.Stop();
        _relay = RelayClient.Create(config, () => _server.Sessions.Json(), OnPhone, PhoneCall.OnAudio);
        if (_relay is not null) _relay.OnConnected = PhoneCall.Resync;
        PhoneCall.Attach(_relay);
        _relay?.Start();
        if (_relay is not null) Clips.PrerenderGreet(Config.Load());   // the first "Hey Parley" answers at once
    }

    // A phone's message (docs/IPHONE.md, v1 + v2), on the relay's receive task.
    private void OnPhone(PhoneMessage message)
    {
        switch (message)
        {
            case PhoneResume r: _server.StartResume(r.Id); break;
            case PhoneCallState c:
                var wasInCall = PhoneCall.Active;
                PhoneCall.OnCall(c.Started, c.Down);
                if (c.Started && !wasInCall) _ = GreetCaller();
                break;
            case PhoneWake _: _server.StartWake(); break;
            case PhonePush p: PhoneCall.SetPush(p.Token, p.Env); break;
            case PhoneAway a: PhoneCall.SetAway(a.On); break;
            case PhoneLater l: PhoneCall.SetLater(l.After); break;
            case PhoneSilent s: PhoneCall.SetSilent(s.On); break;
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
            case PhoneBarge:
                PhoneCall.OnBarge();
                break;
            case PhoneHello:
                if (_pendingPalette is { } pending) _ = PhoneCall.Reply(pending.Frame);
                break;
            case PhonePaletteSaved saved:
                Log.Write($"palette: the phone saved {saved.Name}");
                if (_pendingPalette?.Name == saved.Name) _pendingPalette = null;
                break;
            case PhoneActivity a: PhoneCall.SetActivity(a.Token, a.Env); break;
            // v3: the phone's session view — history from Claude Code's transcript, its images,
            // and typed messages (delivered like a resume instruction).
            // ponytail: re-reads the 3 MB tail per poll (~3 s while open); cache by mtime if it shows.
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
                // An answer (typed, or tapped in the Live Activity) closes that session's question there.
                if (LiveActivity.CurrentAsk?.Id == s.Id) LiveActivity.CurrentAsk = null;
                _server.Resume(s.Id, s.Text);
                break;
            // v6: Snapshots — the list goes out with the next sessions frame; opening answers with
            // a `snapshot` frame (off the receive task: starts take a moment).
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
            // v7: shared sessions — Sir creates the invite (the link goes back), lets the guest in, ends it.
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

    private void RefreshRelayStatus()
    {
        _relayStatus.Visible = _relay is not null;
        _relayStatus.Text = _relay?.Connected == true ? "iPhone: verbunden mit Relay" : "iPhone: Relay nicht erreichbar";
        _callStatus.Visible = PhoneCall.Active;
        _awayStatus.Visible = PhoneCall.Away;
    }

    // "Push-Schlüssel wählen…": the APNs auth key (AuthKey_<KEYID>.p8 from Apple's developer
    // portal) → credentials.json apnsKeyId / apnsTeamId / apnsKeyP8. Checked by signing a token.
    private static void ChoosePushKey()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "APNs-Schlüssel wählen (AuthKey_<KEYID>.p8)",
            Filter = "APNs-Schlüssel (AuthKey_*.p8)|AuthKey_*.p8|Alle .p8-Dateien (*.p8)|*.p8",
            CheckFileExists = true,
        };
        if (dialog.ShowDialog() != DialogResult.OK) return;
        var keyId = ApnsJwt.KeyIdFromFileName(Path.GetFileName(dialog.FileName));
        if (keyId is null)
        {
            MessageBox.Show("Der Dateiname muss AuthKey_<KEYID>.p8 lauten — so lädt Apple den Schlüssel herunter; " +
                "die Key ID wird daraus gelesen.", "Push-Schlüssel", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        string pem;
        try
        {
            pem = File.ReadAllText(dialog.FileName);
            ApnsJwt.Build(keyId, Apns.DefaultTeamId, pem, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        }
        catch (Exception e)
        {
            Log.Write($"apns: chosen key unusable ({e.Message})");
            MessageBox.Show($"Das ist kein gültiger APNs-Schlüssel (.p8): {e.Message}", "Push-Schlüssel",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        var saved = Config.Merge(new Dictionary<string, string>
        {
            ["apnsKeyId"] = keyId,
            ["apnsTeamId"] = Apns.DefaultTeamId,
            ["apnsKeyP8"] = pem,
        });
        if (!saved)
        {
            MessageBox.Show("credentials.json konnte nicht gelesen werden — der Schlüssel wurde nicht gespeichert.",
                "Push-Schlüssel", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        Apns.ResetToken();
        Log.Write($"apns: push key {keyId} saved");
        MessageBox.Show($"Push-Schlüssel gespeichert (Key ID {keyId}, Team {Apns.DefaultTeamId}). " +
            "Im Unterwegs-Modus klingelt Parley jetzt dein iPhone an.", "Push-Schlüssel",
            MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private static void ShowRelayHint()
    {
        var answer = MessageBox.Show(
            "Fürs iPhone braucht Parley die Adresse deines Relays. Trag sie in credentials.json ein, z. B. " +
            "\"relayUrl\": \"https://parley-relay.<konto>.workers.dev\", und wähle dann erneut „Handy verbinden…“.\n\n" +
            Config.CredentialsPath + "\n\nOrdner jetzt öffnen?",
            "Relay nicht eingerichtet", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
        if (answer != DialogResult.Yes) return;
        try { System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{Config.CredentialsPath}\""); } catch { }
    }

    // Rebuild the dynamic "▶ <project> fortsetzen" items (mouse fallback for the voice
    // resume command — no dialog, continues with "Wir machen weiter.") at the top of the
    // tray menu each time it opens.
    private void RefreshParkedMenu(ContextMenuStrip menu)
    {
        for (var i = menu.Items.Count - 1; i >= 0; i--)
            if (menu.Items[i].Tag as string == "parked") menu.Items.RemoveAt(i);
        var list = _server.ResumableList();
        var idx = 0;
        foreach (var p in list)
        {
            var item = new ToolStripMenuItem($"▶ {p.Label} fortsetzen") { Tag = "parked" };
            var id = p.Id;
            item.Click += (_, _) => _server.Resume(id, Server.ResumeInstruction);
            menu.Items.Insert(idx++, item);
        }
        if (list.Count > 0) menu.Items.Insert(idx, new ToolStripSeparator { Tag = "parked" });
    }

    // The Snapshots submenu (as the macOS menu's section): each snapshot with its count — a click
    // opens it — then "Aktuellen Stand sichern …".
    private void RefreshSnapshotsMenu()
    {
        _snapshots.DropDownItems.Clear();
        foreach (var s in _server.Snapshots.List())
        {
            var item = new ToolStripMenuItem($"{s.Name.Replace("&", "&&")} ({s.Sessions.Count})") { ToolTipText = "Öffnen" };
            var id = s.Id;
            item.Click += (_, _) => Task.Run(() => _server.OpenSnapshot(id));
            _snapshots.DropDownItems.Add(item);
        }
        if (_snapshots.DropDownItems.Count > 0) _snapshots.DropDownItems.Add(new ToolStripSeparator());
        var save = new ToolStripMenuItem("Aktuellen Stand sichern …");
        save.Click += (_, _) => SaveSnapshot();
        _snapshots.DropDownItems.Add(save);
    }

    // "Geteilt" (as the macOS menu's section), below the Snapshots: each share a guest asked for or
    // joined — "Max · Website", "fragt an" while he waits for Sir — with "Entfernen".
    private void RefreshSharesMenu(ContextMenuStrip menu)
    {
        for (var i = menu.Items.Count - 1; i >= 0; i--)
            if (menu.Items[i].Tag as string == "shared") menu.Items.RemoveAt(i);
        var list = _shares.List().Where(x => x.State != "invited").ToList();
        if (list.Count == 0) return;
        var idx = menu.Items.IndexOf(_snapshots) + 1;
        menu.Items.Insert(idx++, new ToolStripSeparator { Tag = "shared" });
        menu.Items.Insert(idx++, new ToolStripMenuItem("Geteilt") { Enabled = false, Tag = "shared" });
        foreach (var s in list)
        {
            var text = $"{s.Guest?.Name ?? "Gast"} · {s.Label}" + (s.State == "asking" ? " — fragt an" : "");
            var item = new ToolStripMenuItem(text.Replace("&", "&&")) { Tag = "shared" };
            var remove = new ToolStripMenuItem("Entfernen");
            var id = s.Id;
            remove.Click += (_, _) => Task.Run(() => _shares.Remove(id));
            item.DropDownItems.Add(remove);
            menu.Items.Insert(idx++, item);
        }
    }

    // "Aktuellen Stand sichern …": a name, then every running session under it. As macOS (NSAlert).
    private void SaveSnapshot()
    {
        var name = TextPrompt.Ask("Snapshot sichern", "Merkt sich Name, Session-ID und Ordner jeder laufenden Session.",
            "Name, z. B. Kunde Müller", "Sichern");
        if (name is null) return;
        if (_server.SaveSnapshot(name) is null)
            MessageBox.Show("Snapshot: Name fehlt oder keine Session läuft", "Parley", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }

    private void TestRecordingPill()
    {
        _pill.BeginInvoke(() =>
        {
            _pill.ShowPill();
            var t = new System.Windows.Forms.Timer { Interval = 33 };
            var n = 0;
            t.Tick += (_, _) => { _pill.Push((float)(0.2 + new Random().NextDouble() * 0.7)); if (++n > 90) { t.Stop(); _pill.HidePill(); } };
            t.Start();
        });
    }
}

