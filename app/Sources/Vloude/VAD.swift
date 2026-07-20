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

/// Silence-timer VAD: once speech begins, ends the recording after `trailingSilence`
/// seconds below the speech threshold. Feed it one buffer's dB + wall duration.
struct SilenceVAD {
    var speechThresholdDB: Float = -40
    var trailingSilence: Double = 0.9

    private(set) var started = false
    private(set) var silenceElapsed: Double = 0

    enum Decision: Equatable {
        case waiting    // pre-speech silence, keep listening
        case speaking   // active speech
        case ended      // trailing silence exceeded -> stop recording
    }

    mutating func process(rmsDB: Float, duration: Double) -> Decision {
        if rmsDB >= speechThresholdDB {
            started = true
            silenceElapsed = 0
            return .speaking
        }
        guard started else { return .waiting }
        silenceElapsed += duration
        return silenceElapsed >= trailingSilence ? .ended : .speaking
    }

    mutating func reset() {
        started = false
        silenceElapsed = 0
    }
}
