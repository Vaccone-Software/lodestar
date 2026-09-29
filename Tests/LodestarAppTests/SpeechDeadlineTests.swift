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

    /// The draft's arithmetic is unchanged: the budget is the old two
    /// attempts and their settle.
    func testTheStartBudgetIsTheAttemptsAndTheSettle() {
        XCTAssertEqual(SpeechStart.startBudget,
                       2 * SpeechStart.deadline + SpeechStart.settleSeconds, accuracy: 0.001)
        XCTAssertLessThan(SpeechStart.startBudget + 2 * SpeechStart.prepareDeadline,
                          DraftController.listenWatchdogSeconds)
    }
}
