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
    private RelayClient? _relay;

    public TrayApp()
    {
        _ = _pill.Handle;   // create the handle on the UI thread so BeginInvoke works

        Server? serverRef = null;
        _pipeline = new TurnPipeline(() => serverRef?.QueuedTurns ?? 0, _pill,
            () => serverRef?.ResumableList() ?? new List<Server.ParkedInfo>(),
            (id, instr) => serverRef?.Resume(id, instr),
            id => serverRef?.Sessions.OthersAlive(id) ?? false);
        _server = new Server(turn => _pipeline.Run(turn), () => StatsStore.StartSession());
        serverRef = _server;
        // A session's label appeared → pre-render its "Update zu" + resume lines in the
        // background, so the first announcement / resume click is instant.
        _server.Sessions.OnLabel = label => Clips.Prerender(label, Config.Load());
        // iPhone (docs/IPHONE.md, v2): Unterwegs-Modus rings before a turn; a wake utterance is
        // routed to a session or the Zentrale. The phone's settings survive restarts.
        _pipeline.Ring = label => Ringer.Ring(label);
        _pipeline.SetCallback = (id, at) => _server.Sessions.SetCallback(id, at);
        _server.OnPalette = (name, frame) =>
        {
            Log.Write($"palette: {name} → the phone");
            _pendingPalette = (name, frame);
            _ = PhoneCall.Reply(frame);
        };
        _pipeline.Route = (text, config) => _server.Delivery.Route(text, config);
        PhoneCall.LoadSettings(Config.Load());

        var menu = new ContextMenuStrip();
        // Resumable sessions (parked, or idle with the mod running) are inserted at the top on open.
        menu.Opening += (_, _) => { RefreshParkedMenu(menu); RefreshRelayStatus(); };
        var mute = new ToolStripMenuItem("Stumm schalten") { CheckOnClick = true };
        mute.CheckedChanged += (_, _) =>
        {
            _pipeline.Muted = mute.Checked;
            _tray!.Text = mute.Checked ? "Parley (stumm)" : "Parley";
        };
        menu.Items.Add(mute);
        // iPhone (docs/IPHONE.md): pairing opens the relay's QR page; the status line is set on open.
        var pair = new ToolStripMenuItem("iPhone verbinden…");
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
            Icon = System.Drawing.SystemIcons.Application,
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
        _activityTimer = new System.Threading.Timer(_ => TickLiveActivity(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        _watchdogTimer = new System.Threading.Timer(_ => TickWatchdog(), null, TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));
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
                var calls = Watchdog.Calls(Transcript.TailLines(file, 256 * 1024));
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

    // "iPhone verbinden…": with a relay configured, make sure room + secret exist, connect, and
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
        var config = RelayConfig.Load();
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
            case PhoneCallState c: PhoneCall.OnCall(c.Started, c.Down); break;
            case PhoneWake _: _server.StartWake(); break;
            case PhonePush p: PhoneCall.SetPush(p.Token, p.Env); break;
            case PhoneAway a: PhoneCall.SetAway(a.On); break;
            case PhoneLater l: PhoneCall.SetLater(l.After); break;
            case PhoneSilent s: PhoneCall.SetSilent(s.On); break;
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
            "\"relayUrl\": \"https://parley-relay.<konto>.workers.dev\", und wähle dann erneut „iPhone verbinden…“.\n\n" +
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

