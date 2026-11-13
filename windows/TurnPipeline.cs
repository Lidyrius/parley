namespace Parley;

// The per-turn voice pipeline — full port of the macOS flow:
// TTS prefetch (+ learned timing) → smart media pause → project announcement (another
// session alive) → speak at speaking rate (+beep on listen turns) → record with pill overlay
// (VAD) → transcribe (min-audio guard) → classify → cached ack line + media resume in
// the background (transcript returns immediately) → stats. "" ends the conversation.
// iPhone (docs/IPHONE.md, v2): in a call every step speaks/listens through the phone (AudioOut,
// MicCapture); Unterwegs-Modus rings the phone first; plus the wake greeting and the permission
// question, which ride the same gate as turns.
public sealed class TurnPipeline
{
    public volatile bool Muted;
    // Set once at startup. Ring: Unterwegs-Modus — ring the phone for this label and wait for
    // the call (true = connected). Route: a wake utterance → delivered; returns the line to confirm with.
    public Func<string, Task<RingOutcome>>? Ring;
    // The phone's tile for a session whose call was put off (see Sessions.SetCallback).
    public Action<string, DateTime?>? SetCallback;
    // "Ich rufe zurück". The Linux host is always Unterwegs and may shorten it (PARLEY_CALLBACK_WAIT_SECONDS).
    private static readonly TimeSpan CallBackWait = !OperatingSystem.IsWindows()
        && int.TryParse(Environment.GetEnvironmentVariable("PARLEY_CALLBACK_WAIT_SECONDS"), out var seconds) && seconds >= 0
        ? TimeSpan.FromSeconds(seconds) : TimeSpan.FromMinutes(30);
    public Func<string, Config, Task<string>>? Route;
    // The server — what Sir missed is kept there (Supervisor.cs, Missed). Set once at startup.
    public Server? Host;
    private readonly MicCapture _mic = new();
    private readonly Func<int> _queuedTurns;
    private readonly PillOverlay? _pill;
    private readonly Func<List<Server.ParkedInfo>>? _resumableList;   // parked / idle-with-mod sessions
    private readonly Action<string, string>? _resume;                 // (id, instruction)
    private readonly Func<string, bool>? _othersAlive;   // any session besides this one not stopped
    private List<string> _pendingResume = new();
    private volatile int _resumeGen;   // bumped per turn; cancels a pending debounced resume
    private Task? _ackTask;
    private volatile bool _abandoned;   // this turn's answer was typed instead (POST /turn/cancel)

    // Hookless (docs/HOOKLESS.md): Sir typed before the voice reply came — the turn being voiced
    // records nothing more (the server delivers nothing of it).
    public void Abandon()
    {
        _abandoned = true;
        _mic.Abandon();
    }

    public TurnPipeline(Func<int> queuedTurns, PillOverlay? pill,
        Func<List<Server.ParkedInfo>>? resumableList = null, Action<string, string>? resume = null,
        Func<string, bool>? othersAlive = null)
    {
        _queuedTurns = queuedTurns;
        _pill = pill;
        _resumableList = resumableList;
        _resume = resume;
        _othersAlive = othersAlive;
    }

    public async Task<(string transcript, bool park, int wait, string resume)> Run(TurnPayload turn)
    {
        LiveStatus.Begin(turn.SessionId);
        PhoneCall.SetSpeaker(turn.SpokenLabel.Length == 0 ? "Parley" : turn.SpokenLabel);   // wake dialog: Parley itself
        try
        {
            await AwaitHangUp();
            if (turn.Event == Server.ResumeEvent) return await RunResume(turn);
            if (turn.Event == Server.WakeEvent) return await RunWake(turn);
            if (turn.Event is Server.PermissionEvent or Server.WatchdogEvent) return await RunPermission(turn);
            if (turn.Event == Server.ReminderEvent) return await RunReminder(turn);
            if (turn.Event == Server.CallbackEvent) return await RunCallBack(turn);
            return await RunTurn(turn);
        }
        finally { LiveStatus.Set("idle"); _abandoned = false; }
    }

    // The phone hangs up after a line sent as `last`; a turn that came in meanwhile waits for
    // that (≤ 4 s) and rings anew — instead of talking into a line that is going down.
    private static async Task AwaitHangUp()
    {
        if (!PhoneCall.Line.Ending) return;
        var until = DateTime.UtcNow.AddSeconds(4);
        while (PhoneCall.Active && DateTime.UtcNow < until) await Task.Delay(100);
        Log.Write(PhoneCall.Active ? "phone: still on after the last line — the next one follows" : "phone: hung up after the last line → rings anew");
        PhoneCall.Line.MarkEnding(false);
    }

