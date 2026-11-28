import XCTest
@testable import lodestar
@testable import LodestarCore

/// ⏎ in the editor's lens against a field's real text: every fix lands
/// where it was found, replacements of every length among them. Taking
/// them back is the app's own ⌘Z, not the editor's. Spelling asks no model, so the
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

    /// A doubled word that shrinks the text, a swap of equal length, and
    /// a word that grows: each lands, because the last is fixed first.
    func testEveryFixLandsWhereItWasFound() {
        let rig = rig()
        XCTAssertEqual(fixAll(rig), 3)
        XCTAssertEqual(rig.source.text, Self.fixed)
        XCTAssertTrue(rig.controller.lensMarks.isEmpty, "nothing fixed is still marked")
        XCTAssertTrue(rig.flashes.isEmpty)
    }

    /// A fix made by its letter before the ⏎ leaves the rest to it.
    func testAFixBeforeTheReturnLeavesTheRestToIt() throws {
        let rig = rig()
        let receive = try XCTUnwrap(rig.controller.lensMarks.first { $0.issue.replacement == "receive" })
        var one: Bool?
        rig.controller.fix(receive) { one = $0 }
        rig.settle("the one fix") { one != nil }
        XCTAssertEqual(fixAll(rig), 2)
        XCTAssertEqual(rig.source.text, Self.fixed)
    }

    /// Text that moved under the lens is never written over: nothing
    /// lands, and it says so.
    func testTextThatMovedTakesNoFix() {
        let rig = rig()
        let marks = rig.controller.lensMarks
        rig.source.field = EditorRig.field("Something else entirely was typed here.")
        XCTAssertEqual(fixAll(rig, marks), 0)
        XCTAssertEqual(rig.source.text, "Something else entirely was typed here.")
        XCTAssertEqual(rig.flashes, ["✕ The text changed before the fixes landed"])
    }

    /// The record counts each fix, says it came from ⏎, and keeps no words.
    func testTheRecordCountsEachFix() {
        let rig = rig()
        _ = fixAll(rig)
        let actions = rig.events.map(\.action)
        XCTAssertEqual(actions.filter { $0 == "applied" }.count, 3)
        XCTAssertEqual(actions.filter { $0 == "undone" }.count, 0, "the editor takes nothing back")
        XCTAssertEqual(actions.filter { $0 == "stood" }.count, 3, "every mark answered is shown")
        XCTAssertEqual(Set(rig.events.filter { $0.action == "applied" }.compactMap(\.row)), ["all"])
    }

    /// A long batch lands whole, every fix where it was found. The marks
    /// are made by hand: a checker marks a repeated word once.
    func testALongBatchLandsWhole() {
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
    }
}
