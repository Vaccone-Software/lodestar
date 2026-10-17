import XCTest
@testable import lodestar
@testable import LodestarCore

/// The strip redraws on every key, and a key that only moves the selection
/// shows the same cards: they are not searched for again until the history,
/// the source or the words change.
final class StripRenderCacheTests: XCTestCase {
    func testMovingTheSelectionDoesNotSearchAgain() {
        let stage = Stage()
        for text in ["build one", "build two", "build three", "unrelated"] { stage.seedClip(text) }
        stage.openStrip()
        stage.press("/")
        stage.press("b")
        let engine = stage.engine
        let searched = engine.stripSearches
        stage.press("down")
        stage.press("down")
        stage.press("up")
        XCTAssertEqual(engine.stripSearches, searched, "three redraws, the same cards")
        XCTAssertEqual(engine.strip.shownRecents.map(\.preview), ["build three", "build two", "build one"])

        stage.press("u")
        XCTAssertEqual(engine.stripSearches, searched + 1, "another letter is another search")
        XCTAssertEqual(engine.strip.shownRecents.map(\.preview), ["build three", "build two", "build one"],
                       "bu: all three builds, tied, so newest first")

        let before = engine.stripSearches
        stage.seedClip("build four")
        stage.clipboard.onCapture?()
        XCTAssertEqual(engine.stripSearches, before + 1, "a copy landing is a change")
        XCTAssertEqual(engine.strip.shownRecents.first?.preview, "build four")
        stage.press("escape")
        stage.press("escape")
    }
}
