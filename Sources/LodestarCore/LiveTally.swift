import Foundation

/// What one draft's live recognizer was given and what it gave back, for
/// the line the log keeps when the draft ends. A draft that stayed empty
/// with the meter moving (2026-11-17) left nothing to say which step lost
/// the words: the audio, the model, or a session that was no longer the
/// stream's. This says, without a word of what was said.
public struct LiveTally: Equatable, Sendable {
    /// Samples handed to the model, at its 16 kHz.
    public private(set) var samples = 0
    /// The loudest of them, 0 to 1.
    public private(set) var peak: Float = 0
    /// Chunks the model heard, and the pieces of words it wrote.
    public private(set) var chunks = 0
    public private(set) var pieces = 0
    /// Phrases settled at a pause.
    public private(set) var phrases = 0
    /// Audio that arrived for a session the stream no longer served.
    public private(set) var refused = 0
    /// Calls into the model that threw, and what the first one said.
    public private(set) var failures = 0
    public private(set) var firstFailure: String?

    public static let sampleRate = 16_000.0

    public init() {}

    /// Audio given to the model.
    public mutating func gave(_ audio: [Float]) {
        samples += audio.count
        for sample in audio { peak = max(peak, abs(sample)) }
    }

    /// The model heard `chunks` and wrote `pieces`.
    public mutating func heard(chunks: Int, pieces: Int) {
        self.chunks += chunks
        self.pieces += pieces
    }

    public mutating func settled(_ count: Int = 1) { phrases += count }

    public mutating func notCurrent() { refused += 1 }

    public mutating func failed(_ error: String) {
        failures += 1
        if firstFailure == nil { firstFailure = error }
    }

    /// The log line's fields, in order: seconds of audio given, its peak
    /// in dBFS, chunks heard, pieces written, phrases settled; refusals
    /// and failures only when there were any.
    public var fields: [(key: String, value: Any)] {
        var out: [(key: String, value: Any)] = [
            ("seconds", (Double(samples) / Self.sampleRate * 10).rounded() / 10),
            ("peakDb", peak > 0 ? Int((20 * log10(Double(peak))).rounded()) : -140),
            ("chunks", chunks),
            ("pieces", pieces),
            ("phrases", phrases),
        ]
        if refused > 0 { out.append(("refused", refused)) }
        if failures > 0 {
            out.append(("failures", failures))
            if let firstFailure { out.append(("failure", firstFailure)) }
        }
        return out
    }
}
