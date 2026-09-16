import Foundation

/// A reach's motion, from the device's own deltas: what the hand did on
/// the way to the target, as a shape.
///
/// The pointer tracker times a reach and measures its path; this keeps
/// the motion inside it — raw counts per report, before the system's
/// acceleration curve has touched them — long enough to read the speed
/// profile at the press: how fast, how soon the peak came, how many
/// submovements it took, and where the power sits across the tremor
/// bands (rest tremor lives near 4 to 6 Hz, essential and action tremor
/// up to 12). A reach shorter than a second cannot resolve a band and
/// says so by leaving the bands empty.
///
/// Counts and seconds only: a delta has no screen on it.
public struct ReachMotion: Equatable {
    /// Reports kept per reach; a reach that outruns this is wandering.
    public static let capacity = 4096
    /// The grid the speed profile is read on.
    public static let gridHz = 100.0
    /// Bands need a second of motion to mean anything.
    public static let bandFloor: TimeInterval = 1.0

    private(set) var t: [Double] = []
    private(set) var dx: [Double] = []
    private(set) var dy: [Double] = []
    private var origin: Date?

    public init() {}

    public var count: Int { t.count }

    public mutating func reset() {
        t.removeAll(keepingCapacity: true)
        dx.removeAll(keepingCapacity: true)
        dy.removeAll(keepingCapacity: true)
        origin = nil
    }

    /// One report: the counts it carried and when it arrived.
    public mutating func add(dx: Double, dy: Double, at now: Date) {
        if origin == nil { origin = now }
        guard t.count < Self.capacity, let origin else { return }
        t.append(now.timeIntervalSince(origin))
        self.dx.append(dx)
        self.dy.append(dy)
    }

    /// The profile, read at the press.
    public func kinematics(end: Date) -> Kinematics? {
        guard t.count >= 4, let origin else { return nil }
        let duration = max(t.last!, end.timeIntervalSince(origin))
        guard duration > 0.05 else { return nil }
        // Cumulative path at each report.
        var cumulative = [Double](repeating: 0, count: t.count)
        var path = 0.0
        for i in 0..<t.count {
            path += (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
            cumulative[i] = path
        }
        // Path on a uniform grid, then speed as its difference.
        let steps = Int((t.last! * Self.gridHz).rounded(.down))
        guard steps >= 8 else {
            return Kinematics(samples: t.count, seconds: duration, rate: Double(t.count) / duration,
                              path: path, peakSpeed: path / duration, timeToPeak: 0.5,
                              submovements: 1, bands: [])
        }
        var grid = [Double](repeating: 0, count: steps + 1)
        var j = 0
        for k in 0...steps {
            let time = Double(k) / Self.gridHz
            while j + 1 < t.count, t[j + 1] < time { j += 1 }
            if j + 1 >= t.count {
                grid[k] = cumulative[j]
            } else {
                let span = t[j + 1] - t[j]
                let fraction = span > 0 ? (time - t[j]) / span : 0
                grid[k] = cumulative[j] + (cumulative[j + 1] - cumulative[j]) * max(0, min(1, fraction))
            }
        }
        var speed = [Double](repeating: 0, count: steps)
        for k in 0..<steps { speed[k] = (grid[k + 1] - grid[k]) * Self.gridHz }
        // Peak, and when it came.
        var peak = 0.0
        var peakAt = 0
        for (k, v) in speed.enumerated() where v > peak {
            peak = v
            peakAt = k
        }
        // Submovements: distinct rises of the smoothed profile. One is
        // counted each time the speed climbs past sixty percent of the
        // peak after having fallen below forty-five — a real valley
        // between real peaks, so a flat profile's ripple counts once.
        var smooth = speed
        if speed.count >= 5 {
            for k in 2..<(speed.count - 2) {
                smooth[k] = (speed[k - 2] + speed[k - 1] + speed[k] + speed[k + 1] + speed[k + 2]) / 5
            }
        }
        var submovements = 0
        var armed = true
        for v in smooth {
            if armed, v >= 0.6 * peak {
                submovements += 1
                armed = false
            } else if !armed, v < 0.45 * peak {
                armed = true
            }
        }
        // Bands, when the reach is long enough to resolve them.
        var bands: [Double] = []
        if t.last! >= Self.bandFloor {
            let mean = speed.reduce(0, +) / Double(speed.count)
            let n = speed.count
            let windowed = speed.enumerated().map { k, v in
                (v - mean) * 0.5 * (1 - cos(2 * Double.pi * Double(k) / Double(n - 1)))
            }
            var power = [Double](repeating: 0, count: 13)
            for f in 1...12 {
                let coefficient = 2 * cos(2 * Double.pi * Double(f) / Self.gridHz)
                var s1 = 0.0, s2 = 0.0
                for x in windowed {
                    let s0 = x + coefficient * s1 - s2
                    s2 = s1
                    s1 = s0
                }
                power[f] = s1 * s1 + s2 * s2 - coefficient * s1 * s2
            }
            let low = power[1] + power[2] + power[3]
            let mid = power[4] + power[5] + power[6] + power[7]
            let high = power[8] + power[9] + power[10] + power[11] + power[12]
            let total = low + mid + high
            if total > 0 { bands = [low / total, mid / total, high / total] }
        }
        return Kinematics(samples: t.count, seconds: duration, rate: Double(t.count) / duration,
                          path: path, peakSpeed: peak, timeToPeak: Double(peakAt) / Double(steps),
                          submovements: max(1, submovements), bands: bands)
    }
}

/// One reach's profile.
public struct Kinematics: Codable, Equatable {
    public var samples: Int
    public var seconds: Double
    /// Reports per second — the device's rate, as seen.
    public var rate: Double
    /// Device counts along the path.
    public var path: Double
    /// Counts per second at the fastest point.
    public var peakSpeed: Double
    /// Where the peak fell, as a fraction of the reach.
    public var timeToPeak: Double
    public var submovements: Int
    /// Power fractions in 1–3, 4–7 and 8–12 Hz; empty for a reach under a
    /// second.
    public var bands: [Double]

