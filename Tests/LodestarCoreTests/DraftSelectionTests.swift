import XCTest
@testable import LodestarCore

/// The Mac selection of the Standard editing style, with no app: what makes
/// one, what moves it, and what a deletion or an insertion does to it.
final class DraftSelectionTests: XCTestCase {
    private func buffer(_ text: String, cursor: Int) -> Draft.Buffer {
        Draft.Buffer(text: text, cursor: cursor)
    }

    private func press(_ key: String, in buffer: inout Draft.Buffer, shift: Bool = false,
                       option: Bool = false, command: Bool = false) -> Bool {
        Draft.Standard.move(key, shift: shift, option: option, command: command, in: &buffer)
    }

    private func selected(_ buffer: Draft.Buffer) -> String? {
        buffer.selection.map(buffer.slice)
    }

    // MARK: - Making a selection

    func testShiftArrowsSelectByCharacterAndShrinkBack() {
        var b = buffer("hello world", cursor: 5)
        XCTAssertTrue(press("right", in: &b, shift: true))
        XCTAssertTrue(press("right", in: &b, shift: true))
        XCTAssertEqual(selected(b), " w")
        XCTAssertTrue(press("left", in: &b, shift: true))
        XCTAssertEqual(selected(b), " ")
        XCTAssertTrue(press("left", in: &b, shift: true))
        XCTAssertNil(b.selection, "the two ends meet: nothing is selected")
        XCTAssertTrue(press("left", in: &b, shift: true))
        XCTAssertEqual(selected(b), "o", "and it grows the other way")
    }

    func testOptionShiftArrowsSelectByWord() {
        var b = buffer("one two three", cursor: 4)
        XCTAssertTrue(press("right", in: &b, shift: true, option: true))
        XCTAssertEqual(selected(b), "two")
        XCTAssertTrue(press("left", in: &b, shift: true, option: true))
        XCTAssertNil(b.selection)
        XCTAssertTrue(press("left", in: &b, shift: true, option: true))
        XCTAssertEqual(selected(b), "one ")
    }

    func testCommandShiftArrowsSelectToTheLineAndTheTextEnds() {
        var b = buffer("first\nsecond line\nthird", cursor: 9)
        XCTAssertTrue(press("right", in: &b, shift: true, command: true))
        XCTAssertEqual(selected(b), "ond line")
        XCTAssertTrue(press("left", in: &b, shift: true, command: true))
        XCTAssertEqual(selected(b), "sec", "back across its start to the line's start")
        XCTAssertTrue(press("down", in: &b, shift: true, command: true))
        XCTAssertEqual(selected(b), "ond line\nthird")
        b = buffer("first\nsecond line\nthird", cursor: 9)
        XCTAssertTrue(press("up", in: &b, shift: true, command: true))
        XCTAssertEqual(selected(b), "first\nsec")
    }

    func testShiftUpAndDownSelectByLineKeepingTheColumn() {
        var b = buffer("first\nsecond line\nthird", cursor: 8)
        XCTAssertTrue(press("down", in: &b, shift: true))
        XCTAssertEqual(selected(b), "cond line\nth")
        XCTAssertTrue(press("up", in: &b, shift: true))
        XCTAssertNil(b.selection)
        XCTAssertTrue(press("up", in: &b, shift: true))
        XCTAssertEqual(selected(b), "rst\nse")
    }

    func testSelectAllSelectsEverythingAndLeavesTheCursorAtTheEnd() {
        var b = buffer("one two", cursor: 3)
        b.selectAll()
        XCTAssertEqual(selected(b), "one two")
        XCTAssertEqual(b.cursor, 7)
    }

    // MARK: - Moving without one

    func testCommandUpAndDownMoveToTheTextEnds() {
        var b = buffer("first\nsecond", cursor: 8)
        XCTAssertTrue(press("up", in: &b, command: true))
        XCTAssertEqual(b.cursor, 0)
        XCTAssertNil(b.selection)
        XCTAssertTrue(press("down", in: &b, command: true))
        XCTAssertEqual(b.cursor, 12)
    }

    func testLeftAndRightCollapseASelectionToItsEnds() {
        var b = buffer("hello world", cursor: 3)
        b.select { $0.moveWordRight() }
        XCTAssertEqual(selected(b), "lo")
        b.moveLeft()
        XCTAssertEqual(b.cursor, 3, "← lands where the selection began")
        XCTAssertNil(b.selection)

        b.select { $0.moveWordRight() }
        b.moveRight()
        XCTAssertEqual(b.cursor, 5, "→ lands where it ended")
        XCTAssertNil(b.selection)
    }

    func testEveryOtherPlainMoveDropsTheSelectionAndMovesFromTheCursor() {
        let moves: [(String, (inout Draft.Buffer) -> Void, Int)] = [
            ("word left", { $0.moveWordLeft() }, 0),
            ("word right", { $0.moveWordRight() }, 11),
            ("line start", { $0.moveLineStart() }, 0),
            ("line end", { $0.moveLineEnd() }, 11),
            ("text start", { $0.moveStart() }, 0),
            ("text end", { $0.moveEnd() }, 11),
            ("up", { $0.moveUp() }, 0),
            ("down", { $0.moveDown() }, 11),
            ("set", { $0.setCursor(2) }, 2),
        ]
        for (name, move, cursor) in moves {
            var b = buffer("hello world", cursor: 8)
            b.select { $0.moveLeft(); $0.moveLeft() }
            XCTAssertNotNil(b.selection, name)
            move(&b)
            XCTAssertNil(b.selection, name)
            XCTAssertEqual(b.cursor, cursor, name)
        }
    }

