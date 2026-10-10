import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// `lode ⇥` with the editor on: a letter on every mark, the letter fixes,
/// ⇧ and the letter ignores, ⌥ and the letter learns, ⌫ takes the last fix back, and the lens stands
/// until the last mark is gone.
final class EditorLensScenarioTests: XCTestCase {
    private final class FakeLens: EditorLens {
        var enabled = true
        var lensMarks: [EditorController.Mark] = []
        var fixed: [EditorIssue] = []
        var kept: [EditorIssue] = []
        var learned: [EditorIssue] = []
        var undone = 0
        /// The real editor's marks still describe the text before a fix
        /// until it has read the field again and checked the sentence
        /// (a third of a second on Standard): a stale lens keeps them.
        var stale = false
        func fix(_ mark: EditorController.Mark, completion: @escaping (Bool) -> Void) {
            fixed.append(mark.issue)
            if !stale { lensMarks.removeAll { $0 == mark } }
            completion(true)
        }
        func ignore(_ mark: EditorController.Mark) {
            kept.append(mark.issue)
            lensMarks.removeAll { $0 == mark }
        }
        func learn(_ mark: EditorController.Mark) {
            learned.append(mark.issue)
            lensMarks.removeAll { $0 == mark }
        }
        func fixAll(_ marks: [EditorController.Mark], completion: @escaping (Int) -> Void) {
            fixed.append(contentsOf: marks.map(\.issue))
            if !stale { lensMarks.removeAll { marks.contains($0) } }
            completion(marks.count)
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
        stage.engine.appEditor = lens
        return (stage, lens)
    }

    func testEveryMarkWearsALetterAndItsFix() throws {
        let (stage, lens) = stage(with: [mark("Their", "They're", x: 10), mark("recieve", "receive", x: 120)])
        stage.lode("tab")
        XCTAssertEqual(stage.engine.select.door, .editor)
        XCTAssertTrue(stage.engine.stateDescription.contains("hints"))
        let chips = stage.engine.select.shownChips
        XCTAssertEqual(chips.count, 2)
        XCTAssertTrue(chips.contains { $0.fix == "They're" }, "the letter's tag carries the fix it applies")
        let first = try XCTUnwrap(chips.first?.label.first).description
        XCTAssertTrue(stage.press(first))
        XCTAssertEqual(lens.fixed.count, 1, "a letter fixes")
        XCTAssertTrue(stage.engine.stateDescription.contains("hints"), "a mark remains, so the lens stands")
        let second = try XCTUnwrap(stage.engine.select.shownChips.first?.label.first).description
        XCTAssertTrue(stage.press(second))
        XCTAssertEqual(lens.fixed.count, 2)
        XCTAssertFalse(stage.engine.stateDescription.contains("hints"), "the last mark closes the lens")
    }

    /// ⏎ is yes to what is lit: every fix the lens shows, at once, said
    /// on the pill before it is pressed, and the lens closes behind it.
    func testReturnFixesEveryMarkTheLensShows() {
        let (stage, lens) = stage(with: [mark("its", "it's", x: 10), mark("your", "you're", x: 120),
                                         mark("recieve", "receive", x: 240)])
        stage.lode("tab")
        XCTAssertEqual(stage.engine.select.pill?.state?.offer?.words, "Fix all 3", "the pill says what ⏎ takes")
        XCTAssertTrue(stage.press("return"))
        XCTAssertEqual(Set(lens.fixed.map(\.original)), ["its", "your", "recieve"])
        XCTAssertEqual(stage.engine.select.pill?.state?.offer, SelectController.undoOffer,
                       "the lens stands one key longer, offering ⌫")
        stage.press("delete")
        XCTAssertEqual(lens.undone, 1, "one ⌫ takes the batch back")
    }

    /// After ⏎, any key that is not ⌫ ends the lens and reaches the app:
    /// a second ⏎ sends the message.
    func testAfterFixingAllTheNextKeyGoesToTheApp() {
        let (stage, lens) = stage(with: [mark("its", "it's", x: 10), mark("your", "you're", x: 120)])
        // The engine holds the editor weakly: the lens must outlive the presses.
        withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press("return")
            XCTAssertEqual(lens.fixed.count, 2)
            XCTAssertTrue(stage.engine.stateDescription.contains("hints"), "the lens stands one key longer")
            XCTAssertFalse(stage.press("return"), "the second ⏎ is the app's")
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"))
        }
    }

