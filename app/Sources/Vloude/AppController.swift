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

    let server = ControlServer()
    private let player = TTSPlayer()
    private let mic = MicCapture()

    func start() {
        server.onTurn = { [weak self] turn in
            Task { @MainActor in await self?.handleTurn(turn) }
        }
        server.onReady = { [weak self] ready in
            Task { @MainActor in self?.playReady(ready) }
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

    private func handleTurn(_ turn: TurnPayload) async {
        let key = routeKey(turn.tmux_pane, turn.session_id)
        upsert(SessionInfo(id: key, project: turn.project, pane: turn.tmux_pane, status: "speaking"))
        let config = AppConfig.load()

        MediaKeys.togglePlayPause()                 // pause YouTube/Spotify
        await speak(turn.speak, config: config)
        await beep()

        setStatus(key, "listening")
        let wav = await record()

        setStatus(key, "transcribing")
        let text = await transcribe(wav, config: config)

        if !text.isEmpty { Tmux.inject(pane: turn.tmux_pane, text: text) }
        MediaKeys.togglePlayPause()                 // resume
        setStatus(key, "idle")
        server.completeActiveTurn()
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
        let req = Groq.transcriptionRequest(wav: wav, apiKey: config.groqKey, boundary: "vloudeBoundary")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
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
