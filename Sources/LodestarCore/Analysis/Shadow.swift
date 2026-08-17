import Foundation

/// The models' own report card. Every model here runs in shadow: it
/// predicts each gap one step ahead, is scored against what the hand then
/// did, and only earns influence over recommendations when it out-predicts
/// the naive baseline on this user's data. With one user and no cross-user
/// pooling, this is the discipline that keeps complexity honest —
/// complexity is admitted exactly when it demonstrably predicts *this*
/// person better than the simple thing.
public enum Shadow {
    public struct Score: Equatable {
        public let model: String
        /// Mean Gaussian log-density of one-step-ahead predictions;
        /// higher is better.
        public let meanLogScore: Double
        public let predictions: Int
    }

    /// Replay chain events chronologically; score the per-address running
    /// baseline against the geometry model refitted as data accumulates.
    public static func evaluate(events: [ObservationEvent], refitEvery: Int = 100)
        -> [Score] {
        struct Running {
            var moments = Observations.Moments()
        }
        var baseline: [String: Running] = [:]
        var global = Observations.Moments()
        var trainSamples: [LatencyModel.Sample] = []
        var model: LatencyModel?
        var sinceRefit = 0

        func gaussianLogDensity(_ x: Double, mean: Double, sd: Double) -> Double {
            let safeSD = max(0.15, sd)
            let z = (x - mean) / safeSD
            return -0.5 * z * z - log(safeSD) - 0.5 * log(2 * Double.pi)
        }

        var baselineTotal = 0.0
        var modelTotal = 0.0
        var scored = 0

        let chains = events.filter { $0.kind == .chain }.sorted { $0.t < $1.t }
        for event in chains {
            guard let chain = event.chain, let gaps = event.gaps else { continue }
            let key = Observations.key(chain)
            for (pos, gap) in gaps.enumerated()
                where gap > 0 && gap <= Observations.recallCeiling {
                let value = log(gap)
                // Predict before updating — the only honest order.
                if global.n >= 20 {
                    let running = baseline[key]?.moments
                    let mean = running?.mean ?? global.mean ?? 0
                    let sd = (running?.n ?? 0) >= 5 ? (running?.sd ?? 0.6)
                        : (global.sd ?? 0.6)
                    baselineTotal += gaussianLogDensity(value, mean: mean, sd: sd)
                    if let model {
                        let predicted = model.expectedLog(chain: chain, pos: pos)
                            + (model.fluency[key]?.residual ?? 0)
                        modelTotal += gaussianLogDensity(value, mean: predicted,
                                                         sd: model.residualSD)
                    } else {
                        modelTotal += gaussianLogDensity(value, mean: global.mean ?? 0,
                                                         sd: global.sd ?? 0.6)
                    }
                    scored += 1
                }
                var running = baseline[key] ?? Running()
                running.moments.add(value)
                baseline[key] = running
                global.add(value)
                trainSamples.append(LatencyModel.Sample(address: key, chain: chain,
                                                        pos: pos, log: value))
                sinceRefit += 1
            }
            if sinceRefit >= refitEvery {
                model = LatencyModel.fit(samples: trainSamples) ?? model
                sinceRefit = 0
            }
        }
        guard scored > 0 else { return [] }
        return [
            Score(model: "baseline", meanLogScore: baselineTotal / Double(scored),
                  predictions: scored),
            Score(model: "geometry", meanLogScore: modelTotal / Double(scored),
                  predictions: scored),
        ]
    }

    /// May the geometry model influence recommendations yet?
    public static func geometryEarnedInfluence(_ scores: [Score],
                                               minimumPredictions: Int = 200) -> Bool {
        guard let baseline = scores.first(where: { $0.model == "baseline" }),
              let geometry = scores.first(where: { $0.model == "geometry" }),
              geometry.predictions >= minimumPredictions else { return false }
        return geometry.meanLogScore >= baseline.meanLogScore
    }
}
