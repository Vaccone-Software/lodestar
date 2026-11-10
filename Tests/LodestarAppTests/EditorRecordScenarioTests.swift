import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the record says of a mark's life, through the real controller on
/// its fakes: a mark is counted once however the text around it moves or
/// the field flickers, only if it stood, and ends in one outcome.
final class EditorRecordScenarioTests: XCTestCase {
    private let typo = "We need to recieve them."

    /// A field with one standing mark, a second and a half old.
    private func standing(_ text: String? = nil) -> EditorRig {
        let rig = EditorRig()
        rig.type(text ?? typo)
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        rig.clock.advance(by: 1.5)
        rig.beat()
        rig.drain()
        return rig
    }

    /// The hand moves on to another app.
    private func leave(_ rig: EditorRig) {
        rig.type("All is well here.", pid: 5151, app: "Notes", bundle: "com.apple.Notes")
        rig.drain()
    }

    /// The shelf lets go of the fields it holds once its keeping has run out,
    /// and a beat finds it.
    private func expire(_ rig: EditorRig) {
        rig.clock.advance(by: EditorMarkShelf.keep + 1)
        rig.beat()
        rig.drain()
    }

    private func actions(_ rig: EditorRig) -> [String] { rig.events.compactMap(\.action) }

    // MARK: - A field that flickers

    func testAFieldThatAnswersNothingForAMomentIsTheSameField() {
        let rig = standing()
        rig.controller.receive(nil)
        XCTAssertTrue(rig.controller.lensMarks.isEmpty, "hidden while it cannot be read")
        XCTAssertTrue(rig.drawing.shown.isEmpty)
        XCTAssertNotNil(rig.controller.field, "but not forgotten")

        rig.clock.advance(by: 0.5)
        rig.beat()
        rig.settle("the mark is back") { rig.controller.lensMarks.count == 1 }
        XCTAssertEqual(rig.drawing.shown.count, 1)
        XCTAssertTrue(rig.events.isEmpty, "a flicker writes nothing")

        leave(rig)
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away"], "one mark, counted once")
    }

    func testANewElementWithTheSameTextIsTheSameField() {
        let rig = standing()
        let old = EditorRig.field(typo)
        let rebuilt = EditorField(element: AXUIElementCreateSystemWide(), pid: old.pid, appName: old.appName,
                                  bundleID: old.bundleID, text: old.text, caret: old.caret,
                                  frame: old.frame, windowFrame: old.windowFrame)
        XCTAssertFalse(old.isSame(as: rebuilt))
        rig.clock.advance(by: 0.3)
        rig.source.field = rebuilt
        rig.controller.receive(rebuilt)
        rig.settle("the mark follows the new element") { rig.controller.lensMarks.count == 1 }
        XCTAssertTrue(rig.events.isEmpty)
        leave(rig)
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away"])
    }

    func testAnotherFieldIsAnotherFieldAndEndsTheOldMarks() {
        let rig = standing()
        rig.clock.advance(by: 0.3)
        rig.type("Something else entirely, typed in the same app.")
        rig.drain()
        XCTAssertEqual(actions(rig), ["stood", "replaced"], "the text is not the text it was")
    }

    /// A message sent empties the same element: the marks were left
    /// standing, not edited into nothing.
    func testAFieldSentAndEmptiedLeavesItsMarksStanding() {
        let rig = standing()
        rig.type("")
        rig.drain()
        XCTAssertEqual(actions(rig), ["stood", "replaced"])
    }

    func testAFieldThatStaysGoneIsClearedAfterTheGrace() {
        let rig = standing()
        rig.controller.receive(nil)
        rig.clock.advance(by: 1.0)
        rig.controller.receive(nil)
        XCTAssertNotNil(rig.controller.field, "still inside the grace")
        rig.clock.advance(by: 1.0)
        rig.controller.receive(nil)
        XCTAssertNil(rig.controller.field)
        XCTAssertTrue(rig.events.isEmpty, "waiting on the shelf for the hand's return")
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away"])
    }

    // MARK: - A mark stands only while it is drawn

