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
