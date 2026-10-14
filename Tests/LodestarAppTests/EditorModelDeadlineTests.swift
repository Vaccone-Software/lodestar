import Stoic
import StoicTesting
import Testing
import XCTest
@testable import lodestar

/// The editor's model is given a deadline and is not waited on past it.
/// The clock is virtual, so the deadline passes without a real wait.
final class EditorModelDeadlineTests: XCTestCase {
    func testAnAnswerInsideTheDeadlineIsReturnedAndLeavesNoTimer() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let answer = await EditorModel.within(5) { "fixed" }
            XCTAssertEqual(answer, "fixed")
            XCTAssertEqual(clock.sleeperCount, 0, "the deadline's timer was cancelled, not left to run out")
        }
    }

    func testAnAnswerThatDoesNotComeIsNilAtTheDeadlineAndTheWorkIsCancelled() async throws {
        let clock = TestClock()
        let cancelled = expectation(description: "the generation saw its cancellation")
        try await withTestAmbient(clock: clock) {
            let asking = Task { () -> String? in
                await EditorModel.within(5) { () async -> String? in
                    do { try await Task.sleep(for: .seconds(60)) } catch { cancelled.fulfill() }
                    return "late"
                }
            }
            await clock.waitForSleepers()
            await clock.advance(by: .seconds(6))
            let answer = await asking.value
            XCTAssertNil(answer)
        }
        await fulfillment(of: [cancelled], timeout: 2)
    }
}
