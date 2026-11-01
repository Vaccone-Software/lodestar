import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The draft while speaking holds four whole lines, so the screen behind
/// stays in view; stopping to read opens the whole text, and it stays
/// open through typing until the voice comes back.
final class DraftFoldTests: XCTestCase {
    private var panel: DraftPanel!

    private var reduceMotion: (() -> Bool)!
    private var frame: NSRect?

    override func setUp() {
        super.setUp()
        // The machine's own screen and settings are not the test's: a CI
        // runner's display is smaller than a desk's, and its Reduce Motion
        // is on. The stage's screen, and motion as most people have it.
        frame = ActivePolicy.frameOverride
        ActivePolicy.frameOverride = Stage.screen
        reduceMotion = Accessibility.reduceMotion
        Accessibility.reduceMotion = { false }
        panel = DraftPanel()
    }

    override func tearDown() {
        panel.hide()
        panel = nil
        Accessibility.reduceMotion = reduceMotion
        ActivePolicy.frameOverride = frame
        super.tearDown()
    }

    private var long: String {
        Array(repeating: "The quick brown fox jumps over the lazy dog and keeps going.", count: 12)
            .joined(separator: " ")
    }

    private func view(_ text: String, ghost: String = "", editor: Vim.Mode = .insert) -> DraftView {
        var buffer = Draft.Buffer(text: text)
        buffer.setCursor(buffer.count)
        if !ghost.isEmpty { buffer.showGhost(ghost) }
        var view = DraftView(buffer: buffer, mode: editor == .insert ? .insert : .normal,
                             speech: SpeechState.listening(input: "Mic"),
                             input: "Mic", level: 0.5,
                             destination: ("Ghostty", nil), replacing: false)
        view.editor = editor
        view.micOn = true
        return view
    }

