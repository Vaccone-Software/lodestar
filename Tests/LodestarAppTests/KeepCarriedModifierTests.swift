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
}
