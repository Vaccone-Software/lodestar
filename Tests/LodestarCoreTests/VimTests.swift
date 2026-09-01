import XCTest
@testable import LodestarCore

/// Stock vim over the draft's buffer, one command at a time. Each test
/// types a command the way a hand would and reads the text and cursor
/// back; the pasteboard is a string handed in.
final class VimTests: XCTestCase {
    private var vim = Vim()
    private var buffer = Draft.Buffer()
    private var board: String?
    private var yanks: [String] = []

    override func setUp() {
        vim = Vim()
        buffer = Draft.Buffer()
        board = nil
        yanks = []
    }

    private func load(_ text: String, cursor: Int = 0) {
        buffer = Draft.Buffer(text: text, cursor: cursor)
    }

    @discardableResult
    private func type(_ keys: String) -> [Vim.Effect] {
        var effects: [Vim.Effect] = []
        for c in keys {
            let key: Vim.Key = c == "\u{1B}" ? .escape : .char(c)
            effects = vim.key(key, buffer: &buffer, pasteboard: { self.board })
            for effect in effects {
                if case .yank(let text) = effect { yanks.append(text); board = text }
            }
        }
        return effects
    }

    /// Insert-mode typing, the way the shell reports it, then escape.
    private func insert(_ text: String) {
        XCTAssertEqual(vim.mode, .insert)
        buffer.type(text)
        vim.typed(text)
        vim.leaveInsert(&buffer)
    }

    // MARK: - Motions

    func testWordMotionsAndLineEnds() {
        load("one two three\nfour five")
        type("w"); XCTAssertEqual(buffer.cursor, 4)
        type("w"); XCTAssertEqual(buffer.cursor, 8)
        type("e"); XCTAssertEqual(buffer.cursor, 12)
        type("b"); XCTAssertEqual(buffer.cursor, 8)
        type("$"); XCTAssertEqual(buffer.cursor, 12, "normal mode rests on the last character")
        type("0"); XCTAssertEqual(buffer.cursor, 0)
        type("j"); XCTAssertEqual(buffer.cursor, 14)
        type("G"); XCTAssertEqual(buffer.cursor, 14)
        type("gg"); XCTAssertEqual(buffer.cursor, 0)
        type("3l"); XCTAssertEqual(buffer.cursor, 3)
        type("W"); XCTAssertEqual(buffer.cursor, 4)
    }

    func testFindsCrossLines() {
        load("a.\nb.\nc.")
        type("f.")
        XCTAssertEqual(buffer.cursor, 1)
        type(";")
        XCTAssertEqual(buffer.cursor, 4, "repeat keeps scanning through line breaks")
        type(";")
        XCTAssertEqual(buffer.cursor, 7)
        type("F.")
        XCTAssertEqual(buffer.cursor, 4, "backward find crosses a line break")
        type(",")
        XCTAssertEqual(buffer.cursor, 7, "reverse repeat also crosses a line break")
        type("T.")
        XCTAssertEqual(buffer.cursor, 6, "backward till crosses a line break")
        type("F.")
        type("h")
        XCTAssertEqual(buffer.cursor, 3)
        type("t.")
        XCTAssertEqual(buffer.cursor, 6, "forward till crosses a line break")
        type("f.")
        XCTAssertEqual(buffer.cursor, 7)
        type("f.")
        XCTAssertEqual(buffer.cursor, 7, "find stops at the end of the draft instead of wrapping")
    }


    func testFindMotionsComposeAcrossLinesWithOperators() {
        load("one X\ntwo\nthree", cursor: 10)
        type("dFX")
        XCTAssertEqual(buffer.text, "one three", "F is a document-wide backward operator motion")
        load("one\ntwo X\nthree", cursor: 0)
        type("dtX")
        XCTAssertEqual(buffer.text, "X\nthree", "t is a document-wide forward operator motion")
    }

    func testPercentMatchesBrackets() {
        load("call(a, (b), c) end")
        type("%"); XCTAssertEqual(buffer.cursor, 14)
        type("%"); XCTAssertEqual(buffer.cursor, 4)
    }

    // MARK: - Operators

