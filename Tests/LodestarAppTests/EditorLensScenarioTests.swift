import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// `lode ⇥` with the editor on: a letter on every mark, the letter fixes,
/// ⇧ and the letter keeps, ⌫ takes the last fix back, and the lens stands
/// until the last mark is gone.
final class EditorLensScenarioTests: XCTestCase {
    private final class FakeLens: EditorLens {
        var enabled = true
        var lensMarks: [EditorController.Mark] = []
        var fixed: [EditorIssue] = []
        var kept: [EditorIssue] = []
        var undone = 0
        func fix(_ mark: EditorController.Mark, completion: @escaping (Bool) -> Void) {
            fixed.append(mark.issue)
            lensMarks.removeAll { $0 == mark }
            completion(true)
        }
        func dismiss(_ mark: EditorController.Mark) {
            kept.append(mark.issue)
            lensMarks.removeAll { $0 == mark }
        }
        func undoLastFix(completion: @escaping (Bool) -> Void) {
            undone += 1
            completion(true)
        }
    }

    private func stand(_ stage: Stage) {
        stage.model.stand(WindowModel.Window(
            id: 9, element: AXUIElementCreateSystemWide(), pid: 1, appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap", title: "editor",
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isMinimized: false, isAlive: true, lastFocused: Date()))
    }

    private func mark(_ original: String, _ replacement: String, x: CGFloat) -> EditorController.Mark {
        EditorController.Mark(issue: EditorIssue(range: NSRange(location: Int(x), length: original.count),
                                                 original: original, replacement: replacement, kind: .grammar),
                              rect: CGRect(x: x, y: 300, width: 60, height: 18))
    }

    private func stage(with marks: [EditorController.Mark]) -> (Stage, FakeLens) {
        let stage = Stage()
        stand(stage)
        let lens = FakeLens()
        lens.lensMarks = marks
        stage.engine.select.editor = lens
        return (stage, lens)
    }

    func testEveryMarkWearsALetterAndItsFix() throws {
        let (stage, lens) = stage(with: [mark("Their", "They're", x: 10), mark("recieve", "receive", x: 120)])
        stage.lode("tab")
        XCTAssertEqual(stage.engine.select.door, .editor)
        XCTAssertTrue(stage.engine.stateDescription.contains("hints"))
        let chips = stage.engine.select.shownChips
        XCTAssertEqual(chips.count, 2)
        XCTAssertTrue(chips.contains { $0.label.hasSuffix("· They're") }, "the letter wears the fix it applies")
        let first = try XCTUnwrap(chips.first?.label.first).description
        XCTAssertTrue(stage.press(first))
        XCTAssertEqual(lens.fixed.count, 1, "a letter fixes")
        XCTAssertTrue(stage.engine.stateDescription.contains("hints"), "a mark remains, so the lens stands")
        let second = try XCTUnwrap(stage.engine.select.shownChips.first?.label.first).description
        XCTAssertTrue(stage.press(second))
        XCTAssertEqual(lens.fixed.count, 2)
        XCTAssertFalse(stage.engine.stateDescription.contains("hints"), "the last mark closes the lens")
    }

    func testShiftAndALetterKeepsTheWords() throws {
        let (stage, lens) = stage(with: [mark("retile", "retiling", x: 10), mark("its", "it's", x: 120)])
        stage.lode("tab")
        let label = try XCTUnwrap(stage.engine.select.shownChips.first { $0.label.hasSuffix("retiling") }?.label.first)
        XCTAssertTrue(stage.press(label.description, shift: true))
        XCTAssertEqual(lens.kept.map(\.original), ["retile"], "⇧ keeps, and fixes nothing")
        XCTAssertTrue(lens.fixed.isEmpty)
    }

    func testDeleteTakesTheLastFixBack() throws {
        let (stage, lens) = stage(with: [mark("its", "it's", x: 10), mark("your", "you're", x: 120)])
        stage.lode("tab")
        let first = try XCTUnwrap(stage.engine.select.shownChips.first?.label.first).description
        stage.press(first)
        stage.press("delete")
        XCTAssertEqual(lens.undone, 1, "⌫ with nothing typed is the last fix, taken back")
    }

    func testNoMarksSaysSoAndStandsDown() {
        let (stage, _) = stage(with: [])
        stage.lode("tab")
        XCTAssertFalse(stage.engine.stateDescription.contains("hints"))
        XCTAssertEqual(stage.hud.owner, .flash)
    }

    func testWithTheEditorOffTheKeyIsStillTheTabs() {
        let (stage, lens) = stage(with: [mark("its", "it's", x: 10)])
        lens.enabled = false
        HintTargets.harvestTabs = { _, done in DispatchQueue.main.async { done([]) } }
        stage.lode("tab")
        XCTAssertNotEqual(stage.engine.select.door, .editor)
    }
}
