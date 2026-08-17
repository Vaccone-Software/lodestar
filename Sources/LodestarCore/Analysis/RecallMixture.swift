import Foundation

/// Two states hide inside every pause: motor recall (fast, tight) and
/// reconstruction (slow, diffuse). A two-component Gaussian mixture on
/// log-gaps, fitted by EM with components shared across addresses,
/// separates them; the per-address mixing weight π — "you own this address
/// this share of the time" — is the direct operationalization of the
/// design's own test, *does the gesture belong to the hand*.
///
/// Semi-supervised: a first letter typed while the map was up is a labeled
/// reconstruction (the user waited to read), so those samples' membership
/// is pinned rather than inferred. Robust to the 2-second outlier by
/// construction — it lands in the slow component instead of dragging a
/// mean.
public struct RecallMixture: Equatable {
    public let fastMean: Double
    public let fastSD: Double
    public let slowMean: Double
    public let slowSD: Double
    /// Overall share of recall events.
    public let weight: Double
    /// Address → P(recall), Beta(1,1)-smoothed.
    public let ownership: [String: Double]

    struct Point {
        let address: String
        let log: Double
        let pinnedSlow: Bool
    }

    public static func fit(observations: Observations, minimumSamples: Int = 30,
                           iterations: Int = 60) -> RecallMixture? {
        var points: [Point] = []
        for (address, record) in observations.addresses {
            for sample in record.recent where sample.pos == 0 {
                points.append(Point(address: address, log: sample.log,
                                    pinnedSlow: sample.peeked))
            }
        }
        guard points.count >= minimumSamples else { return nil }
        let values = points.map(\.log).sorted()
        // Start the components apart: lower and upper quartile.
        var muFast = values[values.count / 4]
        var muSlow = values[(values.count * 3) / 4]
        if muSlow - muFast < 0.2 { muSlow = muFast + 0.5 }
        var sdFast = 0.4
        var sdSlow = 0.8
        var weight = 0.7

        func density(_ x: Double, _ mu: Double, _ sd: Double) -> Double {
            let z = (x - mu) / sd
            return exp(-0.5 * z * z) / (sd * (2 * Double.pi).squareRoot())
        }

        var responsibilities = Array(repeating: 0.5, count: points.count)
        for _ in 0..<iterations {
            // E: how fast does each pause look.
            for (index, point) in points.enumerated() {
                if point.pinnedSlow {
                    responsibilities[index] = 0
                    continue
                }
                let fast = weight * density(point.log, muFast, sdFast)
                let slow = (1 - weight) * density(point.log, muSlow, sdSlow)
                responsibilities[index] = fast + slow > 0 ? fast / (fast + slow) : 0.5
            }
            // M: refit both components.
            let fastMass = responsibilities.reduce(0, +)
            let slowMass = Double(points.count) - fastMass
            guard fastMass > 1, slowMass > 1 else { break }
            weight = min(0.98, max(0.02, fastMass / Double(points.count)))
            muFast = zip(points, responsibilities).reduce(0) { $0 + $1.0.log * $1.1 } / fastMass
            muSlow = zip(points, responsibilities).reduce(0) { $0 + $1.0.log * (1 - $1.1) }
                / slowMass
            sdFast = max(0.1, (zip(points, responsibilities).reduce(0) {
                $0 + $1.1 * ($1.0.log - muFast) * ($1.0.log - muFast)
            } / fastMass).squareRoot())
            sdSlow = max(0.15, (zip(points, responsibilities).reduce(0) {
                $0 + (1 - $1.1) * ($1.0.log - muSlow) * ($1.0.log - muSlow)
            } / slowMass).squareRoot())
            // Identifiability: fast stays the fast one.
            if muFast > muSlow {
                swap(&muFast, &muSlow)
                swap(&sdFast, &sdSlow)
                weight = 1 - weight
                for index in responsibilities.indices where !points[index].pinnedSlow {
                    responsibilities[index] = 1 - responsibilities[index]
                }
            }
        }

        // No separation, no mixture: on a fluent user's day the two
        // components collapse onto one unimodal cloud and the ownership
        // numbers become fiction ("owned 43%" against a 95% blind rate).
        // Under a 2× gap between the modes, the honest answer is that no
        // reconstruction mode was detected — the blind rate is the
        // fluency measure, and this model stays silent.
        guard muSlow - muFast >= 0.7 else { return nil }

        var owned: [String: (fast: Double, n: Int)] = [:]
        for (point, responsibility) in zip(points, responsibilities) {
            var entry = owned[point.address] ?? (0, 0)
            entry.fast += responsibility
            entry.n += 1
            owned[point.address] = entry
        }
        var ownership: [String: Double] = [:]
        for (address, entry) in owned {
            ownership[address] = (entry.fast + 1) / (Double(entry.n) + 2)
        }
        return RecallMixture(fastMean: muFast, fastSD: sdFast, slowMean: muSlow,
                             slowSD: sdSlow, weight: weight, ownership: ownership)
    }
}
