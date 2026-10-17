import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SessionInfo: Identifiable, Equatable {
    var id: String        // tmux_pane (or session_id fallback) — routing key
    var project: String
    var pane: String
    var status: String
}

// Ties the control server to the audio + tmux pipeline and exposes session state
// to the menu-bar UI. The per-turn sequence is:
//   pause media -> speak -> beep -> record (VAD) -> transcribe -> tmux inject ->
//   resume media -> complete (drain next).
// While the iPhone has a call connected (docs/IPHONE.md, protocol v2) every step runs through
// the phone instead — voice out as paced PCM frames, the reply from the phone's mic — chosen
// per step, so a call that ends mid-turn hands the rest back to the Mac's speaker and mic.
@MainActor
final class AppController: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var parked: [ParkedInfo] = []   // resumable sessions: parked (see /wake) or idle
    @Published var lastError: String?
    @Published var muted = false   // manual mute toggle (menu)
    @Published var relayConnected: Bool?   // iPhone relay: nil = not configured, else reachable
    @Published var phoneCall = false       // the iPhone's call is connected: all audio goes through it
    @Published var phoneAway = false       // Unterwegs-Modus: updates ring the phone
    @Published var pushKeyId: String?      // APNs key chosen ("Push-Schlüssel wählen…")

    // Muted when the user toggled it OR the Mac is in a Focus / Do-Not-Disturb mode.
    var effectivelyMuted: Bool { muted || FocusStatus.doNotDisturbActive() }

    static let shared = AppController()

    let server = ControlServer()
    private let mic = MicCapture()
    private let hud = RecordingHUD()
    // Fresh TTSPlayer per playback: its deinit tears down the AVAudioEngine, which releases
    // the output device promptly so the mic can grab it. A single long-lived engine (tried
    // once) held the device far longer when merely stopped → the mic sat at 0 buffers for
    // ~10s across retries. The player is a local in each playback func, alive for its span.
    private var started = false
    private var onboardingPlayer: TTSPlayer?
    private var relay: RelayClient?
    private var relayGen = 0   // drops state reports of a replaced relay client
    let phone = PhoneHub()
    private let apns = APNsClient()
    private var audioWork = 0  // queue items + ack clips in flight; 0 → the phone hears `audio idle`
    static let ringTimeout: TimeInterval = 45

    func start() {
        guard !started else { return }   // idempotent: launch + menu .task may both call
        started = true
        mic.prepareInput()   // expensive AUHAL setup now → near-instant mic starts later
        Notifier.requestAuth()
        server.onTurn = { [weak self] turn in
            Task { @MainActor in
                self?.upsert(SessionInfo(id: self?.routeKey(turn.tmux_pane, turn.session_id) ?? turn.session_id,
                                         project: turn.project, pane: turn.tmux_pane, status: "speaking"))
            }
        }
        server.onReady = { [weak self] ready in
            Task { @MainActor in self?.playReady(ready) }
        }
        server.onQueued = { [weak self] turn in
            Task { @MainActor in
                guard let self else { return }
                self.upsert(SessionInfo(id: self.routeKey(turn.tmux_pane, turn.session_id),
                                        project: turn.project, pane: turn.tmux_pane, status: "queued"))
                Notifier.notify(title: "Parley", body: "Projekt \(turn.spokenLabel) wartet auf Antwort")
            }
        }
        server.onParked = { [weak self] list in
            Task { @MainActor in self?.parked = list }
        }
        // A session's label appeared → pre-render its "Update zu" + resume lines in the
        // background, so the first announcement / resume click is instant.
        server.sessions.onLabel = { label in
            Task { await ProjectClips.shared.prerender(label: label, config: AppConfig.load()) }
        }
        // The long-poll pipeline: speak → record → transcribe → return the reply text,
        // which the hook feeds back into the Claude session (terminal-agnostic).
        server.replyProvider = { [weak self] turn, done in
            Task { @MainActor in
                self?.beginAudioWork()
                let reply = await self?.runTurn(turn) ?? TurnReply(transcript: "", park: false)
                self?.endAudioWork()
                done(reply)
            }
        }
        let server = self.server
        phone.onWake = { server.wakeFromPhone() }
        // v3: the phone's session view — history (from Claude Code's transcript), its images,
        // and typed messages (delivered like a routed instruction).
        phone.onChat = { [phone] event in
            DispatchQueue.global(qos: .userInitiated).async {
                switch event {
                case .history(let id, let before):
                    // ponytail: re-reads the 3 MB tail per poll (~3 s while the view is open); cache by mtime if it shows.
                    let page: (items: [Transcript.Item], more: Bool) =
                        Transcript.file(for: id).map { Transcript.page($0, before: before) } ?? (items: [], more: false)
                    phone.reply(Transcript.historyFrame(session: id, items: page.items, before: before, more: page.more))
                case .image(let id, let key):
                    phone.reply(Transcript.imageFrame(key: key, jpeg: Transcript.file(for: id).flatMap { Transcript.image(in: $0, key: key) }))
                case .say(let id, let text):
                    Log.write("phone: typed message for \(id) (\(text.count) chars)")
                    server.deliverRouted(id: id, instruction: text)
                default: break
                }
            }
        }
        phone.onChange = { [weak self] in Task { @MainActor in self?.syncPhone() } }
        syncPhone()
        let push = APNsCredentials.load()
        pushKeyId = push.isComplete ? push.keyId : nil
        Task { await ProjectClips.shared.prerenderGreetings(config: AppConfig.load()) }
        server.start()
        startRelay()
    }

    private func syncPhone() {
        phoneCall = phone.callActive
        phoneAway = phone.away
    }

    // `audio` state for the phone: speaking while any queue item or ack clip runs (the phone
    // and listener refine it), idle once all are done — the phone listens for its wake word then.
    private func beginAudioWork() {
        audioWork += 1
        phone.setAudioState(.speaking)
    }

    private func endAudioWork() {
        audioWork = max(0, audioWork - 1)
        if audioWork == 0 { phone.setAudioState(.idle) }
    }

    // MARK: - /ready greeting

    // Arm the session on /ready. No greeting clip is played: the skill's first <speak>
    // label is the spoken greeting (avoids a double greeting — clip + spoken line).
    private func playReady(_ ready: ReadyPayload) {
        StatsStore.shared.startSession()
        upsert(SessionInfo(id: routeKey(ready.tmux_pane, ready.session_id),
                           project: ready.project, pane: ready.tmux_pane, status: "ready"))
        let project = ready.project.isEmpty ? "" : " · \(ready.project)"
        Notifier.notify(title: "Parley", body: "Voice-Modus aktiv\(project)")
    }

    // MARK: - /turn pipeline

    // Returns the transcribed voice reply ("" = user said nothing → end conversation).
    // The server hands this back to the blocking Stop hook, which injects it into the
    // Claude session. No terminal/tmux coupling.
    private func runTurn(_ turn: TurnPayload) async -> TurnReply {
        let key = routeKey(turn.tmux_pane, turn.session_id)
        LiveStatus.begin(session: turn.session_id)
        phone.setSpeaker(turn.spokenLabel.isEmpty ? "Parley" : turn.spokenLabel)   // wake dialog: Parley itself
        defer { LiveStatus.set(phase: "idle") }
        switch turn.event {
        case ControlServer.resumeEvent: return await runResume(turn)
        case ControlServer.wakeEvent: return await runWake()
        case ControlServer.permissionEvent: return await runPermission(turn)
        default: break
        }
        upsert(SessionInfo(id: key, project: turn.project, pane: turn.tmux_pane, status: "speaking"))
        let config = AppConfig.load()
        resumeGen += 1   // a new turn began → cancel any pending debounced media resume
        Log.write("turn start project=\(turn.project) ttsReady=\(config.ttsReady) sttReady=\(config.sttReady)")

        // Muted (manual toggle or macOS Do-Not-Disturb) → stay silent: no TTS, no mic, no
        // pill. Return "" so the hook ends the turn cleanly; the loop resumes when unmuted.
        // Muting is about the Mac: a connected (or ringing) phone call still carries the turn.
        func mutedTurn() -> TurnReply {
            Log.write("muted (manual=\(muted) dnd=\(FocusStatus.doNotDisturbActive())) → skipping turn")
            setStatus(key, "muted")
            // Stumm: nicht sprechen, aber die Zusammenfassung als Notification zeigen, damit
            // du mitbekommst, dass der Turn fertig ist — auch ohne dass ich rede.
            Notifier.notify(title: "Parley · \(turn.spokenLabel)", body: turn.speak)
            return TurnReply(transcript: "", park: false)
        }
        // Unterwegs + Stumm: no call, no voice on the Mac — a notification, and the session waits
        // (parked) for a reply typed on the phone.
        if phone.away && phone.silent && !phone.callActive { return silentTurn(turn, key: key) }
        let ringing = shouldRing
        if effectivelyMuted && !phone.callActive && !ringing { return mutedTurn() }

        // Kick off Google TTS synthesis IMMEDIATELY — it runs in parallel with everything
        // below. Its observed duration feeds the TTSTiming prediction model.
        let synthStart = Date()
        let synthFlag = SynthFlag()
        let prefetch: Task<Data?, Never>? = config.useGoogle ? Task { [synthFlag] in
            defer { synthFlag.done = true }
            let req = GoogleTTS.request(text: turn.speak, apiKey: config.googleKey, voice: config.googleVoice)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            TTSTiming.record(chars: turn.speak.count, seconds: Date().timeIntervalSince(synthStart))
            return GoogleTTS.pcm(from: data)
        } : nil

        // Predicted answers (<reply>): render their lines now, in parallel with everything
        // below — ready long before the user stops talking.
        let replies = turn.wantsListen ? turn.replies ?? [] : []
        let replyClips: Task<[Data?], Never>? = replies.isEmpty || !config.useGoogle ? nil : Task {
            await withTaskGroup(of: (Int, Data?).self) { group in
                for (i, r) in replies.enumerated() { group.addTask { (i, await GoogleTTS.synth(r.say, config: config)) } }
                var clips = [Data?](repeating: nil, count: replies.count)
                for await (i, pcm) in group { clips[i] = pcm }
                return clips
            }
        }

        // Unterwegs-Modus: ring the phone (VoIP push + `ring`) and wait ≤ 45 s for the call; the
        // synthesis above keeps running meanwhile. No answer → the Mac's speaker as always.
        if ringing { _ = await ringPhone(label: turn.spokenLabel) }
        if effectivelyMuted && !phone.callActive { prefetch?.cancel(); return mutedTurn() }

        // Wait out the previous turn's background ack clip so this turn's audio never
        // overlaps it (only ever blocks if Claude replied faster than the ack played).
        await ackTask?.value
        ackTask = nil

        // Another session alive (any state but stopped) → announce which one is speaking,
        // "Update zu <Name>" (cached, plays instantly — so media must pause right away then).
        let announcement: Data? = server.othersAlive(except: ControlServer.sessionKey(turn))
            ? await ProjectClips.shared.clipData(label: turn.spokenLabel, language: config.language, config: config)
            : nil

        // Smart media pause: don't silence YouTube while we're still WAITING for the TTS.
        // Hold until the synthesis is done — or until ~1s before its PREDICTED completion
        // (learned model), so the pause lands just ahead of playback. With an announcement
        // (instant audio) or without a prefetch, pause immediately.
        if announcement == nil, let _ = prefetch {
            let target = max(0, TTSTiming.predict(chars: turn.speak.count) - 1.0)
            while !synthFlag.done, Date().timeIntervalSince(synthStart) < target {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await pauseMediaIfPlaying()

        if let ann = announcement {
            Log.write("multi-instance → announcing \(turn.spokenLabel)")
            await playClip(ann, rate: config.speakingRate)
        }

        Log.write("speak start (listen=\(turn.wantsListen))")
        let prefetchedPCM: Data? = prefetch == nil ? nil : await prefetch!.value
        await speakAndBeep(turn.speak, config: config, prefetched: prefetchedPCM, beep: turn.wantsListen,
                           slides: turn.slides ?? [], session: ControlServer.sessionKey(turn))
        Log.write("speak done")

        // speak-only turn (<speak-end>): no mic, no pill. Resume media (queue permitting),
        // end cleanly so the hook exits — Claude reports back on its own.
        if !turn.wantsListen {
            scheduleResume()
            setStatus(key, "idle")
            // Ich melde mich selbst zurück (Background-Arbeit fertig) — Notification fängt
            // dich, falls du weg bist und die Ansage verpasst.
            Notifier.notify(title: "Parley · \(turn.spokenLabel)", body: turn.speak)
            Log.write("turn end (speak-only)")
            return TurnReply(transcript: "", park: false)
        }

        // Record → transcribe. If the reply is actually a CONTROL command (resume a paused
        // project by voice) it's handled here and we re-record for THIS session's real
        // answer — the current question still stands. Capped so it can't loop forever.
        var wav = Data()
        var text = ""
        for hop in 0..<4 {
            setStatus(key, "listening")
            Log.write("record start")
            wav = await record()
            Log.write("record done bytes=\(wav.count)")

            setStatus(key, "transcribing")
            text = await transcribe(wav, config: config)
            Log.write("transcribe done chars=\(text.count)")

            // Resumable = parked, or idle with the mod running (gets it via /presence).
            let targets = text.isEmpty || hop >= 3 ? [] : server.resumableList()
            guard !targets.isEmpty,
                  let cmd = await ControlCommand.detect(text, labels: targets.map { $0.label }, config: config),
                  cmd.resume, let target = matchParked(cmd.target, in: targets) else { break }

            let instruction = cmd.instruction.isEmpty ? ControlServer.resumeInstruction : cmd.instruction
            server.resume(id: target.id, instruction: instruction)
            Log.write("control: resume \(target.label) → \"\(instruction)\"")
            await speakAndBeep("Verstanden, Sir — ich nehme \(target.label) wieder auf. Und für dieses Projekt?",
                               config: config, beep: true)
            // loop: listen again for the current session's actual reply
        }

        // "Warte X Minuten" — the reply asks to pause before continuing. Confirm, resume
        // media for the wait, and tell the hook to sleep then re-inject a resume prompt so
        // Claude picks up automatically. (Checked before STOP, which also matches "warte".)
        if !text.isEmpty {
            let wait = await extractWait(text, config: config)
            if wait > 0 {
                let human = humanDuration(wait)
                Log.write("wait requested: \(wait)s")
                StatsStore.shared.recordTurn(speak: turn.speak, transcript: text,
                                             recordSeconds: 0, intent: "WAIT", project: turn.project)
                await speakLine("Verstanden, Sir. Ich warte \(human) und melde mich dann.", config: config)
                scheduleResume()   // let media play during the pause
                setStatus(key, "idle")
                let resume = "[Parley] Die vom Nutzer angeforderte Wartezeit von \(human) ist vorbei. " +
                    "Fahre jetzt fort: prüfe, ob alles wie erwartet funktioniert hat, und berichte kurz."
                return TurnReply(transcript: "", park: false, waitSeconds: wait, resume: resume)
            }
        }

        // Classify (fast, ~0.3 s) — needed for the ack clip, stats and the STOP decision. In
        // parallel: which predicted answer (<reply>) it is, if the session gave any.
        let heard = text
        async let picked = heard.isEmpty ? nil : pickReply(heard, options: replies.map(\.on), config: config)
        var intent = text.isEmpty ? .other : await classify(text, config: config)
        Log.write("classified: \(intent.rawValue)")
        let recordSeconds = Double(max(0, wav.count - 44)) / 2.0 / 16000.0   // 16 kHz mono 16-bit WAV
        StatsStore.shared.recordTurn(speak: turn.speak, transcript: text,
                                     recordSeconds: recordSeconds, intent: intent.rawValue,
                                     project: turn.project)

        // Play the spoken acknowledgment in the BACKGROUND. Returning the transcript now
        // lets the hook inject it immediately, so Claude starts working while the ack line
        // ("Alles klar, ich sehe es mir an") is still playing — no waiting on playback. The
        // next turn awaits this task before it speaks, so audio never overlaps.
        // ORDER inside the task: hi-fi restored → ack clip → THEN media resume, so the
        // video never plays over the acknowledgment.
        // A predicted answer matched → its own line instead of the generic ack (pre-rendered,
        // plays at once). One that asks back opens the mic again; both answers go on.
        var line: AckLine?
        let pick = await picked
        if pick == nil, !replies.isEmpty { Log.write("reply: none of \(replies.count) fits") }
        if let i = pick {
            let r = replies[i], clip = (await replyClips?.value)?[i] ?? nil
            Log.write("reply: \(r.on) → \"\(r.say)\" (rendered=\(clip != nil))")
            if r.listen == true {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await waitForHiFiOutput()
                await speakAndBeep(r.say, config: config, prefetched: clip, beep: true)
                setStatus(key, "listening")
                let more = await transcribe(await record(), config: config)
                Log.write("reply follow-up chars=\(more.count)")
                text += "\n\n[Parley hat nachgefragt: „\(r.say)“]" + (more.isEmpty ? "" : "\n\(more)")
                intent = more.isEmpty ? .other : await classify(more, config: config)
            } else {
                line = AckLine(say: r.say, clip: clip)
                text += "\n\n[Parley hat darauf bereits geantwortet: „\(r.say)“ – nicht wiederholen.]"
            }
        }
        startAck(intent: intent, hasText: !text.isEmpty, line: line, config: config)

        // "Stop heißt Stop": a STOP reply is NOT fed back. The STOP ack clip still plays
        // (background) as the sign-off; returning "" makes the hook exit cleanly.
        // "Stop heißt Stop" — the reply isn't fed back. But the session PARKS instead of
        // ending, so it stays resumable by voice/menu. Likewise a silent turn parks.
        if intent == .stop {
            setStatus(key, "paused")
            Log.write("turn end (stop → parked, resumable)")
            return TurnReply(transcript: "", park: true)
        }
        if text.isEmpty {
            setStatus(key, "paused")
            Log.write("turn end (silence → parked, resumable)")
            return TurnReply(transcript: "", park: true)
        }
        setStatus(key, "sent")
        Log.write("turn end")
        return TurnReply(transcript: text, park: false)
    }

    // Resume a session from the menu (mouse fallback for the voice command) — no dialog.
    func resume(_ id: String) { server.resume(id: id, instruction: ControlServer.resumeInstruction) }

    // Re-read the resumable list (menu opened — idle sessions may have gone stale since).
    func refreshResumable() { parked = server.resumableList() }

    // POST /resume (the mod's button): a short voice dialog instead of a hook turn — the
    // pre-recorded "Ich habe die Arbeit an X wieder aufgenommen…" line, then beep → record →
    // transcribe exactly like a listening turn. No "Update zu" announcement. The transcript
    // ("" → the default instruction) goes back to the server, which hands it to the session.
    private func runResume(_ turn: TurnPayload) async -> TurnReply {
        let config = AppConfig.load()
        resumeGen += 1
        Log.write("resume dialog start project=\(turn.project)")
        let ringing = shouldRing
        if ringing { _ = await ringPhone(label: turn.spokenLabel) }
        if effectivelyMuted && !phone.callActive {
            Log.write("muted → resuming without dialog")
            return TurnReply(transcript: "", park: false)
        }
        await ackTask?.value
        ackTask = nil

        // Cached line (or synthesized live + cached); nil → speakAndBeep synthesizes the text.
        let clip = await ProjectClips.shared.resumeClip(label: turn.spokenLabel, config: config)
        await pauseMediaIfPlaying()
        let line = ProjectClips.resumePhrases(name: turn.spokenLabel, language: config.language)[0]
        await speakAndBeep(line, config: config, prefetched: clip, beep: true)

        LiveStatus.set(phase: "listening")
        let wav = await record()
        LiveStatus.set(phase: "transcribing")
        let text = await transcribe(wav, config: config)
        Log.write("resume dialog done chars=\(text.count)")

        startAck(intent: .other, hasText: !text.isEmpty, config: config)
        return TurnReply(transcript: text, park: false)
    }

    // The acknowledgment in the BACKGROUND, then the media resume (debounced; only once the
    // whole cue is idle). The next queue item awaits it, so audio never overlaps.
    private func startAck(intent: Intent, hasText: Bool, line: AckLine? = nil, config: AppConfig) {
        beginAudioWork()
        ackTask = Task { [weak self] in
            await self?.playAck(intent: intent, hasText: hasText, line: line, config: config)
            self?.scheduleResume()
            self?.endAudioWork()
        }
    }

    // MARK: - iPhone: wake word, ringing, permission questions (docs/IPHONE.md, protocol v2)

    // Ring only in Unterwegs-Modus with no call yet, and when the phone can be reached at all
    // (a VoIP push, or the relay for a phone in the foreground).
    private var shouldRing: Bool {
        phone.away && !phone.silent && !phone.callActive && ((apns.configured && phone.pushTarget != nil) || relayConnected == true)
    }

    private func silentTurn(_ turn: TurnPayload, key: String) -> TurnReply {
        Log.write("Unterwegs + Stumm → notification for \(turn.spokenLabel)")
        if let target = phone.alertTarget {
            let apns = self.apns, session = ControlServer.sessionKey(turn)
            Task.detached {
                await apns.notify(token: target.token, env: target.env, title: "Parley · \(turn.spokenLabel)",
                                  body: turn.speak, session: session)
            }
        } else {
            Log.write("phone: no notification token yet — open the app once with Stumm on")
        }
        setStatus(key, "paused")
        return TurnReply(transcript: "", park: turn.wantsListen)
    }

    // VoIP push + `ring`, then wait ≤ 45 s for `call start`. true = the call is connected.
    private func ringPhone(label: String) async -> Bool {
        Log.write("phone: ringing for \(label) (Unterwegs-Modus)")
        phone.ring(label: label)
        if let target = phone.pushTarget, apns.configured {
            let apns = self.apns
            Task.detached { await apns.push(token: target.token, env: target.env, label: label) }
        }
        let answered = await phone.waitForCall(timeout: Self.ringTimeout)
        Log.write(answered ? "phone: call answered — voicing through the phone" : "phone: no answer in 45 s → the Mac's speaker")
        return answered
    }

    // "Hey Parley" during a call: greeting → listen → route the utterance to a running session
    // or the Zentrale → confirm. Nothing said → nothing happens.
    private func runWake() async -> TurnReply {
        let none = TurnReply(transcript: "", park: false)
        guard phone.callActive else { Log.write("wake: call gone — skipped"); return none }
        let config = AppConfig.load()
        await ackTask?.value
        ackTask = nil
        Log.write("wake: greeting")
        let clip = await ProjectClips.shared.greetClip(config: config)
        let line = ProjectClips.greetPhrases(language: config.language)[0]
        await speakAndBeep(line, config: config, prefetched: clip, beep: true)
        LiveStatus.set(phase: "listening")
        let wav = await record()
        LiveStatus.set(phase: "transcribing")
        let text = await transcribe(wav, config: config)
        guard !text.isEmpty else { Log.write("wake: nothing said"); return none }

        let target = await WakeRouter.route(text, sessions: server.routeTargets(), apiKey: config.groqKey) { req in
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        let confirmation: String
        if let id = target.id {
            server.deliverRouted(id: id, instruction: text)
            confirmation = "Verstanden, ich gebe das an \(target.label) weiter."
        } else {
            // The Zentrale is Parley itself — it takes the job on, it doesn't pass it on.
            _ = deliverToZentrale(text)
            confirmation = Zentrale.takeOver.randomElement()!
        }
        Log.write("wake: \"\(text.prefix(80))\" → \(target.label)")
        await speakLine(confirmation, config: config)
        return none
    }

    // The Zentrale's folder (created from the template when missing), then POST /dispatch's
    // path: delivered if it runs, else pending + a session started. true = started now.
    private func deliverToZentrale(_ text: String) -> Bool {
        let z = ZentraleSettings.load()
        do {
            if try Zentrale.ensure(z, template: Zentrale.templateDir()) { Log.write("zentrale: created \(z.zentraleDir)") }
        } catch {
            Log.write("zentrale: could not create \(z.zentraleDir): \(error.localizedDescription)")
        }
        return server.dispatch(cwd: z.zentraleDir, instruction: text, start: true).started
    }

    // POST /permission: "<Projekt> möchte … — erlauben?", listen; the server decides from the
    // transcript ("" → ask: the normal on-screen prompt).
    private func runPermission(_ turn: TurnPayload) async -> TurnReply {
        let none = TurnReply(transcript: "", park: false)
        let config = AppConfig.load()
        resumeGen += 1
        let ringing = shouldRing
        if effectivelyMuted && !phone.callActive && !ringing { Log.write("muted → permission left to the screen"); return none }
        if ringing { _ = await ringPhone(label: turn.spokenLabel) }
        if effectivelyMuted && !phone.callActive { return none }
        await ackTask?.value
        ackTask = nil
        await pauseMediaIfPlaying()
        Log.write("permission: asking \"\(turn.speak)\"")
        await speakAndBeep(turn.speak, config: config, beep: true)
        LiveStatus.set(phase: "listening")
        let wav = await record()
        LiveStatus.set(phase: "transcribing")
        let text = await transcribe(wav, config: config)
        let decision = PermissionPrompt.decide(text)
        startAck(intent: decision == .allow ? .cont : (decision == .deny ? .stop : .other),
                 hasText: decision != .ask, config: config)
        return TurnReply(transcript: text, park: false)
    }

    // "Push-Schlüssel wählen…": the APNs auth key (AuthKey_<KEYID>.p8) → credentials.json.
    func choosePushKey() {
        let panel = NSOpenPanel()
        panel.title = "APNs-Schlüssel wählen (AuthKey_<KEYID>.p8)"
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let keyId = APNs.keyId(fileName: url.lastPathComponent) else {
            alert("Kein APNs-Schlüssel", "Der Dateiname muss AuthKey_<KEYID>.p8 sein — so lädt Apple den Schlüssel herunter.")
            return
        }
        guard let pem = try? String(contentsOf: url, encoding: .utf8), (try? APNs.privateKey(pem: pem)) != nil else {
            alert("Schlüssel nicht lesbar", "\(url.lastPathComponent) enthält keinen gültigen P-256-Schlüssel.")
            return
        }
        let team = Keychain.get(.apnsTeamId) ?? ""
        Keychain.set(keyId, for: .apnsKeyId)
        Keychain.set(team.isEmpty ? APNsCredentials.defaultTeam : team, for: .apnsTeamId)
        Keychain.set(pem, for: .apnsKeyP8)
        pushKeyId = keyId
        Log.write("apns: push key \(keyId) stored")
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // Fuzzy-match a spoken project name to a resumable session (either contains the other).
    private func matchParked(_ spoken: String, in list: [ParkedInfo]) -> ParkedInfo? {
        let t = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return list.first { p in
            let l = p.label.lowercased()
            return l == t || l.contains(t) || t.contains(l)
        }
    }

    private var ackTask: Task<Void, Never>?
    struct AckLine { var say: String; var clip: Data? }   // a matched <reply>: its line + pre-rendered audio

    // Pause anything playing and remember it for the deferred resume; 0.4s beat if we
    // actually paused something. osascript/perl are blocking → off the main actor.
    private func pauseMediaIfPlaying() async {
        guard !phone.callActive else { return }   // the Mac's media doesn't compete with a phone call
        let newly = await Task.detached { MediaControl.shared.pausePlaying() }.value
        guard !newly.isEmpty else { return }
        for t in newly where !pendingMediaResume.contains(t) { pendingMediaResume.append(t) }
        Log.write("paused media: \(newly.joined(separator: ","))")
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // Media paused across the whole queued conversation burst; resumed only once no
    // further turn is waiting (a queued turn would immediately re-pause it anyway).
    private var pendingMediaResume: [String] = []
    private var hasQueuedTurn: Bool { sessions.contains { $0.status == "queued" } }
    // Bumped whenever a new turn begins; a pending debounced resume checks it and bails if
    // the burst continued — so media only resumes after the WHOLE audio cue is done.
    private var resumeGen = 0

    // Debounced, fire-and-forget: waits out a short grace so a following turn (queued now
    // or arriving within the window) can pre-empt the resume. Only resumes once nothing is
    // queued and no newer turn started. Never awaited by the pipeline (no added latency).
    private func scheduleResume() {
        guard !pendingMediaResume.isEmpty else { return }
        let gen = resumeGen
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // grace: let the next clip/turn pre-empt
            guard gen == self.resumeGen, !self.hasQueuedTurn, !self.pendingMediaResume.isEmpty else {
                Log.write("media resume skipped (cue continued)"); return
            }
            let tokens = self.pendingMediaResume
            self.pendingMediaResume = []
            await self.waitForHiFiOutput()
            await Task.detached { MediaControl.shared.resume(tokens) }.value
            Log.write("resumed media: \(tokens.joined(separator: ","))")
        }
    }

    // AirPods: releasing the mic makes Bluetooth renegotiate from HFP (16/24 kHz) back to
    // hi-fi A2DP — audio played/resumed during the switch is swallowed. Wait until the
    // output device is back at a hi-fi rate (instant on speakers; 3s cap).
    private func waitForHiFiOutput() async {
        guard !phone.callActive else { return }   // the voice goes to the phone
        let start = Date()
        while let sr = AudioDevices.defaultOutputSampleRate(), sr < 40_000,
              Date().timeIntervalSince(start) < 3.0 {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let waited = Date().timeIntervalSince(start)
        if waited > 0.2 { Log.write("waited \(String(format: "%.1f", waited))s for hi-fi output") }
    }

    // Settle after mic teardown, then play the intent's cached Jarvis line (or a chime) —
    // but only once the output is back in hi-fi mode (AirPods HFP→A2DP switch), else the
    // ack clip itself gets swallowed.
    private func playAck(intent: Intent, hasText: Bool, line: AckLine?, config: AppConfig) async {
        var own: Data? = line?.clip
        if own == nil, let line { own = await GoogleTTS.synth(line.say, config: config) }   // not rendered in time
        try? await Task.sleep(nanoseconds: 300_000_000)
        await waitForHiFiOutput()
        if let own {
            await playClip(own, rate: config.speakingRate)
        } else if hasText, let data = LineClips.randomClipData(for: intent) {
            await playClip(data, rate: config.speakingRate)
        } else {
            await playChime()
        }
    }

    // Speak the summary + beep, then FULLY release the audio output device before the
    // mic engine starts. A still-running (or merely stopped-but-alive) output engine
    // starves the input engine → the mic tap never fires (0 buffers). Fresh player per
    // turn + explicit release + a short settle avoids that device contention.
    // During a call the line goes to the phone; if the call ends first, the part not yet heard
    // (and the beep) plays on the Mac.
    private func speakAndBeep(_ text: String, config: AppConfig, prefetched: Data? = nil, beep: Bool = true,
                              slides: [SlideSpec] = [], session: String = "") async {
        if phone.callActive {
            let voice = PhoneVoice(link: phone, rate: config.speakingRate)
            var captioned = false
            await synthesize(text, config: config, prefetched: prefetched) { pcm in
                // Live captions: word times from the (whole, Google) line, just before its first
                // frame — and the line's slides at the times of their words, images after.
                if !captioned {
                    let t = config.useGoogle
                        ? Captions.timings(text: text, pcm: pcm, sampleRate: PhoneAudioFormat.ttsRate, rate: config.speakingRate) : nil
                    if let t { phone.reply(Captions.frame(t)) }
                    if !slides.isEmpty { sendSlides(slides, timed: t, session: session) }
                }
                captioned = true
                voice.enqueue(pcm)
            }
            guard let rest = await voice.finish(beep: beep) else { return }
            Log.write("phone: call ended while speaking → the rest on the Mac's speaker")
            await speakLocal(text, config: config, prefetched: rest, beep: beep)
            return
        }
        await speakLocal(text, config: config, prefetched: prefetched, beep: beep)
    }

    // The line's 24 kHz PCM into `sink`: the prefetched synthesis, else Google (inline retry),
    // else ElevenLabs (streamed).
    private func synthesize(_ text: String, config: AppConfig, prefetched: Data?, into sink: (Data) -> Void) async {
        if let pcm = prefetched {
            sink(pcm)
            Log.write("google tts prefetched (\(pcm.count) bytes)")
        } else if config.useGoogle {
            await synthGoogle(text, config: config, into: sink)   // prefetch failed → inline retry
        } else if config.ttsReady {
            await synthElevenLabs(text, config: config, into: sink)
        } else {
            NSLog("Parley: TTS not configured")
        }
    }

    private func speakLocal(_ text: String, config: AppConfig, prefetched: Data?, beep: Bool) async {
        let player = TTSPlayer(rate: config.speakingRate)
        do { try player.start() } catch { Log.write("tts engine start failed: \(error)") }
        await synthesize(text, config: config, prefetched: prefetched) { player.enqueue(pcmChunk: $0) }
        // Audible "you can talk now" beep after the speech — but ONLY on listen turns.
        // A speak-end turn plays a silent 0.02s finish marker instead (no cue: nobody is
        // being asked to talk). Beeping BEFORE the mic starts is fine because the prepared
        // AUHAL start is near-instant; beeping AFTER mic start is silent on this system.
        await withCheckedContinuation { cont in
            if beep { player.scheduleBeep { cont.resume() } }
            else { player.scheduleBeep(seconds: 0.02, amplitude: 0.0) { cont.resume() } }
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        player.stop()
        // Minimal settle before the mic claims the device — AUHAL needs far less than the
        // old cold engine start; the watchdog covers the rare stuck case.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // Google Cloud TTS (Chirp3 HD): one-shot synthesize → PCM → enqueue.
    private func synthGoogle(_ text: String, config: AppConfig, into sink: (Data) -> Void) async {
        let req = GoogleTTS.request(text: text, apiKey: config.googleKey, voice: config.googleVoice)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, let pcm = GoogleTTS.pcm(from: data) else {
                Log.write("google tts http \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                lastError = "Google TTS HTTP \(code)"
                Notifier.notify(title: "Parley — Fehler",
                                body: code == 429 ? "Google-Kontingent erschöpft." : "Sprachausgabe fehlgeschlagen (HTTP \(code)).")
                return
            }
            sink(pcm)
            Log.write("google tts ok (\(pcm.count) bytes, \(config.googleVoice))")
        } catch {
            Log.write("google tts error: \(error.localizedDescription)")
            lastError = "Google TTS: \(error.localizedDescription)"
        }
    }

    private func synthElevenLabs(_ text: String, config: AppConfig, into sink: (Data) -> Void) async {
        let req = ElevenLabs.streamRequest(
            text: text, config: .init(apiKey: config.elevenLabsKey, voiceID: config.voiceID))
        do {
            Log.write("elevenlabs streaming")
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            var chunk = Data()
            for try await b in bytes {
                chunk.append(b)
                if chunk.count >= 4096 { sink(chunk); chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { sink(chunk) }
            Log.write("elevenlabs stream complete")
        } catch {
            Log.write("tts error: \(error.localizedDescription)")
            lastError = "TTS: \(error.localizedDescription)"
        }
    }

    // MARK: - onboarding tutorial helpers (reuse the real audio + mic + classifier)

    /// Play a pre-rendered tutorial line (settled + hi-fi, so it's audible after any prior IO).
    func onboardingSpeak(_ pcm: Data) async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        await waitForHiFiOutput()
        guard !Task.isCancelled else { return }

        let player = TTSPlayer(rate: AppConfig.load().speakingRate)
        do { try player.start() } catch { return }
        onboardingPlayer = player
        player.enqueue(pcmChunk: pcm)
        let seconds = Double(pcm.count / 2) / ElevenLabs.sampleRate / max(0.5, AppConfig.load().speakingRate)
        try? await Task.sleep(nanoseconds: UInt64((seconds + 0.3) * 1_000_000_000))
        player.stop()
        if onboardingPlayer === player { onboardingPlayer = nil }
    }

    /// Stop a tutorial line immediately when the user advances, goes back, or skips.
    func stopOnboardingSpeak() {
        onboardingPlayer?.stop()
        onboardingPlayer = nil
    }

    /// Record one reply (shows the pill) and report what the user did — for the interactive
    /// tutorial steps. Returns the transcript + whether it was STOP + any wait seconds.
    func onboardingListen() async -> (text: String, isStop: Bool, waitSeconds: Int) {
        let cfg = AppConfig.load()
        let wav = await record()
        let text = await transcribe(wav, config: cfg)
        guard !text.isEmpty else { return ("", false, 0) }
        async let intent = classify(text, config: cfg)
        async let wait = extractWait(text, config: cfg)
        let (i, w) = await (intent, wait)
        return (text, i == .stop, w)
    }

    // Seconds the user asked to wait (0 = not a wait request).
    private func extractWait(_ text: String, config: AppConfig) async -> Int {
        guard !config.groqKey.isEmpty else { return 0 }
        do {
            let (data, resp) = try await URLSession.shared.data(for: Classifier.waitRequest(text: text, apiKey: config.groqKey))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return 0 }
            return Classifier.parseWait(data)
        } catch { return 0 }
    }

    // A line's slides to the phone: the timed list now, each image as it is ready.
    private func sendSlides(_ specs: [SlideSpec], timed: Captions.Timed?, session: String) {
        let items = Slides.items(specs, timed: timed, prefix: "slide-\(UUID().uuidString.prefix(8))")
        phone.reply(Slides.frame(items))
        Log.write("phone: \(items.count) slide(s) for this line")
        let phone = self.phone
        let images = zip(specs, items).compactMap { s, o in s.image.map { (o.id, $0) } }
        guard !images.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for (id, source) in images {
                phone.reply(Transcript.imageFrame(key: id, jpeg: Slides.image(source, session: session)))
            }
        }
    }

    // Speak a one-off line (no beep, no listen) — used for the wait confirmation. Settles
    // after the mic teardown + waits for hi-fi output first (same as playAck), otherwise the
    // line renders into a still-contended device and is silent.
    private func speakLine(_ text: String, config: AppConfig) async {
        guard config.useGoogle, let pcm = await GoogleTTS.synth(text, config: config) else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await waitForHiFiOutput()
        if phone.callActive, let t = Captions.timings(text: text, pcm: pcm, sampleRate: PhoneAudioFormat.ttsRate, rate: config.speakingRate) {
            phone.reply(Captions.frame(t))
        }
        await playClip(pcm, rate: config.speakingRate)
    }

    private func humanDuration(_ seconds: Int) -> String {
        if seconds % 60 == 0 { let m = seconds / 60; return m == 1 ? "eine Minute" : "\(m) Minuten" }
        if seconds < 60 { return "\(seconds) Sekunden" }
        return "\(seconds / 60) Minuten und \(seconds % 60) Sekunden"
    }

    // The session's predicted answer the transcript matches (index), nil = none / no Groq.
    private func pickReply(_ text: String, options: [String], config: AppConfig) async -> Int? {
        guard !options.isEmpty, !config.groqKey.isEmpty,
              let (data, resp) = try? await URLSession.shared.data(for: Classifier.replyRequest(text: text, options: options, apiKey: config.groqKey)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Classifier.parseReply(data, count: options.count)
    }

    private func classify(_ text: String, config: AppConfig) async -> Intent {
        guard !config.groqKey.isEmpty else { return .other }
        do {
            let (data, resp) = try await URLSession.shared.data(for: Classifier.request(text: text, apiKey: config.groqKey))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                Log.write("groq classify http \(code): \(String(data: data, encoding: .utf8)?.prefix(160) ?? "")")
                return .other
            }
            return Classifier.parse(data)
        } catch { return .other }
    }

    private func playClip(_ data: Data, rate: Double = 1.0) async {
        var data = data
        if phone.callActive {
            let voice = PhoneVoice(link: phone, rate: rate)
            voice.enqueue(data)
            guard let rest = await voice.finish(beep: false) else { return }
            Log.write("phone: call ended during a clip → the rest on the Mac's speaker")
            data = rest
            guard !data.isEmpty else { return }
        }
        let player = TTSPlayer(rate: rate)
        do { try player.start() } catch { return }
        player.enqueue(pcmChunk: data)
        let seconds = Double(data.count / 2) / ElevenLabs.sampleRate / max(0.5, rate)   // faster rate → shorter
        try? await Task.sleep(nanoseconds: UInt64((seconds + 0.3) * 1_000_000_000))
        player.stop()
    }

    private func playChime() async {
        if phone.callActive {
            let voice = PhoneVoice(link: phone, rate: 1)
            voice.enqueue(PCMFrames.bytes(PCMFrames.int16(Tones.turnChime(sampleRate: Double(PhoneAudioFormat.ttsRate)))))
            if await voice.finish(beep: false) == nil { return }   // call ended → chime on the Mac
        }
        let player = TTSPlayer()
        do { try player.start() } catch { Log.write("chime start failed: \(error)"); return }
        player.scheduleChime(frequency: 523.25, seconds: 0.32, amplitude: 0.4, decay: 8)
        await withCheckedContinuation { cont in
            player.scheduleChime(frequency: 783.99, seconds: 0.6, amplitude: 0.4, decay: 5.5) { cont.resume() }
        }
        player.stop()
    }

    // During a call the reply comes from the phone's mic. A call that ends before anything was
    // said hands the listening to the Mac (beep first, so the user knows); a started reply is kept.
    private func record() async -> Data {
        if phone.callActive {
            hud.show()
            let hud = self.hud
            let outcome = await PhoneListener(link: phone).record { level in Task { @MainActor in hud.push(level) } }
            hud.finish()
            switch outcome {
            case .finished(let wav):
                return wav
            case .callEnded(let wav, let spoke):
                if spoke { return wav }
                Log.write("phone: call ended before a reply → listening on the Mac")
                await speakLocal("", config: AppConfig.load(), prefetched: Data(), beep: true)
            }
        }
        hud.show()
        mic.onLevel = { [weak self] level in
            LiveStatus.push(level)
            Task { @MainActor in self?.hud.push(level) }
        }
        let wav = await withCheckedContinuation { cont in
            mic.start { wav in cont.resume(returning: wav) }
        }
        mic.onLevel = nil
        hud.finish()
        return wav
    }

    private func transcribe(_ wav: Data, config: AppConfig) async -> String {
        guard config.sttReady else { NSLog("Parley: STT not configured"); return "" }
        // Too little captured audio → skip Groq (it rejects < 0.01s) and end cleanly.
        // 44-byte WAV header + ~0.2s of 16 kHz mono 16-bit.
        let minBytes = 44 + (16000 * 2) / 5
        guard wav.count >= minBytes else {
            NSLog("Parley: recording too short (\(wav.count) bytes) — no reply, no speech or no mic input")
            return ""
        }
        var req = Groq.transcriptionRequest(wav: wav, apiKey: config.groqKey, boundary: "parleyBoundary")
        req.timeoutInterval = 20   // fail fast instead of hanging the hook for the 60s default
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("Parley: STT HTTP \(code): \(body)")
                lastError = "STT HTTP \(code)"
                // Groq blocks VPN / datacenter IPs with a 403 "check your network settings".
                let hint = code == 403 ? "Groq blockt dieses Netzwerk — VPN aus?" : "Transkription fehlgeschlagen (HTTP \(code))."
                Notifier.notify(title: "Parley — Fehler", body: hint)
                return ""   // never feed an error body back as the reply
            }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clean = Groq.cleanTranscript(text)
            if clean.isEmpty && !text.isEmpty { Log.write("stt: dropped Whisper hallucination \"\(text)\"") }
            return clean
        } catch {
            NSLog("Parley: STT error: \(error.localizedDescription)")
            lastError = "STT: \(error.localizedDescription)"
            Notifier.notify(title: "Parley — Fehler", body: "Groq nicht erreichbar (Netzwerk/VPN?).")
            return ""
        }
    }

    // MARK: - iPhone relay (docs/IPHONE.md)

    // "iPhone verbinden…": with a relay configured, make sure room + secret exist, connect, and
    // open the relay's pairing page (QR code) in the browser; without one, say how to set it.
    func pairIPhone() {
        guard let config = RelayConfig.pair(), let page = RelayLink.pairPage(config) else {
            showRelayHint()
            return
        }
        startRelay()
        NSWorkspace.shared.open(page)
    }

    // Connect to the relay when it is configured (launch, pairing); a no-op on unchanged settings.
    func startRelay() {
        let config = RelayConfig.load()
        guard relay?.config != config else { return }
        stopRelay()
        let server = self.server
        guard let client = RelayClient(config: config, sessions: { server.sessionsJSON() },
                                       resume: { server.resumeFromRelay(id: $0) }) else { return }
        relayGen += 1
        let gen = relayGen
        let phone = self.phone
        client.onEvent = { phone.handle($0) }
        client.onAudio = { phone.audioIn($0) }
        phone.attach(text: { [weak client] in client?.sendText($0) }, audio: { [weak client] in client?.sendAudio($0) })
        client.onState = { [weak self] up in
            if !up { phone.handle(.call(false)) }   // no relay, no call audio
            Task { @MainActor in
                guard let self, self.relayGen == gen else { return }
                self.relayConnected = up
            }
        }
        relay = client
        relayConnected = false
        client.start()
    }

    func stopRelay() {
        relay?.stop()
        relay = nil
        relayConnected = nil
        phone.detach()
    }

    private func showRelayHint() {
        let alert = NSAlert()
        alert.messageText = "Relay nicht eingerichtet"
        alert.informativeText = """
            Fürs iPhone braucht Parley die Adresse deines Relays. Trag sie in credentials.json ein, \
            z. B. "relayUrl": "https://parley-relay.<konto>.workers.dev", und wähle dann erneut \
            „iPhone verbinden…“.

            \(Keychain.fileURL.path)
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Im Finder zeigen")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Keychain.fileURL])
        }
    }

    // MARK: - session table helpers

    private func routeKey(_ pane: String, _ session: String?) -> String {
        pane.isEmpty ? (session ?? "unknown") : pane
    }

    private func upsert(_ info: SessionInfo) {
        if let i = sessions.firstIndex(where: { $0.id == info.id }) { sessions[i] = info }
        else { sessions.append(info) }
    }

    private func setStatus(_ id: String, _ status: String) {
        LiveStatus.set(phase: status)
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].status = status
    }
}

// Completion flag readable from the smart-pause poll loop (prefetch task sets it).
final class SynthFlag: @unchecked Sendable { var done = false }
