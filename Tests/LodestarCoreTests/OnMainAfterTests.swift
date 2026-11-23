import Foundation
import Stoic
import StoicTesting
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

    // MARK: - The poll

    /// As the repeating timer it took the place of: the first look is one
    /// interval in, there is one look per interval, and the look that
    /// answers true is the last.
    func testAPollLooksOnceAnIntervalUntilItsAnswerIsTrue() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let looks = Mutex(0)
            let poll = onMain(every: .milliseconds(2_500), label: "test.poll") {
                looks.withLock { $0 += 1; return $0 == 3 }
            }
            for expected in 0..<3 {
                await clock.waitForSleepers(timeout: .seconds(60))
                XCTAssertEqual(looks.withLock { $0 }, expected)
                await clock.advance(by: .milliseconds(2_400))
                XCTAssertEqual(looks.withLock { $0 }, expected, "looked before the interval was over")
                await clock.advance(by: .milliseconds(100))
            }
            await poll.value
            XCTAssertEqual(looks.withLock { $0 }, 3)
            XCTAssertEqual(clock.sleeperCount, 0, "the poll went on after its answer")
        }
    }

    func testACancelledPollNeverLooksAgain() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let looks = Mutex(0)
            let poll = onMain(every: .seconds(1), label: "test.poll") {
                looks.withLock { $0 += 1 }
                return false
            }
            await clock.waitForSleepers(timeout: .seconds(60))
            await clock.advance(by: .seconds(1))
            await clock.waitForSleepers(timeout: .seconds(60))
            poll.cancel()
            await poll.value
            await clock.advance(by: .seconds(10))
            XCTAssertEqual(looks.withLock { $0 }, 1)
        }
    }

    /// The wait ended while main was busy, and main cancels before the poll
    /// runs: no look, as an invalidated timer did not fire.
    func testACancelAfterAPollsWaitEndedButBeforeItLooksRunsNothing() async {
        let looks = Mutex(0)
        let poll = onMain(every: .milliseconds(20), label: "test.poll") {
            looks.withLock { $0 += 1 }
            return false
        }
        await startedWaiting()
        let before = looks.withLock { $0 }
        usleep(150_000)
        poll.cancel()
        await poll.value
        XCTAssertEqual(looks.withLock { $0 }, before, "a cancelled poll looked")
    }

    /// A walk's poll that is begun again from inside its own look: the old
    /// one ends and only the new one goes on.
    func testAPollMayCancelItselfFromItsOwnLook() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let looks = Mutex(0)
            let held = Mutex<Task<Void, Never>?>(nil)
            let poll = onMain(every: .seconds(1), label: "test.poll") {
                looks.withLock { $0 += 1 }
                held.withLock { $0 }?.cancel()
                return false
            }
            held.withLock { $0 = poll }
            await clock.waitForSleepers(timeout: .seconds(60))
            await clock.advance(by: .seconds(1))
            await poll.value
            XCTAssertEqual(looks.withLock { $0 }, 1)
        }
    }

    // MARK: - Which clock

    /// What replaced a `Timer` does not count the time the Mac was asleep.
    func testATimersReplacementCountsOnTheClockItIsGiven() async {
        let awake = TestClock()
        let ran = Mutex(false)
        let task = onMain(after: .seconds(900), clock: awake.erased) { ran.withLock { $0 = true } }
        await awake.waitForSleepers(timeout: .seconds(60))
        XCTAssertFalse(ran.withLock { $0 })
        await awake.advance(by: .seconds(900))
        await task.value
        XCTAssertTrue(ran.withLock { $0 })
    }

    func testAPollCountsOnTheLivenessClock() async {
        let ambientClock = TestClock()
        let awake = TestClock()
        await withTestAmbient(clock: ambientClock) {
            await withAmbient({ $0.livenessClock = awake.erased }) {
                let poll = onMain(every: .seconds(1), label: "test.poll") { true }
                await awake.waitForSleepers(timeout: .seconds(60))
                XCTAssertEqual(ambientClock.sleeperCount, 0)
                await awake.advance(by: .seconds(1))
                await poll.value
            }
        }
    }
}