    func testDeleteWordAndDot() {
        load("one two three four")
        type("dw"); XCTAssertEqual(buffer.text, "two three four")
        type("."); XCTAssertEqual(buffer.text, "three four")
        type("2dw"); XCTAssertEqual(buffer.text, "")
    }

    func testDeleteLineAndPasteFromTheBoard() {
        load("first\nsecond\nthird", cursor: 7)
        type("dd")
        XCTAssertEqual(buffer.text, "first\nthird")
        XCTAssertEqual(buffer.cursor, 6)
        XCTAssertNil(board, "a delete never touches the pasteboard")
        type("yy")
        XCTAssertEqual(yanks, ["third\n"])
        type("P")
        XCTAssertEqual(buffer.text, "first\nthird\nthird")
    }

    func testChangeWordActsLikeChangeToEnd() {
        load("hello world")
        type("cw")
        XCTAssertEqual(buffer.text, " world")
        XCTAssertEqual(vim.mode, .insert)
        insert("bye")
        XCTAssertEqual(buffer.text, "bye world")
        XCTAssertEqual(vim.mode, .normal)
        XCTAssertEqual(buffer.cursor, 2, "escape steps back onto the last typed character")
    }

    func testDollarOperatorsAndCounts() {
        load("keep this part\nnext")
        type("wD")
        XCTAssertEqual(buffer.text, "keep \nnext")
        type("0C")
        insert("only")
        XCTAssertEqual(buffer.text, "only\nnext")
        type("x")
        XCTAssertEqual(buffer.text, "onl\nnext")
        type("2X")
        XCTAssertEqual(buffer.text, "l\nnext", "two characters before the cursor, which rests on the l")
    }

    func testTextObjects() {
        load("say \"hello there\" to (the) world")
        type("fh")
        type("ci\"")
        insert("bye")
        XCTAssertEqual(buffer.text, "say \"bye\" to (the) world")
        type("f(")
        type("da(")
        XCTAssertEqual(buffer.text, "say \"bye\" to  world")
        type("0daw")
        XCTAssertEqual(buffer.text, "\"bye\" to  world")
        type("wciw")
        insert("X")
        XCTAssertEqual(buffer.text, "\"X\" to  world")
    }

    func testYankPutCharwise() {
        load("abc def")
        type("yiw")
        XCTAssertEqual(board, "abc")
        type("$p")
        XCTAssertEqual(buffer.text, "abc defabc")
        type("0P")
        XCTAssertEqual(buffer.text, "abcabc defabc")
    }

    func testReplaceToggleAndJoin() {
        load("abc\n  def")
        type("rz")
        XCTAssertEqual(buffer.text, "zbc\n  def")
        type("~")
        XCTAssertEqual(buffer.text, "Zbc\n  def")
        type("J")
        XCTAssertEqual(buffer.text, "Zbc def")
    }

    func testOpenLinesAndDot() {
        load("one\ntwo")
        type("o")
        insert("new")
        XCTAssertEqual(buffer.text, "one\nnew\ntwo")
        type("O")
        insert("above")
        XCTAssertEqual(buffer.text, "one\nabove\nnew\ntwo")
        type(".")
        XCTAssertEqual(buffer.text, "one\nabove\nabove\nnew\ntwo", "dot repeats the open and the typing")
    }

    func testUndoRedo() {
        load("hello")
        type("x")
        XCTAssertEqual(buffer.text, "ello")
        type("dw")
        XCTAssertEqual(buffer.text, "")
        type("u")
        XCTAssertEqual(buffer.text, "ello")
        type("u")
        XCTAssertEqual(buffer.text, "hello")
        _ = vim.key(.control("r"), buffer: &buffer, pasteboard: { nil })
        XCTAssertEqual(buffer.text, "ello")
        type("u")
        XCTAssertEqual(buffer.text, "hello")
        XCTAssertEqual(type("u"), [.flash("⌂ nothing to undo")])
    }

    func testInsertIsOneUndoStep() {
        load("ab")
        type("A")
        insert("cd")
        XCTAssertEqual(buffer.text, "abcd")
        type("u")
        XCTAssertEqual(buffer.text, "ab")
    }

    // MARK: - Visual

