import Foundation

/// The measurement model: what a pause *should* cost given what the chain
/// asks of the hand, so that what remains is fluency and nothing else.
///
/// v1 compared raw pauses across addresses and quietly measured chain
/// length instead of skill — a two-letter chain mixes a recall gap with a
/// motor gap, a one-letter chain is pure recall, and a fixed threshold
/// cannot tell them apart. This model regresses log-gaps on position and
/// digraph geometry, fitted to this user's own typing; the shrunk residual
/// per address is the deconfounded fluency, and the fitted model run
/// generatively prices a chain that does not exist yet — the counterfactual
/// every recommendation needs and no experiment can ethically produce.
public struct LatencyModel: Equatable {
    public struct Sample: Equatable {
        public let address: String
        public let chain: [String]
        public let pos: Int
        public let log: Double

        public init(address: String, chain: [String], pos: Int, log: Double) {
            self.address = address
            self.chain = chain
            self.pos = pos
            self.log = log
        }
    }

    /// Intercept, trigger-position, same hand, same finger, row distance.
    public let coefficients: [Double]
    /// Residual standard deviation in log space.
    public let residualSD: Double
    /// Address → shrunk mean residual (positive = slower than the chain's
    /// shape explains) and the samples behind it.
    public let fluency: [String: (residual: Double, n: Int)]
    public let samples: Int

    public static func == (a: LatencyModel, b: LatencyModel) -> Bool {
        a.coefficients == b.coefficients && a.residualSD == b.residualSD && a.samples == b.samples
    }

    static func features(chain: [String], pos: Int) -> [Double] {
        guard pos > 0, chain.indices.contains(pos), chain.indices.contains(pos - 1) else {
            // The trigger gap: no previous key, so geometry is silent and
            // the position indicator carries it.
            return [1, 1, 0, 0, 0]
        }
        let digraph = Keyboard.digraph(chain[pos - 1], chain[pos])
        return [1, 0, digraph.sameHand, digraph.sameFinger, digraph.rowDistance]
    }

    public static func fit(samples: [Sample], minimumSamples: Int = 30) -> LatencyModel? {
        guard samples.count >= minimumSamples else { return nil }
        let rows = samples.map { features(chain: $0.chain, pos: $0.pos) }
        let y = samples.map(\.log)
        // Ridge, not plain OLS: a young graph often has every chain
        // sharing one digraph shape, which makes the design collinear.
        // Predictions stay well-defined either way, and predictions are
        // what this model is for.
        guard let beta = Maths.ridge(rows: rows, y: y) else { return nil }
        var residuals: [String: [Double]] = [:]
        var all: [Double] = []
        for (sample, row) in zip(samples, rows) {
            let predicted = zip(beta, row).reduce(0) { $0 + $1.0 * $1.1 }
            let residual = sample.log - predicted
            residuals[sample.address, default: []].append(residual)
            all.append(residual)
        }
        let sd = (Maths.variance(all) ?? 0.25).squareRoot()
        // Partial pooling: an address with two samples borrows the
        // population; one with forty keeps its own story.
        let groups = residuals.map { (key: $0.key, mean: Maths.mean($0.value) ?? 0,
                                      n: $0.value.count) }
        let shrunk = Maths.shrink(groupMeans: groups.map { ($0.mean, $0.n) },
                                  withinVariance: sd * sd)
        var fluency: [String: (residual: Double, n: Int)] = [:]
        for (group, value) in zip(groups, shrunk) {
            fluency[group.key] = (value, group.n)
        }
        return LatencyModel(coefficients: beta, residualSD: sd, fluency: fluency,
                            samples: samples.count)
    }

    public func expectedLog(chain: [String], pos: Int) -> Double {
        zip(coefficients, Self.features(chain: chain, pos: pos)).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// What this chain costs in seconds for the median hand that types
    /// here — the generative read, usable for chains never yet typed.
    /// Log-normal mean would reward variance; the median is the honest
    /// summary of a skewed cost.
    public func chainSeconds(_ chain: [String]) -> Double {
        (0..<chain.count).reduce(0) { $0 + exp(expectedLog(chain: chain, pos: $1)) }
    }

    /// The same chain priced for a specific address's demonstrated hand.
    public func chainSeconds(_ chain: [String], address: String) -> Double {
        let offset = fluency[address]?.residual ?? 0
        return (0..<chain.count).reduce(0) {
            $0 + exp(expectedLog(chain: chain, pos: $1) + offset)
        }
    }

    /// Convenience: build samples from the event log.
    public static func samples(from events: [ObservationEvent]) -> [Sample] {
        events.compactMap { event -> [Sample]? in
            guard event.kind == .chain, let chain = event.chain, let gaps = event.gaps else {
                return nil
            }
            let key = Observations.key(chain)
            return gaps.enumerated().compactMap { pos, gap in
                guard gap > 0, gap <= Observations.recallCeiling else { return nil }
                return Sample(address: key, chain: chain, pos: pos, log: log(gap))
            }
        }.flatMap { $0 }
    }
}
