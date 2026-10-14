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
            _ = try await SpeechStart.withDeadline(0.3) { await Self.stuck(4) }
            XCTFail("a four-second wait inside a 0.3 s deadline returned")
        } catch {
            XCTAssertTrue(error is SpeechStart.TimedOut, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "returned at the deadline, not when the wait ended")
    }

    func testAnAnswerInsideTheDeadlineIsReturned() async throws {
        let value = try await SpeechStart.withDeadline(2) { await Self.stuck(0.1) }
        XCTAssertEqual(value, 1)
    }

    func testAFailureInsideTheDeadlineIsTheFailure() async {
        do {
            _ = try await SpeechStart.withDeadline(2) { () async throws -> Int in throw Boom() }
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
            let value = try await SpeechStart.withDeadline(2.5) { 7 }
            XCTAssertEqual(value, 7)
            XCTAssertEqual(clock.sleeperCount, 0, "the deadline's timer was cancelled")
        }
    }

    /// At the deadline the caller is told, and the work is cancelled in
    /// case it looks; the clock is virtual, so no time passes for real.
    func testTheDeadlineCancelsTheWorkAndSaysTimedOut() async throws {
        let clock = TestClock()
        let cancelled = expectation(description: "work saw its cancellation")
        try await withTestAmbient(clock: clock) {
            let waiting = Task {
                try await SpeechStart.withDeadline(2.5) { () async throws -> Int in
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
            try await SpeechStart.withDeadline(30) { await Self.stuck(0.05) }
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
}
