import Foundation

/// Memory availability, the ACT-R way: base-level activation is
/// `ln Σ tⱼ^(−d)` over the times since each past use — frequent and recent
/// practice raises it, disuse decays it along the power law human
/// forgetting actually follows. High activation predicts fast, reliable
/// recall; low predicts the address will have rotted by the time it is
/// next needed, which is exactly the thing a coach should know before
/// recommending more letters be learned.
///
/// Exact when event timestamps are in the ring; approximated by the
/// three-half-life decayed counters once raw history has been compacted
/// away.
public enum Activation {
    /// The standard decay exponent; ACT-R's default, left alone until this
    /// user's own retention data argues otherwise.
    public static let decay = 0.5

    /// Exact base-level activation from raw use times.
    public static func exact(uses: [Date], at now: Date, d: Double = Activation.decay)
        -> Double? {
        let ages = uses.map { now.timeIntervalSince($0) }.filter { $0 > 0 }
        guard !ages.isEmpty else { return nil }
        // Floor at one minute so a use seconds ago cannot claim infinity.
        let sum = ages.reduce(0) { $0 + pow(max($1, 60), -d) }
        return log(sum)
    }

    /// The approximation from `MultiScale` counters: three exponentials at
    /// spaced half-lives sampling the power-law kernel. Comparable across
    /// addresses, not calibrated to the exact scale.
    public static func approximate(_ usage: Observations.MultiScale, at now: Date) -> Double? {
        let day = usage.value(scale: 0, at: now)
        let week = usage.value(scale: 1, at: now)
        let six = usage.value(scale: 2, at: now)
        let sum = day * pow(43_200, -decay) + week * pow(302_400, -decay)
            + six * pow(1_814_400, -decay)
        guard sum > 0 else { return nil }
        return log(sum)
    }

    /// Use times per address from the ring, for the exact form.
    public static func uses(from events: [ObservationEvent]) -> [String: [Date]] {
        var uses: [String: [Date]] = [:]
        for event in events where event.kind == .chain {
            guard let chain = event.chain else { continue }
            uses[Observations.key(chain), default: []].append(event.t)
        }
        return uses
    }
}
