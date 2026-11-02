import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The cards Keep opens with are the cards the hand reads. The history is
/// polled every third of a second, so a copy made just before ⇧⌘V used to
/// land after the strip was drawn and move every card one place.
final class KeepOpeningTests: XCTestCase {
    private func copy(_ text: String) {
        let board = SystemEvents.pasteboard
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func testACopyMadeJustBeforeOpeningIsOnTheCardsFromTheFirstFrame() {
        let stage = Stage()
        for text in ["one", "two"] { stage.seedClip(text) }
        copy("fresh from the board")
        // No poll has run: the timer is not started and the clock is virtual.
        XCTAssertEqual(stage.clipboard.history.clips.count, 2)
        stage.openStrip()
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertEqual(stage.engine.strip.shownRecents.map(\.preview),
                       ["fresh from the board", "two", "one"],
                       "the copy stands on J as drawn, and nothing moves afterwards")
        stage.press("escape")
    }

    func testAnEmptyHistoryOpensOnACopyNotYetPolled() {
        let stage = Stage()
        copy("the very first copy")
        stage.openStrip()
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false), "not 'nothing copied yet'")
        XCTAssertEqual(stage.engine.strip.shownRecents.map(\.preview), ["the very first copy"])
        stage.press("escape")
    }

    func testNothingNewOnTheBoardLeavesTheCardsAsTheyWere() {
        let stage = Stage()
        for text in ["one", "two"] { stage.seedClip(text) }
        stage.clipboard.capture() // catches up with whatever the board held
        stage.openStrip()
        XCTAssertEqual(stage.engine.strip.shownRecents.map(\.preview), ["two", "one"])
        stage.press("escape")
    }
}
