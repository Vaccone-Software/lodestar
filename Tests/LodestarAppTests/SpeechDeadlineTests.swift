import Stoic
import StoicTesting
import Testing
import XCTest
@testable import lodestar

/// A deadline that returns at the deadline. It was a task group, which
/// returns only once every child has: a start stuck in a continuation held
/// the "deadline" until the start came back (a one-second deadline on a
/// four-second wait returned after 4.3 s).
final class SpeechDeadlineTests: XCTestCase {
    private struct Boom: Error {}

    /// A wait nothing can cancel, the way a CoreAudio start is.
    private static func stuck(_ seconds: TimeInterval) async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume(returning: 1) }
        }
    }

    func testAStuckWaitIsGivenUpOnAtTheDeadline() async {
        let started = Date()
        do {
            _ = try await SpeechStart.withDeadline(0.3, label: "test.deadline") { await Self.stuck(4) }
            XCTFail("a four-second wait inside a 0.3 s deadline returned")
        } catch {
            XCTAssertTrue(error is SpeechStart.TimedOut, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "returned at the deadline, not when the wait ended")
    }

    func testAnAnswerInsideTheDeadlineIsReturned() async throws {
        let value = try await SpeechStart.withDeadline(2, label: "test.deadline") { await Self.stuck(0.1) }
        XCTAssertEqual(value, 1)
    }

    func testAFailureInsideTheDeadlineIsTheFailure() async {
        do {
            _ = try await SpeechStart.withDeadline(2, label: "test.deadline") { () async throws -> Int in throw Boom() }
            XCTFail("no failure")
        } catch {
            XCTAssertTrue(error is Boom, "\(error)")
        }
    }

    /// The sleeper the hand-rolled deadline never cancelled: when the work
    /// wins, nothing is left waiting on the clock.
    func testTheTimerIsGoneWhenTheWorkWins() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let value = try await SpeechStart.withDeadline(2.5, label: "test.deadline") { 7 }
            XCTAssertEqual(value, 7)
            XCTAssertEqual(clock.sleeperCount, 0, "the deadline's timer was cancelled")
        }
    }

    /// At the deadline the caller is told, and the work is cancelled in
    /// case it looks; the clock is virtual, so no time passes for real.
    func testTheDeadlineCancelsTheWorkAndSaysTimedOut() async {
        let clock = TestClock()
        let cancelled = expectation(description: "work saw its cancellation")
        await withTestAmbient(clock: clock) {
            let waiting = Task {
                try await SpeechStart.withDeadline(2.5, label: "test.deadline") { () async throws -> Int in
                    do { try await Task.sleep(for: .seconds(60)) } catch { cancelled.fulfill(); throw error }
                    return 1
                }
            }
            await clock.waitForSleepers()
            await clock.advance(by: .seconds(3))
            do {
                _ = try await waiting.value
                XCTFail("a start that never answered returned")
            } catch {
                XCTAssertTrue(error is SpeechStart.TimedOut, "\(error)")
            }
        }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    /// A caller that is cancelled is not a microphone that did not answer.
    func testACancelledCallerIsCancelledNotTimedOut() async {
        let waiting = Task {
            try await SpeechStart.withDeadline(30, label: "test.deadline") { await Self.stuck(0.05) }
        }
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// The draft's arithmetic is unchanged: the budget is the old two
    /// attempts and their settle.
    func testTheStartBudgetIsTheAttemptsAndTheSettle() {
        XCTAssertEqual(SpeechStart.startBudget,
                       2 * SpeechStart.deadline + SpeechStart.settleSeconds, accuracy: 0.001)
        XCTAssertLessThan(SpeechStart.startBudget + 2 * SpeechStart.prepareDeadline,
                          DraftController.listenWatchdogSeconds)
    }

    // MARK: - One label for each thing that can hang

    /// Work that never returns until it is let go, so a test can fill a
    /// label's slots and give them back.
    private final class Stuck: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [CheckedContinuation<Int, Never>] = []
        func wait() async -> Int {
            await withCheckedContinuation { continuation in
                lock.lock(); held.append(continuation); lock.unlock()
            }
        }
        func release() {
            lock.lock(); let all = held; held = []; lock.unlock()
            for continuation in all { continuation.resume(returning: 0) }
        }
    }

    /// Four audio starts that never come back, each abandoned at its deadline.
    private func wedgeTheAudioStart(_ stuck: Stuck) async {
        addTeardownBlock { stuck.release() }
        for _ in 0..<4 {
            _ = try? await SpeechStart.startAudio(within: 0.05) { await stuck.wait() }
        }
    }

    /// The log's wedge: a headset start hung inside CoreAudio and the
    /// bridge hung behind it, all under one label, and the recognizer's own
    /// `prepareToAnalyze` was refused in the same millisecond with no wait
    /// and blamed. Each wait now has its own slots.
    func testAWedgedAudioStartDoesNotRefuseTheRecognizersPrepare() async throws {
        let stuck = Stuck()
        await wedgeTheAudioStart(stuck)
        do {
            _ = try await SpeechStart.startAudio(within: 0.05) { 1 }
            XCTFail("the audio start's slots are all held, so a fifth start is refused")
        } catch {
            XCTAssertTrue(error is SpeechStart.Wedged, "\(error)")
        }
        let prepared = try await SpeechStart.prepare { 7 }
        XCTAssertEqual(prepared, 7, "the recognizer's wait proceeds while the audio start is wedged")
        let opened = try await SpeechStart.openBridge { true }
        XCTAssertTrue(opened, "and so does the bridge")
    }

    /// The other way round: a recognizer that hangs does not fill the
    /// audio start's slots, so the microphone is not called wedged for it.
    func testAWedgedRecognizerDoesNotRefuseTheAudioStart() async throws {
        let stuck = Stuck()
        addTeardownBlock { stuck.release() }
        for _ in 0..<4 { _ = try? await SpeechStart.withDeadline(0.05, label: SpeechStart.Label.prepare) { await stuck.wait() } }
        do {
            _ = try await SpeechStart.prepare { 1 }
            XCTFail("the recognizer's slots are all held")
        } catch {
            XCTAssertTrue(error is SpeechStart.Wedged, "\(error)")
        }
        let started = try await SpeechStart.startAudio(within: 0.5) { 3 }
        XCTAssertEqual(started, 3)
    }

    func testEachWaitHasItsOwnLabel() {
        let labels = [SpeechStart.Label.prepare, SpeechStart.Label.bridge, SpeechStart.Label.start]
        XCTAssertEqual(Set(labels).count, 3, "\(labels)")
    }

    /// A wedge is a start that never came back, so it ends when one does.
    func testTheWedgeEndsWhenAStuckStartReturns() async throws {
        let stuck = Stuck()
        await wedgeTheAudioStart(stuck)
        stuck.release()
        var answered: Int?
        for _ in 0..<100 where answered == nil {
            answered = try? await SpeechStart.startAudio(within: 0.5) { 5 }
            if answered == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(answered, 5, "a slot came free, and the next start proceeded")
    }
}
