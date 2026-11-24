import Stoic
import StoicTesting
import XCTest
@testable import LodestarCore

/// The one lane MLX work goes through: one holder, first come first
/// served, and a waiter that leaves never runs.
final class MLXGateTests: XCTestCase {
    /// What happened on the lane, in order.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var inside = 0
        private(set) var mostInside = 0
        func enter(_ name: String) {
            lock.withLock {
                lines.append("in \(name)")
                inside += 1
                mostInside = max(mostInside, inside)
            }
        }
        func leave(_ name: String) {
            lock.withLock {
                lines.append("out \(name)")
                inside -= 1
            }
        }
        var all: [String] { lock.withLock { lines } }
    }

    func testOneHolderAtATimeAndFirstComeFirstServed() async {
        let gate = MLXGate()
        let log = Log()
        let first = await gate.acquire()
        XCTAssertNotNil(first)
        var runs: [Task<Void, Never>] = []
        for name in ["a", "b", "c"] {
            runs.append(Task {
                _ = await gate.run {
                    log.enter(name)
                    await Task.yield()
                    log.leave(name)
                }
            })
            // Each is in the queue before the next arrives.
            while gate.waiting < runs.count { await Task.yield() }
        }
        XCTAssertTrue(log.all.isEmpty, "nobody runs while the first holds it")
        gate.release(first!)
        for run in runs { await run.value }
        XCTAssertEqual(log.all, ["in a", "out a", "in b", "out b", "in c", "out c"])
        XCTAssertEqual(log.mostInside, 1)
        XCTAssertFalse(gate.isHeld)
    }

    func testAWaiterWhoseTaskIsCancelledLeavesWithoutRunning() async {
        let gate = MLXGate()
        let held = await gate.acquire()!
        let ran = Log()
        let gone = Task { () -> Bool in
            await gate.run { ran.enter("gone") } != nil
        }
        let after = Task { () -> Bool in
            await gate.run { ran.enter("after") } != nil
        }
        while gate.waiting < 2 { await Task.yield() }
        gone.cancel()
        let ranGone = await gone.value
        XCTAssertFalse(ranGone, "a cancelled waiter is turned away")
        XCTAssertEqual(gate.waiting, 1, "it left the queue")
        gate.release(held)
        let ranAfter = await after.value
        XCTAssertTrue(ranAfter, "the one behind it still gets the lane")
        XCTAssertEqual(ran.all, ["in after"])
        XCTAssertFalse(gate.isHeld)
    }

    func testATaskCancelledBeforeItAsksNeverTakesTheLane() async {
        let gate = MLXGate()
        let task = Task { () -> MLXGate.Permit? in
            while !Task.isCancelled { await Task.yield() }
            return await gate.acquire()
        }
        task.cancel()
        let permit = await task.value
        XCTAssertNil(permit, "cancelled already: turned away even with the lane free")
        XCTAssertFalse(gate.isHeld)
    }

    func testAWaitThatRunsOutReturnsNilAndTheNextWaiterIsUnharmed() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let gate = MLXGate()
            let held = await gate.acquire()!
            let impatient = Task { await gate.acquire(within: .seconds(3)) }
            let patient = Task { await gate.acquire() }
            while gate.waiting < 2 { await Task.yield() }
            await clock.waitForSleepers()
            await clock.advance(by: .seconds(4))
            let early = await impatient.value
            XCTAssertNil(early, "three seconds in the queue, then nil")
            XCTAssertEqual(gate.waiting, 1)
            gate.release(held)
            let later = await patient.value
            XCTAssertNotNil(later)
            if let later { gate.release(later) }
            XCTAssertFalse(gate.isHeld)
            XCTAssertEqual(clock.sleeperCount, 0, "a wait that was answered leaves no timer")
        }
    }

    func testAnAnsweredWaitCancelsItsTimer() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let gate = MLXGate()
            let permit = await gate.acquire(within: .seconds(3))
            XCTAssertNotNil(permit)
            // Give the cancelled timer a moment to wind down.
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(clock.sleeperCount, 0)
            gate.release(permit!)
        }
    }

    func testAHolderTakenBackFromCannotFreeTheLaneFromItsSuccessor() async {
        let gate = MLXGate()
        let stuck = await gate.acquire()!
        let next = Task { await gate.acquire() }
        while gate.waiting < 1 { await Task.yield() }
        gate.release(stuck)          // the supervisor gives up on the holder
        let successor = await next.value!
        gate.release(stuck)          // the stuck holder wakes up late
        XCTAssertTrue(gate.isHeld, "the late release did nothing")
        gate.release(successor)
        XCTAssertFalse(gate.isHeld)
    }

    func testABlockingThreadWaitsItsTurnBehindAnAsyncHolder() async {
        let gate = MLXGate()
        let held = await gate.acquire()!
        let log = Log()
        let thread = Task.detached {
            gate.runBlocking {
                log.enter("thread")
                log.leave("thread")
            }
        }
        while gate.waiting < 1 { await Task.yield() }
        XCTAssertTrue(log.all.isEmpty)
        gate.release(held)
        await thread.value
        XCTAssertEqual(log.all, ["in thread", "out thread"])
        XCTAssertFalse(gate.isHeld)
    }
}
