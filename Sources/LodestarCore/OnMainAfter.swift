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
///
/// `clock` is what the delay is counted on, as `after(_:on:clock:_:)` has it:
/// the ambient clock by default, which counts time the Mac spent asleep. What
/// took the place of a `Timer` passes `Ambient.current.livenessClock`, which
/// does not, as a run loop's timers do not.
@discardableResult
public func onMain(
    after delay: Duration,
    clock: AnyClock? = nil,
    _ work: @escaping @MainActor @Sendable () -> Void
) -> Task<Void, Never> {
    let clock = clock ?? Ambient.current.clock
    return Task { @MainActor in
        do { try await clock.sleep(until: clock.now.advanced(by: delay)) } catch { return }
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

/// Runs `check` on the main actor every `interval` until it answers true,
/// and returns the task that owns the poll: cancelling it ends the poll, and
/// a cancelled poll never runs `check` again.
///
/// The first look is one interval in, as a repeating timer's first fire was:
/// the caller has just looked for itself. Each next one is `interval` after
/// the last has run. Stoic's `recur` over an unbounded schedule, which is why
/// the caller must hold the task and cancel it where it stops caring: a
/// permission poll waits as long as the person takes to grant it.
@discardableResult
public func onMain(
    every interval: Duration,
    label: String,
    until check: @escaping @MainActor () -> Bool
) -> Task<Void, Never> {
    // As a run loop's timer counts: not the time the Mac spent asleep.
    let clock = Ambient.current.livenessClock
    return Task { @MainActor in
        await recur(Schedule.fixed(interval), clock: clock, label: label) { run in
            // The first run only starts the clock: the first look is one
            // interval in.
            guard run.number > 1 else { return .continue }
            return check() ? .stop : .continue
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