    func testVisualSelectDeleteAndYank() {
        load("one two three")
        type("wve")
        XCTAssertEqual(vim.selection(in: buffer), 4..<7)
        type("d")
        XCTAssertEqual(buffer.text, "one  three")
        XCTAssertEqual(vim.mode, .normal)
        type("Vy")
        XCTAssertEqual(board, "one  three\n")
        type("viwc")
        insert("uno")
        XCTAssertEqual(buffer.text, "uno  three")
    }

    func testVisualLineDeleteTakesWholeLines() {
        load("a\nb\nc", cursor: 2)
        type("Vjd")
        XCTAssertEqual(buffer.text, "a")
    }

    func testVisualPasteReplacesTheSelection() {
        load("old text")
        board = "new"
        type("viwp")
        XCTAssertEqual(buffer.text, "new text")
    }

    // MARK: - Pending and escape

    func testEscapeClearsAPendingCommandBeforeItMeansAnythingElse() {
        load("abc")
        type("d")
        XCTAssertTrue(vim.isPending)
        let effects = type("\u{1B}")
        XCTAssertEqual(effects, [])
        XCTAssertFalse(vim.isPending)
        XCTAssertEqual(type("\u{1B}"), [.unhandled], "a bare escape is the shell's")
        XCTAssertEqual(buffer.text, "abc")
    }

    func testPasteWithEmptyBoardFlashes() {
        load("x")
        XCTAssertEqual(type("p"), [.flash("⌂ nothing to paste")])
    }

    func testDotRepeatsAChangeWithTyping() {
        load("aaa bbb ccc")
        type("ciw")
        insert("z")
        XCTAssertEqual(buffer.text, "z bbb ccc")
        type("w.")
        XCTAssertEqual(buffer.text, "z z ccc")
        type("w.")
        XCTAssertEqual(buffer.text, "z z z")
    }

    // MARK: - The second review's findings, pinned

    func testCountsAreCappedAndNeverTrap() {
        load("abc")
        type("99999999999999999999")
        type("l")
        XCTAssertEqual(buffer.cursor, 2, "a huge count moves as far as the line allows")
        type("9999999999~")
        XCTAssertEqual(buffer.text, "abC", "the toggle stops at the line, whatever the count")
    }

    func testDollarUnderAnOperatorKeepsTheNewline() {
        load("abc\ndef")
        type("d$")
        XCTAssertEqual(buffer.text, "\ndef")
        load("abc\ndef")
        type("y$")
        XCTAssertEqual(board, "abc")
        load("abc\ndef", cursor: 1)
        type("c$")
        insert("X")
        XCTAssertEqual(buffer.text, "aX\ndef")
    }

    func testChangeWordOnAWordsLastCharacter() {
        load("foo bar")
        type("e")
        XCTAssertEqual(buffer.cursor, 2)
        type("cw")
        insert("d")
        XCTAssertEqual(buffer.text, "fod bar")
    }

    func testDotRepeatsAVisualChangeOnTheSameShape() {
        load("aaaa bbbb cccc")
        type("vlld")
        XCTAssertEqual(buffer.text, "a bbbb cccc")
        type("w.")
        XCTAssertEqual(buffer.text, "a b cccc", "three characters from the cursor again")
        XCTAssertFalse(vim.isPending)
        load("one two three")
        type("viwc")
        insert("1")
        type("w.")
        XCTAssertEqual(buffer.text, "1 1 three", "a visual change with typing repeats the typing too")
    }

    func testAppendOnAnEmptyLineAndToggleStopsAtTheLine() {
        load("\nnext")
        type("a")
        insert("x")
        XCTAssertEqual(buffer.text, "x\nnext")
        load("ab\ncd")
        type("l5~")
        XCTAssertEqual(buffer.text, "aB\ncd")
    }

    func testDotRepeatsOnlyTheLastChange() {
        load("hello")
        type("xx.")
        XCTAssertEqual(buffer.text, "lo", "one x again, not two")
        load("abc")
        type("x")
        type("i")
        insert("Z")
        type("l.")
        XCTAssertEqual(buffer.text, "ZZbc", "the insert again before b, without the x before it")
    }

