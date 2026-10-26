import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The draft in the Standard editing style, driven through the tap: insert
/// mode and nothing else, esc closing it, and the selection every Mac field
/// has, spoken over, replaced, copied, cut and undone. The stage's draft is
/// Vim's unless a scenario says otherwise; these say so.
final class DraftStandardScenarioTests: XCTestCase {
    private func standardStage(field value: String? = nil, cursor: Int? = nil) -> Stage {
        let stage = Stage()
        stage.draft.editingStyle = .standard
        if let value { stage.field = DraftController.Field(selection: nil, value: value, cursor: cursor) }
        return stage
    }

    private var shift: CGEventFlags { .maskShift }
    private var option: CGEventFlags { .maskAlternate }
    private var command: CGEventFlags { .maskCommand }

    private func type(_ stage: Stage, _ text: String) {
        for character in text { stage.press(character == " " ? "space" : String(character)) }
    }

    private func selected(_ stage: Stage) -> String? {
        stage.draft.buffer.selection.map(stage.draft.buffer.slice)
    }

    // MARK: - Always insert

    func testLettersAreAlwaysLettersAndNoModeIsEverEntered() {
        let stage = standardStage()
        stage.lode(".", shift: true)
        type(stage, "x d u . i")
        XCTAssertEqual(stage.draft.buffer.text, "x d u . i")
        XCTAssertEqual(stage.draft.mode, .insert)
        XCTAssertEqual(stage.draft.vim.mode, .insert)
        XCTAssertEqual(stage.draft.state["style"] as? String, "standard")
    }

    func testReturnPastesShiftReturnIsANewLineAndTabTypesATab() {
        let stage = standardStage()
        stage.lode(".", shift: true)
        type(stage, "a")
        stage.press("return", shift: true)
        stage.press("tab")
        type(stage, "b")
        stage.press("return")
        XCTAssertEqual(stage.pasteboard, ["a\n\tb"])
        XCTAssertEqual(stage.posted.map(\.key), ["v"])
    }

    // MARK: - esc closes