    public init(samples: Int, seconds: Double, rate: Double, path: Double, peakSpeed: Double,
                timeToPeak: Double, submovements: Int, bands: [Double]) {
        self.samples = samples
        self.seconds = seconds
        self.rate = rate
        self.path = path
        self.peakSpeed = peakSpeed
        self.timeToPeak = timeToPeak
        self.submovements = submovements
        self.bands = bands
    }
}

/// Reaches' profiles, folded: sums per quarter hour and per month, the
/// way the pointer's other parts are kept.
public struct KinMoments: Codable, Equatable {
    public var n = 0
    public var secondsSum = 0.0
    public var rateSum = 0.0
    public var pathSum = 0.0
    public var peakSum = 0.0
    public var timeToPeakSum = 0.0
    public var submovementsSum = 0
    /// Reaches long enough to carry bands, and their fractions summed.
    public var bandsN = 0
    public var lowSum = 0.0
    public var midSum = 0.0
    public var highSum = 0.0

    public init() {}

    public mutating func add(_ k: Kinematics) {
        n += 1
        secondsSum += k.seconds
        rateSum += k.rate
        pathSum += k.path
        peakSum += k.peakSpeed
        timeToPeakSum += k.timeToPeak
        submovementsSum += k.submovements
        if k.bands.count == 3 {
            bandsN += 1
            lowSum += k.bands[0]
            midSum += k.bands[1]
            highSum += k.bands[2]
        }
    }

    public mutating func merge(_ other: KinMoments) {
        n += other.n
        secondsSum += other.secondsSum
        rateSum += other.rateSum
        pathSum += other.pathSum
        peakSum += other.peakSum
        timeToPeakSum += other.timeToPeakSum
        submovementsSum += other.submovementsSum
        bandsN += other.bandsN
        lowSum += other.lowSum
        midSum += other.midSum
        highSum += other.highSum
    }

    public var submovementsMean: Double? { n > 0 ? Double(submovementsSum) / Double(n) : nil }
    public var timeToPeakMean: Double? { n > 0 ? timeToPeakSum / Double(n) : nil }
    public var midBandMean: Double? { bandsN > 0 ? midSum / Double(bandsN) : nil }
}
