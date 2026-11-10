import Foundation
import Synchronization

/// The session's audio, held while the draft is open, on the same
/// timeline as the recognizer's word times: a settling ear hears a phrase
/// again from here. Kept in memory only, at most half an hour, and
/// dropped when the next session begins.
public final class HeldAudio: Sendable {
    private struct Held {
        var samples: [Float] = []
        var rate: Double = 16_000
    }
    private let held = Mutex(Held())
    /// Half an hour at 16 kHz.
    public static let cap = 16_000 * 60 * 30

    public init() {}

    public func clear() {
        held.withLock { $0.samples.removeAll(keepingCapacity: true) }
    }

    /// Samples as the recognizer was fed them, at its rate.
    public func append<C: Collection>(_ more: C, rate: Double) where C.Element == Float {
        held.withLock { held in
            if held.samples.isEmpty { held.rate = rate }
            guard held.samples.count < Self.cap else { return }
            held.samples.append(contentsOf: more.prefix(Self.cap - held.samples.count))
        }
    }

    public var seconds: Double {
        held.withLock { Double($0.samples.count) / $0.rate }
    }

    /// The audio between two times, as 16 kHz mono.
    public func slice(from start: Double, to end: Double) -> [Float] {
        let (piece, rate) = held.withLock { held -> ([Float], Double) in
            let rate = held.rate
            let lower = max(0, min(held.samples.count, Int(start * rate)))
            let upper = max(lower, min(held.samples.count, Int(end * rate)))
            return (Array(held.samples[lower..<upper]), rate)
        }
        guard rate != 16_000, !piece.isEmpty else { return piece }
        // Linear resampling: the recognizer's rate is 16 kHz in practice.
        let count = Int(Double(piece.count) * 16_000 / rate)
        return (0..<count).map { i in
            let x = Double(i) * rate / 16_000
            let a = Int(x), b = min(piece.count - 1, a + 1)
            let t = Float(x - Double(a))
            return piece[min(a, piece.count - 1)] * (1 - t) + piece[b] * t
        }
    }
}
