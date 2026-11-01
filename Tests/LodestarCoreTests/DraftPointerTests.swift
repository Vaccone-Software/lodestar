import XCTest
@testable import LodestarCore

/// What the pointer means to the text, with no panel: the word and the
/// line a click count selects, the selection a press and a drag make
/// between them, and what the editor's visual mode makes of the same.
final class DraftPointerTests: XCTestCase {
    private func buffer(_ text: String) -> Draft.Buffer { Draft.Buffer(text: text) }

    private func word(_ text: String, at index: Int) -> String {
        let b = buffer(text)
        return b.slice(Draft.Pointer.wordRange(at: index, in: b))
    }

    private func line(_ text: String, at index: Int) -> String {
        let b = buffer(text)
        return b.slice(Draft.Pointer.lineRange(at: index, in: b))
    }

    // MARK: - Words

    func testAWordIsLettersDigitsAndUnderscores() {
        XCTAssertEqual(word("one two_2 three", at: 5), "two_2")
        XCTAssertEqual(word("one two_2 three", at: 4), "two_2", "its first letter")
        XCTAssertEqual(word("one two_2 three", at: 8), "two_2", "its last")
        XCTAssertEqual(word("version 10", at: 8), "10")
    }

    func testAnApostropheBetweenLettersStaysInTheWord() {
        XCTAssertEqual(word("it's Rocco's turn", at: 1), "it's")
        XCTAssertEqual(word("it's Rocco's turn", at: 7), "Rocco's")
        XCTAssertEqual(word("it\u{2019}s fine", at: 0), "it\u{2019}s", "the typographic one too")
    }

    func testAnApostropheWithoutLettersOnBothSidesIsAUnitAlone() {
        XCTAssertEqual(word("the dogs' bowl", at: 8), "'", "after a letter only")
        XCTAssertEqual(word("say 'hi'", at: 4), "'", "before a letter only")
        XCTAssertEqual(word("say 'hi'", at: 5), "hi")
    }

    func testARunOfSpacesAndTabsIsItsOwnUnit() {
        XCTAssertEqual(word("one   two", at: 4), "   ")
        XCTAssertEqual(word("one \t two", at: 4), " \t ")
    }

    func testAnyOtherCharacterIsAUnitAlone() {
        XCTAssertEqual(word("a, b", at: 1), ",")
        XCTAssertEqual(word("a -> b", at: 3), ">")
        XCTAssertEqual(word("f(x)", at: 1), "(")
    }

    func testTheTextsEndAndANewlineTakeTheCharacterBefore() {
        XCTAssertEqual(word("one two", at: 7), "two", "the end")
        XCTAssertEqual(word("one two\nthree", at: 7), "two", "a newline")
        XCTAssertEqual(word("one two ", at: 8), " ", "a trailing space is a unit too")
    }

    func testThereIsNoWordOnAnEmptyLineOrAnEmptyText() {
        XCTAssertEqual(Draft.Pointer.wordRange(at: 4, in: buffer("one\n\ntwo")), 4..<4)
        XCTAssertEqual(Draft.Pointer.wordRange(at: 0, in: buffer("")), 0..<0)
        XCTAssertEqual(Draft.Pointer.wordRange(at: 4, in: buffer("one\n")), 4..<4, "after a final newline")
        XCTAssertEqual(Draft.Pointer.wordRange(at: 0, in: buffer("\nx")), 0..<0, "a newline with nothing before it")
    }

    func testAnIndexOutOfRangeIsClampedNotTrapped() {
        XCTAssertEqual(word("one two", at: 99), "two")
        XCTAssertEqual(Draft.Pointer.wordRange(at: -3, in: buffer("one two")), 0..<3)
    }

    // MARK: - Lines

