import XCTest
@testable import LodestarCore

/// The keys a Mac field answers by the line, on the lines the eye sees: a
/// dictated paragraph is one logical line, and these are the moves and the
/// deletion that must not treat it as one. The layout is a fake that breaks
/// the text where a panel would, so no panel is needed.
final class DraftLinesTests: XCTestCase {
    /// Lines of `width` characters, broken after a space the way a wrap
    /// breaks, and at every newline. Each line is its characters, with the
    /// wrap's space or the newline left off the end.
    private func lines(for text: String, width: Int = 10) -> Draft.Lines {
        let chars = Array(text)
        var starts: [Int] = [0]
        var lineStart = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "\n" {
                starts.append(i + 1); lineStart = i + 1
            } else if i - lineStart >= width - 1, let space = (lineStart...i).last(where: { chars[$0] == " " }) {
                starts.append(space + 1); lineStart = space + 1; i = space
            }
            i += 1
        }
        func bounds(_ index: Int) -> Range<Int> {
            let k = starts.lastIndex(where: { $0 <= index }) ?? 0
            let lower = starts[k]
            var upper = k + 1 < starts.count ? starts[k + 1] : chars.count
            if k + 1 < starts.count { upper -= 1 }
            return lower..<max(lower, upper)
        }
        return Draft.Lines(
            move: { _, index, down in
                let k = starts.lastIndex(where: { $0 <= index }) ?? 0
                let target = k + (down ? 1 : -1)
                guard starts.indices.contains(target) else { return nil }
                return min(starts[target] + (index - starts[k]), bounds(starts[target]).upperBound)
            },
            bounds: { _, index in bounds(index) })
    }

    /// "aaaa bbbb" / "cccc dddd" / "eeee" on screen, one logical line.
    private let paragraph = "aaaa bbbb cccc dddd eeee"

    func testUpAndDownWalkTheWrappedLinesOfOneParagraph() {
        let eye = lines(for: paragraph)
        var b = Draft.Buffer(text: paragraph, cursor: 12)
        b.moveVisualUp(eye)
        XCTAssertEqual(b.cursor, 2, "a line up, same column, not the paragraph's start")
        b.moveVisualDown(eye)
        XCTAssertEqual(b.cursor, 12)
        b.moveVisualDown(eye)
        XCTAssertEqual(b.cursor, 22)
    }

    func testTheEdgesOfTheTextAreTheTextsEnds() {
        let eye = lines(for: paragraph)
        var b = Draft.Buffer(text: paragraph, cursor: 3)
        b.moveVisualUp(eye)
        XCTAssertEqual(b.cursor, 0, "above the first line is the start, as in a Mac field")
        b = Draft.Buffer(text: paragraph, cursor: 20)
        b.moveVisualDown(eye)
        XCTAssertEqual(b.cursor, paragraph.count)
    }

    func testLineStartAndEndAreTheEyesLinesAndTheEndIsBeforeTheWrappedSpace() {
        let eye = lines(for: paragraph)
        var b = Draft.Buffer(text: paragraph, cursor: 12)
        b.moveVisualLineStart(eye)
        XCTAssertEqual(b.cursor, 10)
        b.moveVisualLineEnd(eye)
        XCTAssertEqual(b.cursor, 19, "after 'dddd', before the space the wrap broke on")
        b.moveVisualLineEnd(eye)
        XCTAssertEqual(b.cursor, 19, "and the same key again stays on that line")
        b.moveVisualLineStart(eye)
        XCTAssertEqual(b.cursor, 10)
    }

    func testWithoutAnyLayoutTheFilesLinesAreUsed() {
        var b = Draft.Buffer(text: "one two\nthree", cursor: 11)
        b.moveVisualLineStart(nil)
        XCTAssertEqual(b.cursor, 8)
        b.moveVisualUp(nil)
        XCTAssertEqual(b.cursor, 0)
        b.moveVisualLineEnd(nil)
        XCTAssertEqual(b.cursor, 7)
    }

    func testHardNewlinesStillEndALine() {
        let text = "one two\nthree"
        let eye = lines(for: text, width: 40)
        var b = Draft.Buffer(text: text, cursor: 10)
        b.moveVisualLineStart(eye)
        XCTAssertEqual(b.cursor, 8)
        b.moveVisualUp(eye)
        XCTAssertEqual(b.cursor, 0)
        b.moveVisualLineEnd(eye)
        XCTAssertEqual(b.cursor, 7)
    }

    func testCommandDeleteTakesTheEyesLineAndNotTheParagraph() {
        let eye = lines(for: paragraph)
        var b = Draft.Buffer(text: paragraph, cursor: 12)
        b.deleteToVisualLineStart(eye)
        XCTAssertEqual(b.text, "aaaa bbbb cc dddd eeee", "only the part of the line before the caret")
        XCTAssertEqual(b.cursor, 10)
    }

    func testCommandDeleteFromALinesStartTakesTheLineBefore() {
        let eye = lines(for: paragraph)
        var b = Draft.Buffer(text: paragraph, cursor: 10)
        b.deleteToVisualLineStart(eye)
        XCTAssertEqual(b.text, "cccc dddd eeee", "the wrapped line before, so the key is never dead mid-paragraph")
        XCTAssertEqual(b.cursor, 0)
    }

    func testCommandDeleteAtAHardLineStartTakesNothing() {
        let text = "one\ntwo"
        let eye = lines(for: text, width: 40)
        var b = Draft.Buffer(text: text, cursor: 4)
        b.deleteToVisualLineStart(eye)
        XCTAssertEqual(b.text, text)
    }

    func testCommandDeleteTakesASelectionInstead() {
        let eye = lines(for: paragraph)
        var b = Draft.Buffer(text: paragraph, cursor: 12)
        b.select { $0.moveLeft() }
        b.deleteToVisualLineStart(eye)
        XCTAssertEqual(b.text, "aaaa bbbb ccc dddd eeee")
    }

    func testShiftedMovesSelectByTheEyesLines() {
        let eye = lines(for: paragraph)
        var b = Draft.Buffer(text: paragraph, cursor: 12)
        XCTAssertTrue(Draft.Standard.move("up", shift: true, option: false, command: false, lines: eye, in: &b))
        XCTAssertEqual(b.selection, 2..<12)
        XCTAssertTrue(Draft.Standard.move("left", shift: true, option: false, command: true, lines: eye, in: &b))
        XCTAssertEqual(b.selection, 0..<12, "⇧⌘← runs to the start of the line the caret is on")
    }

    func testCommandUpAndDownStayTheTextsEnds() {
        let eye = lines(for: paragraph)
        var b = Draft.Buffer(text: paragraph, cursor: 12)
        XCTAssertTrue(Draft.Standard.move("up", shift: false, option: false, command: true, lines: eye, in: &b))
        XCTAssertEqual(b.cursor, 0)
        XCTAssertTrue(Draft.Standard.move("down", shift: false, option: false, command: true, lines: eye, in: &b))
        XCTAssertEqual(b.cursor, paragraph.count)
    }
}
