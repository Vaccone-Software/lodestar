import Foundation
import Stoic

/// Runs `work` on the main actor once `delay` has passed on the ambient
/// clock, and returns the task that owns the wait.
///
/// The replacement for `DispatchQueue.main.asyncAfter`, whose timer belongs to
/// nothing and which a test clock cannot advance. Cancelling the returned
/// task ends the wait, and a cancelled task never runs `work`, which is what
/// cancelling a `DispatchWorkItem` did: that holds even when the wait has
/// already ended and the task is waiting for the main actor, since `work` is
/// started only after the task looks, on the main actor, at whether it was
/// cancelled. A caller that never supersedes or
/// cancels its timer may drop the task: `work` still runs once.
///
/// What `work` touches must be carried to the main actor the way the
/// main-queue observers carry it: `MainQueueOnly(value: WeakRef(self))`.
@discardableResult
public func onMain(
    after delay: Duration,
    _ work: @escaping @MainActor @Sendable () -> Void
) -> Task<Void, Never> {
    Task { @MainActor in
        do { try await Ambient.sleep(for: delay) } catch { return }
        // A wait that ended just before a cancel still has to wait for the
        // main actor, where the cancel ran: it is seen here.
        guard !Task.isCancelled else { return }
        work()
    }
}

/// Runs `step` on the main actor `count` times, the first at once and each
/// next one `interval` after the one before it by the schedule, not by how
/// late the last ran, so a slow turn is made up and the run never drifts
/// longer. Returns the task that owns the run: cancelling it stops the steps
/// that have not run.
@discardableResult
public func onMain(
    every interval: Duration,
    times count: Int,
    _ step: @escaping @MainActor () -> Void
) -> Task<Void, Never> {
    Task { @MainActor in
        let clock = Ambient.current.clock
        let began = clock.now
        for index in 0..<count {
            do { try await Ambient.sleep(until: began.advanced(by: interval * index)) } catch { return }
            guard !Task.isCancelled else { return }
            step()
        }
    }
}

/// Runs `work` on `queue` once `delay` has passed on the ambient clock, and
/// returns the task that owns the wait.
///
/// The replacement for `queue.asyncAfter` where the queue is what serializes
/// the state `work` touches: the wait is the task's, so a test clock moves it
/// and cancelling the task ends it, and the work still arrives on the queue
/// behind whatever the queue was doing, as an `asyncAfter` did.
///
/// `clock` is what the delay is counted on: the ambient clock by default,
/// which counts time the Mac spent asleep. A watchdog, which asks whether
/// something answered while the Mac was awake, passes
/// `Ambient.current.livenessClock`, which does not (that is how
/// `asyncAfter` counted every delay).
@discardableResult
public func after(
    _ delay: Duration,
    on queue: DispatchQueue,
    clock: AnyClock? = nil,
    _ work: @escaping @Sendable () -> Void
) -> Task<Void, Never> {
    let clock = clock ?? Ambient.current.clock
    return Task {
        do { try await clock.sleep(until: clock.now.advanced(by: delay)) } catch { return }
        guard !Task.isCancelled else { return }
        queue.async(execute: work)
    }
}