    /// The lines the panel shows, read off its own layout: which are
    /// whole and which are cut by the window's edges.
    private func visibleLines() -> (whole: Int, cut: Int) {
        let text = panel.textView
        guard let layout = text.layoutManager else { return (0, 0) }
        let visible = text.enclosingScrollView!.contentView.bounds
        var whole = 0, cut = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
            rect, _, _, _, _ in
            guard rect.maxY > visible.minY + 0.5, rect.minY < visible.maxY - 0.5 else { return }
            if rect.minY >= visible.minY - 0.5, rect.maxY <= visible.maxY + 0.5 { whole += 1 } else { cut += 1 }
        }
        return (whole, cut)
    }

    func testSpeakingHoldsFourWholeLines() {
        panel.show(view(long, ghost: "and the ghost of what comes next"))
        XCTAssertFalse(panel.expanded)
        let lines = visibleLines()
        XCTAssertEqual(lines.whole, DraftPanel.compactLines)
        XCTAssertEqual(lines.cut, 0, "no line is cut by the window's edges")
    }

    /// The panel shows what the view says and guesses nothing: escape,
    /// muting or a door are the controller's to weigh, not the glass's.
    func testThePanelShowsWhatTheViewSays() {
        panel.show(view(long, ghost: "spoken"))
        let folded = panel.frame.height
        var open = view(long, editor: .normal)
        open.expanded = true
        panel.show(open)
        XCTAssertTrue(panel.expanded)
        XCTAssertGreaterThan(panel.frame.height, folded)
        panel.show(view(long, editor: .normal))
        XCTAssertFalse(panel.expanded, "normal mode alone does not open it")
        XCTAssertEqual(panel.frame.height, folded, accuracy: 0.5)
        var typed = view(long)
        typed.micOn = false
        panel.show(typed)
        XCTAssertFalse(panel.expanded, "typing with the mic off stays four lines")
    }

    func testAShortDraftIsNotPaddedToFourLines() {
        panel.show(view("A few words", ghost: "and more"))
        XCTAssertLessThan(panel.frame.height, 160)
    }

    /// The input is named whenever the microphone is wanted, heard or
    /// not: it is the one thing about the mic the keys cannot choose.
    func testTheInputIsNamedWhileTheMicIsWanted() {
        panel.show(view(""))
        XCTAssertTrue(panel.inputNamed)
        panel.show(view("", ghost: "hello"))
        XCTAssertTrue(panel.inputNamed, "still named once heard")
        var off = view("hello")
        off.micOn = false
        panel.show(off)
        XCTAssertFalse(panel.inputNamed, "a muted draft names no microphone")
    }

    func testTheLightBurnsOnlyWhileTheMicrophoneIsLive() {
        panel.show(view("", ghost: "x"))
        XCTAssertGreaterThan(panel.lightLength, 0)
        var off = view("x")
        off.micOn = false
        panel.show(off)
        XCTAssertEqual(panel.lightLength, 0)
        panel.show(view("x", editor: .normal))
        XCTAssertEqual(panel.lightLength, 0, "normal mode: the mic waits, the light is out")
    }

    /// The light is visual; VoiceOver hears the same fact in words.
    func testTheLightSaysItsStateToVoiceOver() {
        let light = VoiceLight(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        XCTAssertEqual(light.accessibilityValue() as? String, "off")
        light.show(level: 0.4)
        XCTAssertEqual(light.accessibilityValue() as? String, "listening")
        XCTAssertEqual(light.accessibilityLabel(), "Microphone")
        light.show(level: nil)
        XCTAssertEqual(light.accessibilityValue() as? String, "off")
    }

    /// Three states, three looks: out while turned off, a grey floor
    /// while wanted and not hearing (opening or failed), the accent once
    /// it hears.
    func testTheLightWaitsInGreyWhileTheMicrophoneOpens() {
        var opening = view("")
        opening = DraftView(buffer: opening.buffer, mode: .insert, editor: .insert, speech: nil,
                            micOn: true, destination: ("Ghostty", nil), replacing: false)
        panel.show(opening)
        XCTAssertEqual(panel.lightState, .waiting)
        XCTAssertEqual(panel.lightLength, VoiceLight.floor, accuracy: 0.001)
        var preparing = opening
        preparing = DraftView(buffer: opening.buffer, mode: .insert, editor: .insert,
                              speech: .preparing(progress: 0.4), micOn: true,
                              destination: ("Ghostty", nil), replacing: false)
        panel.show(preparing)
        XCTAssertEqual(panel.lightState, .waiting, "a model still arriving is waiting too")
        let failed = DraftView(buffer: opening.buffer, mode: .insert, editor: .insert,
                               speech: .failed("the microphone did not open"), micOn: true,
                               destination: ("Ghostty", nil), replacing: false)
        panel.show(failed)
        XCTAssertEqual(panel.lightState, .waiting, "failed is wanted and not heard: grey, the note says why")
        panel.show(view(""))
        if case .listening = panel.lightState {} else { XCTFail("heard: the accent") }
        var off = view("")
        off.micOn = false
        panel.show(off)
        XCTAssertEqual(panel.lightState, .off)
    }

    /// The window is the glass plus the shadow's margin; the glass lands
    /// where the draft has always stood.
    func testTheGlassStandsWhereTheDraftAlwaysStood() {
        panel.show(view(long))
        let screen = ActivePolicy.presentationFrame
        let glass = SoftShadow.inset(panel.panel.frame)
        XCTAssertEqual(glass, panel.frame, "the window is where the glass says")
        XCTAssertEqual(glass.minY, screen.minY + Grid.section, accuracy: 0.5)
        XCTAssertFalse(panel.panel.hasShadow, "the shadow is drawn, not the system's")
    }

    /// The shadow's margin is not a target: a click there belongs to the
    /// app beneath, the Dock's top edge among them.
    func testOnlyTheGlassTakesThePointer() {
        panel.show(view("hello"))
        let glass = panel.frame
        panel.gatePointer(at: NSPoint(x: glass.midX, y: glass.midY))
        XCTAssertTrue(panel.takesPointer)
        panel.gatePointer(at: NSPoint(x: glass.midX, y: glass.minY - 10))
        XCTAssertFalse(panel.takesPointer, "under the glass, in its shadow")
        panel.gatePointer(at: NSPoint(x: glass.maxX + 30, y: glass.midY))
        XCTAssertFalse(panel.takesPointer)
    }

    /// The fold is instant: the window is where the layout said the moment
    /// `show` returns, with no motion to wait for (design/05-motion.md).
    func testAFoldIsInstantAndEndsWhereTheLayoutSaid() {
        panel.show(view(long, ghost: "spoken"))
        let folded = panel.frame
        var open = view(long, editor: .normal)
        open.expanded = true
        panel.show(open)
        XCTAssertEqual(SoftShadow.inset(panel.panel.frame), panel.frame, "open, at once")
        XCTAssertGreaterThan(panel.frame.height, folded.height)
        XCTAssertEqual(MotionTests.animations(in: panel.panel.contentView), [], "and nothing is left running")
        panel.show(view(long, ghost: "spoken"))
        XCTAssertEqual(SoftShadow.inset(panel.panel.frame), panel.frame, "shut, at once")
        XCTAssertEqual(panel.frame.height, folded.height, accuracy: 0.5)
    }

    /// The input menu is drawn: the foot names the microphone, the card
    /// opens beside the draft (never over its words), marks the chosen
    /// one, and choosing reports the device and closes it.
    func testTheInputMenuIsDrawnBesideTheDraft() {
        var v = view("hello")
        v.inputs = ["MacBook Pro Microphone", "AirPods"]
        v.systemInput = "AirPods"
        v.chosenInput = "MacBook Pro Microphone"
        var picked: String?? = .none
        panel.onChooseInput = { picked = .some($0) }
        panel.show(v)
        XCTAssertEqual(panel.inputTitle, "MacBook Pro Microphone")
        panel.toggleInputMenu()
        let menu = panel.inputMenuForTests
        XCTAssertTrue(menu.isVisible)
        XCTAssertEqual(menu.titles, ["System (AirPods)", "MacBook Pro Microphone", "AirPods"])
        XCTAssertEqual(menu.currentTitle, "MacBook Pro Microphone")
        XCTAssertFalse(menu.frame.intersects(panel.frame), "beside the draft, never over its words")
        XCTAssertEqual(menu.frame.minY, panel.frame.minY, accuracy: 0.5, "level with the foot")
        menu.choose("System (AirPods)")
        XCTAssertEqual(picked, .some(nil), "System is the default: no device named")
        XCTAssertFalse(menu.isVisible)
        panel.toggleInputMenu()
        panel.hide()
        XCTAssertFalse(menu.isVisible, "the menu goes with the draft")
    }

    /// The cursor's own line is the window's last, wherever on the line
    /// the cursor stands: at its start (after ⇧⏎, `o`, `0`) the character
    /// before it belongs to the line above, and that once hid it.
    func testTheCursorsLineStaysInViewAtTheStartOfALine() {
        let lines = (1...8).map { "line \($0)" }.joined(separator: "\n")
        var buffer = Draft.Buffer(text: lines)
        buffer.setCursor(lines.count - "line 8".count)
        var v = DraftView(buffer: buffer, mode: .normal, editor: .normal,
                          speech: nil, destination: ("Ghostty", nil), replacing: false)
        v.micOn = false
        panel.show(v)
        XCTAssertTrue(lineOfCaretIsVisible(), "the cursor at the start of the last line")
        var trailing = Draft.Buffer(text: lines + "\n")
        trailing.setCursor(trailing.count)
        var t = DraftView(buffer: trailing, mode: .insert, editor: .insert,
                          speech: nil, destination: ("Ghostty", nil), replacing: false)
        t.micOn = false
        panel.show(t)
        XCTAssertTrue(lineOfCaretIsVisible(), "after ⇧⏎, the empty line the caret stands on")
        XCTAssertEqual(visibleLines().cut, 0)
    }

    private func lineOfCaretIsVisible() -> Bool {
        let clip = panel.textView.enclosingScrollView!.contentView
        // The caret and the scroll view are both placed in the panel's
        // root, so their frames compare directly.
        let scroll = panel.textFrame
        return panel.caretFrame.minY >= scroll.minY - 0.5 && panel.caretFrame.maxY <= scroll.maxY + 0.5
            && clip.bounds.height > 0
    }

    /// After `zo` then `zc` the glass shows the last lines again, not the
    /// first: the scroll is laid out for the glass as it now stands.
    func testFoldingBackShowsTheLastLines() {
        var open = view(long)
        open.expanded = true
        panel.show(view(long, ghost: "x"))
        panel.show(open)
        panel.show(view(long))
        let clip = panel.textView.enclosingScrollView!.contentView
        XCTAssertGreaterThan(clip.bounds.minY, 0, "scrolled to the end, not the top")
        XCTAssertEqual(visibleLines().cut, 0)
        XCTAssertTrue(lineOfCaretIsVisible())
    }

    /// Speaking over a selection is the microphone writing, so the light
    /// says listening, not off.
    func testTheLightBurnsWhileSpeakingOverASelection() {
        var buffer = Draft.Buffer(text: "change these words")
        buffer.setCursor(7)
        var v = DraftView(buffer: buffer, mode: .normal, editor: .visual(line: false),
                          selection: 7..<12, speech: .listening(input: "Mic"), input: "Mic",
                          level: 0.5, destination: ("Ghostty", nil), replacing: false)
        v.micOn = true
        panel.show(v)
        if case .listening = panel.lightState {} else { XCTFail("over a selection the mic writes: lit") }
    }

    /// A draft as wide as the screen leaves no room beside it: the menu
    /// stands above it, on screen.
    func testTheInputMenuStaysOnScreenBesideAWideDraft() {
        let screen = ActivePolicy.presentationFrame
        var v = view("let value = compute(input)")
        v.inputs = ["MacBook Pro Microphone", "CalDigit Thunderbolt 3 Audio"]
        v.width = screen.width - 44
        panel.show(v)
        panel.toggleInputMenu()
        let menu = panel.inputMenuForTests.frame
        XCTAssertTrue(screen.contains(menu), "on screen: \(menu) in \(screen)")
        XCTAssertFalse(menu.intersects(panel.frame), "and never over the words")
    }

    func testASilentRoomStillShowsTheFloor() {
        var quiet = view("")
        quiet.level = 0
        panel.show(quiet)
        XCTAssertEqual(panel.lightLength, VoiceLight.floor, accuracy: 0.001)
    }

    /// Under Reduce Motion the light holds still at its whole length: it
    /// still says listening, and nothing moves.
    func testReduceMotionHoldsTheLightWhole() {
        Accessibility.reduceMotion = { true }
        var quiet = view("")
        quiet.level = 0
        panel.show(quiet)
        XCTAssertEqual(panel.lightLength, 1, accuracy: 0.001)
    }

    // MARK: - The window holds still

    private func numbered(_ count: Int) -> String { (1...count).map { "line \($0)" }.joined(separator: "\n") }

    /// A silent insert-mode view of `count` numbered lines with the cursor at
    /// the start of line `line`, one-based.
    private func standing(on line: Int, of count: Int = 12) -> DraftView {
        var buffer = Draft.Buffer(text: numbered(count))
        buffer.setCursor(buffer.lineStartOfLine(line - 1))
        var view = DraftView(buffer: buffer, mode: .insert, editor: .insert, speech: nil,
                             destination: ("Ghostty", nil), replacing: false)
        view.style = .standard
        return view
    }

    /// Where the layout puts the top of a line, one-based.
    private func top(ofLine line: Int) -> CGFloat {
        var tops: [CGFloat] = []
        let layout = panel.textView.layoutManager!
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
            rect, _, _, _, _ in tops.append(rect.minY)
        }
        return tops[line - 1]
    }

    /// The fold ended on the cursor's line every time, so clicking the top
    /// visible line scrolled the text three lines under the pointer. The
    /// window now stays where it stood while the cursor is inside it.
    func testAMoveInsideTheWindowLeavesItWhereItStood() {
        panel.show(standing(on: 12))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 9), accuracy: 0.5, "ends on the cursor's line")
        panel.show(standing(on: 9))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 9), accuracy: 0.5, "the top line, and nothing moved")
        panel.show(standing(on: 10))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 9), accuracy: 0.5)
        XCTAssertEqual(visibleLines().cut, 0)
    }

    func testAMoveAboveTheWindowStartsItOnThatLineAndOneBelowEndsItThere() {
        panel.show(standing(on: 12))
        panel.show(standing(on: 5))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 5), accuracy: 0.5, "above: starts on the cursor's line")
        panel.show(standing(on: 7))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 5), accuracy: 0.5, "inside again: held")
        panel.show(standing(on: 10))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 7), accuracy: 0.5, "below: ends on the cursor's line")
    }

    /// The common case, and the reason the old rule was right for a long
    /// time: words arriving at the end always show the last four lines.
    func testTextArrivingAtTheEndStillShowsTheLastFourLines() {
        panel.show(standing(on: 12))
        for count in 13...15 {
            var view = standing(on: 1, of: count)
            var buffer = view.buffer
            buffer.moveEnd()
            view = DraftView(buffer: buffer, mode: .insert, editor: .insert, speech: nil,
                             destination: ("Ghostty", nil), replacing: false)
            panel.show(view)
            XCTAssertEqual(panel.textScrollOrigin, top(ofLine: count - 3), accuracy: 0.5, "\(count) lines")
        }
        XCTAssertEqual(visibleLines().whole, DraftPanel.compactLines)
    }

    func testAWindowThatIsNoLongerFullIsFoundAgainOnTheCursor() {
        panel.show(standing(on: 12))
        panel.show(standing(on: 4, of: 5))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 1), accuracy: 0.5,
                       "the old window began past where a full one can: it ends on the cursor's line")
        panel.show(standing(on: 5, of: 5))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 2), accuracy: 0.5, "and holds there")
    }

    func testOpeningThenFoldingFindsTheWindowAfresh() {
        panel.show(standing(on: 12))
        panel.show(standing(on: 10))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 9), accuracy: 0.5, "held while folded")
        var open = standing(on: 10)
        open.expanded = true
        panel.show(open)
        panel.show(standing(on: 10))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 7), accuracy: 0.5,
                       "folded again, it ends on the cursor's line like a first fold")
    }

    func testHidingForgetsTheWindow() {
        panel.show(standing(on: 12))
        panel.hide()
        panel.show(standing(on: 10))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 7), accuracy: 0.5)
    }

    /// A wheel may have moved the text since the last render. The press
    /// takes the window as the hand left it, so the line it lands on is
    /// the line it was over and the render after it does not take it back.
    func testTheWindowTheHandScrolledToIsAdoptedBeforeTheNextRender() {
        panel.show(standing(on: 12))
        let clip = panel.textView.enclosingScrollView!.contentView
        clip.scroll(to: NSPoint(x: 0, y: top(ofLine: 5)))
        panel.adoptVisibleWindow()
        panel.show(standing(on: 6))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 5), accuracy: 0.5,
                       "line 6 is inside the window the hand scrolled to: nothing moved")
    }

    func testWithoutAdoptingTheRenderTakesTheWindowBackToTheCursor() {
        panel.show(standing(on: 12))
        let clip = panel.textView.enclosingScrollView!.contentView
        clip.scroll(to: NSPoint(x: 0, y: top(ofLine: 5)))
        panel.show(standing(on: 6))
        XCTAssertEqual(panel.textScrollOrigin, top(ofLine: 6), accuracy: 0.5,
                       "the old window was lines 9 to 12, and line 6 is above it")
    }
}
