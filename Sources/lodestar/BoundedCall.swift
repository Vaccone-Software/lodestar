import Foundation
import LodestarCore
import Stoic
import Synchronization

/// A call that may never come back, given a deadline, for a caller that is
/// not async: a queue's thread, or the main thread, that must not be held by
/// a file on a dead mount or an Apple Event to an app that has stopped
/// answering.
///
/// The waiting is Stoic's `abandoningAfter` (work that blocks) and
/// `abandoningAsyncAfter` (work that awaits), each under a label. What
/// overruns is left running, holds its place under the label until it
/// returns, is counted (`AbandonedWork`), and once all of a label's places
/// are held by work that has not come back the next call is refused at once.
/// Every way of not having an answer (overrun, refused, never begun) is nil.
///
/// The wait is on a task that Stoic's wait answers by its deadline at the
/// latest, so the caller is not held past it; an ordinary Task, so the
/// ambient context of the caller (where Stoic's events go) comes with it. It
/// needs a thread of the cooperative pool for the moment it takes to start
/// the work, and a pool with none to give must not hold the caller for ever:
/// on the real clock the caller waits `backstop` past the deadline and no
/// longer, and has nothing. On a test's clock the deadline is the test's to
/// move, and there is no other.
enum BoundedCall {
    /// How a task is started: an ordinary Task, or a test's stand-in for a
    /// pool that never starts it.
    typealias Start = (@escaping @Sendable () async -> Void) -> Void
    static let task: Start = { work in Task { await work() } }

    /// `work` on a thread of Dispatch's, given `seconds`, under `label`.
    static func blocking<T: Sendable>(_ seconds: TimeInterval, label: String, limit: Int, clock: AnyClock?,
                                      qos: DispatchQoS.QoSClass = .utility, backstop: TimeInterval = 1,
                                      start: Start = task, _ work: @escaping @Sendable () -> T?) -> T? {
        bridge(seconds, label: label, clock: clock, backstop: backstop, start: start) { clock in
            do throws(PolicyError<Never>) {
                return try await abandoningAfter(.seconds(seconds), label: label, limit: limit, clock: clock,
                                                 qos: qos, operation: work)
            } catch {
                return nil
            }
        }
    }

    /// The same for work that awaits: it runs as a task, is cancelled at the
    /// deadline in case it looks, and holds its place under the label until it
    /// returns, cancelled or not.
    static func awaiting<T: Sendable>(_ seconds: TimeInterval, label: String, limit: Int, clock: AnyClock?,
                                      backstop: TimeInterval = 1, start: Start = task,
                                      _ work: @escaping @concurrent @Sendable () async -> T?) -> T? {
        bridge(seconds, label: label, clock: clock, backstop: backstop, start: start) { clock in
            do throws(PolicyError<Never>) {
                return try await abandoningAsyncAfter(.seconds(seconds), label: label, limit: limit, clock: clock,
                                                      operation: work)
            } catch {
                return nil
            }
        }
    }

    private static func bridge<T: Sendable>(_ seconds: TimeInterval, label: String, clock: AnyClock?,
                                            backstop: TimeInterval, start: Start,
                                            _ ask: @escaping @Sendable (AnyClock?) async -> T?) -> T? {
        let handoff = Handoff<T>()
        start { handoff.finish(await ask(clock)) }
        guard clock == nil else { return handoff.wait() }
        guard let answer = handoff.wait(for: seconds + backstop) else {
            Log.error("\(label): the call was not begun or answered \(backstop) s past its deadline, so its caller went on without it")
            return nil
        }
        return answer
    }

    /// An answer handed from the task to the thread waiting for it.
    private final class Handoff<T: Sendable>: Sendable {
        private let stored = Mutex<T?>(nil)
        private let done = DispatchSemaphore(value: 0)
        func finish(_ value: T?) { stored.withLock { $0 = value }; done.signal() }
        func wait() -> T? { done.wait(); return stored.withLock { $0 } }
        /// The answer if it came within `seconds`; a wait that ran out is
        /// told from an answer of nothing by the outer nil.
        func wait(for seconds: TimeInterval) -> T?? {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
            return .some(stored.withLock { $0 })
        }
    }
}