    /// The lens looks again a beat after every fix, and the editor has not
    /// read the field again by then: its marks still name the words just
    /// fixed. 0.47.0 lettered those again, so after ⏎ the old chips came
    /// back over fixed text and every key that was not one of their letters
    /// vanished until Escape.
    func testAfterFixingAllTheLensNeverLettersTheFixedWordsAgain() {
        let (stage, lens) = stage(with: [mark("everyting", "everything", x: 10), mark("seasn", "season", x: 120),
                                         mark("tiem", "time", x: 240)])
        lens.stale = true
        withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press("return")
            XCTAssertEqual(lens.fixed.count, 3)
            stage.pump(until: { stage.engine.select.rescansSettled }, within: 2)
            XCTAssertTrue(stage.engine.select.shownChips.isEmpty, "no chip over a word already fixed")
            XCTAssertEqual(stage.engine.select.pill?.state?.offer, SelectController.undoOffer,
                           "the lens still offers ⌫ for the batch")
            XCTAssertFalse(stage.press("x"), "the next key is the app's, not swallowed")
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"))
        }
    }

    /// The same beat after a letter: the fixed word stays unlettered and
    /// the others keep theirs.
    func testAfterOneFixTheLensLettersOnlyWhatIsLeft() throws {
        let (stage, lens) = stage(with: [mark("its", "it's", x: 10), mark("recieve", "receive", x: 120)])
        lens.stale = true
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            let first = try XCTUnwrap(stage.engine.select.shownChips.first)
            stage.press(String(first.label.first!))
            stage.pump(until: { stage.engine.select.rescansSettled }, within: 2)
            let chips = stage.engine.select.shownChips
            XCTAssertEqual(chips.count, 1)
            XCTAssertFalse(chips.contains { $0.fix == first.fix }, "the fixed word is not lettered again")
        }
    }

    func testShiftAndALetterIgnores() throws {
        let (stage, lens) = stage(with: [mark("retile", "retiling", x: 10), mark("its", "it's", x: 120)])
        stage.lode("tab")
        let label = try XCTUnwrap(stage.engine.select.shownChips.first { $0.fix == "retiling" }?.label.first)
        XCTAssertTrue(stage.press(label.description, shift: true))
        XCTAssertEqual(lens.kept.map(\.original), ["retile"], "⇧ leaves the words, and fixes nothing")
        XCTAssertTrue(lens.fixed.isEmpty)
        XCTAssertTrue(lens.learned.isEmpty, "⇧ teaches nothing")
    }

    func testOptionAndALetterLearns() throws {
        let (stage, lens) = stage(with: [mark("Kubelet", "Kubelik", x: 10), mark("its", "it's", x: 120)])
        stage.lode("tab")
        let label = try XCTUnwrap(stage.engine.select.shownChips.first { $0.fix == "Kubelik" }?.label.first)
        XCTAssertTrue(stage.press(label.description, option: true))
        XCTAssertEqual(lens.learned.map(\.original), ["Kubelet"], "⌥ learns the word")
        XCTAssertTrue(lens.fixed.isEmpty)
        XCTAssertTrue(lens.kept.isEmpty)
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
        // The engine holds the editor weakly: the lens must outlive the
        // press, or the key finds no editor at all.
        let (stage, lens) = stage(with: [])
        withExtendedLifetime(lens) {
            stage.lode("tab")
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"))
            XCTAssertEqual(stage.hud.owner, .flash)
        }
    }

    func testWithTheEditorOffTheKeyOpensNothing() {
        let (stage, lens) = stage(with: [mark("its", "it's", x: 10)])
        lens.enabled = false
        stage.lode("tab")
        XCTAssertNotEqual(stage.engine.select.door, .editor)
        XCTAssertTrue(stage.engine.select.shownChips.isEmpty, "no door opened")
    }
}
