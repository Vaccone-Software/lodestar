import XCTest
@testable import lodestar
@testable import LodestarCore

/// ⏎ in the editor's lens against a field's real text: every fix lands
/// where it was found, replacements of every length among them, and one
/// ⌫ takes the batch back to the letter. Spelling asks no model, so the
/// marks are the spell checker's and the rules', the same on every Mac.
final class EditorFixAllTests: XCTestCase {
    private static let written = "We need to to recieve them. Then we sheduled more."
    private static let fixed = "We need to receive them. Then we scheduled more."

    private func rig(marking text: String = written, count: Int = 3) -> EditorRig {
        let rig = EditorRig()
        rig.controller.apply(enabled: true, engine: .spelling, language: "en_US", vocabulary: [], skipApps: [])
        rig.type(text, caret: 0)
        rig.settle("the marks") { rig.controller.lensMarks.count == count }
        return rig
    }

    private func fixAll(_ rig: EditorRig, _ marks: [EditorController.Mark]? = nil) -> Int? {
        var landed: Int?
        rig.controller.fixAll(marks ?? rig.controller.lensMarks) { landed = $0 }
        rig.settle("the fixes") { landed != nil }
        return landed
    }

    private func undo(_ rig: EditorRig) -> Bool? {
        var done: Bool?
        rig.controller.undoLastFix { done = $0 }
        rig.settle("the undo") { done != nil }
        return done
    }

    /// A doubled word that shrinks the text, a swap of equal length, and
    /// a word that grows: each lands, because the last is fixed first.
    func testEveryFixLandsWhereItWasFound() {
        let rig = rig()
        XCTAssertEqual(fixAll(rig), 3)
        XCTAssertEqual(rig.source.text, Self.fixed)
        XCTAssertTrue(rig.controller.lensMarks.isEmpty, "nothing fixed is still marked")
        XCTAssertTrue(rig.flashes.isEmpty)
    }

    func testOneBackspaceTakesTheWholeBatchBack() {
        let rig = rig()
        _ = fixAll(rig)
        XCTAssertEqual(undo(rig), true)
        XCTAssertEqual(rig.source.text, Self.written, "every word as it was written, to the letter")
        XCTAssertEqual(undo(rig), false, "one batch, one ⌫")
    }

    /// A fix made by its letter before the ⏎ is its own step: ⌫ takes
    /// the batch, and the next ⌫ the letter's fix.
    func testABatchIsUndoneApartFromTheFixBeforeIt() throws {
        let rig = rig()
        let receive = try XCTUnwrap(rig.controller.lensMarks.first { $0.issue.replacement == "receive" })
        var one: Bool?
        rig.controller.fix(receive) { one = $0 }
        rig.settle("the one fix") { one != nil }
        XCTAssertEqual(fixAll(rig), 2)
        XCTAssertEqual(rig.source.text, Self.fixed)
        XCTAssertEqual(undo(rig), true)
        XCTAssertEqual(rig.source.text, "We need to to receive them. Then we sheduled more.",
                       "the batch goes back, the letter's fix stays")
        XCTAssertEqual(undo(rig), true)
        XCTAssertEqual(rig.source.text, Self.written)
    }

    /// Text that moved under the lens is never written over: nothing
    /// lands, it says so, and there is nothing to undo.
    func testTextThatMovedTakesNoFix() {
        let rig = rig()
        let marks = rig.controller.lensMarks
        rig.source.field = EditorRig.field("Something else entirely was typed here.")
        XCTAssertEqual(fixAll(rig, marks), 0)
        XCTAssertEqual(rig.source.text, "Something else entirely was typed here.")
        XCTAssertEqual(rig.flashes, ["✕ The text changed before the fixes landed"])
        XCTAssertEqual(undo(rig), false)
    }

    /// The record counts each fix, says it came from ⏎, and keeps no words.
    func testTheRecordCountsEachFixAndTheirOneUndo() {
        let rig = rig()
        _ = fixAll(rig)
        _ = undo(rig)
        let actions = rig.events.map(\.action)
        XCTAssertEqual(actions.filter { $0 == "applied" }.count, 3)
        XCTAssertEqual(actions.filter { $0 == "undone" }.count, 1)
        XCTAssertEqual(Set(rig.events.filter { $0.action == "applied" }.compactMap(\.row)), ["all"])
    }

    /// Twenty fixes are remembered; a batch larger than that is never cut
    /// in half, or one ⌫ would leave half of it behind. The marks are made
    /// by hand: a checker marks a repeated word once.
    func testALongBatchIsKeptWhole() {
        let words = Array(repeating: "recieve", count: 24).joined(separator: " ")
        let text = "We " + words + "."
        let rig = EditorRig()
        rig.type(text, caret: 0)
        let marks = (0..<24).map { index in
            EditorController.Mark(issue: EditorIssue(range: NSRange(location: 3 + index * 8, length: 7),
                                                     original: "recieve", replacement: "receive", kind: .spelling),
                                  rect: .zero)
        }
        XCTAssertEqual(fixAll(rig, marks), 24)
        XCTAssertEqual(rig.source.text, "We " + Array(repeating: "receive", count: 24).joined(separator: " ") + ".")
        XCTAssertEqual(undo(rig), true)
        XCTAssertEqual(rig.source.text, text, "all twenty four taken back")
    }
}