    // POST /resume (the mod's button): a short voice dialog instead of a hook turn — the
    // pre-recorded "Ich habe die Arbeit an X wieder aufgenommen…" line, then beep → record →
    // transcribe exactly like a listening turn. No "Update zu" announcement. The transcript
    // ("" → the default instruction) goes back to the server, which hands it to the session.
    private async Task<(string transcript, bool park, int wait, string resume)> RunResume(TurnPayload turn)
    {
        var config = Config.Load();
        _resumeGen++;
        Log.Write($"resume dialog start project={turn.Project}");
        var (_, calledBack) = await ReachPhone(turn.SpokenLabel, Server.SessionKey(turn));
        if (PhoneCall.Away && !PhoneCall.Active)
        {
            Log.Write("Unterwegs, phone not reached → resuming without dialog (the PC stays silent)");
            return ("", false, 0, "");
        }
        if (Muted && !PhoneCall.Active)
        {
            Log.Write("muted → resuming without dialog");
            return ("", false, 0, "");
        }
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }
        if (calledBack && !config.Brief) await ThankForCallingBack(config);
        PhoneCall.Line.SwitchTopic(Server.SessionKey(turn));

        // Cached line, or synthesized live + cached; null → no TTS, just the beep.
        var line = await Clips.ResumeClip(turn.SpokenLabel, config);
        await PauseMediaIfPlaying();
        var beeped = line is not null && await AudioOut.PlayPcm(AudioOut.ApplyRate(line, config.SpeakingRate), beep: true);

