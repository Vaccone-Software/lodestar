import Foundation

/// What a bout of work does to the hands as it runs on.
///
/// A bout is continuous work — the pulse closes one when the hands stop
/// for longer than `HealthPulse.boutGap` — and every pulse carries how
/// far into its bout it sat. That is the whole input. The question is
/// whether a measure drifts across a bout, and the answer is fitted here,
/// at read time, per the observation layer's one law.
///
/// The estimator is deliberately the conservative one. Bouts differ from
/// each other for every reason under the sun — the work, the hour, the
/// app — and a slope fitted across pooled pulses would mostly measure
/// *which bouts run long* rather than what happens inside one. So each
/// bout is centred on its own mean before anything is pooled: only
/// within-bout movement contributes, and a bout with one pulse
/// contributes nothing at all. What comes out is a drift per hour with a
/// standard error, and when the error swallows the slope the honest
/// reading is that nothing was shown.
public enum Vigilance {
    /// Bins of elapsed bout time, in minutes. Coarse on purpose: these
    /// are for a person to read, and the slope beside them is the number.
    public static let bins: [(label: String, upTo: Double)] = [
        ("0 to 15m", 15), ("15 to 30m", 30), ("30 to 60m", 60), ("over 60m", .infinity),
    ]

    /// One measure's behaviour across a bout.
    public struct Drift: Equatable {
        /// Mean value in each elapsed-time bin, and how many pulses fed
        /// each — a bin with two pulses behind it is not evidence.
        public var binned: [Double?] = Array(repeating: nil, count: bins.count)
        public var binCounts: [Int] = Array(repeating: 0, count: bins.count)
        /// Change per hour of bout, fitted within bouts, and its
        /// standard error.
        public var perHour: Double?
        public var standardError: Double?
        /// Pulses that could contribute to the slope: those in bouts
        /// with at least two.
        public var fitted = 0

        /// Whether the slope clears twice its own error — the coarse
        /// read, stated as a flag so no surface has to invent one.
        public var isDistinguishable: Bool {
            guard let slope = perHour, let se = standardError, se > 0 else { return false }
            return abs(slope) > 2 * se
        }
    }

    public struct Report: Equatable {
        /// Bouts seen, and the mean length of one in minutes.
        public var bouts = 0
        public var meanBoutMinutes: Double?
        public var longestBoutMinutes: Double?
        /// Pulses carrying a bout position at all. Pulses written before
        /// bouts existed carry none and are skipped rather than guessed.
        public var pulses = 0

        /// Corrections per keystroke as the bout runs on.
        public var correctionRate = Drift()
        /// The share of gaps that were pauses rather than rhythm.
        public var pauseShare = Drift()
        /// Mean hold time, seconds.
        public var holdTime = Drift()
    }

    /// One pulse reduced to the numbers a drift is fitted on.
    struct Sample {
        var bout: Int
        var elapsedHours: Double
        var correctionRate: Double?
        var pauseShare: Double?
        var holdTime: Double?
        var weight: Double
    }

    public static func report(events: [ObservationEvent], days: Int,
                              now: Date = Date()) -> Report? {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let pulses = events.filter { $0.kind == .pulse && $0.t >= cutoff && $0.boutIndex != nil }
            .sorted { $0.t < $1.t }
        guard !pulses.isEmpty else { return nil }

        var samples: [Sample] = []
        var bout = -1
        var boutMinutes: [Int: Double] = [:]
        for pulse in pulses {
            // A window at index zero opened a bout. Anything else
            // continues the one in flight — and if none is, the log
            // starts mid-bout and that bout is joined where it is seen.
            if pulse.boutIndex == 0 || bout < 0 { bout += 1 }
            let elapsed = pulse.boutSeconds ?? 0
            let minutes = Double(pulse.activeMinutes ?? 0)
            boutMinutes[bout] = max(boutMinutes[bout] ?? 0, elapsed / 60 + minutes)

            let keys = pulse.keys ?? 0
            let gaps = (pulse.ikN ?? 0) + (pulse.ikTailN ?? 0)
            let holdN = pulse.holdN ?? 0
            samples.append(Sample(
                bout: bout,
                elapsedHours: elapsed / 3600,
                correctionRate: keys > 0 ? Double(pulse.backspaces ?? 0) / Double(keys) : nil,
                pauseShare: gaps > 0 ? Double(pulse.ikTailN ?? 0) / Double(gaps) : nil,
                holdTime: holdN > 0 ? (pulse.holdSum ?? 0) / Double(holdN) : nil,
                weight: Double(max(1, keys))
            ))
        }

        var out = Report()
        out.pulses = samples.count
        out.bouts = boutMinutes.count
        if !boutMinutes.isEmpty {
            out.meanBoutMinutes = boutMinutes.values.reduce(0, +) / Double(boutMinutes.count)
            out.longestBoutMinutes = boutMinutes.values.max()
        }
        out.correctionRate = drift(samples, value: { $0.correctionRate })
        out.pauseShare = drift(samples, value: { $0.pauseShare })
        out.holdTime = drift(samples, value: { $0.holdTime })
        return out
    }

    // MARK: - The fit

    static func drift(_ samples: [Sample], value: (Sample) -> Double?) -> Drift {
        var out = Drift()
        var binSums = [Double](repeating: 0, count: bins.count)
        var usable: [(bout: Int, x: Double, y: Double)] = []
        for sample in samples {
            guard let y = value(sample) else { continue }
            let minutes = sample.elapsedHours * 60
            let bin = bins.firstIndex { minutes < $0.upTo } ?? bins.count - 1
            binSums[bin] += y
            out.binCounts[bin] += 1
            usable.append((sample.bout, sample.elapsedHours, y))
        }
        for i in bins.indices where out.binCounts[i] > 0 {
            out.binned[i] = binSums[i] / Double(out.binCounts[i])
        }

        // Within-bout centring: each bout's own mean is removed from
        // both sides, so what is left is movement inside bouts and
        // nothing about how bouts differ from one another.
        var grouped: [Int: [(x: Double, y: Double)]] = [:]
        for row in usable { grouped[row.bout, default: []].append((row.x, row.y)) }
        var sxx = 0.0
        var sxy = 0.0
        var centred: [(x: Double, y: Double)] = []
        for (_, rows) in grouped where rows.count >= 2 {
            let xBar = rows.reduce(0) { $0 + $1.x } / Double(rows.count)
            let yBar = rows.reduce(0) { $0 + $1.y } / Double(rows.count)
            for row in rows {
                let dx = row.x - xBar
                let dy = row.y - yBar
                sxx += dx * dx
                sxy += dx * dy
                centred.append((dx, dy))
            }
        }
        out.fitted = centred.count
        guard sxx > 0, centred.count >= 4 else { return out }
        let slope = sxy / sxx
        out.perHour = slope
        // Residual variance, with one degree of freedom spent per bout's
        // mean and one on the slope.
        let bouts = grouped.values.filter { $0.count >= 2 }.count
        let dof = centred.count - bouts - 1
        guard dof > 0 else { return out }
        let residual = centred.reduce(0.0) { sum, row in
            let error = row.y - slope * row.x
            return sum + error * error
        }
        out.standardError = (residual / Double(dof) / sxx).squareRoot()
        return out
    }
}
