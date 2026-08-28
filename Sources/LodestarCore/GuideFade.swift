import Foundation

/// The chain guide's training wheels, lowering themselves.
///
/// The guide paints the moment a chain starts, and for a fresh address
/// that is right — the map is how letters are first learned. But a map
/// that always appears is a map that always gets read, and reading is
/// reconstruction, not recall: the retrieval-practice literature is
/// unambiguous that recall is what compiles the habit. So the guide's
/// delay grows with the subtree's own learning curve — up to two seconds
/// once every address under the prefix has bent — and a stumble anywhere
/// under the prefix brings it back immediately for a while. The scaffold
/// fades exactly as fast as the hand earns it, and never further: a
/// stall still summons the map, just after recall had its chance.
///
/// A struct in core, not timer logic in the shell, for the 0.24.4 reason:
/// when a decision must not be forgotten, push it where the tests reach.
public struct GuideFade: Equatable {
    /// The most a learned subtree waits for its map.
    public static let maxSeconds: TimeInterval = 2.0
    /// Below this the timer is theater; paint immediately.
    public static let minimumDelay: TimeInterval = 0.2
    /// How long a stumble keeps the map immediate for its prefix.
    public static let stumbleHold: TimeInterval = 3600

    /// Prefix key → when the hand last stumbled there (wrong key, or an
    /// abandoned chain). Session-scoped on purpose: yesterday's stumble is
    /// not tonight's, and the learning curves already carry the long view.
    private var stumbles: [String: Date] = [:]

    public init() {}

    /// A wrong key or an abandon under this prefix: the map owes the hand
    /// immediacy for a while, here and below.
    public mutating func stumbled(prefix: [String], at now: Date = Date()) {
        stumbles[Observations.key(prefix)] = now
        // Bounded: a session cannot grow this past the graph it navigates.
        if stumbles.count > 64 {
            let cutoff = now.addingTimeInterval(-Self.stumbleHold)
            stumbles = stumbles.filter { $0.value >= cutoff }
        }
    }

    /// How long the guide should wait before painting for this prefix.
    ///
    /// `leaves` are the full chains reachable under the prefix. The
    /// weakest one decides: a subtree with any unlearned address keeps its
    /// map immediate, because the fade must never take the scaffold from
    /// the address that still needs it. Learning is read off the same
    /// counter every other maturity gate uses — this-epoch trigger
    /// samples against `Coach.bentCompletions` — so "learned" keeps
    /// meaning one thing in the codebase.
    public func delay(prefix: [String], leaves: [[String]],
                      observations: Observations, now: Date = Date()) -> TimeInterval {
        guard !prefix.isEmpty, !leaves.isEmpty else { return 0 }
        // A stumble on this prefix or any ancestor holds the map open.
        for depth in 0...prefix.count {
            let key = Observations.key(Array(prefix.prefix(depth)))
            if let at = stumbles[key], now.timeIntervalSince(at) < Self.stumbleHold {
                return 0
            }
        }
        var weakest = 1.0
        for chain in leaves {
            let samples = observations.addresses[Observations.key(chain)]?.trigger.n ?? 0
            weakest = min(weakest, Double(samples) / Double(Coach.bentCompletions))
        }
        let delay = Self.maxSeconds * weakest
        return delay >= Self.minimumDelay ? delay : 0
    }
}