    /// On a Mac every plain move from a selection starts at its edge in the
    /// direction it goes, whichever end the cursor was left at.
    func testEveryPlainMoveStartsFromTheSelectionsEdgeInItsDirection() {
        let moves: [(String, (inout Draft.Buffer) -> Void, Int)] = [
            ("⌥←", { $0.moveWordLeft() }, 0),
            ("⌘←", { $0.moveLineStart() }, 0),
            ("⌥→", { $0.moveWordRight() }, 18),
            ("⌘→", { $0.moveLineEnd() }, 18),
        ]
        for (name, move, cursor) in moves {
            for rightward in [false, true] {
                var b = buffer("one two three four", cursor: rightward ? 4 : 13)
                b.select { if rightward { $0.moveWordRight(); $0.moveWordRight() } else { $0.moveWordLeft(); $0.moveWordLeft() } }
                XCTAssertEqual(b.selection, 4..<13, name)
                move(&b)
                XCTAssertEqual(b.cursor, cursor, "\(name), cursor left \(rightward ? "after" : "before") the selection")
            }
        }
        for rightward in [false, true] {
            var b = buffer("ab\ncdef\ngh", cursor: rightward ? 3 : 5)
            b.select { if rightward { $0.moveRight(); $0.moveRight() } else { $0.moveLeft(); $0.moveLeft() } }
            XCTAssertEqual(b.selection, 3..<5)
            var up = b
            up.moveUp()
            XCTAssertEqual(up.cursor, 0, "↑ from the start")
            b.moveDown()
            XCTAssertEqual(b.cursor, 10, "↓ from the end, keeping its column")
        }
    }

    func testOtherKeysAreLeftToTheCaller() {
        var b = buffer("hello", cursor: 2)
        XCTAssertFalse(press("left", in: &b), "a plain arrow is insert mode's own")
        XCTAssertFalse(press("left", in: &b, option: true))
        XCTAssertFalse(press("left", in: &b, command: true), "⌘← is insert mode's own, and ⌘⇧← selects")
        XCTAssertFalse(press("a", in: &b, shift: true), "a capital letter is typing")
        XCTAssertFalse(press("delete", in: &b, shift: true))
        XCTAssertFalse(press("return", in: &b, shift: true))
        XCTAssertEqual(b, buffer("hello", cursor: 2))
    }

    // MARK: - Replacing and deleting it

    func testTypingASettledResultOrANewlineReplacesTheSelection() {
        var b = buffer("hello world", cursor: 5)
        b.select { $0.moveWordRight() }
        b.type("!")
        XCTAssertEqual(b.text, "hello!")
        XCTAssertEqual(b.cursor, 6)
        XCTAssertNil(b.selection)

        b = buffer("hello world", cursor: 0)
        b.select { $0.moveWordRight() }
        b.settle("Goodbye")
        XCTAssertEqual(b.text, "Goodbye world")

        b = buffer("hello world", cursor: 5)
        b.select { $0.moveWordRight() }
        b.newline()
        XCTAssertEqual(b.text, "hello\n")
    }

    func testEveryDeletionTakesTheSelectionAndOnlyIt() {
        let deletions: [(String, (inout Draft.Buffer) -> Void)] = [
            ("⌫", { $0.backspace() }),
            ("character", { $0.deleteBackward() }),
            ("⌥⌫", { $0.deleteWordBackward() }),
            ("⌘⌫", { $0.deleteToLineStart() }),
            ("⌃k", { $0.deleteToLineEnd() }),
            ("fn ⌫", { $0.deleteForward() }),
        ]
        for (name, delete) in deletions {
            var b = buffer("one two three", cursor: 4)
            b.select { $0.moveWordRight() }
            delete(&b)
            XCTAssertEqual(b.text, "one  three", name)
            XCTAssertEqual(b.cursor, 4, name)
            XCTAssertNil(b.selection, name)
        }
    }

    func testBackspaceAfterSpeechTakesTheSelectionNotAWord() {
        var b = Draft.Buffer()
        b.settle("one two three")
        b.select { $0.moveLeft(); $0.moveLeft() }
        b.backspace()
        XCTAssertEqual(b.text, "one two thr")
    }

    func testAnEmptySelectionIsNothingToTake() {
        var b = buffer("hello", cursor: 3)
        b.select { $0.moveRight() }
        b.select { $0.moveLeft() }
        XCTAssertNil(b.selection)
        b.backspace()
        XCTAssertEqual(b.text, "helo", "a backspace is a backspace")
    }

    func testAnEditToTheTextEndsASelectionTheOperationDidNotConsume() {
        var b = buffer("hello world", cursor: 5)
        b.select { $0.moveWordRight() }
        b.replace(0..<5, with: "hi")
        XCTAssertNil(b.selection)

        b = buffer("hello", cursor: 0)
        b.selectAll()
        b.restore(characters: Array("hello"), cursor: 2)
        XCTAssertNil(b.selection, "an undo leaves nothing selected")
    }

    // MARK: - Vim

    func testVimsKeysNeverMakeAMacSelection() {
        var vim = Vim()
        var b = buffer("hello world", cursor: 0)
        vim.startInsert(b)
        vim.leaveInsert(&b)
        for key in ["v", "w"] { _ = vim.key(.char(Character(key)), buffer: &b, pasteboard: { nil }) }
        XCTAssertNil(b.anchor)
        XCTAssertNil(b.selection)
        XCTAssertNotNil(vim.selection(in: b), "its own visual selection is the editor's")
    }

    func testTheEditorReportsAMacSelectionToo() {
        var vim = Vim()
        var b = buffer("hello world", cursor: 6)
        vim.startInsert(b)
        XCTAssertNil(vim.selection(in: b))
        b.select { $0.moveWordRight() }
        XCTAssertEqual(vim.selection(in: b), 6..<11)
    }
}
