import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The draft while speaking holds four whole lines, so the screen behind
/// stays in view; stopping to read opens the whole text, and it stays
/// open through typing until the voice comes back.
final class DraftFoldTests: XCTestCase {
    private var panel: DraftPanel!

    override func setUp() {
        super.setUp()
        panel = DraftPanel()
    }

    override func tearDown() {
        panel.hide()
        panel = nil
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

    func testEscapeOpensTheWholeTextAndTypingKeepsItOpen() {
        panel.show(view(long, ghost: "spoken"))
        let folded = panel.frame.height
        panel.show(view(long, editor: .normal))
        XCTAssertTrue(panel.expanded)
        XCTAssertGreaterThan(panel.frame.height, folded)
        panel.show(view(long + " typed"))
        XCTAssertTrue(panel.expanded, "back in insert, still open until the voice returns")
        panel.show(view(long, ghost: "spoken again"))
        XCTAssertFalse(panel.expanded, "speaking folds it")
        XCTAssertEqual(panel.frame.height, folded, accuracy: 0.5)
    }

    func testOpeningWithTextToReadOpensWhole() {
        panel.show(view(long))
        XCTAssertTrue(panel.expanded)
    }

    func testAShortDraftIsNotPaddedToFourLines() {
        panel.show(view("A few words", ghost: "and more"))
        XCTAssertLessThan(panel.frame.height, 160)
    }

    /// The input is named until it is heard, and again when it is not.
    func testTheInputIsNamedUntilItIsHeard() {
        panel.show(view(""))
        XCTAssertTrue(panel.inputNamed, "before the first word")
        panel.show(view("", ghost: "hello"))
        XCTAssertFalse(panel.inputNamed, "heard, so no caption")
        var silent = view("hello")
        silent.silent = true
        panel.show(silent)
        XCTAssertTrue(panel.inputNamed, "named again while nothing is heard")
        var other = view("hello", ghost: "")
        other.input = "AirPods"
        panel.show(other)
        XCTAssertTrue(panel.inputNamed, "a different microphone is news")
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

    func testASilentRoomStillShowsTheFloor() {
        var quiet = view("")
        quiet.level = 0
        panel.show(quiet)
        XCTAssertEqual(panel.lightLength, VoiceLight.floor, accuracy: 0.001)
    }
}