    func testALineTakesItsNewlineAndTheLastHasNone() {
        XCTAssertEqual(line("one\ntwo\nthree", at: 5), "two\n")
        XCTAssertEqual(line("one\ntwo\nthree", at: 0), "one\n")
        XCTAssertEqual(line("one\ntwo\nthree", at: 10), "three")
        XCTAssertEqual(line("one\ntwo\nthree", at: 99), "three", "past the end is the last line")
    }

    func testAnIndexOnANewlineIsThatLine() {
        XCTAssertEqual(line("one\ntwo\nthree", at: 3), "one\n", "the newline belongs to the line it ends")
    }

    func testAnEmptyLineIsItsNewlineAndTheLineAfterAFinalNewlineIsNothing() {
        XCTAssertEqual(line("a\n\nb", at: 2), "\n")
        XCTAssertEqual(Draft.Pointer.lineRange(at: 2, in: buffer("a\n")), 2..<2)
    }

    func testTheGrainsComeFromTheClickCount() {
        XCTAssertEqual(Draft.Pointer.Grain(clicks: 1), .character)
        XCTAssertEqual(Draft.Pointer.Grain(clicks: 2), .word)
        XCTAssertEqual(Draft.Pointer.Grain(clicks: 3), .line)
        XCTAssertEqual(Draft.Pointer.Grain(clicks: 7), .line, "a fourth click is still a line")
        XCTAssertEqual(Draft.Pointer.Grain(clicks: 0), .character)
    }

    // MARK: - A press, and the pointer's place

    private func hit(_ index: Int, insertion: Int? = nil) -> Draft.Pointer.Hit {
        Draft.Pointer.Hit(insertion: insertion ?? index, character: index)
    }

    func testAPressByCharacterIsThePointItself() {
        let b = buffer("hello world")
        XCTAssertEqual(Draft.Pointer.range(at: hit(3, insertion: 4), grain: .character, in: b), 4..<4,
                       "the insertion point nearest the pointer, not the character under it")
        XCTAssertEqual(Draft.Pointer.range(at: hit(3, insertion: 4), grain: .word, in: b), 0..<5,
                       "while the word is the one under it")
    }

    func testADragByCharacterRunsFromThePressToThePointer() {
        let b = buffer("hello world")
        let press = 4..<4
        var s = Draft.Pointer.selection(press: press, to: hit(8), grain: .character, in: b)
        XCTAssertEqual(s.anchor, 4); XCTAssertEqual(s.head, 8)
        s = Draft.Pointer.selection(press: press, to: hit(1), grain: .character, in: b)
        XCTAssertEqual(s.anchor, 4); XCTAssertEqual(s.head, 1, "back, and the direction is kept")
        s = Draft.Pointer.selection(press: press, to: hit(4), grain: .character, in: b)
        XCTAssertEqual(s.anchor, s.head, "no distance, no selection")
    }

    func testADragByWordKeepsThePressedWordWholeEitherWay() {
        let b = buffer("one two three four")
        let press = 4..<7   // "two"
        var s = Draft.Pointer.selection(press: press, to: hit(14), grain: .word, in: b)
        XCTAssertEqual(b.slice(s.anchor..<s.head), "two three four")
        XCTAssertEqual(s.head, 18, "the head is the end that moves")
        s = Draft.Pointer.selection(press: press, to: hit(0), grain: .word, in: b)
        XCTAssertEqual(s.anchor, 7, "backwards the anchor is the pressed word's far end")
        XCTAssertEqual(s.head, 0)
        s = Draft.Pointer.selection(press: press, to: hit(5), grain: .word, in: b)
        XCTAssertEqual(s.anchor, 4); XCTAssertEqual(s.head, 7, "inside the pressed word: the word")
    }

    func testADragByLineGrowsByWholeLines() {
        let b = buffer("one\ntwo\nthree\nfour")
        let press = Draft.Pointer.lineRange(at: 5, in: b)   // "two\n"
        var s = Draft.Pointer.selection(press: press, to: hit(15), grain: .line, in: b)
        XCTAssertEqual(b.slice(s.anchor..<s.head), "two\nthree\nfour")
        s = Draft.Pointer.selection(press: press, to: hit(1), grain: .line, in: b)
        XCTAssertEqual(b.slice(min(s.anchor, s.head)..<max(s.anchor, s.head)), "one\ntwo\n")
        XCTAssertEqual(s.head, 0)
    }

