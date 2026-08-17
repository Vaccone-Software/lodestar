import Foundation

/// Skill acquisition per address: `y = A + B·e^(−αn)` on log-gaps against
/// use count. Exponential rather than linear because individual learning
/// curves are exponential (the classic power law is an averaging artifact —
/// Heathcote, Brown & Mewhort 2000), and a line systematically reads
/// "settled" on an address still improving.
///
/// The learning rate α is pooled across addresses — it is mostly a trait of
/// the person — which is what makes an eight-sample address fittable at
/// all. The one number the recommendation engine cares most about falls out
/// in closed form: the **remaining learning cost** of an address, in
/// seconds, which is the switching cost every rebinding proposal must pay.
public struct LearningCurve: Equatable {
    public struct Fit: Equatable {
        /// Asymptote in log-seconds: the fluency this address is heading to.
        public let asymptote: Double
        /// Starting excess in log-seconds.
        public let scale: Double
        /// Samples the fit rests on.
        public let n: Int
        /// Latest ordinal seen.
        public let latest: Int

        /// The area still under the curve from here: seconds this address
        /// will overcharge before it is fully owned.
        public func remainingSeconds(alpha: Double) -> Double {
            var total = 0.0
            var k = latest + 1
            while k < latest + 500 {
                let excess = exp(asymptote + scale * exp(-alpha * Double(k))) - exp(asymptote)
                if excess < 0.001 { break }
                total += excess
                k += 1
            }
            return max(0, total)
        }

        /// The whole learning bill from n=1: what binding a fresh address
        /// costs before it compiles.
        public func totalSeconds(alpha: Double) -> Double {
            var total = 0.0
            for k in 1...500 {
                let excess = exp(asymptote + scale * exp(-alpha * Double(k))) - exp(asymptote)
                if excess < 0.001 { break }
                total += excess
            }
            return max(0, total)
        }
    }

    /// Pooled learning rate.
    public let alpha: Double
    public let fits: [String: Fit]

    static let alphaGrid: [Double] = [0.02, 0.05, 0.08, 0.12, 0.18, 0.25, 0.35, 0.5, 0.7, 1.0]

    /// Trigger-position samples only: the recall gap is the part that
    /// learns; the motor gaps between letters barely move.
    public static func fit(observations: Observations, minimumSamples: Int = 6)
        -> LearningCurve? {
        var series: [String: [(n: Double, y: Double)]] = [:]
        for (address, record) in observations.addresses {
            let points = (record.first + record.recent)
                .filter { $0.pos == 0 && $0.epoch == record.epoch }
            var seen = Set<Int>()
            var unique: [(Double, Double)] = []
            for point in points.sorted(by: { $0.ordinal < $1.ordinal })
                where !seen.contains(point.ordinal) {
                seen.insert(point.ordinal)
                unique.append((Double(point.ordinal), point.log))
            }
            if unique.count >= minimumSamples { series[address] = unique }
        }
        guard !series.isEmpty else { return nil }

        var bestAlpha = alphaGrid[0]
        var bestSSE = Double.infinity
        var bestFits: [String: Fit] = [:]
        for alpha in alphaGrid {
            var sse = 0.0
            var fits: [String: Fit] = [:]
            for (address, points) in series {
                // Linear in (1, e^{-αn}): closed form per address.
                let rows = points.map { [1.0, exp(-alpha * $0.n)] }
                let y = points.map(\.y)
                guard let beta = Maths.ols(rows: rows, y: y) else { continue }
                var residual = 0.0
                for (row, value) in zip(rows, y) {
                    let predicted = beta[0] + beta[1] * row[1]
                    residual += (value - predicted) * (value - predicted)
                }
                sse += residual
                fits[address] = Fit(asymptote: beta[0], scale: max(0, beta[1]),
                                    n: points.count, latest: Int(points.last?.n ?? 0))
            }
            if !fits.isEmpty, sse < bestSSE {
                bestSSE = sse
                bestAlpha = alpha
                bestFits = fits
            }
        }
        guard !bestFits.isEmpty else { return nil }
        return LearningCurve(alpha: bestAlpha, fits: bestFits)
    }

    /// The expected bill for binding something new: the median learning
    /// cost this person has actually paid per address, or a literature-ish
    /// minute when nothing is fitted yet.
    public func typicalLearningCost() -> Double {
        let costs = fits.values.map { $0.totalSeconds(alpha: alpha) }.filter { $0 > 0 }
        return Maths.median(costs) ?? 60
    }
}
