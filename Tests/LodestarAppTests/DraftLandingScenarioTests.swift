import XCTest
@testable import lodestar
import LodestarCore

/// What the draft keeps of the last words, and where it lands them: ⏎ on
/// the stop's drained finals, a final's remainder past an edit, esc that
/// waits out of sight, and a landing that says when nothing took the text.
final class DraftLandingScenarioTests: XCTestCase {
    // MARK: - ⏎ lands on the stop

    func testReturnLandsAfterEveryFinalTheStopDrains() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("first part")
        stage.speech.finalsOnStop = [Heard("and a second part"), Heard("then a third")]
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard.count, 1, "one landing, once")
        let landed = stage.pasteboard.last ?? ""
        XCTAssertTrue(landed.contains("second part") && landed.contains("third"),
                      "the first final was not the end: \(landed)")
        XCTAssertEqual(stage.posted.map(\.key), ["v"])
    }

    func testReturnWaitsForTheStopToFinishItsFinals() {
        let stage = Stage()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("first part")
        stage.speech.finalsOnStop = [Heard("and the rest")]
        stage.press("return")
        XCTAssertTrue(stage.draft.isOpen, "the stop has not completed")
        stage.speech.finish()
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard.count, 1)
        XCTAssertTrue((stage.pasteboard.last ?? "").contains("the rest"), "\(stage.pasteboard)")
    }

    func testAStopThatCompletesWithAGhostLeftLandsItAsSeen() {
        let stage = Stage()
        stage.speech.settlesOnStop = false
        stage.lode(".")
        stage.speech.settle("sent so far")
        stage.speech.hear("and these")
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard.last, "sent so far and these")
    }

    // MARK: - A dropped final keeps what comes after the edit

    func testWhatFollowsEditedReservedWordsLandsAfterTheEdit() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.hear("send the report")
        stage.press("delete")
        XCTAssertEqual(stage.draft.buffer.text, "send the")
        stage.speech.settle("Send the report today and call Sam.")
        XCTAssertEqual(stage.draft.buffer.text, "send the today and call Sam.",
                       "the hand's edit stands and the words it never saw land after it")
        XCTAssertTrue(stage.commandPress("z"))
        XCTAssertEqual(stage.draft.buffer.text, "send the", "one undo step takes the landing back")
    }

    func testTheRemainderLandsAfterWhatTheHandTypedInPlaceOfTheReservedWords() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.hear("ship it")
        stage.press("delete")
        stage.press("space"); stage.press("n"); stage.press("o")
        XCTAssertEqual(stage.draft.buffer.text, "ship no")
        stage.speech.settle("Ship it now please")
        XCTAssertEqual(stage.draft.buffer.text, "ship no now please",
                       "after the end of the edit, which took in what the hand typed")
    }

    func testAFinalThatDoesNotBeginWithTheReservedWordsIsStillDropped() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.hear("send the report")
        stage.press("delete")
        stage.speech.settle("Something quite different today")
        XCTAssertEqual(stage.draft.buffer.text, "send the")
    }

    func testAFinalWithNothingPastTheReservedWordsIsStillDropped() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.hear("send the report")
        stage.press("delete")
        stage.speech.settle("Send the report.")
        XCTAssertEqual(stage.draft.buffer.text, "send the")
    }
}