    func testCountProductsAreCappedAndMotionsStopWhenTheyStopMoving() {
        load("a\nb\nc")
        type("9999d9999j")
        XCTAssertEqual(buffer.text, "", "every line, once, and no hang")
        load("ab")
        type("9999l")
        XCTAssertEqual(buffer.cursor, 1)
    }

    func testReplaceRefusesToCrossTheLine() {
        load("ab\ncd")
        type("3rx")
        XCTAssertEqual(buffer.text, "ab\ncd")
        type("2rx")
        XCTAssertEqual(buffer.text, "xx\ncd")
    }

    func testChangeBigWordTakesPunctuationToo() {
        load("foo-bar baz")
        type("cW")
        insert("q")
        XCTAssertEqual(buffer.text, "q baz")
    }
    // MARK: - Find lights

    func testFindTargetsLightTheFirstInstanceOfEachCharacterAcrossLines() {
        var buffer = Draft.Buffer(text: "ab a\nba c")
        buffer.setCursor(0)
        XCTAssertEqual(Vim.findTargets(kind: "f", in: buffer), [1, 3, 8],
                       "b at 1, the second a at 3, c at 8; whitespace and repeats unlit")
    }

    func testFindTargetsForTStartOneFurtherLikeTheMotion() {
        var buffer = Draft.Buffer(text: "abc")
        buffer.setCursor(0)
        XCTAssertEqual(Vim.findTargets(kind: "t", in: buffer), [2],
                       "tb cannot move, so b at 1 is not a target; c at 2 is")
    }

    func testFindTargetsScanBackwardForCapitals() {
        var buffer = Draft.Buffer(text: "ab a\nba c")
        buffer.setCursor(8)
        XCTAssertEqual(Vim.findTargets(kind: "F", in: buffer), [6, 5],
                       "the nearest instance of each character behind the cursor; repeats unlit")
        XCTAssertEqual(Vim.findTargets(kind: "T", in: buffer), [6, 5],
                       "Ta lands beside the a at 6, so it is lit; only a match against the cursor is out of reach")
    }

    func testPendingFindAppearsWithTheKeyAndClearsWithTheTarget() {
        var vim = Vim()
        var buffer = Draft.Buffer(text: "alpha")
        buffer.setCursor(0)
        vim.enterNormal(&buffer)
        XCTAssertNil(vim.pendingFind)
        _ = vim.key(.char("f"), buffer: &buffer, pasteboard: { nil })
        XCTAssertEqual(vim.pendingFind, "f")
        _ = vim.key(.char("h"), buffer: &buffer, pasteboard: { nil })
        XCTAssertNil(vim.pendingFind)
        XCTAssertEqual(buffer.cursor, 3)
    }
    func testJAndKWalkTheEyesLinesWhenTheShellProvidesThem() {
        load("abcdef")
        // A fake layout that wraps every three characters.
        vim.visualLine = { _, index, down in
            let landed = down ? index + 3 : index - 3
            return (0..<6).contains(landed) ? landed : nil
        }
        type("j"); XCTAssertEqual(buffer.cursor, 3, "down walks the eye's line, not the file's")
        type("k"); XCTAssertEqual(buffer.cursor, 0)
        type("k"); XCTAssertEqual(buffer.cursor, 0, "past the layout's edge, the logical guard holds")
        type("dj")
        XCTAssertEqual(buffer.text, "abcdef", "an operator's j stays logical: one line has no line below")
    }
    // MARK: - Any-quote and any-bracket (mini.ai's q and b)

    func testAnyQuoteFindsTheCoveringPairAcrossKinds() {
        load("say \"the 'inner' word\" end", cursor: 12)
        type("diq")
        XCTAssertEqual(buffer.text, "say \"the '' word\" end", "the innermost covering kind wins")
        load("say \"the word\" end", cursor: 7)
        type("daq")
        XCTAssertEqual(buffer.text, "say  end")
    }

    func testAnyQuoteReachesAheadWhenNothingCovers() {
        load("plain then `quoted` here", cursor: 0)
        type("diq")
        XCTAssertEqual(buffer.text, "plain then `` here")
    }

    func testAnyBracketPicksTheInnermostCoveringKind() {
        load("a (b [c] d) e", cursor: 6)
        type("dib")
        XCTAssertEqual(buffer.text, "a (b [] d) e")
        type("dib")
        XCTAssertEqual(buffer.text, "a () e", "the next covering kind out")
    }

