import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A second letter struck before the editor has read the field again.
/// The real editor's marks keep their pre-fix ranges until its next beat,
/// so a fix that changed the text's length ("alot" to "a lot", "dont" to
/// "don't", a doubled word removed) left every later mark one or more
/// characters off, and the next pick failed with "The text changed". The
/// fake here holds a real text and refuses a fix whose words are not where
/// the mark says, as `EditorAX.replace` does.
final class EditorLensStaleRangeTests: XCTestCase {
    private final class TextLens: EditorLens {
        var enabled = true
        var text: String
        var lensMarks: [EditorController.Mark]
        var refused: [EditorIssue] = []
        var applied: [EditorIssue] = []
        /// A fix that reports later, as one that waits on the app does.
        var deferred = false
        var waiting: [() -> Void] = []

        init(_ text: String, _ words: [(String, String)]) {
            self.text = text
            let ns = text as NSString
            lensMarks = words.map { original, replacement in
                let range = ns.range(of: original)
                return EditorController.Mark(
                    issue: EditorIssue(range: range, original: original, replacement: replacement, kind: .spelling),
                    rect: CGRect(x: 10 + 40 * CGFloat(range.location), y: 300, width: 50, height: 18))
            }
        }

        func fix(_ mark: EditorController.Mark, completion: @escaping (Bool) -> Void) {
            let issue = mark.issue
            guard EditorAX.stillReads(text, range: issue.range, expected: issue.original) else {
                refused.append(issue)
                completion(false)
                return
            }
            text = (text as NSString).replacingCharacters(in: issue.range, with: issue.replacement)
            applied.append(issue)
            // The marks are not read again until a beat: they stay as they were.
            if deferred { waiting.append { completion(true) } } else { completion(true) }
        }
        func fixAll(_ marks: [EditorController.Mark], completion: @escaping (Int) -> Void) {
            var landed = 0
            for mark in EditorController.fixOrder(marks.map(\.issue)).compactMap({ i in marks.first { $0.issue == i } }) {
                fix(mark) { if $0 { landed += 1 } }
            }
            if deferred { waiting.append { completion(landed) } } else { completion(landed) }
        }
        func ignore(_ mark: EditorController.Mark) {}
        func learn(_ mark: EditorController.Mark) {}
        func undoLastFix(completion: @escaping (Bool) -> Void) { completion(true) }
    }

    private func stand(_ stage: Stage) {
        stage.model.stand(WindowModel.Window(
            id: 9, element: AXUIElementCreateSystemWide(), pid: 1, appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap", title: "editor",
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isMinimized: false, isAlive: true, lastFocused: Date()))
    }

    private func stage(_ lens: TextLens) -> Stage {
        let stage = Stage()
        stand(stage)
        stage.engine.appEditor = lens
        stage.engine.select.holdsFix = { _ in false }
        return stage
    }

    private func letter(for fix: String, in stage: Stage, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let label = stage.engine.select.shownChips.first(where: { $0.fix == fix })?.label else {
            XCTFail("no chip for \(fix)", file: file, line: line)
            return ""
        }
        return label
    }

    func testMarksPastAFixMoveByItsLength() {
        let a = EditorIssue(range: NSRange(location: 0, length: 4), original: "alot", replacement: "a lot", kind: .spelling)
        let early = EditorIssue(range: NSRange(location: 0, length: 2), original: "xx", replacement: "yy", kind: .spelling)
        let overlapping = EditorIssue(range: NSRange(location: 2, length: 4), original: "yyyy", replacement: "z", kind: .spelling)
        let later = EditorIssue(range: NSRange(location: 10, length: 4), original: "dont", replacement: "don't", kind: .spelling)
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let marks = [early, overlapping, later].map { EditorController.Mark(issue: $0, rect: rect) }
        let moved = SelectController.moved(marks, past: a).map(\.issue.range.location)
        XCTAssertEqual(moved, [0, 2, 11], "only the mark wholly after the fix moves, by one")
        let removed = EditorIssue(range: NSRange(location: 4, length: 5), original: "the ", replacement: "", kind: .grammar)
        XCTAssertEqual(SelectController.moved([EditorController.Mark(issue: later, rect: rect)], past: removed)
            .map(\.issue.range.location), [5], "a word that goes pulls the rest back")
        XCTAssertEqual(SelectController.moved(marks, past: early).map(\.issue.range.location), [0, 2, 10],
                       "a fix of the same length moves nothing")
    }

