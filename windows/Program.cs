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
        _pipeline = new TurnPipeline(() => serverRef?.QueuedTurns ?? 0, _pill);
        _server = new Server(turn => _pipeline.Run(turn), () => StatsStore.StartSession());
        serverRef = _server;

        var menu = new ContextMenuStrip();
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

        try { _server.Start(); }
        catch (Exception e)
        {
            Log.Write($"server start failed: {e.Message}");
            MessageBox.Show($"Parley konnte Port 8787 nicht öffnen: {e.Message}", "Parley");
        }
    }
}
