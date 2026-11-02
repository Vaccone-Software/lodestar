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
/// stands selected until it has, and a key struck inside it must neither
/// reach the app and replace the word nor be lost. What the hand types
/// meanwhile is kept and put into the field, in order, after the fix.
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

    /// What reached the app, and whether the fix had landed when it did.
    private final class App {
        var log: [(keys: [SelectController.HeldKey], paced: Bool)] = []
        var landedBefore: [Bool] = []
        var keys: [SelectController.HeldKey] { log.flatMap(\.keys) }
    }

    private func lens(count: Int) -> SlowLens {
        SlowLens((0..<count).map { i in
            EditorController.Mark(
                issue: EditorIssue(range: NSRange(location: 10 * i, length: 4), original: "wrd\(i)",
                                   replacement: "word\(i)", kind: .spelling),
                rect: CGRect(x: 10 + 60 * CGFloat(i), y: 300, width: 50, height: 18))
        })
    }

    private func rig(marks: Int, typing: Bool = true) -> (Stage, SlowLens, App) {
        let lens = lens(count: marks)
        let stage = Stage()
        stand(stage)
        stage.engine.appEditor = lens
        stage.engine.select.holdsFix = { _ in typing }
        let app = App()
        stage.engine.select.replay = { _, keys, paced, done in
            app.log.append((keys, paced))
            done()
        }
        return (stage, lens, app)
    }

    func testTheLastFixHoldsTheKeysUntilItHasLanded() throws {
        let (stage, lens, app) = rig(marks: 1)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            let label = try XCTUnwrap(stage.engine.select.shownChips.first?.label)
            XCTAssertTrue(stage.press(label))
            XCTAssertEqual(lens.landing.count, 1)
            XCTAssertTrue(stage.press("x"), "the word is still selected: the key is not the app's yet")
            XCTAssertTrue(app.keys.isEmpty, "and it is not in the field before the fix")
            XCTAssertTrue(stage.engine.stateDescription.contains("hints"))
            lens.landing.forEach { $0() }
            XCTAssertEqual(app.keys, [.text("x")], "kept, and put in after the fix")
        }
    }

    /// Keys typed while the fix lands arrive in the app in order, after
    /// the fixed word: characters (shift capitalizing), a space, a ⌫ and a
    /// ⏎, none lost.
    func testKeysTypedWhileTheFixLandsArriveInOrder() throws {
        let (stage, lens, app) = rig(marks: 1)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press(try XCTUnwrap(stage.engine.select.shownChips.first?.label))
            stage.press("h")
            stage.press("i", shift: true)
            stage.press("space")
            stage.press("o")
            stage.press("k")
            stage.press("delete")
            stage.press("return")
            stage.press("a")
            XCTAssertTrue(app.keys.isEmpty)
            lens.landing.forEach { $0() }
            XCTAssertEqual(app.keys, [.text("hI ok"), .delete, .enter, .text("a")])
            XCTAssertTrue(app.log.allSatisfy(\.paced), "behind the fix, off the main thread")
        }
    }

    /// The hand typed on, so the lens is over: the next ⌫ is the hand's
    /// and not the lens's undo of the fix.
    func testTheLensEndsOnceWhatWasTypedIsIn() throws {
        let (stage, lens, _) = rig(marks: 1)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press(try XCTUnwrap(stage.engine.select.shownChips.first?.label))
            stage.press("h")
            lens.landing.forEach { $0() }
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"))
            XCTAssertFalse(stage.press("delete"), "the app's own")
        }
    }

    /// Nothing typed: the lens stands one key longer with Undo offered,
    /// as after ⏎.
    func testNothingTypedLeavesTheUndoOffered() throws {
        let (stage, lens, app) = rig(marks: 1)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press(try XCTUnwrap(stage.engine.select.shownChips.first?.label))
            lens.landing.forEach { $0() }
            XCTAssertTrue(app.keys.isEmpty)
            XCTAssertTrue(stage.engine.stateDescription.contains("hints"))
            XCTAssertEqual(stage.engine.select.pill?.state?.offer, SelectController.undoOffer)
            XCTAssertFalse(stage.press("x"), "the next key is the app's")
        }
    }

    /// A ⌘ key is not typing: the hold ends, what was typed goes in first,
    /// and the key passes through after it.
    func testACommandKeyEndsTheHoldAndPassesAfterTheReplay() throws {
        let (stage, lens, app) = rig(marks: 1)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press(try XCTUnwrap(stage.engine.select.shownChips.first?.label))
            stage.press("h")
            stage.press("i")
            XCTAssertFalse(stage.press("a", command: true), "the ⌘ key goes to the app")
            XCTAssertEqual(app.keys, [.text("hi")], "after the replay")
            XCTAssertEqual(app.log.map(\.paced), [false], "now, so it is in before the key")
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"))
            lens.landing.forEach { $0() }
            XCTAssertEqual(app.keys, [.text("hi")], "and nothing is put in twice")
        }
    }

    func testAnArrowEndsTheHoldToo() throws {
        let (stage, lens, app) = rig(marks: 1)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press(try XCTUnwrap(stage.engine.select.shownChips.first?.label))
            stage.press("h")
            XCTAssertFalse(stage.press("left"))
            XCTAssertEqual(app.keys, [.text("h")])
        }
    }

    func testAnAppThatTakesTheDirectWriteEndsTheLensAtOnce() throws {
        let (stage, lens, _) = rig(marks: 1, typing: false)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            let label = try XCTUnwrap(stage.engine.select.shownChips.first?.label)
            stage.press(label)
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"), "nothing is held")
        }
    }

    func testFixAllHoldsAndReplaysTheKeysToo() {
        let (stage, lens, app) = rig(marks: 2)
        withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press("return")
            XCTAssertTrue(stage.press("x"), "the fixes are landing: the key is held")
            XCTAssertTrue(app.keys.isEmpty)
            lens.landing.forEach { $0() }
            XCTAssertEqual(app.keys, [.text("x")])
        }
    }

    /// Too many keys for the hold to keep: the one past the cap ends it,
    /// and everything kept goes in before it.
    func testTheHoldIsCappedAndNothingPastItIsLost() throws {
        let (stage, lens, app) = rig(marks: 1)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press(try XCTUnwrap(stage.engine.select.shownChips.first?.label))
            for _ in 0..<SelectController.heldCapacity { stage.press("x") }
            XCTAssertTrue(app.keys.isEmpty)
            XCTAssertFalse(stage.press("y"), "the thirty-third key ends the hold and goes on")
            XCTAssertEqual(app.keys, [.text(String(repeating: "x", count: SelectController.heldCapacity))])
        }
    }

    /// A fix that never reports: after the limit the hold lifts, and what
    /// was typed is put in all the same.
    func testTheLimitLiftReplaysToo() throws {
        let (stage, lens, app) = rig(marks: 1)
        try withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.press(try XCTUnwrap(stage.engine.select.shownChips.first?.label))
            stage.press("h")
            stage.press("i")
            stage.pump(until: { !app.keys.isEmpty }, within: SelectController.settleLimit + 2)
            XCTAssertEqual(app.keys, [.text("hi")])
            XCTAssertFalse(stage.engine.stateDescription.contains("hints"), "and the lens is over")
        }
    }
}
