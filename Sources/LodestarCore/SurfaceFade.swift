import Foundation

/// The guide's fade, generalized to every surface that answers a question
/// the hand could recall — a bar's footer of keys, a band's verb, a
/// legend. Same law as the chain guide: reading is reconstruction and
/// recall is what compiles the habit, so a legend that always paints is a
/// ceiling. The legend waits longer as the surface is learned, comes
/// straight back on a stumble, and forfeits its wait with disuse. Keyed by
/// the verb the observation layer already counts, so no surface needs a
/// counter of its own.
public struct SurfaceFade: Equatable {
    public static let maxSeconds: TimeInterval = GuideFade.maxSeconds
    public static let minimumDelay: TimeInterval = GuideFade.minimumDelay
    /// Uses of a surface before its legend counts as learned. Twice the
    /// chain's bar, because a footer names several keys where a chain
    /// names one.
    public static let bentUses = 30
    public static let stumbleHold: TimeInterval = GuideFade.stumbleHold
    public static let decayHorizon: TimeInterval = GuideFade.decayHorizon

    /// Surface → when the hand last stumbled there (an abandon: the bar
    /// escaped with typing in it, a select given up). Session-scoped like
    /// the guide's.
    private var stumbles: [String: Date] = [:]

    public init() {}

    public mutating func stumbled(surface: String, at now: Date = Date()) {
        stumbles[surface] = now
    }

    /// How long the surface's legend should wait before painting.
    public func delay(surface: String, observations: Observations,
                      now: Date = Date()) -> TimeInterval {
        if let at = stumbles[surface], now.timeIntervalSince(at) < Self.stumbleHold {
            return 0
        }
        let uses = observations.verbs[surface] ?? 0
        var strength = min(1.0, Double(uses) / Double(Self.bentUses))
        if let last = observations.verbsLastUsed?[surface] {
            let idle = now.timeIntervalSince(last) - Self.decayHorizon
            if idle > 0 { strength *= max(0, 1 - idle / Self.decayHorizon) }
        }
        let delay = Self.maxSeconds * strength
        return delay >= Self.minimumDelay ? delay : 0
    }
}
