import Foundation

/// The session's audio, held while the draft is open, on the same
/// timeline as the recognizer's word times: a settling ear hears a phrase
/// again from here. Kept in memory only, at most half an hour, and
/// dropped when the next session begins.
public final class HeldAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate: Double = 16_000
    /// Half an hour at 16 kHz.
    public static let cap = 16_000 * 60 * 30

    public init() {}

    public func clear() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Samples as the recognizer was fed them, at its rate.
    public func append<C: Collection>(_ more: C, rate: Double) where C.Element == Float {
        lock.lock()
        defer { lock.unlock() }
        if samples.isEmpty { self.rate = rate }
        guard samples.count < Self.cap else { return }
        samples.append(contentsOf: more.prefix(Self.cap - samples.count))
    }

    public var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / rate
    }

    /// The audio between two times, as 16 kHz mono.
    public func slice(from start: Double, to end: Double) -> [Float] {
        lock.lock()
        let rate = self.rate
        let lower = max(0, min(samples.count, Int(start * rate)))
        let upper = max(lower, min(samples.count, Int(end * rate)))
        let piece = Array(samples[lower..<upper])
        lock.unlock()
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
