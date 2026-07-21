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
        // The long-poll pipeline: speak → record → transcribe → return the reply text,
        // which the hook feeds back into the Claude session (terminal-agnostic).
        server.replyProvider = { [weak self] turn, done in
            Task { @MainActor in
                let transcript = await self?.runTurn(turn) ?? ""
                done(transcript)
            }
        }
        server.mediaTestProvider = { MediaKeys.togglePlayPause() }
        server.start()
    }

    // MARK: - /ready greeting

    private func playReady(_ ready: ReadyPayload) {
        upsert(SessionInfo(id: routeKey(ready.tmux_pane, ready.session_id),
                           project: ready.project, pane: ready.tmux_pane, status: "ready"))
        guard let data = ReadyClips.randomClipData() else {
            NSLog("Parley: no ready clips bundled, greeting silent")
            return
        }
        let p = TTSPlayer()
        activePlayer = p
        try? p.start()
        p.enqueue(pcmChunk: data)
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

        // Only pause media that is actually playing (and only that will we resume) —
        // toggling blindly would START media the user had already paused.
        let mediaWasPlaying = MediaKeys.isTrusted && AudioDevices.isDefaultOutputActive()
        if mediaWasPlaying {
            Log.write("media is playing → pause")
            MediaKeys.togglePlayPause()
        } else {
            Log.write("no media playing (trusted=\(MediaKeys.isTrusted)) → leaving it")
        }

        Log.write("speak start")
        await speakAndBeep(turn.speak, config: config)
        Log.write("speak+beep done")

        setStatus(key, "listening")
        Log.write("record start")
        let wav = await record()
        Log.write("record done bytes=\(wav.count)")
        await playDoneTone()   // audible "done listening" cue via the (working) TTS engine path

        setStatus(key, "transcribing")
        Log.write("transcribe start")
        let text = await transcribe(wav, config: config)
        Log.write("transcribe done chars=\(text.count)")

        if mediaWasPlaying {
            Log.write("media resume")
            MediaKeys.togglePlayPause()             // resume only what we paused
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
        let player = TTSPlayer()
        activePlayer = player
        if config.ttsReady {
            let req = ElevenLabs.streamRequest(
                text: text, config: .init(apiKey: config.elevenLabsKey, voiceID: config.voiceID))
            do {
                try player.start()
                Log.write("tts engine started, streaming")
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                var chunk = Data()
                for try await b in bytes {
                    chunk.append(b)
                    if chunk.count >= 4096 { player.enqueue(pcmChunk: chunk); chunk.removeAll(keepingCapacity: true) }
                }
                if !chunk.isEmpty { player.enqueue(pcmChunk: chunk) }
                Log.write("tts stream complete")
            } catch {
                Log.write("tts error: \(error.localizedDescription)")
                lastError = "TTS: \(error.localizedDescription)"
            }
        } else {
            NSLog("Parley: TTS not configured")
        }
        await withCheckedContinuation { cont in player.scheduleBeep { cont.resume() } }
        player.stop()
        activePlayer = nil
        // ponytail: settle lets CoreAudio release the output device before the mic engine
        // claims it. Raised to 450 ms after intermittent 0-buffer captures recurred.
        try? await Task.sleep(nanoseconds: 450_000_000)
    }

    // Distinct descending two-tone "done listening" cue, via a fresh TTS player — the
    // same AVAudioEngine output path as the pre-record beep (reliably audible; NSSound
    // was not audible right after mic teardown).
    private func playDoneTone() async {
        let player = TTSPlayer()
        activePlayer = player
        do { try player.start() }
        catch { Log.write("done-tone start failed: \(error)"); activePlayer = nil; return }
        player.scheduleBeep(frequency: 700, seconds: 0.10)
        await withCheckedContinuation { cont in
            player.scheduleBeep(frequency: 470, seconds: 0.16) { cont.resume() }
        }
        player.stop()
        activePlayer = nil
        Log.write("done-tone played")
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
