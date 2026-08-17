import Foundation

/// How much an app will be wanted, with the uncertainty stated: weekly
/// reach counts fitted as negative binomial by moments. The dispersion is
/// the habit test — near-Poisson counts are a habit, over-dispersed ones
/// are a project that happens to be loud this month — and projects should
/// not earn permanent letters.
public struct Demand: Equatable {
    /// Expected reaches per week.
    public let perWeek: Double
    /// Standard error of that expectation.
    public let se: Double
    /// Variance ÷ mean: 1 is Poisson, far above is bursty.
    public let fano: Double
    public let weeks: Int

    /// Weekly counts from the ring for one app (all routes), zero-filled
    /// between first appearance and now so silence counts as silence.
    public static func weeklyCounts(app: String, events: [ObservationEvent], now: Date)
        -> [Int] {
        let name = app.lowercased()
        var byWeek: [Int: Int] = [:]
        for event in events where event.kind == .reach && event.app == name {
            byWeek[Observations.week(event.t), default: 0] += 1
        }
        guard let first = byWeek.keys.min() else { return [] }
        let current = Observations.week(now)
        guard current >= first else { return [] }
        return (first...current).map { byWeek[$0] ?? 0 }
    }

    /// Launcher-only weekly counts: the demand that a new address would
    /// actually absorb.
    public static func weeklySearcherCounts(app: String, events: [ObservationEvent], now: Date)
        -> [Int] {
        let name = app.lowercased()
        var byWeek: [Int: Int] = [:]
        for event in events
            where event.kind == .reach && event.app == name && event.route == "searcher" {
            byWeek[Observations.week(event.t), default: 0] += 1
        }
        guard let first = byWeek.keys.min() else { return [] }
        let current = Observations.week(now)
        guard current >= first else { return [] }
        return (first...current).map { byWeek[$0] ?? 0 }
    }

    public static func fit(weeklyCounts: [Int]) -> Demand? {
        guard !weeklyCounts.isEmpty else { return nil }
        let values = weeklyCounts.map(Double.init)
        guard let mean = Maths.mean(values) else { return nil }
        let variance = Maths.variance(values) ?? mean
        let spread = max(variance, mean) // never claim less noise than Poisson
        return Demand(perWeek: mean,
                      se: (spread / Double(values.count)).squareRoot(),
                      fano: mean > 0 ? variance / mean : 1,
                      weeks: values.count)
    }

    /// Reaches expected over a horizon, discounted so the far weeks —
    /// where the habit may not survive — count for less.
    public func horizonUses(weeks: Int, halfLife: Double = 8) -> Double {
        (0..<weeks).reduce(0) { $0 + perWeek * pow(0.5, Double($1) / halfLife) }
    }
}
