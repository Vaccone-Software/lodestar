import Foundation

/// Ninety seconds of presses, described exactly.
///
/// The hold-time literature measures its signal *locally*: the interesting
/// thing about a hand is not how even it is over a quarter hour but how
/// its evenness comes and goes over a minute and a half, and pooling ten
/// such windows into one number erases precisely that. So presses are
/// gathered by non-overlapping ninety-second windows (the length the
/// index was defined on), and each window is written down as exact order
/// statistics and exact counts — quantiles read from the raw array at
/// full precision, the distribution function at the four edges the
/// published features use, the power sums a skew and a kurtosis need —
/// rather than as bins that would have to be interpolated later. What
/// leaves the window is a few dozen numbers; the presses themselves live
/// in the raw store and are never in the event.
///
/// Every statistic here is a description, computed on collection because
/// the raw array is in hand and gone a moment later. Nothing is judged.
public struct HoldWindow: Equatable {
    public static let length: TimeInterval = 90
    /// Typing presses a window needs before its statistics are worth
    /// anything, the published floor (a third of the window's seconds).
    public static let minimum = 30
    /// Two presses further apart than this are not a pair; the gap is a
    /// pause, not a rhythm.
    public static let pairGap: TimeInterval = 2.0
    /// Presses held past this are a held key, not a keystroke, and are
    /// kept out of the moments while still counted.
    public static let holdCeiling: TimeInterval = 1.0

    private var start: Date?
    private var presses: [KeyPress] = []

    public init() {}

    public var isOpen: Bool { start != nil }
    public var openedAt: Date? { start }
    public var count: Int { presses.count }

    /// A press landed. When it falls past the open window's end, that
    /// window closes and is returned; this press opens the next.
    public mutating func add(_ press: KeyPress) -> WindowStats? {
        var closed: WindowStats?
        if let start, press.down.timeIntervalSince(start) >= Self.length {
            closed = close()
        }
        if start == nil { start = press.down }
        presses.append(press)
        return closed
    }

    /// Close the open window whatever its length — a break, a flush, the
    /// switch going off.
    public mutating func close() -> WindowStats? {
        guard let start else { return nil }
        let stats = Self.stats(start: start, presses: presses)
        self.start = nil
        presses.removeAll(keepingCapacity: true)
        return stats
    }

    /// Close the window if its ninety seconds have run out with no press
    /// to close it.
    public mutating func closeIfStale(now: Date) -> WindowStats? {
        guard let start, now.timeIntervalSince(start) >= Self.length else { return nil }
        return close()
    }

    // MARK: - The description

    public static func stats(start: Date, presses: [KeyPress]) -> WindowStats {
        var stats = WindowStats(start: start)
        let ordered = presses.sorted { $0.down < $1.down }
        stats.presses = ordered.count
        stats.seconds = ordered.last.map { $0.down.timeIntervalSince(start) } ?? 0
        for press in ordered {
            stats.kinds[Int(press.kind.rawValue)] += 1
            if press.shift { stats.shift += 1 }
            if press.chord { stats.chord += 1 }
            if press.gesture { stats.gesture += 1 }
            if press.lens { stats.lens += 1 }
            if press.repeated { stats.repeated += 1 }
            if press.hold == nil { stats.unseen += 1 }
            stats.keyboardTypes[String(press.keyboardType), default: 0] += 1
        }
        // The typing habit, with a measured hold under the ceiling.
        let typing = ordered.filter { press in
            press.isTyping && (press.hold.map { $0 > 0 && $0 <= holdCeiling } ?? false)
        }
        stats.typing = typing.count
        stats.valid = typing.count >= minimum
        let holds = typing.map { $0.hold! }
        for h in holds { stats.hold.add(h) }
        let sorted = holds.sorted()
        stats.holdQ = [0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95].map { quantile(sorted, $0) }
        stats.holdCDF = [0.125, 0.25, 0.375, 0.5].map { edge in sorted.filter { $0 < edge }.count }
        if sorted.count >= 4 {
            let q1 = quantile(sorted, 0.25), q3 = quantile(sorted, 0.75)
            let iqr = q3 - q1
            stats.outliers = sorted.filter { $0 < q1 - 1.5 * iqr || $0 > q3 + 1.5 * iqr }.count
        }
        // By hand.
        for hand in [Keys.Hand.left, .right] {
            let side = typing.filter { $0.hand == hand }.map { $0.hold! }.sorted()
            var stat = WindowStats.Side()
            for h in side { stat.hold.add(h) }
            stat.q = [0.25, 0.5, 0.75].map { quantile(side, $0) }
            if hand == .left { stats.left = stat } else { stats.right = stat }
        }
        // Consecutive pairs of the typing habit.
        var fluctuations: [Double] = []
        for i in 1..<max(1, typing.count) {
            let a = typing[i - 1], b = typing[i]
            let latency = b.down.timeIntervalSince(a.down)
            guard latency > 0, latency <= pairGap else { continue }
            let flight = latency - a.hold!
            stats.latency.add(latency)
            stats.flight.add(flight)
            let overlap = max(0, -flight)
            stats.overlap.add(overlap)
            if overlap > 0 { stats.overlapN += 1 }
            let d = log(b.hold! / a.hold!)
            stats.fluct.add(d)
            fluctuations.append(d)
            switch (a.hand, b.hand) {
            case (.left, .left): stats.ll.add(latency: latency, flight: flight)
            case (.left, .right): stats.lr.add(latency: latency, flight: flight)
            case (.right, .left): stats.rl.add(latency: latency, flight: flight)
            case (.right, .right): stats.rr.add(latency: latency, flight: flight)
            default: break
            }
        }
        let sortedFluct = fluctuations.sorted()
        stats.fluctQ = [0.25, 0.5, 0.75].map { quantile(sortedFluct, $0) }
        return stats
    }

