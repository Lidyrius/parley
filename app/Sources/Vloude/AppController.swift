import Foundation
import SwiftUI

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
    private let player = TTSPlayer()
    private let mic = MicCapture()
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
        server.start()
    }

    // MARK: - /ready greeting

    private func playReady(_ ready: ReadyPayload) {
        upsert(SessionInfo(id: routeKey(ready.tmux_pane, ready.session_id),
                           project: ready.project, pane: ready.tmux_pane, status: "ready"))
        guard let data = ReadyClips.randomClipData() else {
            NSLog("Vloude: no ready clips bundled, greeting silent")
            return
        }
        try? player.start()
        player.enqueue(pcmChunk: data)
    }

    // MARK: - /turn pipeline

    // Returns the transcribed voice reply ("" = user said nothing → end conversation).
    // The server hands this back to the blocking Stop hook, which injects it into the
    // Claude session. No terminal/tmux coupling.
    private func runTurn(_ turn: TurnPayload) async -> String {
        let key = routeKey(turn.tmux_pane, turn.session_id)
        upsert(SessionInfo(id: key, project: turn.project, pane: turn.tmux_pane, status: "speaking"))
        let config = AppConfig.load()

        MediaKeys.togglePlayPause()                 // pause YouTube/Spotify
        await speak(turn.speak, config: config)
        await beep()
        player.stop()                               // free the audio device before capture

        setStatus(key, "listening")
        let wav = await record()

        setStatus(key, "transcribing")
        let text = await transcribe(wav, config: config)

        MediaKeys.togglePlayPause()                 // resume
        setStatus(key, text.isEmpty ? "idle" : "sent")
        return text
    }

    private func speak(_ text: String, config: AppConfig) async {
        guard config.ttsReady else { NSLog("Vloude: TTS not configured"); return }
        let req = ElevenLabs.streamRequest(
            text: text, config: .init(apiKey: config.elevenLabsKey, voiceID: config.voiceID))
        do {
            try player.start()
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            var chunk = Data()
            for try await b in bytes {
                chunk.append(b)
                if chunk.count >= 4096 { player.enqueue(pcmChunk: chunk); chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { player.enqueue(pcmChunk: chunk) }
        } catch {
            lastError = "TTS: \(error.localizedDescription)"
        }
    }

    private func beep() async {
        await withCheckedContinuation { cont in
            player.scheduleBeep { cont.resume() }
        }
    }

    private func record() async -> Data {
        await withCheckedContinuation { cont in
            mic.start { wav in cont.resume(returning: wav) }
        }
    }

    private func transcribe(_ wav: Data, config: AppConfig) async -> String {
        guard config.sttReady else { NSLog("Vloude: STT not configured"); return "" }
        // Too little captured audio → skip Groq (it rejects < 0.01s) and end cleanly.
        // 44-byte WAV header + ~0.2s of 16 kHz mono 16-bit.
        let minBytes = 44 + (16000 * 2) / 5
        guard wav.count >= minBytes else {
            NSLog("Vloude: recording too short (\(wav.count) bytes) — no reply, likely no mic input")
            return ""
        }
        let req = Groq.transcriptionRequest(wav: wav, apiKey: config.groqKey, boundary: "vloudeBoundary")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("Vloude: STT HTTP \(code): \(body)")
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