    func testEscapeClosesTheSpeakDoorAndKeepsTheTextInTheClipboard() {
        let stage = standardStage()
        stage.lode(".")
        stage.speech.settle("Hello there.")
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen, "one esc, no normal mode in between")
        XCTAssertEqual(stage.pasteboard, ["Hello there."])
        XCTAssertTrue(stage.posted.isEmpty, "nothing is pasted")
        XCTAssertEqual(stage.lastDraft?.action, "cancelled")
        XCTAssertEqual(stage.lastDraft?.row, "escape")
        XCTAssertEqual(stage.lastDraft?.editing, "standard", "the record says which style the hand used")
    }

    func testEscapeClosesTheEditDoorToo() {
        let stage = standardStage(field: "one two", cursor: 7)
        stage.lode(".", shift: true)
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard, ["one two"])
    }

    func testEscapeWithASelectionStillCloses() {
        let stage = standardStage(field: "one two", cursor: 7)
        stage.lode(".", shift: true)
        stage.chord("left", [shift, option])
        XCTAssertEqual(selected(stage), "two")
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen)
    }

    func testVimStillEntersNormalModeOnEscape() {
        let stage = Stage()
        stage.lode(".", shift: true)
        type(stage, "hi")
        stage.press("escape")
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.draft.mode, .normal)
        XCTAssertEqual(stage.draft.state["style"] as? String, "vim")
        XCTAssertEqual(stage.draft.vim.mode, .normal)
        stage.chord("left", [shift])
        XCTAssertNil(stage.draft.buffer.selection, "⇧← is only a move under Vim")
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen, "a second esc closes")
        XCTAssertEqual(stage.lastDraft?.editing, "vim")
    }

    // MARK: - A session keeps its style

    /// A config reload mid-draft changes the next draft, not this one: the
    /// style in force is the one the door found.
    func testTheStyleIsFixedForTheSessionAndChangesAtTheNextDoor() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "one two", cursor: 0)
        stage.lode(".", shift: true)
        stage.press("escape")
        XCTAssertEqual(stage.draft.mode, .normal)

        stage.draft.editingStyle = .standard
        XCTAssertEqual(stage.draft.sessionStyle, .vim)
        stage.press("x")
        XCTAssertEqual(stage.draft.buffer.text, "ne two", "x is still a vim verb")
        stage.chord("right", [shift])
        XCTAssertNil(stage.draft.buffer.selection, "and ⇧→ is still only a move")
        XCTAssertTrue(stage.engine.sheetSections().flatMap { $0.rows }.map(\.label).contains("Left, down, up, right"))
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen, "a bare esc in normal mode closes, as Vim's does")
        XCTAssertEqual(stage.lastDraft?.editing, "vim")

        stage.lode(".", shift: true)
        XCTAssertEqual(stage.draft.sessionStyle, .standard)
        type(stage, "x")
        XCTAssertEqual(stage.draft.buffer.text, "one twox", "the next draft is Standard: letters are letters")
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen, "and its esc closes")
        XCTAssertEqual(stage.lastDraft?.editing, "standard")
    }

    // MARK: - Selecting

    func testShiftArrowsSelectTypingReplacesAndCommandZBringsItBack() {
        let stage = standardStage(field: "hello world", cursor: 11)
        stage.lode(".", shift: true)
        for _ in 0..<5 { stage.chord("left", [shift]) }
        XCTAssertEqual(selected(stage), "world")
        XCTAssertEqual(stage.draft.vim.selection(in: stage.draft.buffer), 6..<11, "the panel draws what the buffer holds")
        type(stage, "x")
        XCTAssertEqual(stage.draft.buffer.text, "hello x")
        type(stage, "y")
        XCTAssertTrue(stage.commandPress("z"))
        XCTAssertEqual(stage.draft.buffer.text, "hello world", "the replacement is one step, and it gives the text back")
        XCTAssertEqual(stage.draft.mode, .insert)
    }

    func testWordLineAndTextSelectionsReachTheBufferThroughTheTap() {
        let stage = standardStage(field: "first\nsecond line", cursor: 17)
        stage.lode(".", shift: true)
        stage.chord("left", [shift, option])
        XCTAssertEqual(selected(stage), "line")
        stage.chord("left", [shift, command])
        XCTAssertEqual(selected(stage), "second line")
        stage.chord("up", [shift, command])
        XCTAssertEqual(selected(stage), "first\nsecond line", "to the start of the text, the far end staying put")
        stage.chord("down", [shift])
        XCTAssertEqual(selected(stage), "second line", "and a line down shrinks it again")
        XCTAssertTrue(stage.chord("up", [command]), "taken, not passed to the app underneath")
        XCTAssertEqual(stage.draft.buffer.cursor, 0)
        XCTAssertNil(stage.draft.buffer.selection)
        stage.chord("down", [shift, command])
        XCTAssertEqual(selected(stage), "first\nsecond line")
        stage.chord("up", [command])
        stage.chord("down", [command])
        XCTAssertEqual(stage.draft.buffer.cursor, 17)
    }

    func testPlainArrowsCollapseToTheEndsAndOtherMovesDropIt() {
        let stage = standardStage(field: "one two three", cursor: 7)
        stage.lode(".", shift: true)
        stage.chord("left", [shift, option])
        stage.press("left")
        XCTAssertEqual(stage.draft.buffer.cursor, 4, "← lands where the selection began")
        XCTAssertNil(stage.draft.buffer.selection)

        stage.chord("right", [shift, option])
        stage.press("right")
        XCTAssertEqual(stage.draft.buffer.cursor, 7, "→ lands where it ended")

        stage.chord("left", [shift, option])
        stage.press("up")
        XCTAssertNil(stage.draft.buffer.selection)
        XCTAssertEqual(stage.draft.buffer.cursor, 0)
    }

    func testEveryDeletionTakesTheSelectionAndOnlyIt() {
        let deletions: [(String, (Stage) -> Void)] = [
            ("⌫", { _ = $0.press("delete") }),
            ("⌥⌫", { _ = $0.optionPress("delete") }),
            ("⌘⌫", { _ = $0.commandPress("delete") }),
            ("⌃h", { _ = $0.controlPress("h") }),
            ("⌃w", { _ = $0.controlPress("w") }),
            ("⌃u", { _ = $0.controlPress("u") }),
            ("⌃k", { _ = $0.controlPress("k") }),
        ]
        for (name, delete) in deletions {
            let stage = standardStage(field: "one two three", cursor: 7)
            stage.lode(".", shift: true)
            stage.chord("left", [shift, option])
            XCTAssertEqual(selected(stage), "two", name)
            delete(stage)
            XCTAssertEqual(stage.draft.buffer.text, "one  three", name)
            XCTAssertEqual(stage.draft.buffer.cursor, 4, name)
            XCTAssertTrue(stage.commandPress("z"), name)
            XCTAssertEqual(stage.draft.buffer.text, "one two three", "\(name) is its own undo step")
        }
    }

    func testShiftReturnAndTabReplaceTheSelectionToo() {
        for (name, press, expected) in [("⇧⏎", { (stage: Stage) in _ = stage.press("return", shift: true) }, "a \n c"),
                                        ("tab", { (stage: Stage) in _ = stage.press("tab") }, "a \t c")] {
            let stage = standardStage(field: "a b c", cursor: 3)
            stage.lode(".", shift: true)
            stage.chord("left", [shift, option])
            XCTAssertEqual(selected(stage), "b", name)
            press(stage)
            XCTAssertEqual(stage.draft.buffer.text, expected, name)
            XCTAssertNil(stage.draft.buffer.selection, name)
        }
    }

    // MARK: - Select all, and speech over it

    func testCommandASelectsAllAsAMacSelectionNotVimsVisual() {
        let stage = standardStage(field: "one two", cursor: 3)
        stage.lode(".", shift: true)
        XCTAssertTrue(stage.commandPress("a"))
        XCTAssertEqual(stage.draft.mode, .insert)
        XCTAssertEqual(stage.draft.vim.mode, .insert)
        XCTAssertEqual(selected(stage), "one two")
        stage.press("delete")
        XCTAssertEqual(stage.draft.buffer.text, "")
    }

    func testSettledSpeechReplacesTheSelectionInOneStepAndTheMicKeepsWriting() {
        let stage = standardStage()
        stage.lode(".")
        stage.speech.settle("Hello there.")
        XCTAssertTrue(stage.commandPress("a"))
        stage.speech.hear("goodbye")
        XCTAssertEqual(stage.draft.buffer.ghost, "", "the selection waits for the words that replace it")
        stage.speech.settle("Goodbye.")
        XCTAssertEqual(stage.draft.buffer.text, "Goodbye.")
        XCTAssertNil(stage.draft.buffer.selection)
        XCTAssertEqual(stage.draft.mode, .insert)
        stage.speech.settle("More.")
        XCTAssertEqual(stage.draft.buffer.text, "Goodbye. More.", "and the mic keeps writing after")

        XCTAssertTrue(stage.commandPress("z"))
        XCTAssertEqual(stage.draft.buffer.text, "Goodbye.", "the last result goes first")
        XCTAssertTrue(stage.commandPress("z"))
        XCTAssertEqual(stage.draft.buffer.text, "Hello there.", "then the replacement, whole, in one step")
    }

    func testSpeechOverAPartialSelectionLeavesTheRestAlone() {
        let stage = standardStage()
        stage.lode(".")
        stage.speech.settle("fix the middle word here")
        stage.chord("left", [shift, option])
        stage.chord("left", [shift, option])
        XCTAssertEqual(selected(stage), "word here")
        stage.speech.settle("text")
        XCTAssertEqual(stage.draft.buffer.text, "fix the middle text")
    }

    // MARK: - The pasteboard

    func testCommandCCopiesTheSelectionOrTheWholeDraftAndCommandXCuts() {
        let stage = standardStage(field: "one two three", cursor: 7)
        var flashes: [String] = []
        stage.draft.flash = { flashes.append($0) }
        stage.lode(".", shift: true)

        XCTAssertTrue(stage.commandPress("c"))
        XCTAssertEqual(stage.pasteboard.last, "one two three", "nothing selected: the draft, as ever")
        XCTAssertEqual(flashes.last, "⌂ draft copied")

        XCTAssertTrue(stage.commandPress("x"))
        XCTAssertEqual(flashes.last, "nothing selected, ⌘A selects all")
        XCTAssertEqual(stage.draft.buffer.text, "one two three")

        stage.chord("left", [shift, option])
        XCTAssertTrue(stage.commandPress("c"))
        XCTAssertEqual(stage.pasteboard.last, "two")
        XCTAssertEqual(flashes.last, "⌂ copied")
        XCTAssertEqual(selected(stage), "two", "a copy leaves the selection standing")

        XCTAssertTrue(stage.commandPress("x"))
        XCTAssertEqual(stage.pasteboard.last, "two")
        XCTAssertEqual(stage.draft.buffer.text, "one  three")
        XCTAssertTrue(stage.commandPress("z"))
        XCTAssertEqual(stage.draft.buffer.text, "one two three", "a cut is its own step")
    }

    func testCommandVReplacesTheSelection() {
        let stage = standardStage(field: "one two three", cursor: 7)
        stage.pasteboard = ["2"]
        stage.lode(".", shift: true)
        stage.chord("left", [shift, option])
        XCTAssertTrue(stage.commandPress("v"))
        XCTAssertEqual(stage.draft.buffer.text, "one 2 three")
        XCTAssertTrue(stage.commandPress("z"))
        XCTAssertEqual(stage.draft.buffer.text, "one two three")
    }

    // MARK: - The four lines

    /// The cursor is never out of sight: the folded view ends on the
    /// cursor's line, wherever a move takes it, so there is no `zo` to ask.
    func testTheFoldedViewFollowsTheCursorUp() {
        let panel = DraftPanel()
        defer { panel.hide() }
        let text = (1...12).map { "line \($0)" }.joined(separator: "\n")
        var buffer = Draft.Buffer(text: text)
        buffer.moveEnd()
        var view = DraftView(buffer: buffer, mode: .insert, editor: .insert, speech: nil,
                             destination: nil, replacing: false)
        view.style = .standard
        panel.show(view)
        let atTheEnd = panel.textScrollOrigin
        for _ in 0..<10 { buffer.moveUp() }
        view = DraftView(buffer: buffer, mode: .insert, editor: .insert, speech: nil,
                         destination: nil, replacing: false)
        view.style = .standard
        panel.show(view)
        XCTAssertLessThan(panel.textScrollOrigin, atTheEnd, "the window rose with the cursor")
    }

    // MARK: - What it draws

    func testAStandardDraftIsSetInSansAndVimsInMonoAndTheSelectionIsDrawn() {
        let panel = DraftPanel()
        defer { panel.hide() }
        var buffer = Draft.Buffer(text: "hello world", cursor: 5)
        buffer.select { $0.moveWordRight() }
        func font(_ style: Draft.EditingStyle) -> NSFont? {
            var view = DraftView(buffer: buffer, mode: .insert, editor: .insert, selection: buffer.selection,
                                 speech: nil, destination: nil, replacing: false)
            view.style = style
            panel.show(view)
            return panel.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        }
        let standard = font(.standard)
        XCTAssertEqual(standard, BarTheme.Role.body.font)
        XCTAssertEqual(standard?.isFixedPitch, false)
        let vim = font(.vim)
        XCTAssertEqual(vim, BarTheme.Role.draft.font)
        XCTAssertEqual(vim?.isFixedPitch, true)

        _ = font(.standard)
        let storage = panel.textView.textStorage
        XCTAssertNil(storage?.attribute(.backgroundColor, at: 2, effectiveRange: nil))
        XCTAssertNotNil(storage?.attribute(.backgroundColor, at: 7, effectiveRange: nil), "the selection is washed")
    }

    // MARK: - What it is called

    func testTheDraftLessonSaysWhatTheChosenStyleDoes() {
        let standard = WalkController.lessonCard(.draft, editing: .standard)
        let vim = WalkController.lessonCard(.draft, editing: .vim)
        XCTAssertFalse((standard.sentence + standard.detail).contains("Vim"))
        XCTAssertTrue(standard.detail.contains("like any Mac text field"))
        XCTAssertTrue(vim.sentence.contains("Vim"))
        XCTAssertTrue(vim.detail.contains("Vim keys"))
    }

    // MARK: - The keys

    func testTheKeysSheetSaysEscClosesUnderStandardAndStopsTypingUnderVim() {
        func labels(_ stage: Stage) -> [String] {
            stage.engine.sheetSections().flatMap { $0.rows }.map(\.label)
        }
        let standard = standardStage()
        standard.lode(".", shift: true)
        XCTAssertTrue(labels(standard).contains("Close, kept in the clipboard"))
        XCTAssertFalse(labels(standard).contains("Stop typing, start editing"))
        XCTAssertTrue(labels(standard).contains("Select, then speak to replace it"))

        let vim = Stage()
        vim.lode(".", shift: true)
        XCTAssertTrue(labels(vim).contains("Stop typing, start editing"))
        XCTAssertFalse(labels(vim).contains("Close, kept in the clipboard"))
        XCTAssertFalse(labels(vim).contains("Select, then speak to replace it"), "Vim's sheet is unchanged")

        let card = HotkeyEngine.draftSections(style: .standard, editor: .insert, card: true)
            .flatMap { $0.rows }.map(\.label)
        XCTAssertTrue(card.contains("Back to the clipboard"))
        XCTAssertFalse(card.contains("Stop typing, start editing"))
    }
}
