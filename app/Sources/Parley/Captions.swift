import Foundation

// Live captions for a call (protocol v3, docs/IPHONE.md): when each word of a spoken line
// starts, read off the synthesized audio itself — one pass over it, no extra TTS request. The
// voice's pauses (≥ 120 ms clearly below the line's level) are matched to the text's
// punctuation; the words between two anchors share that stretch by their length. The phone
// plays the words against the call's own frame clock, so network jitter can't shift them.
enum Captions {
    struct Timed: Equatable {
        var words: [String]
        var starts: [Double]   // seconds from the line's first sample
        var end: Double
    }

    static let breaks: Set<Character> = [".", ",", ";", ":", "!", "?", "–", "—", "…"]

    /// `pcm`: 16-bit LE mono at `sampleRate`, as it will be heard except for the speaking `rate`
    /// (times are divided by it). nil for empty text or silence.
    static func timings(text: String, pcm: Data, sampleRate: Int, rate: Double = 1) -> Timed? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let hop = max(1, sampleRate / 100)                       // 10 ms
        let n = pcm.count / 2 / hop
        guard !words.isEmpty, n > 0 else { return nil }
        var rms = [Float](repeating: 0, count: n)
        pcm.withUnsafeBytes { raw in
            for i in 0..<n {
                var sum: Float = 0
                for j in (i * hop)..<((i + 1) * hop) {
                    let v = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: j * 2, as: Int16.self))) / 32768
                    sum += v * v
                }
                rms[i] = (sum / Float(hop)).squareRoot()
            }
        }
        guard let peak = rms.max(), peak > 0 else { return nil }
        let voiced = rms.map { $0 > peak * 0.06 }                // ≈ −24 dB under the loudest 10 ms
        guard let first = voiced.firstIndex(of: true), let last = voiced.lastIndex(of: true) else { return nil }

        var pauses: [(from: Int, to: Int)] = []                  // [from, to) in 10 ms frames
        var i = first
        while i <= last {
            guard !voiced[i] else { i += 1; continue }
            var j = i
            while j <= last, !voiced[j] { j += 1 }
            if j - i >= 12 { pauses.append((i, j)) }
            i = j
        }

        // Where each word boundary would be if time followed the characters; punctuated ones snap
        // to the nearest later pause within 0.8 s.
        let weights = words.map { Double($0.count) + 1 }
        let total = weights.reduce(0, +)
        let span = Double(last + 1 - first)
        var anchors: [(word: Int, end: Int, start: Int)] = []
        var acc = 0.0
        var floor = first
        for k in 1..<max(1, words.count) {
            acc += weights[k - 1]
            guard let mark = words[k - 1].last, breaks.contains(mark) else { continue }
            let expected = Double(first) + acc / total * span
            let near = pauses.filter { $0.from > floor }
                .min { abs(Double($0.from + $0.to) / 2 - expected) < abs(Double($1.from + $1.to) / 2 - expected) }
            if let p = near, abs(Double(p.from + p.to) / 2 - expected) < 80 {
                anchors.append((k, p.from, p.to))
                floor = p.to
            }
        }

        var starts = [Double](repeating: 0, count: words.count)
        var segStart = first, from = 0
        for seg in anchors.map({ ($0.word, $0.end, $0.start) }) + [(words.count, last + 1, last + 1)] {
            let (to, segEnd, next) = seg
            let w = weights[from..<to].reduce(0, +)
            var t = Double(segStart)
            for k in from..<to {
                starts[k] = t
                t += weights[k] / w * Double(segEnd - segStart)
            }
            segStart = next
            from = to
        }
        let scale = 0.01 / max(0.5, rate)
        return Timed(words: words, starts: starts.map { $0 * scale }, end: Double(last + 1) * scale)
    }

    /// `{"t":"caption","words":[…],"at":[…],"end":…,"last":…}` — sent just before the line's first
    /// frame. `last`: nothing follows on this call (a speak-end line, no other turn waiting) — a
    /// phone that hangs up after the talk starts leaving before the line ends.
    static func frame(_ t: Timed, last: Bool = false) -> String {
        struct Wire: Encodable { let t = "caption"; let words: [String]; let at: [Double]; let end: Double; let last: Bool }
        func r(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        let data = (try? JSONEncoder().encode(Wire(words: t.words, at: t.starts.map(r), end: r(t.end), last: last))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