        var (_, text) = await ListenOnce(config, beeped: beeped);
        Log.Write($"resume dialog done chars={text.Length}");
        StartAck(Groq.Intent.Other, text.Length > 0, config);
        return (text, false, 0, "");
    }

    // "Hey Parley" during a call: cached greeting → beep → listen on the phone → route the
    // utterance (a running session by name, else the Zentrale) → a short spoken confirmation.
    private async Task<(string transcript, bool park, int wait, string resume)> RunWake(TurnPayload turn)
    {
        var config = Config.Load();
        _resumeGen++;
        Log.Write("wake: greeting");
        if (Muted)
        {
            Log.Write("muted → ignoring the wake word");
            return ("", false, 0, "");
        }
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }

        var greeting = config.Brief ? null : await Clips.GreetClip(config);
        var beeped = greeting is not null && await AudioOut.PlayPcm(AudioOut.ApplyRate(greeting, config.SpeakingRate), beep: true);
        var (_, text) = await ListenOnce(config, beeped: beeped);
        if (text.Length == 0)
        {
            Log.Write("wake: nothing said");
            return ("", false, 0, "");
        }
        string line;
        try
        {
            // "Hey Parley" after a call he didn't take: what he missed and what he says now go
            // to the Zentrale together.
            if (Host is { } host && host.TakeMissed(text) is { } all)
            {
                host.Delivery.ToZentrale(all, config);
                line = Zentrale.TakeOver[Random.Shared.Next(Zentrale.TakeOver.Length)];
            }
            else line = Route is null ? "" : await Route(text, config);
        }
        catch (Exception e)
        {
            Log.Write($"wake: routing failed ({e.Message})");
            line = "Das konnte ich leider nicht weitergeben, Sir.";
        }
        if (line.Length > 0 && !config.Brief) await SpeakLine(line, config);
        Log.Write($"wake: done chars={text.Length}");
        return (text, false, 0, "");
    }

    // POST /permission: "<Projekt> möchte … — erlauben?" → beep → listen. The transcript goes back;
    // the server maps it to allow / deny / ask. No TTS (nothing could be asked) or past the
    // request's deadline → "" (= ask: the on-screen prompt decides).
    // A Wiedervorlage for Sir (Reminders.cs), spoken like an update: the phone rings when
    // Unterwegs; muted, Stumm or not reached → a notification (and an alert on the phone). As macOS.
    private async Task<(string transcript, bool park, int wait, string resume)> RunReminder(TurnPayload turn)
    {
        var none = ("", false, 0, "");
        var config = Config.Load();
        _resumeGen++;
        var synth = GoogleTts.Synthesize(turn.Speak, config);
        if (PhoneCall.Away && !PhoneCall.Silent && !PhoneCall.Active) await ReachPhone("Parley", "");
        if ((Muted || PhoneCall.Away) && !PhoneCall.Active)
        {
            Log.Write("reminder → notification");
            Notifier.Notify("Parley · Erinnerung", turn.Speak);
            if (PhoneCall.Away) _ = Apns.SendAlert("Parley · Erinnerung", turn.Speak, "");
            return none;
        }
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }
        if (await synth is not { } pcm)
        {
            Notifier.Notify("Parley · Erinnerung", turn.Speak);
            return none;
        }
        await PauseMediaIfPlaying();
        await AudioOut.PlayPcm(AudioOut.ApplyRate(pcm, config.SpeakingRate), caption: turn.Speak, last: _queuedTurns() == 0);
        ScheduleResume();
        return none;
    }

    private async Task<(string transcript, bool park, int wait, string resume)> RunPermission(TurnPayload turn)
    {
        var config = Config.Load();
        _resumeGen++;
        Log.Write($"permission question project={turn.Project}");
        if (Muted)
        {
            Log.Write("muted → permission left to the screen");
            return ("", false, 0, "");
        }
        var synth = GoogleTts.Synthesize(turn.Speak, config);
        await ReachPhone(turn.SpokenLabel, Server.SessionKey(turn), callBack: false);
        if (PhoneCall.Away && !PhoneCall.Active)
        {
            Log.Write("Unterwegs, phone not reached → permission left to the screen");
            return ("", false, 0, "");
        }
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }
        var pcm = await synth;
        if (pcm is null || DateTime.UtcNow >= (turn.Deadline ?? DateTime.MaxValue))
        {
            Log.Write(pcm is null ? "permission: no TTS → left to the screen" : "permission: too late to ask → left to the screen");
            return ("", false, 0, "");
        }
        await PauseMediaIfPlaying();
        var beeped = await AudioOut.PlayPcm(AudioOut.ApplyRate(pcm, config.SpeakingRate), caption: turn.Speak, beep: true);
        var (_, text) = await ListenOnce(config, beeped: beeped);
        ScheduleResume();
        Log.Write($"permission answer chars={text.Length}");
        return (text, false, 0, "");
    }

    // The question with its predicted answers into the iPhone's Live Activity: a tap answers it.
    private static void AskInLiveActivity(TurnPayload turn)
    {
        if (!turn.WantsListen) return;
        LiveActivity.CurrentAsk = LiveActivity.Ask.From(Server.SessionKey(turn), turn.SpokenLabel, turn.Speak,
                                                        (turn.Replies ?? new List<Reply>()).Select(r => r.On));
    }

    private async Task<(string transcript, bool park, int wait, string resume)> RunTurn(TurnPayload turn)
    {
        var config = Config.Load();
        Log.Write($"turn start project={turn.Project} listen={turn.WantsListen}");
        _resumeGen++;

        // Unterwegs + Stumm: no call, no voice on the PC — a notification, and the session waits
        // (parked) for a reply typed on the phone.
        if (PhoneCall.Away && PhoneCall.Silent && !PhoneCall.Active)
        {
            Log.Write($"Unterwegs + Stumm → notification for {turn.SpokenLabel}");
            _ = Apns.SendAlert($"Parley · {turn.SpokenLabel}", turn.Speak, Server.SessionKey(turn));
            AskInLiveActivity(turn);
            return ("", turn.WantsListen, 0, "");
        }

        if (Muted)
        {
            Log.Write("muted → skipping turn");
            // Stumm: nicht sprechen, aber die Zusammenfassung als Notification zeigen.
            Notifier.Notify($"Parley · {turn.SpokenLabel}", turn.Speak);
            return ("", false, 0, "");
        }

        // Überwachungsmodus: a call Sir didn't take must not hold the Zentrale. While lines of it
        // wait for his call back, a new one joins them — no new ring. And once he can hear again
        // (he is in a call, or back at the PC) all of them come as one summary, not this line alone.
        var session = Server.SessionKey(turn);
        var ringing = ShouldRing;
        if (Host is { MissedCount: > 0 } waits && waits.IsZentrale(session))
        {
            if (ringing) return MissedTurn(turn, first: false);
            if (PhoneCall.Active || !PhoneCall.Away)
            {
                waits.AddMissed(turn);
                waits.CallBack();
                return ("", true, 0, "");
            }
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

        // Predicted answers (<reply>): render their lines now, in parallel with everything
        // below — ready long before the user stops talking.
        var replies = turn.WantsListen ? turn.Replies ?? new List<Reply>() : new List<Reply>();
        var replyClips = Task.WhenAll(replies.Select(r => GoogleTts.Synthesize(r.Say, config)));

        // Unterwegs-Modus (docs/IPHONE.md, v2): no call yet → ring the phone and wait for it
        // (≤ 45 s) while the synthesis runs; unanswered, the turn plays on the speaker.
        // "Not now" on the phone puts the line off: ring again in a minute or five, or wait for
        // Sir's call back (the phone's tile offers "Rückrufen") — then thank him first.
        // Fragerunde: right after a call, gather for a few minutes, then ring once for all.
        if (ringing) await GatherRound(session);
        var rang = ringing && !PhoneCall.Active;
        // The line's voice is ready before the phone rings: once Sir answers it goes out in one
        // piece (a phone that takes clips plays it only when it holds all of it).
        if (rang) await prefetch;
        var calledBack = false;
        if (rang && Ring is { } ringOnce && Host?.IsZentrale(session, supervised: true) == true)
        {
            // One ring. Not taken (or "not now"): the line is kept for his call back and the
            // Zentrale goes on — no waiting half an hour with everything behind it.
            var rung = await ringOnce(turn.SpokenLabel);
            if (rung.Kind == RingKind.Later) return MissedTurn(turn, first: true, ringAgain: rung.After);
            if (rung.Kind == RingKind.Missed) return MissedTurn(turn, first: true);
        }
        else (_, calledBack) = await ReachPhone(turn.SpokenLabel, session);
        if (ringing && PhoneCall.Active && !config.Brief) await AnnounceRound(config);
        // Unterwegs and not on the phone: the PC stays silent — the line waits as a notification.
        if (PhoneCall.Away && !PhoneCall.Active)
        {
            Log.Write($"Unterwegs, phone not reached → notification for {turn.SpokenLabel}");
            _ = Apns.SendAlert($"Parley · {turn.SpokenLabel}", turn.Speak, Server.SessionKey(turn));
            AskInLiveActivity(turn);
            return ("", turn.WantsListen, 0, "");
        }
        if (calledBack && !config.Brief) await ThankForCallingBack(config);

        // Wait out the previous turn's background ack so audio never overlaps.
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }

        // Another session alive (any state but stopped) → cached "Update zu <Name>"
        // announcement (instant audio → pause right away).
        // In a call that was about another session, always (even Ohne Floskeln): else Sir answers
        // the wrong one.
        var switched = PhoneCall.Line.SwitchTopic(Server.SessionKey(turn));
        byte[]? announcement = switched || !config.Brief && _othersAlive?.Invoke(Server.SessionKey(turn)) == true
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
        // Barge-in at the PC: talking over the line cuts it (in a call the phone watches itself).
        var watch = pcm is not null && config.BargeIn && !PhoneCall.Active && !PhoneCall.Away ? new BargeWatch(turn.Speak) : null;
        var beeped = false;   // the beep went with the line (a phone that takes clips, v8)
        if (pcm is not null)
        {
            Log.Write($"speak start ({pcm.Length} bytes, rate {config.SpeakingRate:0.00})");
            beeped = await AudioOut.PlayPcm(AudioOut.ApplyRate(pcm, config.SpeakingRate), caption: turn.Speak,
                                            slides: turn.Slides, session: Server.SessionKey(turn),
                                            last: !turn.WantsListen && _queuedTurns() == 0,
                                            cancellationToken: watch?.Heard ?? default, beep: turn.WantsListen);
        }
        else Log.Write("no TTS audio (missing key or synth failed)");
        var localPreroll = watch is null ? null : await watch.Stop();
        // Barge-in: Sir talked over Parley — listen now (even after a speak-only line), with the
        // seconds he already spoke.
        var barged = PhoneCall.TakeBarge() || watch?.Barged == true;
        if (barged) Log.Write("barge-in: listening");

        if (!turn.WantsListen && !barged)
        {
            ScheduleResume();
            // Ich melde mich selbst zurück — Notification fängt dich, falls du weg bist.
            Notifier.Notify($"Parley · {turn.SpokenLabel}", turn.Speak);
            Log.Write("turn end (speak-only)");
            return ("", false, 0, "");
        }

        // Record → transcribe. A CONTROL command (resume a parked / idle project by voice) is
        // handled here and we re-record for THIS session's real answer. Capped to 4 hops.
        byte[] wav = Array.Empty<byte>();
        var text = "";
        for (var hop = 0; hop < 4; hop++)
        {
            (wav, text) = await ListenOnce(config, barged && hop == 0, watch?.Barged == true ? localPreroll : null, beeped);

            var parked = _resumableList?.Invoke() ?? new List<Server.ParkedInfo>();
            if (text.Length == 0 || parked.Count == 0 || hop >= 3) break;
            var cmd = await Groq.DetectControlCommand(text, parked.Select(p => p.Label).ToList(), config);
            if (cmd is not { Resume: true }) break;
            var target = MatchParked(cmd.Value.Target, parked);
            if (target is null) break;

            var instruction = string.IsNullOrWhiteSpace(cmd.Value.Instruction) ? Server.ResumeInstruction : cmd.Value.Instruction;
            _resume?.Invoke(target.Value.Id, instruction);
            Log.Write($"control: resume {target.Value.Label} → \"{instruction}\"");
            beeped = await SpeakLine($"Verstanden, Sir — ich nehme {target.Value.Label} wieder auf. Und für dieses Projekt?", config, beep: true);
            // loop: listen again for the current session's actual reply
        }

        // "Warte X Minuten" — pause before continuing (checked before STOP, which also
        // matches "warte"). Confirm, resume media for the wait, tell the hook to sleep then
        // re-inject a resume prompt so Claude picks up automatically.
        if (text.Length > 0)
        {
            var wait = await Groq.ClassifyWait(text, config);
            if (wait > 0)
            {
                var human = HumanDuration(wait);
                Log.Write($"wait requested: {wait}s");
                StatsStore.RecordTurn(turn.Speak, text, 0, "WAIT", turn.Project);
                await SpeakLine($"Verstanden, Sir. Ich warte {human} und melde mich dann.", config);
                ScheduleResume();
                var resume = $"[Parley] Die vom Nutzer angeforderte Wartezeit von {human} ist vorbei. " +
                    "Fahre jetzt fort: prüfe, ob alles wie erwartet funktioniert hat, und berichte kurz." +
                    $"\n\nSeine Antwort davor, vollständig:\n{text}";
                return ("", false, wait, resume);
            }
        }

        // In parallel with the intent: which predicted answer (<reply>) it is, if any.
        var pick = text.Length == 0 ? Task.FromResult<int?>(null) : Groq.PickReply(text, replies.Select(r => r.On).ToList(), config);
        var intent = text.Length == 0 ? Groq.Intent.Other : await Groq.Classify(text, config);
        Log.Write($"classified: {intent}");

        var recordSeconds = Math.Max(0, wav.Length - 44) / 2.0 / 16000.0;
        StatsStore.RecordTurn(turn.Speak, text, recordSeconds, intent.ToString().ToUpperInvariant(), turn.Project);

        // A predicted answer matched → its own line instead of the generic ack (pre-rendered,
        // plays at once). One that asks back opens the mic again; both answers go on.
        (string say, byte[]? clip)? line = null;
        var picked = await pick;
        if (picked is null && replies.Count > 0) Log.Write($"reply: none of {replies.Count} fits");
        // Asking back after an answer that already says what to do would be wrong: generic ack.
        if (picked is int a && replies[a].Listen == true && text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length > 12)
        {
            Log.Write($"reply: {replies[a].On} asks back, but the answer is already detailed → generic ack");
            picked = null;
        }
        if (picked is int i)
        {
            var r = replies[i];
            var clip = (await replyClips)[i];
            Log.Write($"reply: {r.On} → \"{r.Say}\" (rendered={clip is not null})");
            if (r.Listen == true)
            {
                var asked = await SpeakLine(r.Say, config, clip, beep: true);
                var (_, more) = await ListenOnce(config, beeped: asked);
                text += $"\n\n[Parley hat nachgefragt: „{r.Say}“]" + (more.Length == 0 ? "" : "\n" + more);
                intent = more.Length == 0 ? Groq.Intent.Other : await Groq.Classify(more, config);
            }
            else if (!config.Brief)
            {
                line = (r.Say, clip);
                text += $"\n\n[Parley hat darauf bereits geantwortet: „{r.Say}“ – nicht wiederholen.]";
            }
        }
        StartAck(intent, text.Length > 0, config, line);

        // "Stop heißt Stop" — reply isn't fed back, but the session PARKS (stays resumable
        // by voice/tray) instead of ending. A silent turn parks too.
        if (intent == Groq.Intent.Stop)
        {
            Log.Write("turn end (stop → parked, resumable)");
            return ("", true, 0, "");
        }
        // A failed transcription is not silence: parking on it would loop the hook forever.
        if (text.Length == 0 && _sttFailed)
        {
            Log.Write("turn end (transcription failed → not parked)");
            return ("", false, 0, "");
        }
        if (text.Length == 0)
        {
            Log.Write("turn end (silence → parked, resumable)");
            return ("", true, 0, "");
        }
        Log.Write("turn end");
        return (text, false, 0, "");
    }

    // ---- a call Sir didn't take (Überwachungsmodus; Supervisor.cs, Missed) — as macOS -------

    // Ring only in Unterwegs-Modus with no call yet, and when the phone can be reached at all.
    private static bool ShouldRing => Ringer.CanRing && !PhoneCall.Active;

    private DateTime _missedNoticeAt = DateTime.MinValue;
    private static readonly TimeSpan SummaryWait = TimeSpan.FromSeconds(60);

    /// The Zentrale's line is kept for Sir's call back; its turn ends now — nothing waits for him.
    /// `first`: this is the line that rang: the Zentrale learns that he didn't answer.
    private (string transcript, bool park, int wait, string resume) MissedTurn(TurnPayload turn, bool first, double? ringAgain = null)
    {
        var n = Host!.AddMissed(turn, ringAgain);
        Log.Write($"missed: {turn.SpokenLabel} — {(first ? "the call was not taken" : "no new ring")}, {n} line(s) wait for Sir's call back"
            + (ringAgain is double again ? $", ringing once more in {(int)again} s" : ""));
        // One notification, then at most one every quarter of an hour with the count — the Live
        // Activity shows it all the time (LiveActivity.FromSessions reads `missed`).
        if ((first || DateTime.UtcNow - _missedNoticeAt >= Missed.NoticeEvery) && PhoneCall.Alert.Token.Length > 0)
        {
            _missedNoticeAt = DateTime.UtcNow;
            _ = Apns.SendAlert($"Parley · {turn.SpokenLabel}", Missed.Waiting(n) + ". Zuletzt: " + turn.Speak, Server.SessionKey(turn));
        }
        return (first ? Missed.Note : "", true, 0, "");
    }

    /// Sir is back — he called, pressed "Anrufen", or the ring he asked for was taken: everything
    /// he missed goes to the Zentrale as one instruction, and the gate is held until its summary
    /// waits there (no hang-up in between, no second ring).
    private async Task<(string transcript, bool park, int wait, string resume)> RunCallBack(TurnPayload turn)
    {
        var none = ("", false, 0, "");
        if (Host is not { } host) return none;
        if (turn.Speak == "ring")   // "In 5 Min.": the one ring he asked for
        {
            if (!ShouldRing || host.MissedCount == 0 || Ring is not { } ringOnce) return none;
            if ((await ringOnce(Routing.ZentraleName)).Kind != RingKind.Answered)
            {
                Log.Write("missed: the ring Sir asked for was not taken either — the lines keep waiting");
                return none;
            }
        }
        if ((PhoneCall.Away && !PhoneCall.Active) || host.TakeMissed() is not { } all) return none;
        Log.Write("missed: Sir is back — what he missed goes to the Zentrale for one summary");
        var config = Config.Load();
        host.Delivery.ToZentrale(all, config);
        if (_ackTask is not null) { await _ackTask; _ackTask = null; }
        if (!config.Brief)
        {
            var de = config.Language.StartsWith("de", StringComparison.OrdinalIgnoreCase);
            await SpeakLine(de ? "Einen Moment, Sir, ich fasse zusammen, was Sie verpasst haben."
                               : "One moment, Sir, I'll sum up what you missed.", config);
        }
        var until = DateTime.UtcNow + SummaryWait;
        while (DateTime.UtcNow < until && _queuedTurns() == 0 && (PhoneCall.Active || !PhoneCall.Away)) await Task.Delay(100);
        return none;
    }

    // Beep → record (pill + VAD) → transcribe (min-audio guard): one listening pass.
    /// Rings (Unterwegs), and follows the phone's "not now": rings again after the delay, or
    /// waits up to 30 min for Sir's own call (the tile offers "Rückrufen").
    /// `callBack`: a call Sir didn't take counts as "Ich rufe zurück" too (not for a permission
    /// prompt — its hook gives up after two minutes). As macOS.
    private async Task<(bool reached, bool calledBack)> ReachPhone(string label, string session, bool callBack = true)
    {
        if (Ring is null || PhoneCall.Active) return (PhoneCall.Active, false);
        // Nothing to ring (at the PC, Stumm, or no way to the phone): no ring and no waiting for
        // a call back — the turn is voiced here, or waits as a notification.
        if (!Ringer.CanRing) return (false, false);
        async Task<RingOutcome> RingOnce()
        {
            var o = await Ring!(label);
            if (o.Kind != RingKind.Missed || !callBack) return o;
            Log.Write("phone: not answered → waits for Sir's call back");
            return new RingOutcome(RingKind.Later);
        }
        var outcome = await RingOnce();
        var calledBack = false;
        for (var repeats = 0; outcome.Kind == RingKind.Later; repeats++)
        {
            if (repeats >= 3)   // put off three times: the line waits as a notification
            {
                Log.Write("phone: put off 3 times → not reached");
                break;
            }
            if (outcome.After is double after)
            {
                var at = DateTime.UtcNow.AddSeconds(after);
                SetCallback?.Invoke(session, at);
                while (DateTime.UtcNow < at && !PhoneCall.Active) await Task.Delay(250);
                SetCallback?.Invoke(session, null);
                outcome = PhoneCall.Active ? new RingOutcome(RingKind.Answered) : await RingOnce();
            }
            else
            {
                SetCallback?.Invoke(session, DateTime.MaxValue);
                calledBack = await PhoneCall.WaitForCall(CallBackWait);
                SetCallback?.Invoke(session, null);
                Log.Write(calledBack ? "phone: Sir called back" : $"phone: no call back in {(int)CallBackWait.TotalMinutes} min");
                outcome = new RingOutcome(calledBack ? RingKind.Answered : RingKind.Missed);
            }
        }
        return (outcome.Kind == RingKind.Answered, calledBack);
    }

    // ---- Fragerunde (as macOS) ----------------------------------------------------------

    // After a call, the next updates don't ring at once while other sessions still work: for up
    // to the phone's setting (90 s by default, 0 = off) they gather (queued,
    // shown so in the Island) and then come as one round. Sir calling in meanwhile starts it.
    // Permission prompts never wait.
    // Another session besides this one is still working (an update may follow soon).
    public Func<string, bool>? OthersWorking;
    // Sir's own timer ran out for this session's turn / for one waiting at the gate.
    public Func<string, bool>? AfterWait;
    public Func<bool>? TimerQueued;

    // Only while more can come: another session still working. Nothing else at work → it rings
    // at once (waiting would only delay this one update). Sir's own timer ("ruf mich in 2
    // Minuten zurück") never waits: its turn rings at once, and one queued behind ends the wait.
    private async Task GatherRound(string session)
    {
        var gap = TimeSpan.FromSeconds(Config.Load().RoundSeconds);   // the phone's setting; 0 = off
        if (gap <= TimeSpan.Zero || PhoneCall.LastCallEnd is not { } end || PhoneCall.Active) return;
        var ready = end + gap;
        bool More() => OthersWorking?.Invoke(session) == true;
        bool Timer() => TimerQueued?.Invoke() == true;
        if (DateTime.UtcNow >= ready || !More()) return;
        if (AfterWait?.Invoke(session) == true) { Log.Write("Fragerunde: skipped — Sir's timer ran out"); return; }
        Log.Write($"Fragerunde: gathering until {ready.ToLocalTime():HH:mm:ss}");
        LiveStatus.Set("queued");
        while (DateTime.UtcNow < ready && !PhoneCall.Active && PhoneCall.Away && More() && !Timer()) await Task.Delay(500);
        var why = DateTime.UtcNow >= ready ? "waited long enough" : Timer() ? "Sir's timer ran out" : "nothing else at work";
        Log.Write($"Fragerunde: ringing now ({why})");
        LiveStatus.Set("speaking");
    }

    // "Ich habe drei Updates für Sie, Sir." — before the first of several in a new call.
    private async Task AnnounceRound(Config config)
    {
        var n = 1 + _queuedTurns();
        if (n < 2) return;
        var de = config.Language.StartsWith("de", StringComparison.OrdinalIgnoreCase);
        string[] words = { "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun" };
        var count = n - 2 < words.Length ? words[n - 2] : n.ToString();
        Log.Write($"Fragerunde: {n} updates");
        await SpeakLine(de ? $"Ich habe {count} Updates für Sie, Sir." : $"I have {n} updates for you, Sir.", config);
    }

    private async Task ThankForCallingBack(Config config)
    {
        var de = config.Language.StartsWith("de", StringComparison.OrdinalIgnoreCase);
        await SpeakLine(de ? "Danke für Ihren Rückruf, Sir." : "Thank you for calling back, Sir.", config);
    }

    // The last ListenOnce's transcription failed (key, HTTP, network) — not silence.
    private bool _sttFailed;

    /// `preroll`: a barge-in at the PC's mic; a phone barge-in brings the phone's own.
    /// `beeped`: the beep went with the line before (a phone that takes clips, v8).
    private async Task<(byte[] wav, string text)> ListenOnce(Config config, bool barged = false, IReadOnlyList<byte[]>? preroll = null,
                                                             bool beeped = false)
    {
        _sttFailed = false;
        if (_abandoned) return (Array.Empty<byte>(), "");
        if (!barged && !beeped)   // after a barge-in Sir is already talking: no beep
        {
            // A clip's beep has been played when it returns: nothing to wait out.
            if (!await AudioOut.PlayBeep()) await Task.Delay(100);
        }

        LiveStatus.Set("listening");
        Log.Write("record start");
        ShowPill(true);
        _mic.OnLevel = level => { LiveStatus.Push(level); _pill?.BeginInvoke(() => _pill.Push(level)); };
        var wav = await _mic.Record(barged ? preroll ?? PhoneCall.RecentMic() : null);
        _mic.OnLevel = null;
        ShowPill(false);
        Log.Write($"record done bytes={wav.Length}");
        LiveStatus.Set("transcribing");

        var minBytes = 44 + 16000 * 2 / 5;   // header + ~0.2s
        var (text, failed) = wav.Length >= minBytes && !_abandoned ? await Groq.TryTranscribe(wav, config) : ("", false);
        _sttFailed = failed;
        Log.Write($"transcribe done chars={text.Length}{(failed ? " (failed)" : "")}");
        return (wav, text);
    }

    // Ack (cached Jarvis line, chime fallback) + media resume in the background — the
    // transcript returns immediately so Claude starts working during the ack. Order:
    // hi-fi restored → ack → resume (never video over the acknowledgment).
    private void StartAck(Groq.Intent intent, bool hasText, Config config, (string say, byte[]? clip)? line = null)
    {
        if (config.Brief) { ScheduleResume(); return; }
        // Taken now, before the turn's own hold ends: the phone never sees `idle` (and listens
        // for the wake word) in the gap before the ack plays.
        var hold = PhoneCall.Hold();
        _ackTask = Task.Run(async () =>
        {
            try
            {
                // A matched <reply> line (rendered live if it wasn't ready in time).
                var own = line is { } l ? l.clip ?? await GoogleTts.Synthesize(l.say, config) : null;
                await Task.Delay(300);
                await AudioOut.WaitForHiFiOutput();
                if (own is not null) await AudioOut.PlayPcm(AudioOut.ApplyRate(own, config.SpeakingRate));
                else if (hasText)
                {
                    var clip = Clips.AckClip(intent, config);
                    if (clip is not null) await AudioOut.PlayPcm(AudioOut.ApplyRate(clip, config.SpeakingRate));
                    else await AudioOut.PlayChime();
                }
                ScheduleResume();
            }
            finally { hold.Dispose(); }
        });
    }

    private static string HumanDuration(int seconds)
    {
        if (seconds % 60 == 0) { var m = seconds / 60; return m == 1 ? "eine Minute" : $"{m} Minuten"; }
        if (seconds < 60) return $"{seconds} Sekunden";
        return $"{seconds / 60} Minuten und {seconds % 60} Sekunden";
    }

    // Speak a short dynamic line (no mic) — used to confirm a resume before re-listening.
    // `beep`: Parley listens after it; true = the beep went with the line (as AudioOut.PlayPcm).
    private static async Task<bool> SpeakLine(string text, Config config, byte[]? prefetched = null, bool beep = false)
    {
        var pcm = prefetched ?? await GoogleTts.Synthesize(text, config);
        if (pcm is null) return false;
        // Settle after the mic teardown + wait for hi-fi output, else it renders silent.
        await Task.Delay(300);
        await AudioOut.WaitForHiFiOutput();
        return await AudioOut.PlayPcm(AudioOut.ApplyRate(pcm, config.SpeakingRate), caption: text, beep: beep);
    }

    // Fuzzy-match a spoken project name to a parked session (either contains the other).
    private static Server.ParkedInfo? MatchParked(string spoken, List<Server.ParkedInfo> parked)
    {
        var t = spoken.Trim().ToLowerInvariant();
        if (t.Length == 0) return null;
        foreach (var p in parked)
        {
            var l = p.Label.ToLowerInvariant();
            if (l == t || l.Contains(t) || t.Contains(l)) return p;
        }
        return null;
    }

    private void ShowPill(bool show)
    {
        try { _pill?.BeginInvoke(() => { if (show) _pill.ShowPill(); else _pill.HidePill(); }); }
        catch { }
    }

    private async Task PauseMediaIfPlaying()
    {
        // In a call the voice goes to the phone — the PC's music/video can keep playing.
        if (PhoneCall.Active) return;
        var newly = await MediaControl.PausePlaying();
        if (newly.Count == 0) return;
        foreach (var id in newly)
            if (!_pendingResume.Contains(id)) _pendingResume.Add(id);
        Log.Write($"paused media: {string.Join(",", newly)}");
        await Task.Delay(400);
    }

    // Debounced, fire-and-forget: waits a short grace so a following clip/turn can pre-empt
    // the resume, then resumes only if the whole audio cue is idle (nothing queued and no
    // newer turn started). _resumeGen is bumped at each turn start to cancel a stale resume.
    private void ScheduleResume()
    {
        if (_pendingResume.Count == 0) return;
        var gen = _resumeGen;
        _ = Task.Run(async () =>
        {
            await Task.Delay(1500);
            if (gen != _resumeGen || _queuedTurns() > 0 || _pendingResume.Count == 0)
            {
                Log.Write("media resume skipped (cue continued)");
                return;
            }
            var ids = _pendingResume;
            _pendingResume = new List<string>();
            await AudioOut.WaitForHiFiOutput();
            await MediaControl.Resume(ids);
            Log.Write($"resumed media: {string.Join(",", ids)}");
        });
    }
}
