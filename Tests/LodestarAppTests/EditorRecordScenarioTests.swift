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
        XCTAssertEqual(actions(rig), ["stood", "left"], "one mark, counted once")
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
        XCTAssertEqual(actions(rig), ["stood", "left"])
    }

    func testAnotherFieldIsAnotherFieldAndEndsTheOldMarks() {
        let rig = standing()
        rig.clock.advance(by: 0.3)
        rig.type("Something else entirely, typed in the same app.")
        rig.drain()
        XCTAssertEqual(actions(rig), ["stood", "left"], "the text is not the text it was")
    }

    /// A message sent empties the same element: the marks were left
    /// standing, not edited into nothing.
    func testAFieldSentAndEmptiedLeavesItsMarksStanding() {
        let rig = standing()
        rig.type("")
        rig.drain()
        XCTAssertEqual(actions(rig), ["stood", "left"])
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
        XCTAssertEqual(actions(rig), ["stood", "left"])
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
        XCTAssertEqual(actions(rig), ["stood", "left"])
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
