import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The draft takes the mouse, driven the way a hand drives it: through the
/// controller's own press, drag and release, aimed at points on the real
/// glass that the real layout says are over a letter. Nothing here moves
/// a system pointer; what is proved is that a point on the words becomes
/// the edit it should in both editing styles, that the glass stays the
/// app underneath's guest while it happens, and that the fold, the undo
/// and the record keep the promises the design makes about it.
final class DraftPointerScenarioTests: XCTestCase {
    // MARK: - Rigging

    /// A Standard draft with `value` pulled in, the caret at `cursor`.
    private func standard(_ value: String, cursor: Int? = nil) -> Stage {
        let stage = Stage()
        stage.draft.editingStyle = .standard
        stage.field = DraftController.Field(selection: nil, value: value, cursor: cursor ?? value.count)
        stage.lode(".", shift: true)
        return stage
    }

    /// A Vim draft with `value` pulled in, in normal mode with the cursor at `cursor`.
    private func vim(_ value: String, cursor: Int = 0, normal: Bool = true) -> Stage {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: value, cursor: cursor)
        stage.lode(".", shift: true)
        if normal { stage.press("escape") }
        return stage
    }

    private func panel(_ stage: Stage) -> DraftPanel { stage.draft.panel }

    /// Over a character's left half by default: the point that means to
    /// put the caret before it.
    private func over(_ stage: Stage, _ index: Int, _ fraction: CGFloat = 0.25) -> NSPoint {
        panel(stage).windowPoint(forCharacter: index, at: fraction)
    }

    private func click(_ stage: Stage, _ index: Int, _ fraction: CGFloat = 0.25, clicks: Int = 1, shift: Bool = false) {
        stage.draft.pointerDown(at: over(stage, index, fraction), clicks: clicks, shift: shift)
        stage.draft.pointerUp()
    }

    /// A press at one insertion point and a release at another, the pointer
    /// passing through the points between.
    private func drag(_ stage: Stage, from: Int, to: Int, clicks: Int = 1, release: Bool = true) {
        stage.draft.pointerDown(at: over(stage, from), clicks: clicks, shift: false)
        stage.draft.pointerDragged(to: over(stage, to))
        if release { stage.draft.pointerUp() }
    }

    private func selected(_ stage: Stage) -> String? {
        stage.draft.buffer.selection.map(stage.draft.buffer.slice)
    }

    /// What the glass shows selected, in either style.
    private func shown(_ stage: Stage) -> String? {
        stage.draft.vim.selection(in: stage.draft.buffer).map(stage.draft.buffer.slice)
    }

    private func type(_ stage: Stage, _ text: String) {
        for character in text { stage.press(character == " " ? "space" : String(character)) }
    }

    private func event(_ type: NSEvent.EventType, _ stage: Stage, at point: NSPoint,
                       clicks: Int = 1, shift: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? .shift : [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: panel(stage).panel.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    // MARK: - Standard: a click

    func testAClickPutsTheCaretOnTheNearerSideOfALetter() {
        let stage = standard("hello world")
        click(stage, 2, 0.25)
        XCTAssertEqual(stage.draft.buffer.cursor, 2, "the left half of a letter: before it")
        click(stage, 2, 0.75)
        XCTAssertEqual(stage.draft.buffer.cursor, 3, "the right half: after it")
        XCTAssertNil(stage.draft.buffer.selection)
        XCTAssertEqual(stage.draft.mode, .insert)
    }

    func testAClickAfterTheLastLetterAndBeyondALinesEndLandsAtTheEnds() {
        let stage = standard("one\ntwo")
        click(stage, 7)
        XCTAssertEqual(stage.draft.buffer.cursor, 7, "past the last letter: the end of the text")
        click(stage, 3)
        XCTAssertEqual(stage.draft.buffer.cursor, 3, "past the first line's last letter: before its newline, not after")
    }

    func testAClickBelowTheTextIsTheEndAndAboveItTheFirstLine() {
        let stage = standard("one two\nthree four", cursor: 4)
        let box = panel(stage).textBoxInWindow
        let x = over(stage, 1).x
        stage.draft.pointerDown(at: NSPoint(x: x, y: box.minY - 40), clicks: 1, shift: false)
        XCTAssertEqual(stage.draft.buffer.cursor, 18, "below the box: the end")
        stage.draft.pointerUp()
        stage.draft.pointerDown(at: NSPoint(x: x, y: box.maxY + 40), clicks: 1, shift: false)
        XCTAssertEqual(stage.draft.buffer.cursor, 1, "above the box: the first line, by x")
        stage.draft.pointerUp()
    }

    func testAClickEndsASelection() {
        let stage = standard("hello world")
        stage.chord("left", [.maskShift, .maskAlternate])
        XCTAssertEqual(selected(stage), "world")
        click(stage, 1)
        XCTAssertNil(stage.draft.buffer.selection)
        XCTAssertEqual(stage.draft.buffer.cursor, 1)
    }

    func testTheGlassStaysAGuestWhileItIsClicked() {
        let stage = standard("hello world")
        let active = NSApp.isActive
        let key = NSApp.keyWindow
        let before = panel(stage).panel.isKeyWindow
        let point = over(stage, 4)
        panel(stage).panel.sendEvent(event(.leftMouseDown, stage, at: point))
        panel(stage).panel.sendEvent(event(.leftMouseUp, stage, at: point))
        XCTAssertEqual(stage.draft.buffer.cursor, 4, "the real event reached the controller")
        XCTAssertEqual(panel(stage).panel.isKeyWindow, before)
        XCTAssertFalse(panel(stage).panel.isKeyWindow, "a click on the words never makes the glass key")
        XCTAssertEqual(NSApp.isActive, active, "and never activates Lodestar")
        XCTAssertTrue(NSApp.keyWindow === key)
        XCTAssertFalse(panel(stage).textView.acceptsFirstResponder)
        XCTAssertFalse(panel(stage).textView.needsPanelToBecomeKey)
        XCTAssertTrue(panel(stage).textView.acceptsFirstMouse(for: nil))
        XCTAssertFalse(panel(stage).textView.isEditable)
        XCTAssertFalse(panel(stage).textView.isSelectable)
    }

    func testTheRealEventsCarryTheClickCountAndShift() {
        let stage = standard("one two three", cursor: 0)
        let text = panel(stage).textView
        let two = over(stage, 5)
        text.mouseDown(with: event(.leftMouseDown, stage, at: two, clicks: 2))
        text.mouseUp(with: event(.leftMouseUp, stage, at: two, clicks: 2))
        XCTAssertEqual(selected(stage), "two", "the view reported two clicks")
        let three = over(stage, 9)
        text.mouseDown(with: event(.leftMouseDown, stage, at: three, clicks: 1, shift: true))
        text.mouseUp(with: event(.leftMouseUp, stage, at: three, clicks: 1, shift: true))
        XCTAssertEqual(selected(stage), "two three", "and the shift, by the grain the double click chose")
    }

    func testOtherButtonsAreTheAppUnderneathsBusiness() {
        let stage = standard("hello world", cursor: 3)
        let text = panel(stage).textView
        let point = over(stage, 8)
        text.rightMouseDown(with: event(.rightMouseDown, stage, at: point))
        text.otherMouseDown(with: event(.otherMouseDown, stage, at: point))
        XCTAssertEqual(stage.draft.buffer.cursor, 3)
        XCTAssertNil(text.menu(for: event(.rightMouseDown, stage, at: point)), "no context menu of its own")
        XCTAssertFalse(panel(stage).pointerHeld)
    }

    func testTheIBeamIsAskedForOverTheWords() {
        let stage = standard("hello world")
        let text = panel(stage).textView
        text.updateTrackingAreas()
        let area = text.beamArea
        XCTAssertNotNil(area)
        XCTAssertTrue(text.trackingAreas.contains { $0 === area })
        let options = area?.options ?? []
        XCTAssertTrue(options.contains(.cursorUpdate))
        XCTAssertTrue(options.contains(.activeAlways))
        XCTAssertTrue(options.contains(.inVisibleRect))
        NSCursor.arrow.set()
        text.cursorUpdate(with: event(.mouseMoved, stage, at: over(stage, 2)))
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam)
    }

    func testPressesWhileClosingOrNotOpenAreSwallowed() {
        let idle = Stage()
        idle.draft.pointerDown(at: NSPoint(x: 10, y: 10), clicks: 2, shift: true)
        idle.draft.pointerDragged(to: NSPoint(x: 40, y: 10))
        idle.draft.pointerUp()
        XCTAssertFalse(idle.draft.isOpen)

        let stage = Stage()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("first sentence.")
        stage.speech.hear("second one")
        stage.press("return")
        XCTAssertTrue(stage.draft.isOpen, "closing, waiting for the last words")
        let point = over(stage, 3)
        stage.draft.pointerDown(at: point, clicks: 2, shift: false)
        stage.draft.pointerDragged(to: over(stage, 9))
        XCTAssertEqual(stage.draft.buffer.ghost, "second one", "a press while closing changes nothing")
        XCTAssertEqual(stage.draft.buffer.cursor, "first sentence.".count)
        stage.speech.finish()
        XCTAssertEqual(stage.pasteboard.last, "first sentence. second one")
        XCTAssertEqual(stage.lastDraft?.pointerActs, 0, "and is not counted")
    }

    // MARK: - Standard: a drag

    func testADragSelectsFromThePressToThePointerAndBackwardsToo() {
        let stage = standard("hello world")
        drag(stage, from: 2, to: 8)
        XCTAssertEqual(selected(stage), "llo wo")
        XCTAssertEqual(stage.draft.buffer.cursor, 8, "the caret goes with the pointer")
        XCTAssertEqual(stage.draft.buffer.anchor, 2)
        drag(stage, from: 8, to: 2)
        XCTAssertEqual(selected(stage), "llo wo")
        XCTAssertEqual(stage.draft.buffer.cursor, 2, "backwards: the same text, the caret at the pointer")
        XCTAssertEqual(stage.draft.buffer.anchor, 8)
    }

    func testDraggingBackToThePressPointSelectsNothing() {
        let stage = standard("hello world")
        drag(stage, from: 4, to: 9, release: false)
        XCTAssertEqual(selected(stage), "o wor")
        stage.draft.pointerDragged(to: over(stage, 4))
        XCTAssertNil(stage.draft.buffer.selection)
        stage.draft.pointerUp()
    }

    func testTypingReplacesWhatWasDraggedAndCommandZBringsItBack() {
        let stage = standard("hello world")
        drag(stage, from: 6, to: 11)
        type(stage, "x")
        XCTAssertEqual(stage.draft.buffer.text, "hello x")
        _ = stage.commandPress("z")
        XCTAssertEqual(stage.draft.buffer.text, "hello world")
    }

    // MARK: - Standard: words and lines

    func testADoubleClickSelectsTheWordUnderThePointer() {
        let stage = standard("one two three", cursor: 0)
        click(stage, 5, 0.75, clicks: 2)
        XCTAssertEqual(selected(stage), "two", "the word the letter is in, though the click was on its far half")
        XCTAssertEqual(stage.draft.buffer.cursor, 7)
    }

    func testADoubleClickAndDragGrowsByWholeWords() {
        let stage = standard("one two three four", cursor: 0)
        drag(stage, from: 5, to: 10, clicks: 2, release: false)
        XCTAssertEqual(selected(stage), "two three", "the pointer is in 'three': the word to its end")
        stage.draft.pointerDragged(to: over(stage, 1))
        XCTAssertEqual(selected(stage), "one two", "back over 'one': the pressed word stays whole")
        XCTAssertEqual(stage.draft.buffer.anchor, 7)
        stage.draft.pointerUp()
    }

    func testATripleClickSelectsTheLineWithItsNewlineAndTheLastLineHasNone() {
        let stage = standard("one\ntwo\nthree", cursor: 0)
        click(stage, 5, clicks: 3)
        XCTAssertEqual(selected(stage), "two\n")
        click(stage, 10, clicks: 3)
        XCTAssertEqual(selected(stage), "three")
        click(stage, 5, clicks: 4)
        XCTAssertEqual(selected(stage), "two\n", "a fourth click is still a line")
    }

    func testATripleClickAndDragGrowsByWholeLines() {
        let stage = standard("one\ntwo\nthree\nfour", cursor: 0)
        drag(stage, from: 5, to: 10, clicks: 3, release: false)
        XCTAssertEqual(selected(stage), "two\nthree\n")
        stage.draft.pointerDragged(to: over(stage, 1))
        XCTAssertEqual(selected(stage), "one\ntwo\n")
        stage.draft.pointerUp()
    }

    // MARK: - Standard: shift-click

    func testShiftClickExtendsFromTheCaretWhenNothingIsSelected() {
        let stage = standard("hello world", cursor: 3)
        click(stage, 8, shift: true)
        XCTAssertEqual(selected(stage), "lo wo")
        XCTAssertEqual(stage.draft.buffer.anchor, 3)
        XCTAssertEqual(stage.draft.buffer.cursor, 8)
    }

    func testShiftClickKeepsTheAnchorOfASelectionAndMovesTheOtherEnd() {
        let stage = standard("hello world")
        drag(stage, from: 4, to: 8)
        click(stage, 10, shift: true)
        XCTAssertEqual(selected(stage), "o worl")
        XCTAssertEqual(stage.draft.buffer.anchor, 4)
        click(stage, 1, shift: true)
        XCTAssertEqual(selected(stage), "ell", "past the anchor: the same anchor, the other way")
        XCTAssertEqual(stage.draft.buffer.anchor, 4)
        XCTAssertEqual(stage.draft.buffer.cursor, 1)
    }

    func testShiftClickAfterADoubleClickExtendsByWholeWords() {
        let stage = standard("one two three four", cursor: 0)
        click(stage, 5, clicks: 2)
        XCTAssertEqual(selected(stage), "two")
        click(stage, 15, shift: true)
        XCTAssertEqual(selected(stage), "two three four")
        click(stage, 0, shift: true)
        XCTAssertEqual(selected(stage), "one two three four".prefix(7).description, "the pressed word kept whole")
    }

    func testAKeyReturnsTheGrainToCharacters() {
        let stage = standard("one two three four", cursor: 0)
        click(stage, 5, clicks: 2)
        stage.press("right")
        XCTAssertEqual(stage.draft.buffer.cursor, 7)
        click(stage, 11, shift: true)
        XCTAssertEqual(selected(stage), " thr", "by characters again: from the caret at 7 to the click")
    }

    // MARK: - Both: the ghost

    func testAPressSettlesAStandingGhostWhereItStandsAndReadsTheFreshLayout() {
        let stage = Stage()
        stage.draft.editingStyle = .standard
        stage.lode(".")
        stage.speech.settle("First sentence.")
        stage.speech.hear("and more words")
        XCTAssertEqual(stage.draft.buffer.ghost, "and more words")
        // Beyond the settled text, over the grey words that follow it.
        var inGhost = over(stage, 14, 0.9)
        inGhost.x += 45
        stage.draft.pointerDown(at: inGhost, clicks: 1, shift: false)
        stage.draft.pointerUp()
        XCTAssertEqual(stage.draft.buffer.ghost, "")
        XCTAssertEqual(stage.draft.buffer.text, "First sentence. and more words", "the ghost is text where it stood")
        XCTAssertGreaterThan(stage.draft.buffer.cursor, 15, "and the point read the words that were under it")
        XCTAssertLessThan(stage.draft.buffer.cursor, 26)
    }

    func testAPressOnTheGhostsFirstLetterBeforeItLandsAtTheStart() {
        let stage = Stage()
        stage.draft.editingStyle = .standard
        stage.lode(".")
        stage.speech.settle("First sentence.")
        stage.speech.hear("and more")
        click(stage, 0)
        XCTAssertEqual(stage.draft.buffer.text, "First sentence. and more")
        XCTAssertEqual(stage.draft.buffer.cursor, 0)
    }

    func testAPressIsTheHandActing() {
        let stage = Stage()
        stage.draft.editingStyle = .standard
        stage.lode(".")
        stage.speech.settle("First sentence.")
        stage.speech.hear("and more")
        click(stage, 3)
        // A final that arrives for the settled ghost revises it in place,
        // as it does after a key, rather than landing at the caret.
        stage.speech.settle("And more.")
        XCTAssertEqual(stage.draft.buffer.text.hasPrefix("First sentence."), true)
        XCTAssertEqual(stage.draft.buffer.text.count, "First sentence. And more.".count,
                       "revised where it stood; nothing doubled")
    }

    // MARK: - Standard: undo

    func testCommandZAfterAClickThenTypingTakesBackOnlyWhatWasTypedAfterTheClick() {
        let stage = standard("", cursor: 0)
        type(stage, "abc")
        click(stage, 0)
        XCTAssertEqual(stage.draft.buffer.cursor, 0)
        type(stage, "x")
        XCTAssertEqual(stage.draft.buffer.text, "xabc")
        _ = stage.commandPress("z")
        XCTAssertEqual(stage.draft.buffer.text, "abc", "only the x")
        _ = stage.commandPress("z")
        XCTAssertEqual(stage.draft.buffer.text, "", "and then the run before the click")
    }

    func testTheClickItselfIsNotAnUndoStep() {
        let stage = standard("", cursor: 0)
        type(stage, "abc")
        click(stage, 0)
        _ = stage.commandPress("z")
        XCTAssertEqual(stage.draft.buffer.text, "", "no edit followed the click: command Z is not a cursor move")
    }

    func testAnArrowEndsTheTypingRunToo() {
        let stage = standard("", cursor: 0)
        type(stage, "abc")
        stage.press("left")
        type(stage, "x")
        XCTAssertEqual(stage.draft.buffer.text, "abxc")
        _ = stage.commandPress("z")
        XCTAssertEqual(stage.draft.buffer.text, "abc", "a move of the caret ends the run, in any Mac field")
    }

    func testAPasteAfterAClickIsItsOwnStep() {
        let stage = standard("", cursor: 0)
        stage.pasteboard = ["PASTED"]
        type(stage, "abc")
        click(stage, 1)
        _ = stage.commandPress("v")
        XCTAssertEqual(stage.draft.buffer.text, "aPASTEDbc")
        _ = stage.commandPress("z")
        XCTAssertEqual(stage.draft.buffer.text, "abc")
    }

    // MARK: - Both: the fold

    private var twelveLines: String { (1...12).map { "line \($0)" }.joined(separator: "\n") }

    private func lineStart(_ line: Int) -> Int { twelveLines.split(separator: "\n", omittingEmptySubsequences: false)[..<(line - 1)].reduce(0) { $0 + $1.count + 1 } }

    func testAClickInsideTheFoldedWindowDoesNotMoveTheText() {
        let stage = standard(twelveLines)
        let before = panel(stage).textScrollOrigin
        XCTAssertGreaterThan(before, 0, "folded to the last four lines")
        // The top visible line is the ninth.
        click(stage, lineStart(9) + 2)
        XCTAssertEqual(panel(stage).textScrollOrigin, before, accuracy: 0.5, "the text did not scroll under the pointer")
        XCTAssertEqual(stage.draft.buffer.cursor, lineStart(9) + 2)
        click(stage, lineStart(10) + 1)
        XCTAssertEqual(panel(stage).textScrollOrigin, before, accuracy: 0.5)
    }

    func testAClickInsideTheFoldedWindowInVimDoesNotMoveItEither() {
        let stage = vim(twelveLines, cursor: twelveLines.count)
        let before = panel(stage).textScrollOrigin
        click(stage, lineStart(9) + 2)
        XCTAssertEqual(panel(stage).textScrollOrigin, before, accuracy: 0.5)
        XCTAssertEqual(stage.draft.buffer.cursor, lineStart(9) + 2)
    }

    func testAWheelScrolledWindowIsWhatAPressLandsIn() {
        let stage = standard(twelveLines)
        let clip = panel(stage).textView.enclosingScrollView!.contentView
        // The hand scrolled the text up to lines 5 to 8.
        var tops: [CGFloat] = []
        let layout = panel(stage).textView.layoutManager!
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
            rect, _, _, _, _ in tops.append(rect.minY)
        }
        clip.scroll(to: NSPoint(x: 0, y: tops[4]))
        click(stage, lineStart(6) + 2)
        XCTAssertEqual(stage.draft.buffer.cursor, lineStart(6) + 2, "the line the pointer was over")
        XCTAssertEqual(panel(stage).textScrollOrigin, tops[4], accuracy: 0.5, "and the window stayed where the hand put it")
    }

    // MARK: - Both: the gate

    func testTheWindowKeepsTheMouseWhileTheButtonIsDownEvenOffTheGlass() {
        let stage = standard("hello world")
        let glass = panel(stage).frame
        let away = NSPoint(x: glass.maxX + 200, y: glass.midY)
        panel(stage).gatePointer(at: away)
        XCTAssertFalse(panel(stage).takesPointer, "off the glass the window ignores the mouse")
        let text = panel(stage).textView
        let start = over(stage, 2)
        text.mouseDown(with: event(.leftMouseDown, stage, at: start))
        XCTAssertTrue(panel(stage).pointerHeld)
        panel(stage).gatePointer(at: away)
        XCTAssertTrue(panel(stage).takesPointer, "held: the drag is still the hand's")
        text.mouseUp(with: event(.leftMouseUp, stage, at: start))
        XCTAssertFalse(panel(stage).pointerHeld)
        panel(stage).gatePointer(at: away)
        XCTAssertFalse(panel(stage).takesPointer, "released: the glass is only the glass again")
    }

    func testALostMouseUpAndAClosingDraftCannotLeaveTheGateHeld() {
        let stage = standard("hello world")
        let text = panel(stage).textView
        text.mouseDown(with: event(.leftMouseDown, stage, at: over(stage, 2)))
        XCTAssertTrue(panel(stage).pointerHeld)
        // The release goes to another app: only the gate's own watch sees it.
        let gate = Mirror(reflecting: panel(stage)).children.first { $0.label == "gate" }?.value as? PointerGate
        XCTAssertNotNil(gate)
        gate?.held = false
        XCTAssertFalse(panel(stage).pointerHeld)
        text.mouseDown(with: event(.leftMouseDown, stage, at: over(stage, 2)))
        XCTAssertTrue(panel(stage).pointerHeld)
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertFalse(panel(stage).pointerHeld, "hiding the glass lets go")
    }

    // MARK: - Both: autoscroll

    func testADragPastTheTextBoxTakesALineAtATimeUntilItComesBack() {
        let stage = standard(twelveLines)
        let start = lineStart(10) + 2
        stage.draft.pointerDown(at: over(stage, start), clicks: 1, shift: false)
        XCTAssertFalse(stage.draft.autoscrolling)
        let box = panel(stage).textBoxInWindow
        let x = over(stage, start).x
        stage.draft.pointerDragged(to: NSPoint(x: x, y: box.maxY + 30))
        XCTAssertTrue(stage.draft.autoscrolling, "past the top: a timer, not a loop")
        let first = stage.draft.buffer.cursor
        XCTAssertEqual(stage.draft.buffer.lineIndex(of: first), 8, "the top visible line, to begin with")
        stage.draft.autoscrollStep()
        XCTAssertEqual(stage.draft.buffer.lineIndex(of: stage.draft.buffer.cursor), 7, "one line up")
        stage.draft.autoscrollStep()
        XCTAssertEqual(stage.draft.buffer.lineIndex(of: stage.draft.buffer.cursor), 6)
        XCTAssertEqual(stage.draft.buffer.anchor, start, "the press point stays the anchor")
        // Back over the text: the pointer decides again.
        stage.draft.pointerDragged(to: over(stage, lineStart(7) + 2))
        XCTAssertFalse(stage.draft.autoscrolling)
        stage.draft.pointerUp()
        XCTAssertEqual(selected(stage)?.hasPrefix("ne 7\n"), true, "from the line the pointer came back over")
    }

    func testAutoscrollGoesDownAndStopsWhenTheButtonComesUp() {
        let stage = standard(twelveLines, cursor: 0)
        // Lines 1 to 4 are the window, with the caret at the top of the text.
        let start = 2
        stage.draft.pointerDown(at: over(stage, start), clicks: 1, shift: false)
        let box = panel(stage).textBoxInWindow
        stage.draft.pointerDragged(to: NSPoint(x: over(stage, start).x, y: box.minY - 30))
        XCTAssertTrue(stage.draft.autoscrolling)
        for _ in 0..<5 { stage.draft.autoscrollStep() }
        XCTAssertEqual(stage.draft.buffer.lineIndex(of: stage.draft.buffer.cursor), 3 + 5,
                       "the last visible line to begin with, then a line a step")
        stage.draft.pointerUp()
        XCTAssertFalse(stage.draft.autoscrolling)
        let held = stage.draft.buffer.cursor
        stage.draft.autoscrollStep()
        XCTAssertEqual(stage.draft.buffer.cursor, held, "a stray tick after the release does nothing")
    }

    func testAutoscrollInVimExtendsTheVisualSelection() {
        let stage = vim(twelveLines, cursor: twelveLines.count - 1)
        let start = lineStart(11) + 2
        stage.draft.pointerDown(at: over(stage, start), clicks: 1, shift: false)
        let box = panel(stage).textBoxInWindow
        stage.draft.pointerDragged(to: NSPoint(x: over(stage, start).x, y: box.maxY + 30))
        let held = panel(stage).textScrollOrigin
        stage.draft.autoscrollStep()
        stage.draft.autoscrollStep()
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: false))
        XCTAssertEqual(stage.draft.buffer.lineIndex(of: stage.draft.buffer.cursor), 6,
                       "the top visible line, the ninth, then two lines up")
        XCTAssertLessThan(panel(stage).textScrollOrigin, held, "the editor keeps its fold, so the window followed")
        stage.draft.pointerUp()
    }

    // MARK: - Vim: a click

    func testAClickInNormalModePutsTheCursorOnTheCharacterUnderThePointer() {
        let stage = vim("one two three", cursor: 0)
        click(stage, 5, 0.75)
        XCTAssertEqual(stage.draft.buffer.cursor, 5, "the character under the pointer, whichever half")
        XCTAssertEqual(stage.draft.mode, .normal)
        XCTAssertEqual(stage.draft.vim.mode, .normal)
    }

    func testAClickInNormalModeRestsOnACharacterNotPastALinesEnd() {
        let stage = vim("one\ntwo", cursor: 0)
        click(stage, 3)
        XCTAssertEqual(stage.draft.buffer.cursor, 2)
        click(stage, 7)
        XCTAssertEqual(stage.draft.buffer.cursor, 6)
    }

    func testAClickDropsAHalfTypedCommand() {
        let stage = vim("one two three", cursor: 0)
        stage.press("d")
        stage.press("2")
        XCTAssertTrue(stage.draft.vim.isPending)
        click(stage, 8)
        XCTAssertFalse(stage.draft.vim.isPending)
        stage.press("w")
        XCTAssertEqual(stage.draft.buffer.text, "one two three", "the d was dropped: w is only a move")
    }

    func testAClickInVisualModeLeavesItAndPutsTheCursorWhereItLanded() {
        let stage = vim("one two three", cursor: 0)
        stage.press("v"); stage.press("e")
        XCTAssertEqual(shown(stage), "one")
        click(stage, 9)
        XCTAssertEqual(stage.draft.vim.mode, .normal)
        XCTAssertNil(shown(stage))
        XCTAssertEqual(stage.draft.buffer.cursor, 9)
    }

    func testAClickInInsertMovesTheCaretAndStaysInsert() {
        let stage = vim("one two", cursor: 7, normal: false)
        XCTAssertEqual(stage.draft.mode, .insert)
        click(stage, 3)
        XCTAssertEqual(stage.draft.mode, .insert)
        XCTAssertEqual(stage.draft.buffer.cursor, 3, "a caret between characters")
        type(stage, "x")
        XCTAssertEqual(stage.draft.buffer.text, "onex two")
    }

    func testClicksLeaveTheMicrophoneAndTheModeAlone() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("one two three")
        let (pauses, resumes) = (stage.speech.pauses, stage.speech.resumes)
        click(stage, 4)
        click(stage, 7)
        XCTAssertEqual(stage.draft.mode, .insert)
        XCTAssertEqual(stage.speech.pauses, pauses)
        XCTAssertEqual(stage.speech.resumes, resumes)
        stage.speech.settle("four")
        XCTAssertEqual(stage.draft.buffer.text, "one two four three",
                       "speech still writes, at the caret the click put there")
    }

    func testAClickInNormalModeKeepsTheMicrophoneAsleep() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("one two three")
        stage.press("escape")
        let resumes = stage.speech.resumes
        click(stage, 4)
        XCTAssertEqual(stage.draft.mode, .normal)
        XCTAssertEqual(stage.speech.resumes, resumes, "pointing at a word is not selecting it")
    }

    func testAClickThatEndsAVisualSelectionPutsTheMicrophoneBackToSleep() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("one two three")
        stage.press("escape")
        stage.press("0"); stage.press("v"); stage.press("e")
        let (pauses, resumes) = (stage.speech.pauses, stage.speech.resumes)
        XCTAssertEqual(resumes, 1, "a selection wakes it")
        click(stage, 5)
        XCTAssertEqual(stage.speech.pauses, pauses + 1)
        stage.speech.settle("ignored")
        XCTAssertEqual(stage.draft.buffer.text, "one two three")
    }

    // MARK: - Vim: a drag

    func testADragInNormalModeIsVisualOverTheCharactersBetweenItsPoints() {
        let stage = vim("one two three", cursor: 0)
        drag(stage, from: 4, to: 7)
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: false))
        XCTAssertEqual(shown(stage), "two")
        XCTAssertEqual(stage.draft.buffer.cursor, 6, "inclusive, as vim's own mouse")
    }

    func testADragBackwardsSelectsTheSameCharactersWithTheCursorAtThePointer() {
        let stage = vim("one two three", cursor: 0)
        drag(stage, from: 7, to: 4)
        XCTAssertEqual(shown(stage), "two")
        XCTAssertEqual(stage.draft.buffer.cursor, 4)
        XCTAssertEqual(stage.draft.vim.visualAnchor, 6)
    }

    func testADragThatNeverLeavesItsPointIsOnlyAClick() {
        let stage = vim("one two three", cursor: 0)
        drag(stage, from: 4, to: 4)
        XCTAssertEqual(stage.draft.vim.mode, .normal)
        XCTAssertEqual(stage.draft.buffer.cursor, 4)
    }

    func testDraggingBackToThePressPointLeavesVisual() {
        let stage = vim("one two three", cursor: 0)
        drag(stage, from: 4, to: 9, release: false)
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: false))
        stage.draft.pointerDragged(to: over(stage, 4))
        XCTAssertEqual(stage.draft.vim.mode, .normal)
        XCTAssertNil(shown(stage))
        stage.draft.pointerUp()
    }

    func testTheSelectionADragMadeIsTheEditorsToActOn() {
        let stage = vim("one two three", cursor: 0)
        drag(stage, from: 4, to: 8)
        stage.press("d")
        XCTAssertEqual(stage.draft.buffer.text, "one three")
    }

    func testADragFromInsertLeavesInsertThroughTheModePathAndWakesTheMicForTheSelection() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("one two three")
        XCTAssertEqual(stage.draft.mode, .insert)
        let (pauses, resumes) = (stage.speech.pauses, stage.speech.resumes)
        drag(stage, from: 4, to: 7)
        XCTAssertEqual(stage.draft.mode, .normal, "esc's own path")
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: false))
        XCTAssertEqual(shown(stage), "two")
        XCTAssertEqual(stage.speech.pauses, pauses + 1, "leaving insert paused the microphone, as a key esc does")
        XCTAssertEqual(stage.speech.resumes, resumes + 1, "and the selection woke it for speaking over")
        stage.speech.settle("TWO")
        XCTAssertEqual(stage.draft.buffer.text, "one TWO three", "speaking over the dragged words replaces them")
        XCTAssertEqual(stage.draft.mode, .insert)
    }

    func testSpeakingOverADraggedSelectionIsOneStepBack() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("one two three")
        drag(stage, from: 4, to: 7)
        stage.speech.settle("TWO")
        _ = stage.commandPress("z")
        XCTAssertEqual(stage.draft.buffer.text, "one two three")
    }

    // MARK: - Vim: words and lines

    func testADoubleClickInVimIsVisualOverTheWord() {
        let stage = vim("one two three", cursor: 0)
        click(stage, 5, clicks: 2)
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: false))
        XCTAssertEqual(shown(stage), "two")
    }

    func testADoubleClickAndDragInVimGrowsByWholeWords() {
        let stage = vim("one two three four", cursor: 0)
        drag(stage, from: 5, to: 10, clicks: 2, release: false)
        XCTAssertEqual(shown(stage), "two three")
        stage.draft.pointerDragged(to: over(stage, 1))
        XCTAssertEqual(shown(stage), "one two")
        stage.draft.pointerUp()
    }

    func testATripleClickInVimIsVisualLineOverTheLine() {
        let stage = vim("one\ntwo\nthree", cursor: 0)
        click(stage, 5, clicks: 3)
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: true))
        XCTAssertEqual(shown(stage), "two\n")
    }

    func testATripleClickAndDragInVimGrowsByLines() {
        let stage = vim("one\ntwo\nthree\nfour", cursor: 0)
        drag(stage, from: 5, to: 10, clicks: 3, release: false)
        XCTAssertEqual(shown(stage), "two\nthree\n")
        stage.draft.pointerDragged(to: over(stage, 1))
        XCTAssertEqual(shown(stage), "one\ntwo\n")
        stage.draft.pointerUp()
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: true))
    }

    func testADoubleClickInInsertLeavesInsertForVisual() {
        let stage = vim("one two", cursor: 7, normal: false)
        click(stage, 5, clicks: 2)
        XCTAssertEqual(stage.draft.mode, .normal)
        XCTAssertEqual(shown(stage), "two")
    }

    // MARK: - Vim: shift-click

    func testShiftClickInNormalIsVisualFromTheCursorToTheClick() {
        let stage = vim("one two three", cursor: 0)
        click(stage, 5, shift: true)
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: false))
        XCTAssertEqual(shown(stage), "one tw", "inclusive of the character clicked")
    }

    func testShiftClickInVisualKeepsTheAnchorAndMovesTheCursor() {
        let stage = vim("one two three", cursor: 0)
        click(stage, 4)
        stage.press("v"); stage.press("l")
        click(stage, 10, shift: true)
        XCTAssertEqual(shown(stage), "two thr")
        click(stage, 0, shift: true)
        XCTAssertEqual(shown(stage), "one t", "past the anchor, the same anchor")
        XCTAssertEqual(stage.draft.vim.visualAnchor, 4)
    }

    func testShiftClickInVisualLineStaysLinewise() {
        let stage = vim("one\ntwo\nthree\nfour", cursor: 0)
        stage.press("v", shift: true)
        click(stage, 10, shift: true)
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: true))
        XCTAssertEqual(shown(stage), "one\ntwo\nthree\n")
    }

    func testShiftClickInInsertIsADragFromTheCaret() {
        let stage = vim("one two three", cursor: 4, normal: false)
        click(stage, 9, shift: true)
        XCTAssertEqual(stage.draft.mode, .normal)
        XCTAssertEqual(shown(stage), "two t")
    }

    // MARK: - Vim: undo

    func testCommandZAfterAClickThenTypingInVimInsertTakesBackOnlyTheLaterTyping() {
        let stage = Stage()
        stage.lode(".")
        type(stage, "abc")
        click(stage, 0)
        type(stage, "x")
        XCTAssertEqual(stage.draft.buffer.text, "xabc")
        _ = stage.commandPress("z")
        XCTAssertEqual(stage.draft.buffer.text, "abc")
    }

    // MARK: - The record

    func testTheRecordCountsPressesOnTheText() {
        let stage = standard("hello world")
        click(stage, 2)
        click(stage, 5, clicks: 2)
        drag(stage, from: 1, to: 8)
        stage.press("return")
        XCTAssertEqual(stage.lastDraft?.pointerActs, 3)
        XCTAssertEqual(stage.lastDraft?.typed, 0, "a press is not a keystroke")
        XCTAssertEqual(stage.lastDraft?.backspaces, 0)
    }

    func testADraftNobodyPointedAtRecordsNone() {
        let stage = standard("hello world")
        stage.press("return")
        XCTAssertEqual(stage.lastDraft?.pointerActs, 0)
    }

    func testTheCountStartsAgainWithTheNextDraft() {
        let stage = standard("hello world")
        click(stage, 2)
        stage.press("escape")
        XCTAssertEqual(stage.lastDraft?.pointerActs, 1)
        stage.field = DraftController.Field(selection: nil, value: "again", cursor: 5)
        stage.lode(".", shift: true)
        stage.press("return")
        XCTAssertEqual(stage.lastDraft?.pointerActs, 0)
    }

    func testTheRecordNeverHoldsTheText() {
        let stage = standard("hello world")
        click(stage, 2)
        stage.press("return")
        let line = SealedFixture.text(of: stage.eventsFile)
        XCTAssertFalse(line.contains("hello"))
    }
}
