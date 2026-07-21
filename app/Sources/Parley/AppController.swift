import Foundation
import SwiftUI
import AppKit

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
@MainActor
final class AppController: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var lastError: String?

    static let shared = AppController()

    let server = ControlServer()
    private let mic = MicCapture()
    private let hud = RecordingHUD()
    private var activePlayer: TTSPlayer?   // fresh per playback; released before capture
    private var started = false

    func start() {
        guard !started else { return }   // idempotent: launch + menu .task may both call
        started = true
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

        // Pause media that is ACTUALLY playing (via each app's own player state — the only
        // reliable signal), then resume exactly those apps afterwards. Never touches media
        // the user had already paused. See MediaControl.
        // osascript is blocking I/O — run it off the main actor to keep the UI responsive.
        let pausedMedia = await Task.detached { MediaControl.shared.pausePlaying() }.value
        if !pausedMedia.isEmpty {
            Log.write("paused media: \(pausedMedia.joined(separator: ","))")
            try? await Task.sleep(nanoseconds: 400_000_000)   // 0.4 s beat before speaking
        }

        Log.write("speak start")
        await speakAndBeep(turn.speak, config: config)
        Log.write("speak+beep done")

        setStatus(key, "listening")
        Log.write("record start")
        let wav = await record()
        Log.write("record done bytes=\(wav.count)")

        setStatus(key, "transcribing")
        Log.write("transcribe start")
        let text = await transcribe(wav, config: config)
        Log.write("transcribe done chars=\(text.count)")

        // Classify the reply and play the matching cached Jarvis line (replaces the chime).
        let intent = await acknowledge(text, config: config)
        let recordSeconds = Double(max(0, wav.count - 44)) / 2.0 / 16000.0   // 16 kHz mono 16-bit WAV
        StatsStore.shared.recordTurn(speak: turn.speak, transcript: text,
                                     recordSeconds: recordSeconds, intent: intent.rawValue,
                                     project: turn.project)

        // Resume exactly what we paused (each was playing at the start).
        if !pausedMedia.isEmpty {
            await Task.detached { MediaControl.shared.resume(pausedMedia) }.value
            Log.write("resumed media: \(pausedMedia.joined(separator: ","))")
        }
        // "Stop heißt Stop": a STOP reply is NOT fed back — returning "" makes the hook
        // exit cleanly, so no further speak/record turn is prompted. The STOP ack clip
        // already played as the sign-off.
        if intent == .stop {
            setStatus(key, "idle")
            Log.write("turn end (stop → conversation ends)")
            return ""
        }
        setStatus(key, text.isEmpty ? "idle" : "sent")
        Log.write("turn end")
        return text
    }

    // Speak the summary + beep, then FULLY release the audio output device before the
    // mic engine starts. A still-running (or merely stopped-but-alive) output engine
    // starves the input engine → the mic tap never fires (0 buffers). Fresh player per
    // turn + explicit release + a short settle avoids that device contention.
    private func speakAndBeep(_ text: String, config: AppConfig) async {
        let player = TTSPlayer(rate: config.speakingRate)
        activePlayer = player
        do { try player.start() } catch { Log.write("tts engine start failed: \(error)") }
        if config.useGoogle {
            await synthGoogle(text, config: config, into: player)
        } else if config.ttsReady {
            await synthElevenLabs(text, config: config, into: player)
        } else {
            NSLog("Parley: TTS not configured")
        }
        // Beep is queued after the speech buffers; its completion fires when both finish.
        await withCheckedContinuation { cont in player.scheduleBeep { cont.resume() } }
        player.stop()
        activePlayer = nil
        // ponytail: settle lets CoreAudio release the output device before the mic engine
        // claims it. Raised to 450 ms after intermittent 0-buffer captures recurred.
        try? await Task.sleep(nanoseconds: 450_000_000)
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

    // Distinct descending two-tone "done listening" cue, via a fresh TTS player — the
    // same AVAudioEngine output path as the pre-record beep (reliably audible; NSSound
    // was not audible right after mic teardown).
    // Classify the reply → play the matching cached line; fall back to the chime when
    // there's no text, no clips bundled, or classification fails.
    @discardableResult
    private func acknowledge(_ text: String, config: AppConfig) async -> Intent {
        // Settle: the mic engine just tore down; a cold output engine started too soon
        // renders into a contended device and produces no audible sound. Free it first.
        try? await Task.sleep(nanoseconds: 300_000_000)
        var intent = Intent.other
        if !text.isEmpty {
            intent = await classify(text, config: config)
            Log.write("classified: \(intent.rawValue)")
            if let data = LineClips.randomClipData(for: intent) {
                await playClip(data, rate: config.speakingRate)
                return intent
            }
            Log.write("no line clip for \(intent.rawValue) → chime")
        }
        await playChime()
        return intent
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
        activePlayer = player
        do { try player.start() } catch { activePlayer = nil; return }
        player.enqueue(pcmChunk: data)
        let seconds = Double(data.count / 2) / ElevenLabs.sampleRate / max(0.5, rate)   // faster rate → shorter
        try? await Task.sleep(nanoseconds: UInt64((seconds + 0.3) * 1_000_000_000))
        player.stop()
        activePlayer = nil
    }

    private func playChime() async {
        let player = TTSPlayer()
        activePlayer = player
        do { try player.start() } catch { Log.write("chime start failed: \(error)"); activePlayer = nil; return }
        player.scheduleChime(frequency: 523.25, seconds: 0.32, amplitude: 0.4, decay: 8)
        await withCheckedContinuation { cont in
            player.scheduleChime(frequency: 783.99, seconds: 0.6, amplitude: 0.4, decay: 5.5) { cont.resume() }
        }
        player.stop()
        activePlayer = nil
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

    private func setStatus(_ id: String, _ status: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].status = status
    }
}
