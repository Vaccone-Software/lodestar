import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The editor inside the draft: dictated words get the editor's marks,
/// lode ⇥ letters them over the draft, and a letter fixes the draft's own
/// text in one undo step.
final class DraftEditorScenarioTests: XCTestCase {
    private func stage() -> (Stage, DraftEditor, FakeProofreader, [String]) {
        let stage = Stage()
        let reader = FakeProofreader()
        let editor = DraftEditor(proofreader: reader, clock: stage.clock.clock)
        editor.draft = stage.draft
        stage.draft.onTextChange = { [weak editor] text, caret, ghost in
            editor?.textChanged(text, caret: caret, ghost: ghost) ?? []
        }
        stage.engine.draftEditor = editor
        editor.apply(enabled: true, engine: .standard, language: "en_US", vocabulary: [], modelReady: true)
        addTeardownBlock { withExtendedLifetime(editor) {} }
        return (stage, editor, reader, [])
    }

    private func marked(_ stage: Stage) -> [String] {
        let text = stage.draft.buffer.text as NSString
        return stage.draft.editorMarks.map { text.substring(with: $0) }
    }

    func testDictatedWordsAreMarkedInTheDraft() {
        let (stage, _, _, _) = stage()
        stage.lode(".")
        stage.speech.settle("We need to recieve them.")
        XCTAssertEqual(marked(stage), ["recieve"])
    }

    func testAGhostStillStandingIsNotMarked() {
        let (stage, _, _, _) = stage()
        stage.lode(".")
        stage.speech.settle("We need to recieve")
        stage.speech.hear("them tomorow")
        XCTAssertTrue(stage.draft.editorMarks.isEmpty, "words the recognizer may still rewrite")
    }

    func testTheLensLettersTheDraftsMarksAndALetterFixesThem() throws {
        let (stage, _, _, _) = stage()
        stage.lode(".")
        stage.speech.settle("We need to recieve the the files.")
        XCTAssertEqual(marked(stage), ["recieve", "the the"])
        stage.lode("tab")
        XCTAssertEqual(stage.engine.select.door, .editor, "lode ⇥ with the draft open is the draft's lens")
        let chips = stage.engine.select.shownChips
        XCTAssertEqual(chips.count, 2)
        let receive = try XCTUnwrap(chips.first { $0.label.hasSuffix("· receive") }?.label.first).description
        XCTAssertTrue(stage.press(receive))
        XCTAssertEqual(stage.draft.buffer.text, "We need to receive the the files.")
        XCTAssertTrue(stage.draft.isOpen, "a fix is the draft's own edit; the draft stays")
    }

    func testBackspaceInTheLensUndoesTheFix() throws {
        let (stage, _, _, _) = stage()
        stage.lode(".")
        stage.speech.settle("We need to recieve the the files.")
        stage.lode("tab")
        let receive = try XCTUnwrap(stage.engine.select.shownChips.first { $0.label.hasSuffix("· receive") }?.label.first)
        XCTAssertTrue(stage.press(receive.description))
        XCTAssertEqual(stage.draft.buffer.text, "We need to receive the the files.")
        stage.press("delete")
        stage.clock.advance(by: 0.5)
        XCTAssertEqual(stage.draft.buffer.text, "We need to recieve the the files.", "⌫ takes the fix back")
    }

    func testShiftAndALetterKeepsAWord() throws {
        let (stage, editor, _, _) = stage()
        var learned: [String] = []
        editor.learnName = { learned.append($0) }
        stage.lode(".")
        stage.speech.settle("We ship lodestr today.")
        stage.lode("tab")
        let letter = try XCTUnwrap(stage.engine.select.shownChips.first?.label.first)
        XCTAssertTrue(stage.press(letter.description, shift: true))
        XCTAssertEqual(learned, ["lodestr"], "a word the dictionary did not know is one of your words now")
        XCTAssertTrue(stage.draft.editorMarks.isEmpty)
        XCTAssertEqual(stage.draft.buffer.text, "We ship lodestr today.", "nothing changed")
    }

    func testAFinishedSentenceIsReadByTheModel() {
        let (stage, _, reader, _) = stage()
        reader.answer("Their going to push it.", "They're going to push it.")
        stage.lode(".")
        stage.speech.settle("Their going to push it.")
        let deadline = Date().addingTimeInterval(3)
        while !marked(stage).contains("Their"), Date() < deadline { Stage.pump() }
        XCTAssertEqual(reader.asked, ["Their going to push it."])
        XCTAssertEqual(marked(stage), ["Their"])
    }

    func testTheEditorOffMarksNothing() {
        let (stage, editor, reader, _) = stage()
        editor.apply(enabled: false, engine: .standard, language: "en_US", vocabulary: [], modelReady: true)
        stage.lode(".")
        stage.speech.settle("Their going to recieve it.")
        XCTAssertTrue(stage.draft.editorMarks.isEmpty)
        for _ in 0..<5 { Stage.pump() }
        XCTAssertTrue(reader.asked.isEmpty)
    }
}

/// Vim's spelling keys inside the draft: ]s to the mark, z= takes its fix,
/// zg keeps the word.
final class DraftSpellingKeysTests: XCTestCase {
    func testBracketSThenZEqualsFixesTheWordInTheDraft() {
        let stage = Stage()
        let editor = DraftEditor(proofreader: FakeProofreader(), clock: stage.clock.clock)
        editor.draft = stage.draft
        stage.draft.onTextChange = { [weak editor] text, caret, ghost in
            editor?.textChanged(text, caret: caret, ghost: ghost) ?? []
        }
        stage.draft.onSpellKey = { [weak editor] range, keep in editor?.spellKey(on: range, keep: keep) }
        editor.apply(enabled: true, engine: .spelling, language: "en_US", vocabulary: [], modelReady: false)
        var learned: [String] = []
        editor.learnName = { learned.append($0) }
        stage.lode(".")
        stage.speech.settle("We recieve it. Then we sheduled lodestr.")
        stage.press("escape")
        _ = stage.press("]")
        _ = stage.press("s")
        _ = stage.press("z")
        _ = stage.press("=", shift: false)
        XCTAssertEqual(stage.draft.buffer.text, "We receive it. Then we sheduled lodestr.", "the first mark, fixed")
        _ = stage.press("]")
        _ = stage.press("s")
        _ = stage.press("]")
        _ = stage.press("s")
        _ = stage.press("z")
        _ = stage.press("g")
        XCTAssertEqual(learned, ["lodestr"], "zg keeps the word under the cursor")
        withExtendedLifetime(editor) {}
    }
}
