import Stoic
import StoicTesting
import XCTest
@testable import lodestar

/// The question in words has a deadline: a model that never answers leaves
/// the rows the words matched, and never "Reading the question" for ever. The
/// clock is the test's own.
final class SettingsAskTests: XCTestCase {
    private struct Refused: Error {}

    func testAModelThatNeverAnswersIsNoAnswerAtTheDeadline() async {
        let clock = TestClock()
        let asking = Task {
            await SettingsAsk.bounded(clock: clock.erased) {
                // As the session does: it waits, and returns when cancelled.
                try await Task.sleep(for: .seconds(3600))
                return "Scroll speed"
            }
        }
        for _ in 0..<2000 where clock.sleeperCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(clock.sleeperCount, 1, "the question is open, with its deadline")
        await clock.advance(by: SettingsAsk.deadline)
        let answer = await asking.value
        XCTAssertNil(answer)
    }

    func testAnAnswerInTimeIsTheAnswerAndAFailureIsNone() async {
        let clock = TestClock()
        let answer = await SettingsAsk.bounded(clock: clock.erased) { "Scroll speed" }
        XCTAssertEqual(answer, "Scroll speed")
        let failed = await SettingsAsk.bounded(clock: clock.erased) { throw Refused() }
        XCTAssertNil(failed)
        XCTAssertEqual(clock.sleeperCount, 0, "no deadline is left running")
    }
}
