import XCTest
@testable import lodestar
import LodestarCore
import LodestarEars

/// ⏎ waits for the ear and the rewrite, and says so once the wait is long
/// enough to be noticed. A second ⏎ lands at once with what stands.
final class DraftFinishingScenarioTests: XCTestCase {
    private func timed(_ text: String, _ start: Double, _ end: Double) -> Heard {
        Heard(text, words: [Heard.Word(text, start: start, end: end)])
    }

    /// A stage whose ear is stuck on the first hearing until released.
    private func stuck(_ ear: FakeEar) -> Stage {
        ear.holdFirst()
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 6), rate: 16_000)
        return stage
    }

    func testTheFootSaysFinishingOnceTheWaitIsLong() {
        let ear = FakeEar(answer: "Rebase local/dev on main.")
        let stage = stuck(ear)
        stage.lode(".")
        stage.speech.settle(timed("Rebase local dev on main.", 0, 2))
        stage.press("return")
        XCTAssertTrue(stage.draft.isOpen, "waiting for the ear")
        XCTAssertEqual(stage.draft.state["finishing"] as? Bool, false, "not yet: a landing this quick needs no word")
        XCTAssertNotEqual(stage.draft.panel.registerDetail, "finishing")
        stage.clock.advance(by: 0.2)
        XCTAssertEqual(stage.draft.state["finishing"] as? Bool, true)
        XCTAssertEqual(stage.draft.panel.registerDetail, "finishing")
        ear.release()
        stage.pump(until: { !stage.pasteboard.isEmpty })
        XCTAssertEqual(stage.pasteboard.last, "Rebase local/dev on main.", "the ear's words, after the wait")
        XCTAssertFalse(stage.draft.isOpen)
    }

    func testALandingThatNeedsNoWaitNeverSaysIt() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("Plain words.")
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen)
        stage.clock.advance(by: 1)
        XCTAssertEqual(stage.draft.state["open"] as? Bool, false)
    }

    func testASecondReturnLandsAtOnceWithWhatStands() {
        let ear = FakeEar(answer: "Rebase local/dev on main.")
        let stage = stuck(ear)
        stage.lode(".")
        stage.speech.settle(timed("Rebase local dev on main.", 0, 2))
        stage.press("return")
        XCTAssertTrue(stage.pasteboard.isEmpty)
        stage.clock.advance(by: 0.2)
        XCTAssertTrue(stage.press("return"), "swallowed, as every key is, and acted on")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard.last, "Rebase local dev on main.", "the live words, as they stood")
        XCTAssertEqual(stage.posted.map(\.key), ["v"])
        ear.release()
        stage.clock.advance(by: 3)
        XCTAssertEqual(stage.posted.map(\.key), ["v"], "and the waits it cut short land nothing more")
    }

    func testASecondReturnSettlesTheGhostAsSeen() {
        let stage = Stage()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("send this")
        stage.speech.hear("and these")
        stage.press("return")
        XCTAssertTrue(stage.draft.isOpen, "the recognizer is still finishing")
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard.last, "send this and these")
        stage.speech.finish()
        XCTAssertEqual(stage.posted.map(\.key), ["v"], "the late final changes nothing")
    }

    /// A held ⏎ repeats; its repeats are not a second ⏎.
    func testARepeatedReturnIsNotASecondOne() {
        let ear = FakeEar(answer: "Rebase local/dev on main.")
        let stage = stuck(ear)
        stage.lode(".")
        stage.speech.settle(timed("Rebase local dev on main.", 0, 2))
        stage.press("return")
        stage.clock.advance(by: 0.2)
        XCTAssertTrue(stage.pressRepeat("return"))
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertTrue(stage.pasteboard.isEmpty)
        ear.release()
        stage.pump(until: { !stage.pasteboard.isEmpty })
    }

    func testOtherKeysAreStillSwallowed() {
        let ear = FakeEar(answer: "Rebase local/dev on main.")
        let stage = stuck(ear)
        stage.lode(".")
        stage.speech.settle(timed("Rebase local dev on main.", 0, 2))
        stage.press("return")
        stage.clock.advance(by: 0.2)
        XCTAssertTrue(stage.press("a"))
        XCTAssertTrue(stage.press("escape"))
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.draft.buffer.text, "Rebase local dev on main.")
        ear.release()
        stage.pump(until: { !stage.pasteboard.isEmpty })
    }
}
