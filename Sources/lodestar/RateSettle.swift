import Foundation

/// Waiting out a Bluetooth headset's profile flip, so an engine is built
/// for the rate the headset will keep.
///
/// A radio at rest is on its music profile (48 kHz in the field log) and
/// opening its input flips it to hands-free (24 kHz): the first start is
/// what asks for the flip, and an engine built or started before the
/// rate has landed is bound to the rate the headset is leaving. Either
/// the start is refused (-10868) or it runs and delivers nothing, which
/// the silence watch calls four seconds later and a rebuild answers
/// three seconds after that: 8 of the 13 engines that started across the
/// flip in the log were deaf, against 2 of 42 built after it. The old
/// answer was to try again at once and then on a timer, which raced the
/// same transition. This waits for the rate itself.
///
/// Pure: the rate, the clock and the pause are arguments, so the rule
/// runs on a virtual clock in the tests and on CoreAudio in the app.
enum RateSettle {
    /// How long the rate must hold still before it is believed. The flip
    /// can post a rate and then another (24 kHz, then the telephone
    /// band) a beat apart.
    static let quiet: TimeInterval = 0.3
    /// The most a wait may take. The flip landed about 3.5 s after the
    /// first start in the log and the refusal comes one to two seconds
    /// into that, so the rate is two seconds off at the worst and a little
    /// more is room; it stays inside the whole start's budget, so a
    /// headset that never moves costs a bounded pause rather than a stall,
    /// and the bridge keeps the take while it is spent.
    static let deadline: TimeInterval = 3.5
    static let poll: TimeInterval = 0.05

    enum Outcome: Equatable {
        /// The rate moved off the stale one and held for the quiet period.
        case settled(rate: Double, seconds: TimeInterval)
        /// It never did: the last rate seen, which may be the stale one,
        /// because -10868 has other causes than a flip.
        case timedOut(rate: Double?, seconds: TimeInterval)
        /// The device has no readable rate; waiting for it would be a guess.
        case unreadable
        /// The session this wait was for has been stopped or replaced.
        case superseded
    }

    /// Wait until `rate` has left `stale` and stood still for `quiet`.
    /// With no stale rate to leave, until it has stood still.
    static func wait(from stale: Double?, quiet: TimeInterval = RateSettle.quiet,
                     deadline: TimeInterval = RateSettle.deadline,
                     rate: () -> Double?, superseded: () -> Bool = { false },
                     clock: () -> TimeInterval, pause: (TimeInterval) -> Void) -> Outcome {
        let began = clock()
        guard var last = rate() else { return .unreadable }
        var since = began
        while true {
            let now = clock()
            if superseded() { return .superseded }
            let elapsed = now - began
            if let current = rate() {
                if current != last { last = current; since = now }
                let left = stale.map { current != $0 } ?? true
                if left, now - since >= quiet { return .settled(rate: current, seconds: elapsed) }
            }
            if elapsed >= deadline { return .timedOut(rate: last, seconds: elapsed) }
            pause(min(poll, deadline - elapsed))
        }
    }
}