    /// The field went quiet 0.3 s after the mark was drawn and the grace ran
    /// out two seconds on: the mark was on the screen for 0.3 s, and the rest
    /// was a wait with nothing drawn.
    func testAMarkHiddenSoonAfterItWasDrawnIsNeverShownWhenTheGraceEnds() {
        let rig = EditorRig()
        rig.type(typo)
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        rig.clock.advance(by: 0.3)
        rig.controller.receive(nil)
        rig.clock.advance(by: 1.0)
        rig.controller.receive(nil)
        rig.clock.advance(by: 1.0)
        rig.controller.receive(nil)
        XCTAssertNil(rig.controller.field, "the grace has run out")
        rig.drain()
        XCTAssertTrue(rig.events.isEmpty, "it was drawn for 0.3 s: \(rig.events.map(\.action))")
    }

    func testAMarkThatStoodASecondAndAHalfIsRecordedAtThatWhenTheGraceEnds() throws {
        let rig = standing()
        rig.controller.receive(nil)
        rig.clock.advance(by: 1.0)
        rig.controller.receive(nil)
        rig.clock.advance(by: 1.0)
        rig.controller.receive(nil)
        XCTAssertNil(rig.controller.field)
        rig.drain()
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away"])
        XCTAssertEqual(try XCTUnwrap(rig.events.last?.seconds), 1.5, accuracy: 0.11, "not 3.5, the wait was not drawn")
    }

    /// A field with nowhere to draw (no frame of its own, none for its window)
    /// keeps its marks in the controller and draws nothing.
    func testTimeWithTheLinesDownBecauseThereIsNowhereToDrawThemIsNotStanding() throws {
        let rig = standing()
        rig.clock.advance(by: 0.6)
        let old = EditorRig.field(typo)
        let bare = EditorField(element: old.element, pid: old.pid, appName: old.appName, bundleID: old.bundleID,
                               text: old.text, caret: old.caret, frame: nil, windowFrame: nil)
        rig.source.field = bare
        rig.controller.receive(bare)
        rig.settle("the lines come down") { rig.drawing.shown.isEmpty }
        XCTAssertEqual(rig.controller.lensMarks.count, 1, "the mark is still known")
        rig.clock.advance(by: 5)
        rig.beat()
        rig.drain()
        leave(rig)
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away"])
        XCTAssertEqual(try XCTUnwrap(rig.events.last?.seconds), 2.1, accuracy: 0.11, "1.5 s, then 0.6 s more before they came down")
    }

    // MARK: - A draft that is left and returned to

    /// Back in the field the hand left, with the text as it was.
    private func comeBack(_ rig: EditorRig, to text: String? = nil) {
        rig.type(text ?? typo)
        rig.settle("the mark is drawn again") { rig.controller.lensMarks.count == 1 }
    }

    /// The same unsent draft, looked in on twice, is one mark: the second
    /// stand carries on from the first, and the time away is not standing.
    func testReturningToTheSameUnsentTextIsTheSameMark() throws {
        let rig = standing()
        leave(rig)
        XCTAssertTrue(rig.events.isEmpty, "left on the shelf, not ended")
        XCTAssertEqual(rig.controller.parkedFields, 1)
        rig.clock.advance(by: 120)
        comeBack(rig)
        XCTAssertEqual(rig.controller.parkedFields, 0, "taken off the shelf")
        rig.clock.advance(by: 1.5)
        rig.beat()
        rig.drain()
        leave(rig)
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away"], "one mark, not two")
        XCTAssertEqual(try XCTUnwrap(rig.events.last?.seconds), 3.0, accuracy: 0.11,
                       "1.5 s, then 1.5 s: not the two minutes away, not the ten more on the shelf")
    }

    /// A draft left for the afternoon was sent or forgotten: its marks end as
    /// they stood when it was left, the moment the shelf lets them go.
    func testAMarkOnTheShelfEndsWithItsTrueTimeWhenTheKeepingRunsOut() throws {
        let rig = standing()
        leave(rig)
        rig.clock.advance(by: EditorMarkShelf.keep - 1)
        rig.beat()
        rig.drain()
        XCTAssertTrue(rig.events.isEmpty, "still kept")
        rig.clock.advance(by: 2)
        rig.beat()
        rig.drain()
        XCTAssertEqual(actions(rig), ["stood", "away"])
        XCTAssertEqual(try XCTUnwrap(rig.events.last?.seconds), 1.5, accuracy: 0.11, "not ten minutes")
        XCTAssertEqual(rig.controller.parkedFields, 0)
    }

