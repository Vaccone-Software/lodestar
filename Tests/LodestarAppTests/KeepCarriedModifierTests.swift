import XCTest
@testable import lodestar
@testable import LodestarCore

/// Keep opens on ⇧⌘V with the hand still on its keys. A modifier still
/// down from that gesture is not a choice made over the cards: they are
/// drawn, and act, as if it were not held, until it has been let go and
/// pressed again.
final class KeepCarriedModifierTests: XCTestCase {
    private func opened(_ flags: CGEventFlags = [.maskShift, .maskCommand]) -> Stage {
        let stage = Stage()
        for text in ["one", "two"] { stage.seedClip(text) }
        stage.chord("v", flags)
        return stage
    }

    private func close(_ stage: Stage) {
        stage.modifiers([])
        stage.press("escape")
    }

    func testShiftStillDownFromOpeningShowsNothingAndPastesPlain() {
        let stage = opened()
        XCTAssertEqual(stage.engine.strip.shownHeld, .none)
        // ⌘ comes up first, as it does: shift is all that is left down.
        stage.modifiers(.maskShift)
        XCTAssertEqual(stage.engine.strip.shownHeld, .none, "the opening's shift is not held over the cards")
        XCTAssertTrue(stage.chord("return", .maskShift))
        XCTAssertEqual(stage.stripPastes, 1)
        XCTAssertEqual(stage.lastPaste?.row, "plain", "what is shown is what the key does")
    }

    func testShiftCountsOnceReleasedAndPressedAgain() {
        let stage = opened()
        stage.modifiers(.maskShift)
        stage.modifiers([])
        XCTAssertEqual(stage.engine.strip.shownHeld, .none)
        stage.modifiers(.maskShift)
        XCTAssertEqual(stage.engine.strip.shownHeld, .shift, "pressed again, it counts")
        XCTAssertTrue(stage.chord("return", .maskShift))
        XCTAssertEqual(stage.lastPaste?.row, "native")
    }

    func testOptionStillDownFromOpeningDoesNotCountEither() {
        let stage = opened([.maskShift, .maskCommand, .maskAlternate])
        stage.modifiers([.maskShift, .maskAlternate])
        XCTAssertEqual(stage.engine.strip.shownHeld, .none)
        stage.modifiers(.maskAlternate)
        XCTAssertEqual(stage.engine.strip.shownHeld, .none, "shift let go, option still the opening's")
        stage.modifiers([])
        stage.modifiers(.maskAlternate)
        XCTAssertEqual(stage.engine.strip.shownHeld, .option)
        close(stage)
    }

    func testAModifierPressedAfterOpeningCountsAtOnce() {
        let stage = opened()
        stage.modifiers(.maskShift)
        stage.modifiers([.maskShift, .maskControl])
        XCTAssertEqual(stage.engine.strip.shownHeld, .control, "control is new; shift is still the opening's")
        stage.modifiers(.maskShift)
        XCTAssertEqual(stage.engine.strip.shownHeld, .none)
        stage.modifiers([.maskShift, .maskAlternate])
        XCTAssertEqual(stage.engine.strip.shownHeld, .option)
        close(stage)
    }

    func testWhatOneOpeningCarriedIsNotCarriedIntoTheNext() {
        let stage = opened([.maskShift, .maskCommand, .maskAlternate])
        stage.modifiers([.maskShift, .maskAlternate])
        stage.press("escape")
        stage.modifiers([])
        stage.chord("v", [.maskShift, .maskCommand])
        stage.modifiers(.maskShift)
        XCTAssertEqual(stage.engine.strip.shownHeld, .none)
        stage.modifiers([.maskShift, .maskAlternate])
        XCTAssertEqual(stage.engine.strip.shownHeld, .option, "this opening carried only shift")
        close(stage)
    }

    /// ⌘ is the one the opening always leaves down, and its finger is the
    /// slowest to lift: a letter struck before it has pastes that card
    /// rather than opening its actions.
    func testCommandStillDownFromOpeningPastesTheLetterAndDoesNotOpenItsActions() {
        let stage = opened()
        XCTAssertEqual(stage.engine.strip.shownHeld, .none)
        XCTAssertTrue(stage.chord("j", [.maskShift, .maskCommand]))
        XCTAssertEqual(stage.stripPastes, 1, "J pasted")
        XCTAssertEqual(stage.lastPaste?.action, "pasted")
        XCTAssertEqual(stage.lastPaste?.row, "plain", "not native: the opening's shift does not count either")
        XCTAssertEqual(stage.engine.grammarState, .idle, "and the actions never opened")
    }

    /// A key that names no card was closing the strip and being swallowed
    /// while ⌘ was still the opening's; now it is an ordinary dead key.
    func testCommandStillDownFromOpeningDoesNotMakeAnyKeyAShortcut() {
        let stage = opened()
        stage.modifiers(.maskCommand)
        XCTAssertTrue(stage.chord("w", .maskCommand))
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false), "a dead key, not a closing one")
        close(stage)
    }

    func testCommandLetGoAndPressedAgainOpensTheActions() {
        let stage = opened()
        stage.modifiers(.maskCommand)
        stage.modifiers([])
        XCTAssertEqual(stage.engine.strip.shownHeld, .none)
        stage.modifiers(.maskCommand)
        XCTAssertTrue(stage.chord("j", .maskCommand))
        XCTAssertEqual(stage.engine.grammarState, .pastePanel(searching: false), "pressed again, it counts")
        XCTAssertEqual(stage.stripPastes, 0)
        close(stage)
    }

    /// With ⌘ carried and ⇧ struck fresh, the cards wear the form ⇧ asks
    /// for: ⌘ no longer hides it as a held ⌘ would.
    func testShiftPressedOverACarriedCommandShowsAtOnce() {
        let stage = opened()
        stage.modifiers(.maskCommand)
        XCTAssertEqual(stage.engine.strip.shownHeld, .none)
        stage.modifiers([.maskCommand, .maskShift])
        XCTAssertEqual(stage.engine.strip.shownHeld, .shift)
        close(stage)
    }
}
