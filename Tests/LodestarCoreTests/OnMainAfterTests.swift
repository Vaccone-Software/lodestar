import Foundation
import Stoic
import Synchronization
import XCTest
@testable import LodestarCore

/// The timers that took the place of `asyncAfter`: a cancel stops the work as
/// cancelling a `DispatchWorkItem` did, including the cancel that lands after
/// the wait is over but before the main actor has run what follows it.
@MainActor
final class OnMainAfterTests: XCTestCase {
    func testTheWorkRunsOnceTheDelayHasPassed() async {
        let ran = Mutex(false)
        let task = onMain(after: .milliseconds(10)) { ran.withLock { $0 = true } }
        await task.value
        XCTAssertTrue(ran.withLock { $0 })
    }

    func testACancelBeforeTheDelayEndsRunsNothing() async {
        let ran = Mutex(false)
        let task = onMain(after: .seconds(5)) { ran.withLock { $0 = true } }
        task.cancel()
        await task.value
        XCTAssertFalse(ran.withLock { $0 })
    }

    /// The wait ends while the main thread is busy, and the main thread
    /// cancels before it gets to the task: the work must not run, as a
    /// cancelled work item already sitting in the main queue did not.
    func testACancelAfterTheWaitEndedButBeforeMainRanItRunsNothing() async {
        let ran = Mutex(false)
        let task = onMain(after: .milliseconds(20)) { ran.withLock { $0 = true } }
        // Let the task start its wait (it starts on the main actor, so only
        // once this turn gives it up), then hold the main thread past the
        // delay, so the wait is over and the rest of the task is queued
        // behind this turn when the cancel comes.
        await startedWaiting()
        usleep(150_000)
        task.cancel()
        await task.value
        XCTAssertFalse(ran.withLock { $0 }, "a cancelled timer ran its work")
    }

    func testACancelledRepetitionStopsItsSteps() async {
        let steps = Mutex(0)
        let task = onMain(every: .milliseconds(20), times: 100) { steps.withLock { $0 += 1 } }
        await startedWaiting()
        let before = steps.withLock { $0 }
        usleep(150_000)
        task.cancel()
        await task.value
        XCTAssertEqual(steps.withLock { $0 }, before, "steps ran after the cancel")
    }

    /// Gives the main actor a few turns, so a task started on it begins.
    private func startedWaiting() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testTheQueueTimerIsCancelledTheSameWay() async {
        let ran = Mutex(false)
        let queue = DispatchQueue(label: "on-main-after.tests")
        let task = after(.milliseconds(5), on: queue) { ran.withLock { $0 = true } }
        task.cancel()
        await task.value
        queue.sync {}
        XCTAssertFalse(ran.withLock { $0 })
    }
}