    /// The same words in another app are another draft.
    func testTheSameTextInAnotherAppDoesNotTakeTheLedger() {
        let rig = standing()
        rig.type(typo, pid: 5151, app: "Notes", bundle: "com.apple.Notes")
        rig.settle("the mark in Notes") { rig.controller.lensMarks.count == 1 }
        rig.clock.advance(by: 1.5)
        rig.beat()
        rig.drain()
        XCTAssertEqual(rig.controller.parkedFields, 1, "TextEdit's draft is still waiting")
        rig.type("All is well here.", pid: 6000, app: "Mail", bundle: "com.apple.mail")
        rig.drain()
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away", "stood", "away"], "two drafts, two marks: \(rig.events.compactMap(\.app))")
        XCTAssertEqual(Set(rig.events.compactMap(\.app)), ["textedit", "notes"])
    }

    /// Another field in the same app, with other words in it, is another field
    /// and leaves the first one's marks where they are.
    func testAnotherFieldInTheSameAppLeavesTheShelfedDraftWaiting() {
        let rig = standing()
        let other = EditorRig.field("Lunch is at noon today.")
        let rebuilt = EditorField(element: AXUIElementCreateSystemWide(), pid: other.pid, appName: other.appName,
                                  bundleID: other.bundleID, text: other.text, caret: other.caret,
                                  frame: other.frame, windowFrame: other.windowFrame)
        rig.source.field = rebuilt
        rig.controller.receive(rebuilt)
        rig.drain()
        XCTAssertEqual(rig.controller.parkedFields, 1)
        XCTAssertTrue(rig.events.isEmpty)
        // The first field comes back as it was: the same mark.
        let first = EditorRig.field(typo)
        let again = EditorField(element: AXUIElementCreateApplication(1), pid: first.pid, appName: first.appName,
                                bundleID: first.bundleID, text: first.text, caret: first.caret,
                                frame: first.frame, windowFrame: first.windowFrame)
        rig.clock.advance(by: 60)
        rig.source.field = again
        rig.controller.receive(again)
        rig.settle("the mark is back") { rig.controller.lensMarks.count == 1 }
        XCTAssertEqual(rig.controller.parkedFields, 0)
        rig.type("All is well here.", pid: 5151, app: "Notes", bundle: "com.apple.Notes")
        rig.drain()
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away"], "one mark")
    }

    /// The hand went off with a draft, and it was sent from there: back in the
    /// same field with the text written over, the marks were not walked away
    /// from but replaced.
    func testADraftThatComesBackWrittenOverEndsAsReplaced() {
        let rig = standing()
        leave(rig)
        rig.clock.advance(by: 60)
        rig.type("")
        rig.drain()
        XCTAssertEqual(actions(rig), ["stood", "replaced"])
        XCTAssertEqual(rig.controller.parkedFields, 0)
    }

    /// A mark left standing is recorded with how it was left: the text written
    /// over in place is not the hand going away.
    func testWrittenOverInPlaceAndGoneAwayAreRecordedApart() {
        let sent = standing()
        sent.type("")
        sent.drain()
        XCTAssertEqual(actions(sent), ["stood", "replaced"])

        let away = standing()
        leave(away)
        expire(away)
        XCTAssertEqual(actions(away), ["stood", "away"])
    }