    func testAnyBracketReachesAheadWhenNotEnclosed() {
        load("before {curly} after", cursor: 0)
        type("dab")
        XCTAssertEqual(buffer.text, "before  after")
    }

    func testStockPairsStillAnswerByTheirOwnCharacters() {
        load("f(x[y]{z})", cursor: 4)
        type("di[")
        XCTAssertEqual(buffer.text, "f(x[]{z})")
        type("di(")
        XCTAssertEqual(buffer.text, "f()")
        load("a {b} c", cursor: 3)
        type("diB")
        XCTAssertEqual(buffer.text, "a {} c", "B keeps vim's braces")
    }
    // MARK: - Surround (mini.surround's sa, sd, sr)

    func testSurroundAddWrapsAnObject() {
        load("say hello there", cursor: 6)
        type("saiwq")
        XCTAssertEqual(buffer.text, "say \"hello\" there")
        XCTAssertEqual(buffer.cursor, 4, "the cursor rests on the opening delimiter")
    }

    func testSurroundAddSpacedOpenAndPlainClose() {
        load("word", cursor: 0)
        type("saiw(")
        XCTAssertEqual(buffer.text, "( word )", "an opening character pads")
        load("word", cursor: 0)
        type("saiw)")
        XCTAssertEqual(buffer.text, "(word)", "a closing character does not")
    }

    func testSurroundAddTakesAMotionAndALine() {
        load("one two", cursor: 0)
        type("saw`")
        XCTAssertEqual(buffer.text, "`one `two", "a motion span, exactly what w covers")
        load("first\nsecond", cursor: 2)
        type("sas]")
        XCTAssertEqual(buffer.text, "[first]\nsecond", "the doubled key wraps the line")
    }

    func testSurroundAddWrapsTheVisualSelection() {
        load("pick these words", cursor: 5)
        type("vesab")
        XCTAssertEqual(buffer.text, "pick (these) words")
    }

    func testSurroundDeleteUnwrapsByFinderOrKind() {
        load("say \"quoted\" here", cursor: 6)
        type("sdq")
        XCTAssertEqual(buffer.text, "say quoted here", "q finds whichever quote kind covers")
        load("say [deep] here", cursor: 6)
        type("sdb")
        XCTAssertEqual(buffer.text, "say deep here", "b finds whichever bracket kind covers")
        load("f(x)", cursor: 2)
        type("sd)")
        XCTAssertEqual(buffer.text, "fx")
    }

    func testSurroundReplaceSwapsDelimiters() {
        load("say 'word' here", cursor: 6)
        type("srq")
        XCTAssertEqual(buffer.text, "say 'word' here", "half a replace changes nothing yet")
        type("]")
        XCTAssertEqual(buffer.text, "say [word] here", "any quote in, brackets out")
        type("sr]\"")
        XCTAssertEqual(buffer.text, "say \"word\" here")
    }

    func testSurroundIsPendingAndEscapeAbandonsIt() {
        load("word", cursor: 0)
        type("s")
        XCTAssertTrue(vim.isPending)
        type("\u{1B}")
        XCTAssertFalse(vim.isPending)
        XCTAssertEqual(buffer.text, "word", "an abandoned surround changes nothing")
        type("sr'")
        type("\u{1B}")
        type("saiw")
        type("\u{1B}")
        XCTAssertEqual(buffer.text, "word")
    }

    func testSurroundIsOneUndoStep() {
        load("plain", cursor: 0)
        type("saiw\"")
        XCTAssertEqual(buffer.text, "\"plain\"")
        type("u")
        XCTAssertEqual(buffer.text, "plain")
    }
    /// Found by the seeded storms while surround landed, but older than
    /// either: any visual command on an empty draft reached for a line
    /// index that does not exist.
    func testVisualCommandsOnAnEmptyBufferCollapseToNormal() {
        load("")
        type("vy")
        XCTAssertEqual(vim.mode, .normal)
        load("")
        type("vd")
        XCTAssertEqual(buffer.text, "")
        load("")
        type("Vsaq")
        XCTAssertEqual(buffer.text, "", "even a surround finds nothing to wrap")
    }
}
