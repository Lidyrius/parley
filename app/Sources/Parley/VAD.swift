import Foundation

// Voice-activity detection over mic buffers. Pure math + a small state machine so
// it can be unit-tested with synthetic sample buffers (no audio device).

enum Level {
    /// Root-mean-square of float samples in [-1, 1].
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// dBFS. Silence (rms 0) is clamped to a floor instead of -inf.
    static func dB(_ rms: Float, floor: Float = -120) -> Float {
        guard rms > 0 else { return floor }
        return max(floor, 20 * log10(rms))
    }
}

/// ADAPTIVE silence VAD. A fixed threshold cut people off during quiet-but-present speech
/// and natural pauses. Instead we track a running average of the user's OWN speaking
/// loudness (EWMA) and only end once the level drops FAR below that average (a big relative
/// drop) AND stays there for `trailingSilence`. Soft speakers get a low bar, loud speakers
/// a high one; a mid-sentence breath never ends the turn.
struct SilenceVAD {
    var trailingSilence: Double = 1.8         // sustained strong drop before ending
    var dropDB: Float = 22                    // "extreme drop" = this far below the average

    private var speechAvgDB: Float = -32
    private var hasAvg = false
    private(set) var started = false
    private(set) var silenceElapsed: Double = 0

    init(trailingSilence: Double = 1.8, dropDB: Float = 22) {
        self.trailingSilence = trailingSilence
        self.dropDB = dropDB
    }

    enum Decision: Equatable {
        case waiting    // pre-speech silence, keep listening
        case speaking   // active speech
        case ended      // trailing silence exceeded -> stop recording
    }

    mutating func process(rmsDB: Float, duration: Double) -> Decision {
        // Dynamic floor relative to how loud the user has been speaking (clamped sane).
        let threshold = min(-45, max(-70, speechAvgDB - dropDB))
        if rmsDB >= threshold {
            started = true
            silenceElapsed = 0
            if rmsDB > -50 {                  // only real speech feeds the average
                if hasAvg { speechAvgDB = speechAvgDB * 0.95 + rmsDB * 0.05 }
                else { speechAvgDB = rmsDB; hasAvg = true }
            }
            return .speaking
        }
        guard started else { return .waiting }
        silenceElapsed += duration
        return silenceElapsed >= trailingSilence ? .ended : .speaking
    }

    mutating func reset() {
        started = false
        silenceElapsed = 0
        speechAvgDB = -32
        hasAvg = false
    }
}
