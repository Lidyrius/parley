import Foundation
import SwiftUI
import AppKit

struct SessionInfo: Identifiable, Equatable {
    var id: String        // tmux_pane (or session_id fallback) — routing key
    var project: String
    var pane: String
    var status: String
    var lastActive = Date()   // refreshed on each ready/turn; used to count live instances
}

// Ties the control server to the audio + tmux pipeline and exposes session state
// to the menu-bar UI. The per-turn sequence is:
//   pause media -> speak -> beep -> record (VAD) -> transcribe -> tmux inject ->
//   resume media -> complete (drain next).
@MainActor
final class AppController: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var lastError: String?
    @Published var muted = false   // manual mute toggle (menu)

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

    func start() {
        guard !started else { return }   // idempotent: launch + menu .task may both call
        started = true
        mic.prepareInput()   // expensive AUHAL setup now → near-instant mic starts later
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
            }
        }
        // The long-poll pipeline: speak → record → transcribe → return the reply text,
        // which the hook feeds back into the Claude session (terminal-agnostic).
        server.replyProvider = { [weak self] turn, done in
            Task { @MainActor in
                let transcript = await self?.runTurn(turn) ?? ""
                done(transcript)
            }
        }
        server.start()
    }

    // MARK: - /ready greeting

    // Arm the session on /ready. No greeting clip is played: the skill's first <speak>
    // label is the spoken greeting (avoids a double greeting — clip + spoken line).
    private func playReady(_ ready: ReadyPayload) {
        StatsStore.shared.startSession()
        upsert(SessionInfo(id: routeKey(ready.tmux_pane, ready.session_id),
                           project: ready.project, pane: ready.tmux_pane, status: "ready"))
    }

    // MARK: - /turn pipeline

    // Returns the transcribed voice reply ("" = user said nothing → end conversation).
    // The server hands this back to the blocking Stop hook, which injects it into the
    // Claude session. No terminal/tmux coupling.
    private func runTurn(_ turn: TurnPayload) async -> String {
        let key = routeKey(turn.tmux_pane, turn.session_id)
        upsert(SessionInfo(id: key, project: turn.project, pane: turn.tmux_pane, status: "speaking"))
        let config = AppConfig.load()
        Log.write("turn start project=\(turn.project) ttsReady=\(config.ttsReady) sttReady=\(config.sttReady)")

        // Muted (manual toggle or macOS Do-Not-Disturb) → stay silent: no TTS, no mic, no
        // pill. Return "" so the hook ends the turn cleanly; the loop resumes when unmuted.
        if effectivelyMuted {
            Log.write("muted (manual=\(muted) dnd=\(FocusStatus.doNotDisturbActive())) → skipping turn")
            setStatus(key, "muted")
            return ""
        }

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

        // Wait out the previous turn's background ack clip so this turn's audio never
        // overlaps it (only ever blocks if Claude replied faster than the ack played).
        await ackTask?.value
        ackTask = nil

        // Multiple projects running in parallel → announce which one is speaking (cached,
        // plays instantly — so media must pause right away in that case).
        let announcement: Data? = liveProjectCount() > 1
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
        await speakAndBeep(turn.speak, config: config, prefetched: prefetchedPCM, beep: turn.wantsListen)
        Log.write("speak done")

        // speak-only turn (<speak-end>): no mic, no pill. Resume media (queue permitting),
        // end cleanly so the hook exits — Claude reports back on its own.
        if !turn.wantsListen {
            await maybeResumeMedia()
            setStatus(key, "idle")
            Log.write("turn end (speak-only)")
            return ""
        }

        setStatus(key, "listening")
        Log.write("record start")
        let wav = await record()
        Log.write("record done bytes=\(wav.count)")

        setStatus(key, "transcribing")
        Log.write("transcribe start")
        let text = await transcribe(wav, config: config)
        Log.write("transcribe done chars=\(text.count)")

        // Classify (fast, ~0.3 s) — needed for the ack clip, stats and the STOP decision.
        let intent = text.isEmpty ? .other : await classify(text, config: config)
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
        ackTask = Task { [weak self] in
            await self?.playAck(intent: intent, hasText: !text.isEmpty, config: config)
            await self?.maybeResumeMedia()
        }

        // "Stop heißt Stop": a STOP reply is NOT fed back. The STOP ack clip still plays
        // (background) as the sign-off; returning "" makes the hook exit cleanly.
        if intent == .stop {
            setStatus(key, "idle")
            Log.write("turn end (stop → conversation ends)")
            return ""
        }
        setStatus(key, text.isEmpty ? "idle" : "sent")
        Log.write("turn end")
        return text
    }

    private var ackTask: Task<Void, Never>?

    // Pause anything playing and remember it for the deferred resume; 0.4s beat if we
    // actually paused something. osascript/perl are blocking → off the main actor.
    private func pauseMediaIfPlaying() async {
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

    private func maybeResumeMedia() async {
        guard !pendingMediaResume.isEmpty else { return }
        guard !hasQueuedTurn else { Log.write("media resume deferred (turns queued)"); return }
        let tokens = pendingMediaResume
        pendingMediaResume = []
        await waitForHiFiOutput()
        await Task.detached { MediaControl.shared.resume(tokens) }.value
        Log.write("resumed media: \(tokens.joined(separator: ","))")
    }

    // AirPods: releasing the mic makes Bluetooth renegotiate from HFP (16/24 kHz) back to
    // hi-fi A2DP — audio played/resumed during the switch is swallowed. Wait until the
    // output device is back at a hi-fi rate (instant on speakers; 3s cap).
    private func waitForHiFiOutput() async {
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
    private func playAck(intent: Intent, hasText: Bool, config: AppConfig) async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        await waitForHiFiOutput()
        if hasText, let data = LineClips.randomClipData(for: intent) {
            await playClip(data, rate: config.speakingRate)
        } else {
            await playChime()
        }
    }

    // Speak the summary + beep, then FULLY release the audio output device before the
    // mic engine starts. A still-running (or merely stopped-but-alive) output engine
    // starves the input engine → the mic tap never fires (0 buffers). Fresh player per
    // turn + explicit release + a short settle avoids that device contention.
    private func speakAndBeep(_ text: String, config: AppConfig, prefetched: Data? = nil, beep: Bool = true) async {
        let player = TTSPlayer(rate: config.speakingRate)
        do { try player.start() } catch { Log.write("tts engine start failed: \(error)") }
        if let pcm = prefetched {
            player.enqueue(pcmChunk: pcm)
            Log.write("google tts prefetched (\(pcm.count) bytes)")
        } else if config.useGoogle {
            await synthGoogle(text, config: config, into: player)   // prefetch failed → inline retry
        } else if config.ttsReady {
            await synthElevenLabs(text, config: config, into: player)
        } else {
            NSLog("Parley: TTS not configured")
        }
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
    private func synthGoogle(_ text: String, config: AppConfig, into player: TTSPlayer) async {
        let req = GoogleTTS.request(text: text, apiKey: config.googleKey, voice: config.googleVoice)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, let pcm = GoogleTTS.pcm(from: data) else {
                Log.write("google tts http \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                lastError = "Google TTS HTTP \(code)"
                return
            }
            player.enqueue(pcmChunk: pcm)
            Log.write("google tts ok (\(pcm.count) bytes, \(config.googleVoice))")
        } catch {
            Log.write("google tts error: \(error.localizedDescription)")
            lastError = "Google TTS: \(error.localizedDescription)"
        }
    }

    private func synthElevenLabs(_ text: String, config: AppConfig, into player: TTSPlayer) async {
        let req = ElevenLabs.streamRequest(
            text: text, config: .init(apiKey: config.elevenLabsKey, voiceID: config.voiceID))
        do {
            Log.write("elevenlabs streaming")
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            var chunk = Data()
            for try await b in bytes {
                chunk.append(b)
                if chunk.count >= 4096 { player.enqueue(pcmChunk: chunk); chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { player.enqueue(pcmChunk: chunk) }
            Log.write("elevenlabs stream complete")
        } catch {
            Log.write("tts error: \(error.localizedDescription)")
            lastError = "TTS: \(error.localizedDescription)"
        }
    }

    private func classify(_ text: String, config: AppConfig) async -> Intent {
        guard !config.groqKey.isEmpty else { return .other }
        do {
            let (data, resp) = try await URLSession.shared.data(for: Classifier.request(text: text, apiKey: config.groqKey))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .other }
            return Classifier.parse(data)
        } catch { return .other }
    }

    private func playClip(_ data: Data, rate: Double = 1.0) async {
        let player = TTSPlayer(rate: rate)
        do { try player.start() } catch { return }
        player.enqueue(pcmChunk: data)
        let seconds = Double(data.count / 2) / ElevenLabs.sampleRate / max(0.5, rate)   // faster rate → shorter
        try? await Task.sleep(nanoseconds: UInt64((seconds + 0.3) * 1_000_000_000))
        player.stop()
    }

    private func playChime() async {
        let player = TTSPlayer()
        do { try player.start() } catch { Log.write("chime start failed: \(error)"); return }
        player.scheduleChime(frequency: 523.25, seconds: 0.32, amplitude: 0.4, decay: 8)
        await withCheckedContinuation { cont in
            player.scheduleChime(frequency: 783.99, seconds: 0.6, amplitude: 0.4, decay: 5.5) { cont.resume() }
        }
        player.stop()
    }

    private func record() async -> Data {
        hud.show()
        mic.onLevel = { [weak self] level in
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
            NSLog("Parley: recording too short (\(wav.count) bytes) — no reply, likely no mic input")
            return ""
        }
        let req = Groq.transcriptionRequest(wav: wav, apiKey: config.groqKey, boundary: "parleyBoundary")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("Parley: STT HTTP \(code): \(body)")
                lastError = "STT HTTP \(code)"
                return ""   // never feed an error body back as the reply
            }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            lastError = "STT: \(error.localizedDescription)"
            return ""
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

    // Distinct projects seen within the window — i.e. instances currently running in
    // parallel. Used to decide whether to announce which project is speaking.
    // ponytail: 5-min recency proxy for "alive"; there's no clean session-ended signal.
    private func liveProjectCount() -> Int {
        let cutoff = Date().addingTimeInterval(-300)
        return Set(sessions.filter { $0.lastActive > cutoff }.map { $0.project }).count
    }

    private func setStatus(_ id: String, _ status: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].status = status
    }
}

// Completion flag readable from the smart-pause poll loop (prefetch task sets it).
final class SynthFlag: @unchecked Sendable { var done = false }
