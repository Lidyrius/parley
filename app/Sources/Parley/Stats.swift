import Foundation
import SwiftUI

// Usage statistics, tracked per voice-session and all-time. The all-time record persists
// to ~/Library/Application Support/Parley/stats.json; the session record lives in memory
// and resets when a new voice session starts (/ready).
struct StatsData: Codable, Equatable {
    var turns = 0
    var charsSpoken = 0          // characters Parley spoke (TTS) — drives credits
    var parleyWords = 0          // words Parley spoke
    var userWords = 0            // words you spoke (transcribed)
    var userSpeakingSeconds = 0.0
    var timeSavedSeconds = 0.0   // typing-time of your words − your speaking time
    var activeSeconds = 0.0      // time voice mode was active
    var sessions = 0
    var intents: [String: Int] = [:]        // FEATURE / BUG / STOP / CONTINUE / OTHER
    var projectTurns: [String: Int] = [:]

    // Monthly TTS-character accounting (Google Cloud TTS bills per character).
    // Chirp3 HD: first 1M chars/month free, then $30 per 1M chars. Only the spoken
    // summaries are billed live — cached greeting/ack clips are generated once.
    static let freeCharsPerMonth = 1_000_000
    static let dollarsPerMillionChars = 30.0
    var charMonth = ""           // "YYYY-MM"
    var charsThisMonth = 0

    var billableCharsThisMonth: Int { max(0, charsThisMonth - Self.freeCharsPerMonth) }
    var estimatedDollarsThisMonth: Double {
        Double(billableCharsThisMonth) / 1_000_000 * Self.dollarsPerMillionChars
    }

    mutating func record(speak: String, transcript: String, recordSeconds: Double,
                         intent: String, project: String, month: String) {
        turns += 1
        charsSpoken += speak.count
        parleyWords += wordCount(speak)
        let uw = wordCount(transcript)
        userWords += uw
        userSpeakingSeconds += recordSeconds
        timeSavedSeconds += max(0, Double(uw) / 40.0 * 60.0 - recordSeconds)   // typing 40 wpm
        intents[intent, default: 0] += 1
        if !project.isEmpty { projectTurns[project, default: 0] += 1 }
        if charMonth != month { charMonth = month; charsThisMonth = 0 }
        charsThisMonth += speak.count
    }

    private func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}

@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published var total = StatsData()
    @Published var session = StatsData()

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("stats.json")
    }

    private init() {
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(StatsData.self, from: data) {
            total = s
        }
    }

    /// A new voice session began — bump session count, reset session record.
    func startSession() {
        session = StatsData()
        total.sessions += 1
        session.sessions = 1
        save()
    }

    func recordTurn(speak: String, transcript: String, recordSeconds: Double, intent: String, project: String) {
        let month = Self.currentMonth()
        total.record(speak: speak, transcript: transcript, recordSeconds: recordSeconds,
                     intent: intent, project: project, month: month)
        session.record(speak: speak, transcript: transcript, recordSeconds: recordSeconds,
                       intent: intent, project: project, month: month)
        save()
    }

    func addActiveTime(_ seconds: Double) {
        total.activeSeconds += seconds
        session.activeSeconds += seconds
    }

    private func save() {
        if let data = try? JSONEncoder().encode(total) { try? data.write(to: url, options: .atomic) }
    }

    private static func currentMonth() -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