    // MARK: - The buffer's selection

    func testSelectingByEndsKeepsTheAnchorAndMovesTheCursor() {
        var b = buffer("hello world")
        b.select(anchor: 6, cursor: 2)
        XCTAssertEqual(b.selection, 2..<6)
        XCTAssertEqual(b.cursor, 2)
        XCTAssertEqual(b.anchor, 6)
        b.select(anchor: 3, cursor: 3)
        XCTAssertNil(b.selection)
        XCTAssertNil(b.anchor, "ends that meet are no selection, not a hidden one")
        b.select(anchor: -4, cursor: 99)
        XCTAssertEqual(b.selection, 0..<11, "clamped to the text")
    }

    // MARK: - The editor's visual selection

    func testVisualSpanIsInclusiveOfTheCursorsCharacter() {
        XCTAssertEqual(Draft.Pointer.visualSpan(anchor: 2, head: 6)?.anchor, 2)
        XCTAssertEqual(Draft.Pointer.visualSpan(anchor: 2, head: 6)?.cursor, 5, "forwards: up to the character before the head")
        XCTAssertEqual(Draft.Pointer.visualSpan(anchor: 6, head: 2)?.anchor, 5, "backwards: from the character before the anchor")
        XCTAssertEqual(Draft.Pointer.visualSpan(anchor: 6, head: 2)?.cursor, 2)
        XCTAssertNil(Draft.Pointer.visualSpan(anchor: 3, head: 3))
    }

    private func visual(_ text: String, anchor: Int, head: Int, line: Bool = false) -> (Vim, Draft.Buffer) {
        var vim = Vim()
        var b = buffer(text)
        vim.startInsert(b)
        vim.leaveInsert(&b)
        let span = Draft.Pointer.visualSpan(anchor: anchor, head: head)!
        vim.visual(anchor: span.anchor, cursor: span.cursor, line: line, buffer: &b)
        return (vim, b)
    }

    func testAForwardDragSelectsTheCharactersBetweenItsPoints() {
        let (vim, b) = visual("hello world", anchor: 2, head: 7)
        XCTAssertEqual(vim.mode, .visual(line: false))
        XCTAssertEqual(vim.selection(in: b).map(b.slice), "llo w")
    }

    func testABackwardDragSelectsTheSameCharactersTheOtherWay() {
        let (vim, b) = visual("hello world", anchor: 7, head: 2)
        XCTAssertEqual(vim.selection(in: b).map(b.slice), "llo w")
        XCTAssertEqual(b.cursor, 2, "the cursor is the end that moves")
        XCTAssertEqual(vim.visualAnchor, 6)
    }

    func testTheLineFormSelectsWholeLines() {
        let (vim, b) = visual("one\ntwo\nthree", anchor: 4, head: 8, line: true)
        XCTAssertEqual(vim.mode, .visual(line: true))
        XCTAssertEqual(vim.selection(in: b).map(b.slice), "two\n")
    }

    func testAVisualSelectionMadeByThePointerIsTheEditorsToActOn() {
        var (vim, b) = visual("hello world", anchor: 6, head: 11)
        _ = vim.key(.char("d"), buffer: &b, pasteboard: { nil })
        XCTAssertEqual(b.text, "hello ")
        XCTAssertEqual(vim.mode, .normal)
    }

