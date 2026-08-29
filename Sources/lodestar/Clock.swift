import Foundation

/// When the shell waits.
///
/// Every delay a surface takes — the peek's half second, the coach's
/// settle, the minute a chip stands, a flash's fade — goes through here
/// rather than straight to the main queue, so the scenario harness can
/// hold a clock of its own and advance it by hand. A sixty-second chip is
/// then a sixty-second chip in no wall time, and a test that says "at ten
/// seconds the offer is spent" states its own clock instead of inheriting
/// the machine's. The app uses `.live`: the wall clock and the main queue.
struct Clock {
    /// The current moment.
    let now: () -> Date
    /// Run `work` after `delay`, unless it is cancelled first. Always on
    /// the main thread — everything scheduled through here draws.
    let after: (TimeInterval, DispatchWorkItem) -> Void

    static let live = Clock(
        now: { Date() },
        after: { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        })
}
