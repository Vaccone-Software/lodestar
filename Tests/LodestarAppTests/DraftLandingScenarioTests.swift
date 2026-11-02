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

    // MARK: - esc waits for the last words, out of sight

    /// Esc closes at once in the Standard style, and from normal mode in
    /// Vim, where the microphone has already been paused.
    private func standard() -> Stage {
        let stage = Stage()
        stage.draft.editingStyle = .standard
        return stage
    }

    private func flashes(_ stage: Stage) -> Flashes {
        let seen = Flashes()
        stage.draft.flash = { seen.texts.append($0) }
        return seen
    }

    final class Flashes { var texts: [String] = [] }

    func testEscClosesAtOnceAndTheClipTakesTheLastWordsWhenTheStopCompletes() {
        let stage = standard()
        let seen = flashes(stage)
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("Meet at noon")
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen, "the panel goes at once")
        XCTAssertTrue(stage.pasteboard.isEmpty, "the clip waits for the stop")
        XCTAssertTrue(seen.texts.isEmpty, "and so does its flash")
        stage.speech.finalsOnStop = [Heard("by the east door")]
        stage.speech.finish()
        XCTAssertEqual(stage.pasteboard.count, 1)
        XCTAssertTrue((stage.pasteboard.last ?? "").hasPrefix("Meet at noon"), "\(stage.pasteboard)")
        XCTAssertTrue((stage.pasteboard.last ?? "").hasSuffix("by the east door"), "\(stage.pasteboard)")
        XCTAssertEqual(seen.texts, ["⌂ draft kept in the clipboard"])
    }

    func testEscWritesTheTextAsItStoodWhenTheStopNeverCompletes() {
        let stage = standard()
        let seen = flashes(stage)
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("Meet at noon")
        stage.press("escape")
        stage.clock.advance(by: 0.9)
        XCTAssertTrue(stage.pasteboard.isEmpty)
        stage.clock.advance(by: 0.2)
        XCTAssertEqual(stage.pasteboard, ["Meet at noon"])
        XCTAssertEqual(seen.texts, ["⌂ draft kept in the clipboard"])
        stage.speech.finalsOnStop = [Heard("too late")]
        stage.speech.finish()
        XCTAssertEqual(stage.pasteboard, ["Meet at noon"], "written once")
        XCTAssertEqual(seen.texts.count, 1)
    }

    func testWordsStillBeingHeardAtEscAreKept() {
        let stage = standard()
        stage.lode(".")
        stage.speech.settle("Meet at noon")
        stage.speech.hear("by the door")
        stage.press("escape")
        XCTAssertTrue((stage.pasteboard.last ?? "").contains("by the door"), "\(stage.pasteboard)")
    }

    func testADraftOpenedAgainMeanwhileIsNotTouchedByTheOneThatLeft() {
        let stage = standard()
        let seen = flashes(stage)
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("Old words")
        stage.press("escape")
        stage.speech.slowToStop = false
        stage.lode(".")
        XCTAssertTrue(stage.draft.isOpen)
        stage.speech.settle("New words")
        stage.speech.settleFromPreviousSession("late old words")
        XCTAssertEqual(stage.draft.buffer.text, "New words", "the late final is not the new draft's")
        stage.speech.finish()
        XCTAssertTrue(stage.draft.isOpen, "the new draft is still open")
        XCTAssertEqual(stage.draft.buffer.text, "New words")
        XCTAssertEqual(stage.pasteboard.count, 1)
        XCTAssertTrue((stage.pasteboard.last ?? "").contains("late old words"), "\(stage.pasteboard)")
        XCTAssertTrue((stage.pasteboard.last ?? "").hasPrefix("Old words"))
        XCTAssertEqual(seen.texts, ["⌂ draft kept in the clipboard"])
    }

    func testALaterDraftThatHasLandedIsNotTakenBackByTheOneThatLeft() {
        let stage = standard()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("Old words")
        stage.press("escape")
        stage.speech.slowToStop = false
        stage.lode(".")
        stage.speech.settle("New words")
        stage.press("return")
        XCTAssertEqual(stage.pasteboard, ["New words"])
        stage.speech.finish()
        XCTAssertEqual(stage.pasteboard, ["New words"], "the newer landing stays the pasteboard")
    }

    func testAQuitDoesNotWaitForTheStop() {
        let stage = Stage()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("Meet at noon")
        stage.draft.cancel(reason: "quit")
        XCTAssertEqual(stage.pasteboard, ["Meet at noon"], "the process is going: nothing is left to wait with")
    }

    func testAnotherReasonWaitsAsEscDoesButSaysNothing() {
        let stage = standard()
        let seen = flashes(stage)
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("Meet at noon")
        stage.draft.cancel(reason: "control")
        XCTAssertTrue(stage.pasteboard.isEmpty)
        stage.speech.finish()
        XCTAssertEqual(stage.pasteboard, ["Meet at noon"])
        XCTAssertTrue(seen.texts.isEmpty)
    }

    func testEscOutOfInsertModeKeepsTheClipAtOnce() {
        let stage = standard()
        stage.speech.slowToStop = true
        stage.lode(".", shift: true)
        stage.press("h"); stage.press("i")
        stage.press("escape")
        XCTAssertEqual(stage.pasteboard, ["hi"], "no live microphone, nothing to wait for")
    }
}