    /// Three length-changing fixes struck one after another with no beat
    /// between: each lands where its words are.
    func testASecondLetterStruckAtOnceLandsAfterALengthChangingFix() throws {
        let lens = TextLens("I alot dont recieve it", [("alot", "a lot"), ("dont", "don't"), ("recieve", "receive")])
        let stage = stage(lens)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            for fix in ["a lot", "don't", "receive"] {
                stage.press(letter(for: fix, in: stage))
            }
            XCTAssertTrue(lens.refused.isEmpty, "\(lens.refused.map(\.original)) met a stale range")
            XCTAssertEqual(lens.text, "I a lot don't receive it")
        }
    }

    func testTheLaterWordFirstNeedsNoShift() {
        let lens = TextLens("I alot dont recieve it", [("alot", "a lot"), ("dont", "don't"), ("recieve", "receive")])
        let stage = stage(lens)
        withExtendedLifetime(lens) {
            stage.lode("tab")
            for fix in ["receive", "don't", "a lot"] {
                stage.press(letter(for: fix, in: stage))
            }
            XCTAssertTrue(lens.refused.isEmpty)
            XCTAssertEqual(lens.text, "I a lot don't receive it")
        }
    }

    /// A doubled word removed pulls the rest back.
    func testADoubledWordRemovedPullsTheNextMarkBack() {
        let text = "this this is recieve"
        let doubled = EditorController.Mark(
            issue: EditorIssue(range: NSRange(location: 0, length: 5), original: "this ", replacement: "", kind: .grammar),
            rect: CGRect(x: 10, y: 300, width: 50, height: 18))
        let lens = TextLens(text, [("recieve", "receive")])
        lens.lensMarks.insert(doubled, at: 0)
        let stage = stage(lens)
        withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press(letter(for: "", in: stage))
            stage.press(letter(for: "receive", in: stage))
            XCTAssertTrue(lens.refused.isEmpty)
            XCTAssertEqual(lens.text, "this is receive")
        }
    }

    /// What was answered is remembered by the words the editor knows it
    /// by, so the look after the fix, which still holds the stale mark,
    /// does not letter it again.
    func testAMovedMarkAnsweredIsNeverLetteredAgain() {
        let lens = TextLens("I alot dont recieve it", [("alot", "a lot"), ("dont", "don't"), ("recieve", "receive")])
        let stage = stage(lens)
        withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press(letter(for: "a lot", in: stage))
            stage.press(letter(for: "don't", in: stage))
            stage.pump(until: { stage.engine.select.rescansSettled }, within: 2)
            let left = stage.engine.select.shownChips.map(\.fix)
            XCTAssertEqual(left, ["receive"], "the look finds the marks as the editor still holds them")
        }
    }
}

/// The last fix of an app that takes typing lands over a beat: the word
/// stands selected until it has, and a key struck inside it must not reach
/// the app and replace the word.
final class EditorFixSettlingTests: XCTestCase {
    private func stand(_ stage: Stage) {
        stage.model.stand(WindowModel.Window(
            id: 9, element: AXUIElementCreateSystemWide(), pid: 1, appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap", title: "editor",
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isMinimized: false, isAlive: true, lastFocused: Date()))
    }

    private final class SlowLens: EditorLens {
        var enabled = true
        var lensMarks: [EditorController.Mark]
        var landing: [() -> Void] = []
        init(_ marks: [EditorController.Mark]) { lensMarks = marks }
        func fix(_ mark: EditorController.Mark, completion: @escaping (Bool) -> Void) {
            landing.append { completion(true) }
        }
        func fixAll(_ marks: [EditorController.Mark], completion: @escaping (Int) -> Void) {
            landing.append { completion(marks.count) }
        }
        func ignore(_ mark: EditorController.Mark) {}
        func learn(_ mark: EditorController.Mark) {}
        func undoLastFix(completion: @escaping (Bool) -> Void) { completion(true) }
    }

    private func lens(count: Int) -> SlowLens {
        SlowLens((0..<count).map { i in
            EditorController.Mark(
                issue: EditorIssue(range: NSRange(location: 10 * i, length: 4), original: "wrd\(i)",
                                   replacement: "word\(i)", kind: .spelling),
                rect: CGRect(x: 10 + 60 * CGFloat(i), y: 300, width: 50, height: 18))
        })
    }

    func testTheLastFixHoldsTheKeysUntilItHasLanded() throws {
        let lens = lens(count: 1)
        let stage = Stage()
        stand(stage)
        stage.engine.appEditor = lens
        stage.engine.select.holdsFix = { _ in true }
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            let label = try XCTUnwrap(stage.engine.select.shownChips.first?.label)
            XCTAssertTrue(stage.press(label))
            XCTAssertEqual(lens.landing.count, 1)
            XCTAssertTrue(stage.press("x"), "the word is still selected: the key is the lens's, not the app's")
            XCTAssertTrue(stage.engine.stateDescription.contains("hints"))
            lens.landing.forEach { $0() }
            XCTAssertFalse(stage.press("x"), "landed: the key is the app's again")
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"))
        }
    }

    func testAnAppThatTakesTheDirectWriteEndsTheLensAtOnce() throws {
        let lens = lens(count: 1)
        let stage = Stage()
        stand(stage)
        stage.engine.appEditor = lens
        stage.engine.select.holdsFix = { _ in false }
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            let label = try XCTUnwrap(stage.engine.select.shownChips.first?.label)
            stage.press(label)
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"), "nothing is held")
        }
    }

    func testFixAllHoldsTheKeysUntilItHasLanded() {
        let lens = lens(count: 2)
        let stage = Stage()
        stand(stage)
        stage.engine.appEditor = lens
        withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press("return")
            XCTAssertTrue(stage.press("x"), "the fixes are landing: the key is held")
            lens.landing.forEach { $0() }
            XCTAssertFalse(stage.press("x"), "landed: the next key goes to the app")
        }
    }

    func testAFixThatNeverReportsDoesNotKeepTheKeys() {
        let lens = lens(count: 2)
        let stage = Stage()
        stand(stage)
        stage.engine.appEditor = lens
        withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press("return")
            XCTAssertTrue(stage.press("x"))
            stage.pump(until: { !stage.press("x") }, within: SelectController.settleLimit + 2)
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"), "after the limit the keys are the app's")
        }
    }
}
