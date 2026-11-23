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

    // MARK: - The settling

    private final class Owner {}
    private let owner = Owner()

    func testOnlyTheLastOfABurstRunsItsDelayAfterItself() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let slot = TaskSlot<Void, any Error>(label: "test.settle")
            let ran = Mutex<[Int]>([])
            for call in 1...3 {
                let mark = clock.totalSleeps
                slot.settle(for: owner, after: .seconds(1)) { _ in ran.withLock { $0.append(call) } }
                await clock.waitForSleepers(newerThan: mark, timeout: .seconds(60))
                await clock.advance(by: .milliseconds(900))
            }
            XCTAssertEqual(ran.withLock { $0 }, [], "ran before the burst had settled")
            await clock.advance(by: .milliseconds(100))
            await finished(slot)
            XCTAssertEqual(ran.withLock { $0 }, [3])
            XCTAssertFalse(slot.isRunning)
        }
    }

    /// The delay is each call's own: a longer one put off and a shorter one
    /// put in its place runs at the shorter.
    func testEachCallBringsItsOwnDelay() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let slot = TaskSlot<Void, any Error>(label: "test.settle")
            let ran = Mutex<[String]>([])
            slot.settle(for: owner, after: .seconds(60)) { _ in ran.withLock { $0.append("long") } }
            await clock.waitForSleepers(timeout: .seconds(60))
            let mark = clock.totalSleeps
            slot.settle(for: owner, after: .seconds(1)) { _ in ran.withLock { $0.append("short") } }
            await clock.waitForSleepers(newerThan: mark, timeout: .seconds(60))
            await clock.advance(by: .seconds(1))
            await finished(slot)
            await clock.advance(by: .seconds(120))
            XCTAssertEqual(ran.withLock { $0 }, ["short"])
        }
    }

    /// The wait is over and the work is queued behind the turn that cancels
    /// or supersedes it: it must not run, as with a cancelled `onMain`.
    func testACancelOrANewerCallAfterTheWaitEndedRunsNothing() async {
        let slot = TaskSlot<Void, any Error>(label: "test.settle")
        let ran = Mutex<[String]>([])
        slot.settle(for: owner, after: .milliseconds(200)) { _ in ran.withLock { $0.append("cancelled") } }
        XCTAssertTrue(slot.isRunning, "waiting is owed")
        await startedWaiting()
        usleep(400_000)
        slot.cancel()
        XCTAssertFalse(slot.isRunning, "a cancelled call is not owed")
        await finished(slot)
        XCTAssertEqual(ran.withLock { $0 }, [])

        slot.settle(for: owner, after: .milliseconds(200)) { _ in ran.withLock { $0.append("superseded") } }
        await startedWaiting()
        usleep(400_000)
        slot.settle(for: owner, after: .milliseconds(1)) { _ in ran.withLock { $0.append("newer") } }
        await finished(slot)
        XCTAssertEqual(ran.withLock { $0 }, ["newer"])
    }

    /// Runs on main, and may ask for the next from inside its own run, as a
    /// fold that failed does.
    func testTheWorkMayAskForTheNextFromItsOwnRun() async {
        let slot = TaskSlot<Void, any Error>(label: "test.settle")
        let ran = Mutex(0)
        slot.settle(for: owner, after: .milliseconds(1)) { owner in
            dispatchPrecondition(condition: .onQueue(.main))
            ran.withLock { $0 += 1 }
            slot.settle(for: owner, after: .milliseconds(1)) { _ in ran.withLock { $0 += 1 } }
        }
        await finished(slot)
        XCTAssertEqual(ran.withLock { $0 }, 2)
    }

    func testNothingRunsForAnOwnerThatIsGone() async {
        let slot = TaskSlot<Void, any Error>(label: "test.settle")
        let ran = Mutex(false)
        var owner: Owner? = Owner()
        slot.settle(for: owner!, after: .milliseconds(20)) { _ in ran.withLock { $0 = true } }
        owner = nil
        await finished(slot)
        XCTAssertFalse(ran.withLock { $0 })
    }

    /// Until every piece of the slot's work has ended.
    private func finished(_ slot: TaskSlot<Void, any Error>) async {
        while slot.unfinishedCount > 0 { await Task.yield() }
    }
}
