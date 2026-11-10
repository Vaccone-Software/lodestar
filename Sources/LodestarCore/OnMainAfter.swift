import Foundation
import Stoic

/// Runs `work` on the main actor once `delay` has passed on the ambient
/// clock, and returns the task that owns the wait.
///
/// The replacement for `DispatchQueue.main.asyncAfter`, whose timer belongs to
/// nothing and which a test clock cannot advance. Cancelling the returned
/// task ends the wait, and a cancelled wait never runs `work`, which is what
/// cancelling a `DispatchWorkItem` did. A caller that never supersedes or
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
            step()
        }
    }
}
