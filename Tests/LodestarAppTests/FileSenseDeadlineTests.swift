import Stoic
import StoicTesting
import XCTest
@testable import lodestar

/// How a read of a file is waited for, apart from what is read: given its
/// seconds, abandoned at them and counted, refused at once under a label that
/// has no place left, and let go of when it comes back late. The clock is the
/// test's own, so a read overruns when the test moves it and never because a
/// machine was slow, and a refusal is told from a wait by the clock not
/// having moved.
final class FileSenseDeadlineTests: XCTestCase {
    private let clock = TestClock()
    private let events = RecordingInstrumentation()

    override func setUp() {
        setOverride(\FileSense.Type.clock, to: clock.erased)
        // A read still stuck outlives its test; its place under the label goes
        // when it comes back, which is what the tests open.
        addTeardownBlock { [clock] in await clock.advance(by: .seconds(1_000_000)) }
    }

    /// A read that blocks its thread until the test lets it through, and says
    /// when it began and when it was through.
    private final class Stuck: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var _began = 0
        private var _finished = 0
        var began: Int { lock.withLock { _began } }
        var finished: Int { lock.withLock { _finished } }
        func run() -> Int? {
            lock.withLock { _began += 1 }
            gate.wait()
            lock.withLock { _finished += 1 }
            return 7
        }
        func release() { for _ in 0..<8 { gate.signal() } }
    }

    /// A call of the synchronous API from a thread of its own, as a queue of
    /// the store makes it, with the recording sink as the context it is made in.
    private func read(seconds: Double = 2, label: String, limit: Int = 2,
                      _ work: @escaping @Sendable () -> Int?) async -> Int? {
        let events = events
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let answer = withAmbient({ $0.instrumentation = events }) {
                    FileSense.withDeadline(seconds, label: label, limit: limit, work)
                }
                continuation.resume(returning: answer)
            }
        }
    }

    /// Real time for what threads and tasks do after the clock moved. A
    /// hang guard: a condition that does not come fails the test.
    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func abandoned(_ label: String) -> Int { AbandonedWork.current.filter { $0.label == label }.count }

    // MARK: A read that overruns

    func testAReadThatReturnsInTimeIsItsAnswerAndLeavesNothingWaiting() async {
        let answer = await read(label: "test.quick") { 5 }
        XCTAssertEqual(answer, 5)
        XCTAssertEqual(clock.sleeperCount, 0, "its deadline's timer was cancelled, not left to run out")
        XCTAssertEqual(events.names, [], "and nothing was decided that needs saying")
    }

    func testAReadThatNeverReturnsIsAbandonedAtItsDeadlineAndTheCallerHasNothing() async {
        let stuck = Stuck()
        defer { stuck.release() }
        let asking = Task { await read(label: "test.stuck") { stuck.run() } }
        let began = await eventually { stuck.began == 1 && clock.sleeperCount == 1 }
        XCTAssertTrue(began, "the read is under way, with its two seconds")
        await clock.advance(by: .seconds(2))
        let answer = await asking.value
        XCTAssertNil(answer, "the answer of a read that overran is nothing, as it was")
        XCTAssertEqual(stuck.finished, 0, "the read was left running, not waited for")
        XCTAssertEqual(abandoned("test.stuck"), 1, "and it is on the ledger of abandoned work")
        XCTAssertTrue(events.names.contains("abandoned.started"), "and the context the caller made the call in was told")
    }

    // MARK: A label with no place left

    func testWhenEveryPlaceUnderALabelHoldsAReadThatNeverCameBackTheNextReadIsRefusedAtOnce() async {
        let stuck = Stuck()
        defer { stuck.release() }
        let first = Task { await read(label: "test.wedged") { stuck.run() } }
        let second = Task { await read(label: "test.wedged") { stuck.run() } }
        let began = await eventually { stuck.began == 2 && clock.sleeperCount == 2 }
        XCTAssertTrue(began, "both places are in use, each read with its own two seconds")
        await clock.advance(by: .seconds(2))
        let firstAnswer = await first.value
        let secondAnswer = await second.value
        XCTAssertNil(firstAnswer)
        XCTAssertNil(secondAnswer)
        XCTAssertEqual(abandoned("test.wedged"), 2)

        // An hour, and the clock is not moved: only a refusal comes back.
        let ran = LockedCount()
        let third = Task { await read(seconds: 3600, label: "test.wedged") { ran.add(); return 1 } }
        let refused = await eventually { events.names.contains("abandoned.wedged") }
        if !refused { await clock.advance(by: .seconds(10_000)) }   // so a failure is not a hang
        XCTAssertTrue(refused, "refused at once, without waiting for a place or for its hour")
        let thirdAnswer = await third.value
        XCTAssertNil(thirdAnswer, "the caller has the answer of a read that overran")
        XCTAssertEqual(ran.count, 0, "the read was never begun")
        XCTAssertEqual(clock.sleeperCount, 0, "and no deadline was started for it")
    }

    /// Only the label that is wedged refuses: what is read under another is
    /// read as before.
    func testAWedgedLabelDoesNotRefuseAnother() async {
        let stuck = Stuck()
        defer { stuck.release() }
        let first = Task { await read(label: "test.wedged-one", limit: 1) { stuck.run() } }
        _ = await eventually { stuck.began == 1 && clock.sleeperCount == 1 }
        await clock.advance(by: .seconds(2))
        _ = await first.value
        let elsewhere = await read(label: "test.not-wedged", limit: 1) { 3 }
        XCTAssertEqual(elsewhere, 3)
    }

    // MARK: A read that comes back late

    func testAStuckReadThatLaterReturnsFreesItsPlaceUnderTheLabel() async {
        let stuck = Stuck()
        defer { stuck.release() }
        let first = Task { await read(label: "test.late", limit: 1) { stuck.run() } }
        _ = await eventually { stuck.began == 1 && clock.sleeperCount == 1 }
        await clock.advance(by: .seconds(2))
        _ = await first.value
        let refused = await read(label: "test.late", limit: 1) { 9 }
        XCTAssertNil(refused, "the only place is held by the read that has not come back")
        XCTAssertEqual(events.names.filter { $0 == "abandoned.wedged" }.count, 1)

        stuck.release()
        let freed = await eventually { abandoned("test.late") == 0 }
        XCTAssertTrue(freed, "it came back, and the ledger lets it go")
        XCTAssertTrue(events.names.contains("abandoned.completed"), "saying it was late")
        let again = await read(label: "test.late", limit: 1) { 9 }
        XCTAssertEqual(again, 9, "and the next read has its place")
        XCTAssertEqual(stuck.finished, 1)
    }

    // MARK: Reads that await

    func testAnAwaitedReadThatNeverReturnsIsAbandonedAndOneThatLooksIsCancelledAtTheDeadline() async {
        let gate = FileGate()
        defer { gate.open() }
        let stuck = Task { () -> Int? in
            let events = events
            return await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: withAmbient({ $0.instrumentation = events }) {
                        FileSense.withAsyncDeadline(2, label: "test.async-stuck", limit: 2) { await gate.wait(); return 1 }
                    })
                }
            }
        }
        let cancelled = LockedCount()
        let looking = Task { () -> Int? in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: FileSense.withAsyncDeadline(2, label: "test.async-looks", limit: 2) {
                        do { try await Task.sleep(for: .seconds(3600)) } catch { cancelled.add() }
                        return nil
                    })
                }
            }
        }
        let waiting = await eventually { clock.sleeperCount == 2 }
        XCTAssertTrue(waiting, "both reads are waiting for their two seconds")
        await clock.advance(by: .seconds(2))
        let stuckAnswer = await stuck.value
        let lookingAnswer = await looking.value
        XCTAssertNil(stuckAnswer)
        XCTAssertNil(lookingAnswer)
        XCTAssertEqual(abandoned("test.async-stuck"), 1, "the read that ignores cancellation holds its place")
        let sawCancel = await eventually { cancelled.count == 1 && abandoned("test.async-looks") == 0 }
        XCTAssertTrue(sawCancel, "the read that looks was cancelled at the deadline and let its place go")
    }

    /// QuickLook answers by callback, and what its cancel does is not
    /// promised: the read is answered when the task is cancelled, and a
    /// callback that comes after is ignored.
    func testACallbackThatNeverComesIsGivenUpOnWhenTheTaskIsCancelled() async {
        let late = LateCallback()
        let cancels = LockedCount()
        let answered = LockedCount()
        let waiting = Task { () -> Int? in
            let answer = await FileSense.awaiting(start: { late.keep($0) }, cancel: { cancels.add() })
            answered.add()
            return answer
        }
        let started = await eventually { late.isKept }
        XCTAssertTrue(started)
        waiting.cancel()
        let returned = await eventually { answered.count == 1 }
        if !returned { late.call(nil) }   // so a failure is not a hang
        XCTAssertTrue(returned, "answered when cancelled, with the callback still to come")
        let answer = await waiting.value
        XCTAssertNil(answer)
        XCTAssertEqual(cancels.count, 1, "the request was cancelled with its maker")
        late.call(5)   // too late: nothing is resumed twice
    }

    func testACallbackThatComesIsTheAnswerAndACancellationAfterItChangesNothing() async {
        let cancels = LockedCount()
        let waiting = Task { () -> Int? in
            await FileSense.awaiting(start: { answer in answer(11) }, cancel: { cancels.add() })
        }
        let answer = await waiting.value
        XCTAssertEqual(answer, 11)
        waiting.cancel()
        XCTAssertEqual(cancels.count, 0)
    }

    private final class LockedCount: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func add() { lock.withLock { _count += 1 } }
    }

    private final class LateCallback: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: (@Sendable (Int?) -> Void)?
        var isKept: Bool { lock.withLock { answer != nil } }
        func keep(_ answer: @escaping @Sendable (Int?) -> Void) { lock.withLock { self.answer = answer } }
        func call(_ value: Int?) { lock.withLock { answer }?(value) }
    }
}
