import Foundation

/// A log-spaced histogram of durations, in seconds.
///
/// The health pulse used to keep a mean and a standard deviation of the
/// typing rhythm, which is enough to describe a bell and nothing else. Two
/// moments cannot say whether a rhythm is one mode or two, and they cannot
/// see a tail at all — and the tail is where the interesting part of a
/// motor measurement lives: the pauses, the lapses, the stall before a
/// hard word. This keeps the *shape* and stays cheap enough to write on
/// every pulse forever.
///
/// The line the pulse lives under is unchanged and this does not approach
/// it: a histogram of how long presses lasted is not a record of which
/// keys were pressed. Shape, never identity.
///
/// Edges are fixed constants rather than data-dependent quantiles on
/// purpose — two histograms can only be merged if they agree on their
/// bins, and these must merge across pulses, across months, and across
/// machines, for the life of the archive.
public struct Histogram: Equatable {
    /// The first edge: eight milliseconds, comfortably under any real
    /// key press.
    public static let base = 0.008
    /// Four bins per doubling — about 19% per bin, fine enough to read a
    /// median off and coarse enough to stay small.
    public static let perOctave = 4.0
    /// Sixty-four bins reach 0.008 × 2¹⁶ ≈ 524 seconds, just under the
    /// gap that ends a bout, so every gap a bout can contain has a bin.
    public static let count = 64

    public private(set) var bins: [Int]

    public init() { bins = [Int](repeating: 0, count: Self.count) }

    public init(bins: [Int]) {
        var padded = bins.prefix(Self.count).map { $0 }
        padded.append(contentsOf: [Int](repeating: 0, count: Self.count - padded.count))
        self.bins = padded
    }

    /// The bin a duration falls in. Anything at or below `base` lands in
    /// the first, anything past the top edge in the last: a histogram
    /// with no overflow cannot lie about its own tail by dropping it.
    public static func index(for seconds: Double) -> Int {
        guard seconds > base else { return 0 }
        let raw = perOctave * log2(seconds / base)
        return min(count - 1, max(0, Int(raw.rounded(.down))))
    }

    /// The lower edge of a bin, in seconds.
    public static func edge(_ index: Int) -> Double {
        base * pow(2, Double(index) / perOctave)
    }

    /// The geometric middle of a bin — the honest single value to report
    /// for everything it holds.
    public static func midpoint(_ index: Int) -> Double {
        edge(index) * pow(2, 0.5 / perOctave)
    }

    public mutating func add(_ seconds: Double) {
        bins[Self.index(for: seconds)] += 1
    }

    public mutating func merge(_ other: Histogram) {
        for i in 0..<Self.count { bins[i] += other.bins[i] }
    }

    public var total: Int { bins.reduce(0, +) }
    public var isEmpty: Bool { total == 0 }

    /// The value at a quantile, read to the bin. Reported at the bin's
    /// geometric midpoint, so the resolution of the answer is the
    /// resolution of the instrument and no finer.
    public func quantile(_ p: Double) -> Double? {
        let n = total
        guard n > 0, p >= 0, p <= 1 else { return nil }
        let target = max(1, Int((Double(n) * p).rounded(.up)))
        var seen = 0
        for i in 0..<Self.count {
            seen += bins[i]
            if seen >= target { return Self.midpoint(i) }
        }
        return Self.midpoint(Self.count - 1)
    }

    public var median: Double? { quantile(0.5) }

    /// The share of samples at or above a threshold — the tail mass,
    /// which is the number a vigilance question actually asks for.
    public func mass(atOrAbove seconds: Double) -> Double? {
        let n = total
        guard n > 0 else { return nil }
        let from = Self.index(for: seconds)
        let tail = bins[from...].reduce(0, +)
        return Double(tail) / Double(n)
    }

    /// Mean of the binned values, at bin resolution. The pulse also keeps
    /// exact moments for the rhythm it measures; this is for the merged
    /// views where only the histogram survived.
    public var mean: Double? {
        let n = total
        guard n > 0 else { return nil }
        var sum = 0.0
        for i in 0..<Self.count where bins[i] > 0 {
            sum += Self.midpoint(i) * Double(bins[i])
        }
        return sum / Double(n)
    }
}

/// Encoded as a bare array with its trailing zeros trimmed: a pulse of
/// key presses occupies a dozen bins near the bottom, and writing
/// fifty zeros after them on every pulse forever is the kind of cost
/// that is invisible until the year it is not.
extension Histogram: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(bins: try container.decode([Int].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let last = bins.lastIndex(where: { $0 != 0 }) ?? -1
        try container.encode(Array(bins.prefix(last + 1)))
    }
}
