import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// `lode ?` on a draft that has nowhere left to grow.
///
/// The draft stands 22pt off the bottom of the screen and grows upward
/// with its text, so a long dictation reaches the top and stops there.
/// Asking for the keys then cannot make the glass any taller: the room
/// has to come out of the text instead. The bug this pins was worse than
/// a crooked frame — the layout used to be corrected in the animation's
/// completion handler, and a frame animation whose target equals its
/// current value never runs, so AppKit never called it. The keys were
/// drawn straight over the last hundred points of the text and stayed
/// there until something else happened to re-render the panel.
final class DraftKeysCeilingTests: XCTestCase {
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

    private func view(_ text: String) -> DraftView {
        var buffer = Draft.Buffer(text: text)
        buffer.setCursor(buffer.count)
        var view = DraftView(buffer: buffer, mode: .insert,
                             speech: SpeechState.listening(input: "Mic"),
                             destination: ("Ghostty", nil), replacing: false)
        view.editor = Vim.Mode.insert
        view.micOn = true
        return view
    }

    /// Long enough to reach the top of any screen a Mac has.
    private var tall: String {
        Array(repeating: "The quick brown fox jumps over the lazy dog and keeps going.",
              count: 200).joined(separator: " ")
    }

    private var sections: [CheatSheet.Section] {
        HotkeyEngine.draftSections(editor: .insert, card: false)
    }

    /// Settle the animation without waiting on the wall for longer than
    /// it takes.
    private func settle(_ seconds: Double = 0.45) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.signal() }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    func testAFullDraftDoesNotGrowPastTheTopOfTheScreen() {
        let screen = ActivePolicy.presentationFrame
        panel.show(view(tall))
        let before = panel.frame
        XCTAssertLessThanOrEqual(before.maxY, screen.maxY)
        panel.showKeys(sections)
        settle()
        let after = panel.frame
        XCTAssertLessThanOrEqual(after.maxY, screen.maxY,
                                 "the glass may not run off the top to hold its keys")
        XCTAssertEqual(after.height, before.height, accuracy: 0.5,
                       "at the ceiling there is no room to take, so the text gives it instead")
    }

    /// The property that actually matters, held from the first frame
    /// rather than from the animation's end: the keys and the words
    /// never occupy the same points.
    func testTheKeysNeverDrawOverTheText() {
        panel.show(view(tall))
        panel.showKeys(sections)
        // Immediately — before any animation could have finished.
        XCTAssertGreaterThanOrEqual(panel.textFrame.minY, panel.keysFrame.maxY,
                                    "the text begins above the keys at the first frame")
        settle()
        XCTAssertGreaterThanOrEqual(panel.textFrame.minY, panel.keysFrame.maxY,
                                    "and is still above them when the motion has run")
    }

    /// A draft with room to grow takes it, which is the ordinary case and
    /// must not have been broken by fixing the other one.
    func testADraftWithRoomStillGrows() {
        panel.show(view("Two short lines of dictation, and nothing more."))
        let before = panel.frame.height
        panel.showKeys(sections)
        settle()
        XCTAssertGreaterThan(panel.frame.height, before + 100,
                             "the ordinary draft opens by the keys' whole band")
        XCTAssertGreaterThanOrEqual(panel.textFrame.minY, panel.keysFrame.maxY)
    }

    /// The text that no longer fits is scrolled, not lost, and the cursor
    /// stays in the window — a hand that asks for the keys mid-sentence
    /// must not lose its place.
    func testTheTextScrollsRatherThanDisappears() {
        panel.show(view(tall))
        panel.showKeys(sections)
        settle()
        XCTAssertTrue(panel.textOverflows, "more text than room means a scroller")
        XCTAssertGreaterThan(panel.textScrollOrigin, 0,
                             "the window onto the text has moved down to the cursor")
    }

    /// The keys are capped against the draft's own default width, and a
    /// draft can be narrower than that — the panel takes the screen's
    /// width when the screen is small. The columns must stay inside
    /// whatever glass they are actually in.
    func testTheKeysStayInsideANarrowGlass() {
        var narrow = view("short")
        narrow.width = 380
        panel.show(narrow)
        panel.showKeys(sections)
        settle()
        XCTAssertEqual(panel.frame.width, 380, accuracy: 0.5)
        XCTAssertLessThanOrEqual(panel.keysFrame.maxX, panel.frame.width,
                                 "the columns may not run out through the side of the glass")
    }

    /// The clip door is a draft that stands above the strip, so its
    /// ceiling is lower than the screen's by whatever the strip takes.
    func testTheClipDoorKeepsItsCeilingAboveTheStrip() {
        let screen = ActivePolicy.presentationFrame
        var above = view(tall)
        above.standsAbove = 220
        panel.show(above)
        panel.showKeys(HotkeyEngine.draftSections(editor: .insert, card: true))
        settle()
        XCTAssertLessThanOrEqual(panel.frame.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, 220,
                                    "the door stands above the strip, keys or no keys")
        XCTAssertGreaterThanOrEqual(panel.textFrame.minY, panel.keysFrame.maxY)
    }

    /// And it all comes back.
    func testTogglingBackRestoresTheLayout() {
        panel.show(view(tall))
        let closed = panel.frame
        let text = panel.textFrame
        panel.showKeys(sections)
        settle()
        panel.hideKeys()
        settle()
        XCTAssertEqual(panel.frame.height, closed.height, accuracy: 0.5)
        XCTAssertEqual(panel.textFrame.minY, text.minY, accuracy: 0.5)
        XCTAssertEqual(panel.keysFrame, .zero, "the keys are gone, not merely invisible")
    }
}
