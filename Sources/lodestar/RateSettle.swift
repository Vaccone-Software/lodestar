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
    /// The highest rate a hands-free profile runs at (24 kHz in the log, 16
    /// kHz on the headsets whose telephone band is narrower). A flip goes
    /// from the music profile's rate down to one of these, so an input
    /// already at or below it, and not moving, has no flip coming.
    static let phoneRate: Double = 24_000

    enum Outcome: Equatable {
        /// The rate moved off the stale one and held for the quiet period.
        case settled(rate: Double, seconds: TimeInterval)
        /// It never did: the last rate seen, which may be the stale one,
        /// because -10868 has other causes than a flip.
        case timedOut(rate: Double?, seconds: TimeInterval)
        /// The device has no readable rate; waiting for it would be a guess.
        case unreadable
        /// The rate is already a hands-free one and is where the engine was
        /// built: the flip has happened and no other is coming, so there is
        /// nothing to wait for. A start refused here has another cause.
        case alreadyThere(rate: Double)
        /// The session this wait was for has been stopped or replaced.
        case superseded
    }

    /// Whether a flip may still be coming, for an engine built at `stale`
    /// on an input that reads `rate` now. Not when both are one rate that
    /// is a hands-free one: waiting for it to leave that rate was 3.5 s for
    /// nothing every time a headset already at 16 kHz refused a start, and
    /// the wait that was then owed again left the second attempt less time
    /// than it needed. Anything unknown is waited for, as before.
    static func flipComing(from stale: Double?, rate: Double?) -> Bool {
        guard let stale, let rate else { return true }
        return !(stale == rate && rate <= phoneRate)
    }

    /// Wait until `rate` has left `stale` and stood still for `quiet`.
    /// With no stale rate to leave, until it has stood still. No wait at all
    /// when `flipComing` says there is none.
    static func wait(from stale: Double?, quiet: TimeInterval = RateSettle.quiet,
                     deadline: TimeInterval = RateSettle.deadline,
                     rate: () -> Double?, superseded: () -> Bool = { false },
                     clock: () -> TimeInterval, pause: (TimeInterval) -> Void) -> Outcome {
        let began = clock()
        guard var last = rate() else { return .unreadable }
        guard flipComing(from: stale, rate: last) else { return .alreadyThere(rate: last) }
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