    /// A quantile of a sorted array, linearly interpolated between the
    /// two order statistics it falls between. Zero for an empty array,
    /// which the counts beside it make unambiguous.
    public static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}

/// Power sums to the fourth: the sufficient statistics for a mean, a
/// spread, a skew and a kurtosis, mergeable forever.
public struct Moments: Codable, Equatable {
    public var n = 0
    public var sum = 0.0
    public var sumSq = 0.0
    public var sumCube = 0.0
    public var sumQuad = 0.0

    public init() {}

    public mutating func add(_ x: Double) {
        n += 1
        sum += x
        let x2 = x * x
        sumSq += x2
        sumCube += x2 * x
        sumQuad += x2 * x2
    }

    public mutating func merge(_ other: Moments) {
        n += other.n
        sum += other.sum
        sumSq += other.sumSq
        sumCube += other.sumCube
        sumQuad += other.sumQuad
    }

    public var mean: Double? { n > 0 ? sum / Double(n) : nil }

    /// Sample standard deviation.
    public var sd: Double? {
        guard n > 1, let mean else { return nil }
        return max(0, (sumSq - Double(n) * mean * mean) / Double(n - 1)).squareRoot()
    }

    /// Central moments from the power sums.
    private func central(_ k: Int) -> Double? {
        guard n > 0, let m = mean else { return nil }
        let nn = Double(n)
        switch k {
        case 2: return sumSq / nn - m * m
        case 3: return sumCube / nn - 3 * m * sumSq / nn + 2 * m * m * m
        case 4: return sumQuad / nn - 4 * m * sumCube / nn + 6 * m * m * sumSq / nn - 3 * m * m * m * m
        default: return nil
        }
    }

    public var skewness: Double? {
        guard n > 2, let m2 = central(2), m2 > 0, let m3 = central(3) else { return nil }
        return m3 / pow(m2, 1.5)
    }

    /// Excess kurtosis: zero for a bell.
    public var kurtosis: Double? {
        guard n > 3, let m2 = central(2), m2 > 0, let m4 = central(4) else { return nil }
        return m4 / (m2 * m2) - 3
    }
}

/// One window's description, as it is written to the ring.
public struct WindowStats: Codable, Equatable {
    public struct Side: Codable, Equatable {
        public var hold = Moments()
        /// p25, p50, p75.
        public var q: [Double] = []
        public init() {}
    }

    public struct Pair: Codable, Equatable {
        public var n = 0
        public var latency = Moments()
        public var flight = Moments()
        public init() {}
        public mutating func add(latency: Double, flight: Double) {
            n += 1
            self.latency.add(latency)
            self.flight.add(flight)
        }
    }

    public var start: Date
    /// First press to last press.
    public var seconds = 0.0
    public var presses = 0
    /// Typing-habit presses with a measured hold.
    public var typing = 0
    public var valid = false
    public var hold = Moments()
    /// p5, p10, p25, p50, p75, p90, p95.
    public var holdQ: [Double] = []
    /// Holds under 0.125, 0.25, 0.375, 0.5 seconds — the published
    /// histogram, as exact counts.
    public var holdCDF: [Int] = []
    /// Holds beyond 1.5 interquartile ranges from the quartiles.
    public var outliers = 0
    /// ln(hold₂ ÷ hold₁) over consecutive typing presses.
    public var fluct = Moments()
    /// p25, p50, p75 of the fluctuations.
    public var fluctQ: [Double] = []
    /// Release of one press to the press of the next, signed: negative is
    /// a rollover, the next key down before this one came up.
    public var flight = Moments()
    /// The rollover, floored at zero — the published coordination term.
    public var overlap = Moments()
    public var overlapN = 0
    /// Press to press.
    public var latency = Moments()
    public var left = Side()
    public var right = Side()
    public var ll = Pair()
    public var lr = Pair()
    public var rl = Pair()
    public var rr = Pair()
    /// Presses by `Keys.Kind`, indexed by raw value.
    public var kinds = [Int](repeating: 0, count: Keys.Kind.allCases.count)
    public var shift = 0
    public var chord = 0
    public var gesture = 0
    public var lens = 0
    public var repeated = 0
    /// Presses whose release was never seen.
    public var unseen = 0
    public var keyboardTypes: [String: Int] = [:]
    // Context, filled by the shell at close.
    public var app: String?
    public var role: String?
    public var keyboards: [String]?
    public var power: String?
    public var screens: Int?
    public var dictation: Bool?
    public var tz: Int?
    public var boutSeconds: Double?

    public init(start: Date) { self.start = start }

    // MARK: - Read-time views, the published features by name

    /// (q2 − q1) ÷ (q3 − q1): where the median sits in the middle half.
    public var vIQR: Double? {
        guard holdQ.count == 7 else { return nil }
        let q1 = holdQ[2], q2 = holdQ[3], q3 = holdQ[4]
        return q3 > q1 ? (q2 - q1) / (q3 - q1) : nil
    }

    /// Outliers as a share of the typing presses.
    public var vOut: Double? { typing > 0 ? Double(outliers) / Double(typing) : nil }

    /// The four-bin normalized histogram, 0 to 0.5 seconds.
    public var vHist: [Double]? {
        guard holdCDF.count == 4, typing > 0 else { return nil }
        var previous = 0
        return holdCDF.map { edge in
            defer { previous = edge }
            return Double(edge - previous) / Double(typing)
        }
    }

    /// Left median hold minus right median hold, seconds.
    public var asymmetry: Double? {
        guard left.q.count == 3, right.q.count == 3, left.hold.n > 0, right.hold.n > 0 else { return nil }
        return left.q[1] - right.q[1]
    }
}
