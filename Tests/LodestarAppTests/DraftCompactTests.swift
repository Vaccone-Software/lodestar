import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The draft stands over the bottom of someone else's screen, so it
/// covers as little as it can: the text hugs its words down to one line,
/// and the foot steps away while the voice is heard and it has nothing
/// to say.
final class DraftCompactTests: XCTestCase {
    private var panel: DraftPanel!
    private var frame: NSRect?

    override func setUp() {
        super.setUp()
        frame = ActivePolicy.frameOverride
        ActivePolicy.frameOverride = Stage.screen
        panel = DraftPanel()
    }

    override func tearDown() {
        panel.hide()
        panel = nil
        ActivePolicy.frameOverride = frame
        super.tearDown()
    }

    private func view(_ text: String, speech: SpeechState = .listening(input: "Mic"),
                      micOn: Bool = true) -> DraftView {
        var buffer = Draft.Buffer(text: text)
        buffer.setCursor(buffer.count)
        var view = DraftView(buffer: buffer, mode: .insert, editor: .insert, speech: speech,
                             input: "Mic", level: 0.5, destination: ("Ghostty", nil), replacing: false)
        view.micOn = micOn
        return view
    }

    private var lineHeight: CGFloat {
        panel.textView.layoutManager!.defaultLineHeight(for: BarTheme.Role.body.font)
    }

    /// Hearing, with nothing to report, the draft is one line of text and
    /// its air: no foot, no slack under the words.
    func testAHearingDraftIsItsLineAndItsAir() {
        panel.show(view(""))
        XCTAssertFalse(panel.footShown, "the light says it hears; the foot has nothing to add")
        XCTAssertFalse(panel.inputNamed)
        XCTAssertEqual(panel.textFrame.height, lineHeight, accuracy: 0.5, "an empty draft is one line waiting")
        XCTAssertEqual(panel.frame.height, (Grid.part * 2 + lineHeight).rounded(.up), accuracy: 0.5)
        XCTAssertEqual(panel.textFrame.minY, Grid.part, accuracy: 0.5, "the same air under the words as over them")
    }

    /// The words grow the glass upward from where it stands.
    func testWordsGrowTheGlassUpward() {
        panel.show(view(""))
        let empty = panel.frame
        panel.show(view("One line.\nTwo lines."))
        XCTAssertEqual(panel.frame.minY, empty.minY, accuracy: 0.5, "the bottom edge stays put")
        XCTAssertGreaterThan(panel.frame.height, empty.height)
    }

    /// The foot returns the moment it has something to say, and the text
    /// stands on it.
    func testTheFootReturnsWithNews() {
        var silent = view("hello")
        silent.silent = true
        panel.show(silent)
        XCTAssertTrue(panel.footShown, "hearing nothing is news")
        XCTAssertEqual(panel.registerDetail, "hearing nothing on Mic")
        XCTAssertEqual(panel.textFrame.minY, 32, accuracy: 0.5, "the text stands on the foot")

        panel.show(view("hello", speech: .failed("the microphone did not open")))
        XCTAssertTrue(panel.footShown, "a failure is news")

        panel.show(view("hello", speech: .preparing(progress: nil)))
        XCTAssertTrue(panel.footShown, "not hearing yet")

        panel.show(view("hello", micOn: false))
        XCTAssertTrue(panel.footShown, "typing alone, the foot says where ⏎ lands")
        XCTAssertEqual(panel.registerText, "Ghostty")

        var finishing = view("hello")
        finishing.finishing = true
        panel.show(finishing)
        XCTAssertTrue(panel.footShown, "landing is news")

        var card = view("hello")
        card.card = .init(name: "Clip", icon: nil, detail: "")
        panel.show(card)
        XCTAssertTrue(panel.footShown, "a card names itself")

        panel.show(view("hello"))
        XCTAssertFalse(panel.footShown, "and steps away again once the news is gone")
    }

    /// Keys up stand on the foot, so the foot stands too.
    func testKeysBringTheFoot() {
        panel.show(view("hello"))
        panel.showKeys(HotkeyEngine.draftSections(style: .standard, editor: .insert, card: false))
        XCTAssertTrue(panel.footShown)
        XCTAssertGreaterThanOrEqual(panel.textFrame.minY, panel.keysFrame.maxY)
    }

    /// A line of prose holds the reading measure, about 66 characters, in
    /// either face: the sans of Standard and the mono of Vim.
    func testALineOfProseHoldsTheReadingMeasure() {
        let prose = Array(repeating: "The flex container has a gap of twelve but the cards still touch, so something is overriding it.",
                          count: 4).joined(separator: " ")
        for style in [Draft.EditingStyle.standard, .vim] {
            var shown = view(prose)
            shown.style = style
            panel.show(shown)
            XCTAssertEqual(panel.frame.width, DraftPanel.readingWidth(for: shown.role), accuracy: 0.5)
            let layout = panel.textView.layoutManager!
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &range)
            XCTAssertTrue((55...75).contains(range.length), "\(style): \(range.length) characters on the first line")
        }
    }

    /// The glass stands a group's air off the screen's edge.
    func testTheGlassStandsAGroupOffTheEdge() {
        panel.show(view("hello"))
        XCTAssertEqual(panel.frame.minY, ActivePolicy.presentationFrame.minY + Grid.group, accuracy: 0.5)
    }
}
