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
}
