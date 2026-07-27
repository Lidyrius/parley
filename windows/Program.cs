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

    public TrayApp()
    {
        _ = _pill.Handle;   // create the handle on the UI thread so BeginInvoke works

        Server? serverRef = null;
        _pipeline = new TurnPipeline(() => serverRef?.QueuedTurns ?? 0, _pill,
            () => serverRef?.ParkedList() ?? new List<Server.ParkedInfo>(),
            (id, instr) => serverRef?.Wake(id, instr));
        _server = new Server(turn => _pipeline.Run(turn), () => StatsStore.StartSession());
        serverRef = _server;

        var menu = new ContextMenuStrip();
        // Parked (paused-but-resumable) sessions are inserted at the top on open.
        menu.Opening += (_, _) => RefreshParkedMenu(menu);
        var mute = new ToolStripMenuItem("Stumm schalten") { CheckOnClick = true };
        mute.CheckedChanged += (_, _) =>
        {
            _pipeline.Muted = mute.Checked;
            _tray!.Text = mute.Checked ? "Parley (stumm)" : "Parley";
        };
        menu.Items.Add(mute);
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
        quit.Click += (_, _) => { _tray!.Visible = false; Application.Exit(); };
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
    }

    // Rebuild the dynamic "▶ <project> fortsetzen" items (mouse fallback for the voice
    // resume command) at the top of the tray menu each time it opens.
    private void RefreshParkedMenu(ContextMenuStrip menu)
    {
        for (var i = menu.Items.Count - 1; i >= 0; i--)
            if (menu.Items[i].Tag as string == "parked") menu.Items.RemoveAt(i);
        var list = _server.ParkedList();
        var idx = 0;
        foreach (var p in list)
        {
            var item = new ToolStripMenuItem($"▶ {p.Label} fortsetzen") { Tag = "parked" };
            var id = p.Id;
            item.Click += (_, _) => _server.Wake(id, "Wir machen weiter.");
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