    /// The text came back changed past recognition: not the draft that was left.
    func testTextThatCameBackChangedPastRecognitionIsNotTheDraftThatWasLeft() {
        let rig = standing()
        leave(rig)
        rig.clock.advance(by: 30)
        let words = "Meeting notes: please recieve the parcel before noon."
        let fresh = EditorField(element: AXUIElementCreateSystemWide(), pid: 4242, appName: "TextEdit",
                                bundleID: "com.apple.TextEdit", text: words, caret: words.utf16.count,
                                frame: CGRect(x: 80, y: 180, width: 800, height: 400),
                                windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        rig.source.field = fresh
        rig.controller.receive(fresh)
        rig.settle("its own mark") { rig.controller.lensMarks.count == 1 }
        rig.clock.advance(by: 1.5)
        rig.beat()
        rig.drain()
        XCTAssertEqual(rig.controller.parkedFields, 1, "the old draft is still waiting, and this one is not it")
        leave(rig)
        XCTAssertEqual(rig.controller.parkedFields, 2)
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away", "stood", "away"], "two drafts, two marks")
    }

    /// The hand is in a terminal, which the editor never reads: no read comes,
    /// and the beat alone lets the shelf go.
    func testTheShelfLetsGoOnTheBeatWhileTheHandIsInAnAppThatIsNeverRead() {
        let rig = standing()
        rig.controller.frontmostApp = { (777, "com.mitchellh.ghostty", "Ghostty") }
        rig.controller.poll()
        XCTAssertNil(rig.controller.field)
        XCTAssertEqual(rig.controller.parkedFields, 1)
        rig.clock.advance(by: EditorMarkShelf.keep + 1)
        rig.controller.poll()
        XCTAssertEqual(actions(rig), ["stood", "away"])
        XCTAssertEqual(rig.controller.parkedFields, 0)
    }

    /// Switched off, the editor reads nothing again: what it held ends.
    func testSwitchingTheEditorOffEndsTheMarksOnTheShelf() {
        let rig = standing()
        leave(rig)
        XCTAssertEqual(rig.controller.parkedFields, 1)
        rig.controller.apply(enabled: false, engine: .standard, language: "en_US", vocabulary: [], skipApps: [])
        rig.drain()
        XCTAssertEqual(actions(rig), ["stood", "away"])
        XCTAssertEqual(rig.controller.parkedFields, 0)
    }

    // MARK: - A mark's identity

    func testTypingBeforeAMarkDoesNotCountItAgain() {
        let rig = standing()
        rig.type("So we need to recieve them.")
        rig.settle("the mark, a few characters on") { rig.controller.lensMarks.first?.issue.range.location == 14 }
        rig.clock.advance(by: 1.5)
        rig.beat()
        rig.drain()
        leave(rig)
        expire(rig)
        XCTAssertEqual(actions(rig), ["stood", "away"])
    }

    // MARK: - How a mark ends

    func testAMarkTheHandFixedBeforeItWasReadIsNeverShown() {
        let rig = EditorRig()
        rig.type(typo)
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        rig.type("We need to receive them.")
        rig.clock.advance(by: 2)
        rig.settleBeating("the mark is gone") { rig.controller.lensMarks.isEmpty }
        leave(rig)
        XCTAssertTrue(rig.events.isEmpty, "it stood no time at all")
    }

    func testAMarkTheHandFixedAfterItStoodIsFixedByHand() throws {
        let rig = standing()
        rig.type("We need to receive them.")
        rig.clock.advance(by: 2)
        rig.settleBeating("judged") { rig.events.contains { $0.action == "byhand" } }
        XCTAssertEqual(actions(rig), ["stood", "byhand"])
        XCTAssertEqual(rig.events.last?.rec, "spelling")
        XCTAssertEqual(try XCTUnwrap(rig.events.last?.seconds), 1.5, accuracy: 0.11, "how long it stood before the hand")
    }

    func testAMarkTheHandEditedIntoSomethingStillWrongIsEdited() {
        let rig = standing()
        rig.type("We need to recieved them.")
        rig.clock.advance(by: 2)
        rig.settleBeating("judged") { rig.events.contains { $0.action == "changed" } }
        XCTAssertEqual(actions(rig).prefix(2), ["stood", "changed"])
    }

    // MARK: - A read that was on its way when the hand typed

    /// A beat asks where the mark stands, and the hand changes the text while
    /// that read is under way: the mark the read answers for is the hand's
    /// edit's to judge, and the answer is about text no longer in the field.
    private func handTypesDuringARead(_ text: String) -> EditorRig {
        let rig = standing()
        let held = DispatchSemaphore(value: 0)
        rig.queue.async { held.wait() }
        rig.clock.advance(by: 1)
        rig.beat()
        rig.type(text)
        rig.clock.advance(by: 2)
        held.signal()
        return rig
    }

    func testAMarkEditedDuringAReadIsStillEdited() {
        let rig = handTypesDuringARead("We need to recieved them.")
        rig.settleBeating("judged") { rig.events.contains { $0.action == "changed" } }
        XCTAssertEqual(actions(rig).prefix(2), ["stood", "changed"])
    }

    func testAMarkFixedDuringAReadIsStillFixedByHand() throws {
        let rig = handTypesDuringARead("We need to receive them.")
        rig.settleBeating("judged") { rig.events.contains { $0.action == "byhand" } }
        XCTAssertEqual(actions(rig), ["stood", "byhand"])
        XCTAssertEqual(try XCTUnwrap(rig.events.last?.seconds), 2.5, accuracy: 0.11, "how long it stood before the hand")
    }

    /// The read's answer is dropped only for text the hand has moved on from.
    func testAReadOfTheSameTextStillPlacesTheMarks() {
        let rig = standing()
        let held = DispatchSemaphore(value: 0)
        rig.queue.async { held.wait() }
        rig.clock.advance(by: 1)
        rig.drawing.hide()
        rig.beat()
        held.signal()
        rig.settle("drawn again") { rig.drawing.shown.count == 1 }
        XCTAssertEqual(rig.controller.lensMarks.count, 1)
    }

    func testAMarkTheLensFixedIsOneFixAndNotAlsoLeftOrByHand() throws {
        let rig = standing()
        var done: Bool?
        rig.controller.fix(rig.controller.lensMarks[0]) { done = $0 }
        rig.settle("the fix") { done != nil }
        rig.clock.advance(by: 3)
        rig.beat()
        rig.drain()
        leave(rig)
        XCTAssertEqual(actions(rig), ["stood", "applied"])
        XCTAssertEqual(rig.events.last?.row, "keys")
        XCTAssertEqual(try XCTUnwrap(rig.events.last?.seconds), 1.5, accuracy: 0.11)
    }

    func testAMarkTheModelOverrulesIsWithdrawnAndNeverShown() {
        let rig = EditorRig()
        rig.reader.hold()
        rig.reader.answer(typo, typo)
        rig.type(typo)
        rig.settle("the spell checker's mark") { rig.controller.lensMarks.count == 1 }
        rig.clock.advance(by: 1.5)
        rig.beat()
        rig.drain()
        rig.reader.letGo()
        rig.settleBeating("the mark is withdrawn") { rig.controller.lensMarks.isEmpty }
        rig.clock.advance(by: 4)
        rig.beat()
        rig.drain()
        leave(rig)
        XCTAssertEqual(actions(rig), ["withdrawn"], "not a mark that was shown")
    }

    // MARK: - The model going quiet

    private let sentences = ["Their going to push it.", "Please send the file.", "We ship on Friday.",
                             "Call me tomorrow then.", "Lunch is at noon.", "The room is booked.",
                             "Nothing else to add.", "See you there soon."]

    /// The text of the first `count` sentences, with a last unfinished one
    /// so the caret's own sentence waits.
    private func text(_ count: Int) -> String { sentences.prefix(count).joined(separator: " ") + " And" }

    func testTheEditorSaysOnceWhenTheModelStopsAnswering() {
        let rig = EditorRig()
        rig.type(text(2))
        rig.settle("two asked") { rig.reader.asked.count == 2 }
        rig.drain()
        XCTAssertTrue(rig.flashes.isEmpty, "two unanswered is not yet a run")

        rig.type(text(3))
        rig.settle("the notice") { rig.flashes.count == 1 }
        XCTAssertEqual(rig.flashes, [EditorController.silentLine])

        rig.type(text(4))
        rig.settle("a fourth asked") { rig.reader.asked.count == 4 }
        rig.drain()
        XCTAssertEqual(rig.flashes.count, 1, "once for the run")
    }

    func testAnAnswerEndsTheRunAndTheNextRunIsToldAgain() {
        let rig = EditorRig()
        rig.type(text(3))
        rig.settle("the notice") { rig.flashes.count == 1 }
        rig.reader.answer(sentences[3], sentences[3])
        rig.type(text(4))
        rig.settle("the answer") { rig.reader.asked.count == 4 }
        rig.drain()
        for count in 5...7 { rig.type(text(count)) ; rig.settle("asked \(count)") { rig.reader.asked.count == count } }
        rig.settle("the second notice") { rig.flashes.count == 2 }
        XCTAssertEqual(Set(rig.flashes), [EditorController.silentLine])
    }
}
