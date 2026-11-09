import XCTest
@testable import lodestar
import LodestarCore

/// What the draft does between ⏎ or esc and the text reaching its place:
/// the door keys wait with the keyboard, the words the recognizer still
/// owes land in the draft they were said into, ⏎ keeps what esc would,
/// and a quit does not take back what esc promised.
final class DraftEndingScenarioTests: XCTestCase {
    /// The Standard style, where esc ends the draft rather than leaving
    /// insert mode.
    private func standard() -> Stage {
        let stage = Stage()
        stage.draft.editingStyle = .standard
        return stage
    }

    // MARK: - Door keys during the wait

    func testADoorKeyWhileReturnWaitsNeverStartsTheMicrophone() {
        let stage = Stage()
        stage.targetAnswers = false
        stage.lode(".", shift: true)
        stage.press("h"); stage.press("i")
        stage.press("return")
        XCTAssertTrue(stage.draft.isOpen, "the landing waits on the target")
        stage.lode(".")
        XCTAssertEqual(stage.speech.listens, 0, "a draft that is ending asks for no microphone")
        stage.clock.advance(by: DraftController.targetWaitSeconds + 0.1)
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.speech.openSessions, 0, "nothing on screen, nothing listening")
        XCTAssertEqual(stage.pasteboard, ["hi"])
    }

    func testMutingWhileReturnWaitsStillLandsTheFinalsTheStopDrains() {
        let stage = Stage()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("first part")
        stage.speech.finalsOnStop = [Heard("and the rest")]
        stage.press("return")
        stage.lode(".", shift: true)
        stage.speech.finish()
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard.count, 1)
        XCTAssertTrue((stage.pasteboard.last ?? "").contains("the rest"),
                      "words said into a committed draft land in it: \(stage.pasteboard)")
    }

    // MARK: - ⏎ keeps what esc keeps

    /// A ghost stands while the session is not listening: the input was
    /// changed and the new one has not said it listens yet.
    private func ghostBetweenSessions() -> Stage {
        let stage = standard()
        stage.speech.settlesOnStop = false
        stage.lode(".")
        stage.speech.settle("sent so far")
        stage.speech.hear("and these")
        stage.speech.slowToListen = true
        stage.draft.selectInput("Other Microphone")
        XCTAssertEqual(stage.draft.buffer.ghost, "and these")
        return stage
    }

    func testReturnLandsTheGhostEscWouldKeep() {
        let kept = ghostBetweenSessions()
        kept.press("escape")
        let landed = ghostBetweenSessions()
        landed.press("return")
        XCTAssertFalse(landed.draft.isOpen)
        XCTAssertEqual(kept.pasteboard, ["sent so far and these"])
        XCTAssertEqual(landed.pasteboard, kept.pasteboard, "⏎ lands the words esc would keep")
        XCTAssertEqual(landed.speech.openSessions, 0)
    }

    // MARK: - A quit while esc waits

    func testAQuitWhileEscWaitsKeepsTheText() {
        let stage = standard()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("Meet at noon")
        stage.speech.hear("by the door")
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertTrue(stage.pasteboard.isEmpty, "esc waits for the stop")
        stage.draft.cancel(reason: "quit")
        XCTAssertEqual(stage.pasteboard, ["Meet at noon by the door"],
                       "the process is going: what esc promised is written now")
        stage.speech.finish()
        stage.clock.advance(by: DraftController.departBackstopSeconds + 0.1)
        XCTAssertEqual(stage.pasteboard.count, 1, "written once")
    }

    func testAQuitWithADraftOpenAgainKeepsBothNewestLast() {
        let stage = standard()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("Old words")
        stage.press("escape")
        stage.speech.slowToStop = false
        stage.lode(".", shift: true)
        stage.press("n"); stage.press("e"); stage.press("w")
        stage.draft.cancel(reason: "quit")
        XCTAssertEqual(stage.pasteboard, ["Old words", "new"], "the open draft is the newer clip")
    }
}
