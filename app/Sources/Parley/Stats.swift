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

    // Today's usage across all sessions (GET /sessions → today). Optional so older
    // stats.json files without it still decode; only meaningful on the all-time record,
    // where DailyStats.shared owns it.
    var today: DayStats?

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

    nonisolated static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("stats.json")
    }

    nonisolated static func loadFromDisk() -> StatsData? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StatsData.self, from: data)
    }

    private init() {
        if let s = Self.loadFromDisk() { total = s }
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
        DailyStats.shared.recordTurn(spokenSeconds: recordSeconds)
        save()

        // Cost warning at 90% of the free monthly TTS-character tier — once per month.
        let threshold = Int(Double(StatsData.freeCharsPerMonth) * 0.9)
        if total.charsThisMonth >= threshold, costWarnedMonth != month {
            costWarnedMonth = month
            let pct = Int(Double(total.charsThisMonth) / Double(StatsData.freeCharsPerMonth) * 100)
            Notifier.notify(title: "Parley — Kosten",
                            body: "Google-Gratiskontingent zu \(pct)% genutzt (\(total.charsThisMonth) / \(StatsData.freeCharsPerMonth) Zeichen).")
        }
    }

    private var costWarnedMonth = ""   // in-memory guard; resets on relaunch (fine — once/session/month)

    func addActiveTime(_ seconds: Double) {
        total.activeSeconds += seconds
        session.activeSeconds += seconds
    }

    // The only writer of stats.json: the all-time record plus today's (DailyStats).
    func save() {
        var file = total
        file.today = DailyStats.shared.snapshot()
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: Self.url, options: .atomic) }
    }

    private static func currentMonth() -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

// Today's usage across all sessions: voiced turns, seconds you spoke, and Claude cost. Rolls
// over at local midnight. Cost comes from the mod's cumulative per-session costUsd: only the
// increase since that session's last report counts, so restarts and repeated reports never
// double-count — the per-session baselines (costSeen) persist with the day.
struct DayStats: Codable, Equatable {
    struct CostMark: Codable, Equatable { var cost: Double; var at: Double }   // at = epoch s
    var day = ""                           // local "yyyy-MM-dd"
    var turns = 0
    var spokenSeconds = 0.0
    var costUsd = 0.0
    var costSeen: [String: CostMark] = [:] // session_id → last cumulative costUsd reported
}

// Thread-safe owner of today's DayStats: cost arrives on the server queue, turns on the main
// actor. Persisted inside stats.json by StatsStore.save().
final class DailyStats: @unchecked Sendable {
    static let shared = DailyStats(day: StatsStore.loadFromDisk()?.today ?? DayStats(),
                                   persist: { Task { @MainActor in StatsStore.shared.save() } })

    private let lock = NSLock()
    private var d: DayStats
    private let now: @Sendable () -> Date
    private let persist: @Sendable () -> Void

    init(day: DayStats = DayStats(), now: @escaping @Sendable () -> Date = { Date() },
         persist: @escaping @Sendable () -> Void = {}) {
        d = day
        self.now = now
        self.persist = persist
    }

    func recordTurn(spokenSeconds: Double) {
        lock.withLock { roll(now()); d.turns += 1; d.spokenSeconds += spokenSeconds }
    }

    // A session reported its cumulative cost. Known session → add the increase; unknown one
    // that started today → all of it accrued today; unknown and older → baseline only.
    func addCost(session: String, cumulative: Double, startedAt: Date?) {
        let changed = lock.withLock {
            let t = now()
            roll(t)
            if let last = d.costSeen[session] {
                d.costUsd += max(0, cumulative - last.cost)
            } else if let s = startedAt, s >= Calendar.current.startOfDay(for: t) {
                d.costUsd += max(0, cumulative)
            }
            let changed = d.costSeen[session]?.cost != cumulative
            d.costSeen[session] = .init(cost: cumulative, at: t.timeIntervalSince1970)
            return changed
        }
        if changed { persist() }
    }

    func snapshot() -> DayStats { lock.withLock { roll(now()); return d } }

    // New local day → zero the counters; keep cost baselines seen within the last 24 h.
    private func roll(_ t: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: t)
        let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        guard d.day != key else { return }
        d.day = key
        d.turns = 0
        d.spokenSeconds = 0
        d.costUsd = 0
        d.costSeen = d.costSeen.filter { t.timeIntervalSince1970 - $0.value.at < 86_400 }
    }
}