    func testPointingDropsAHalfTypedCommandAndLeavesVisual() {
        var vim = Vim()
        var b = buffer("one two three")
        vim.startInsert(b)
        vim.leaveInsert(&b)
        _ = vim.key(.char("d"), buffer: &b, pasteboard: { nil })
        _ = vim.key(.char("3"), buffer: &b, pasteboard: { nil })
        XCTAssertTrue(vim.isPending)
        vim.point(at: 5, buffer: &b)
        XCTAssertFalse(vim.isPending)
        XCTAssertEqual(b.cursor, 5)
        _ = vim.key(.char("w"), buffer: &b, pasteboard: { nil })
        XCTAssertEqual(b.text, "one two three", "the half-typed d was dropped: w is only a move")
        XCTAssertEqual(b.cursor, 8)

        _ = vim.key(.char("v"), buffer: &b, pasteboard: { nil })
        XCTAssertEqual(vim.mode, .visual(line: false))
        vim.point(at: 1, buffer: &b)
        XCTAssertEqual(vim.mode, .normal)
        XCTAssertNil(vim.selection(in: b))
        XCTAssertEqual(b.cursor, 1)
    }

    func testPointingInNormalModeRestsOnACharacterNeverPastALinesEnd() {
        var vim = Vim()
        var b = buffer("abc\ndef")
        vim.startInsert(b)
        vim.leaveInsert(&b)
        vim.point(at: 3, buffer: &b)   // the newline
        XCTAssertEqual(b.cursor, 2, "the last character of the line")
        vim.point(at: 7, buffer: &b)   // the end of the text
        XCTAssertEqual(b.cursor, 6)
    }

    func testPointingInInsertMovesTheCaretAndKeepsTheModeAndTheRun() {
        var vim = Vim()
        var b = buffer("abc")
        vim.startInsert(b)
        vim.point(at: 1, buffer: &b)
        XCTAssertEqual(vim.mode, .insert)
        XCTAssertEqual(b.cursor, 1, "a caret between characters, unclamped")
        vim.point(at: 3, buffer: &b)
        XCTAssertEqual(b.cursor, 3)
        XCTAssertEqual(vim.mode, .insert)
    }

    func testVisualFromInsertLeavesInsertFirst() {
        var vim = Vim()
        var b = buffer("hello world")
        vim.startInsert(b)
        vim.visual(anchor: 0, cursor: 4, line: false, buffer: &b)
        XCTAssertEqual(vim.mode, .visual(line: false))
        XCTAssertEqual(vim.selection(in: b).map(b.slice), "hello")
    }

    func testVisualOnAnEmptyTextIsHarmless() {
        var vim = Vim()
        var b = buffer("")
        vim.startInsert(b)
        vim.visual(anchor: 0, cursor: 0, line: true, buffer: &b)
        XCTAssertEqual(b.cursor, 0)
        XCTAssertEqual(vim.mode, .visual(line: true))
        _ = vim.key(.char("d"), buffer: &b, pasteboard: { nil })
        XCTAssertEqual(vim.mode, .normal)
    }
}

/// The draft's record counts how often the hand pointed at the text, beside
/// what it typed and how often it took a letter back.
final class DraftPointerRecordTests: XCTestCase {
    func testARecordWrittenBeforeTheDraftTookTheMouseStillReadsAndCountsNone() throws {
        let old = #"{"t": 0, "kind": "draft", "app": "ghostty", "typed": 40, "words": 12, "backspaces": 3, "switches": 2}"#
        let event = try JSONDecoder().decode(ObservationEvent.self, from: Data(old.utf8))
        XCTAssertEqual(event.kind, .draft)
        XCTAssertEqual(event.backspaces, 3)
        XCTAssertNil(event.pointerActs, "absent in the record, and read as none")
        XCTAssertEqual(event.pointerActs ?? 0, 0)
    }

    func testTheCountSurvivesTheRoundTrip() throws {
        var event = ObservationEvent(t: Date(timeIntervalSince1970: 0), kind: .draft)
        event.pointerActs = 4
        let back = try JSONDecoder().decode(ObservationEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(back.pointerActs, 4)
        XCTAssertEqual(back, event)
    }
}
