import XCTest
@testable import lodestar

/// The pill's composition, read as pieces rather than pixels: two wings,
/// a center that is empty, a caret, or the hand's words, and a fold that
/// moves nothing.
final class ModePillTests: XCTestCase {
    private let icon = NSImage(size: NSSize(width: 16, height: 16))

    func testStandingIsTwoWingsAndNothingBetween() {
        let state = ModePill.State(mode: .scroll, app: "Slack", icon: icon, listening: false, text: nil)
        XCTAssertEqual(ModePill.layout(for: state),
                       [.symbol("arrow.up.and.down"), .modeWord("Scroll"), .appWord("Slack"), .appIcon])
    }

    func testAListeningLensStandsACaretInTheCenter() {
        let state = ModePill.State(mode: .click, app: "Brave", icon: icon, listening: true, text: nil)
        XCTAssertEqual(ModePill.layout(for: state),
                       [.symbol("cursorarrow.click.2"), .modeWord("Click"), .caret, .appWord("Brave"), .appIcon])
    }

    func testAnyTextFoldsBothWingsToTheirGlyphs() {
        let state = ModePill.State(mode: .select, app: "Ghostty", icon: icon, listening: true, text: "thr")
        XCTAssertEqual(ModePill.layout(for: state),
                       [.symbol("character.cursor.ibeam"), .text("thr"), .appIcon])
    }

    func testTheGlyphsNeverMoveBetweenStates() {
        let standing = ModePill.State(mode: .click, app: "Brave", icon: icon, listening: true, text: nil)
        let typing = ModePill.State(mode: .click, app: "Brave", icon: icon, listening: true, text: "a")
        XCTAssertEqual(ModePill.layout(for: standing).first, ModePill.layout(for: typing).first)
        XCTAssertEqual(ModePill.layout(for: standing).last, ModePill.layout(for: typing).last)
    }

    func testAnAnchoredWordRidesAheadOfTheFarEnd() {
        let waiting = ModePill.State(mode: .select, app: "Ghostty", icon: icon, listening: true, text: nil, anchored: "Threads")
        XCTAssertEqual(ModePill.layout(for: waiting),
                       [.symbol("character.cursor.ibeam"), .anchored("Threads"), .caret, .appIcon],
                       "the wings fold and the caret waits after the word already taken")
        let typing = ModePill.State(mode: .select, app: "Ghostty", icon: icon, listening: true, text: "fo", anchored: "Threads")
        XCTAssertEqual(ModePill.layout(for: typing),
                       [.symbol("character.cursor.ibeam"), .anchored("Threads"), .text("fo"), .appIcon])
    }

    func testADraggedPillComesBackWhereItWasLeft() {
        let pill = ModePill()
        let state = ModePill.State(mode: .scroll, app: "Slack", icon: icon, listening: false, text: nil)
        pill.show(state)
        let home = ModePill.home(for: pill.frame.size)
        pill.remember(origin: NSPoint(x: home.x + 40, y: home.y + 120))
        XCTAssertEqual(pill.offset.x, 40, accuracy: 0.5)
        XCTAssertEqual(pill.offset.y, 120, accuracy: 0.5)
        pill.hide()
        pill.show(state)
        XCTAssertEqual(pill.offset.y, 120, accuracy: 0.5, "the displacement outlives a hide")
        pill.hide()
    }

    func testAnAppWithoutAnIconKeepsItsName() {
        let state = ModePill.State(mode: .scroll, app: "Ghostty", icon: nil, listening: false, text: "word")
        XCTAssertEqual(ModePill.layout(for: state).last, .appWord("Ghostty"))
    }

    func testEveryDimensionIsTheHeightOverAPowerOfPhi() {
        let phi = ModePill.phi
        XCTAssertEqual(ModePill.radius, ModePill.height / (phi * phi), accuracy: 0.001)
        XCTAssertEqual(ModePill.inset, ModePill.height / phi, accuracy: 0.001)
        XCTAssertEqual(ModePill.wingGap, ModePill.height / phi, accuracy: 0.001)
        XCTAssertEqual(ModePill.wordGap, ModePill.height / (phi * phi * phi), accuracy: 0.001)
    }

    func testTheHandsWordsAreUprightAndLargerThanTheWings() {
        let traits = NSFontManager.shared.traits(of: ModePill.textFont)
        XCTAssertFalse(traits.contains(.italicFontMask), "the italic was tried and retired")
        XCTAssertGreaterThan(ModePill.textFont.pointSize, BarTheme.bodyFont.pointSize)
    }

    func testShowAndHideOnTheGlass() {
        let pill = ModePill()
        let state = ModePill.State(mode: .scroll, app: "Slack", icon: icon, listening: false, text: nil)
        pill.show(state)
        XCTAssertTrue(pill.isVisible)
        XCTAssertEqual(pill.state, state)
        pill.show(ModePill.State(mode: .scroll, app: "Slack", icon: icon, listening: false, text: "Threads"))
        XCTAssertEqual(pill.state?.text, "Threads")
        pill.hide()
        XCTAssertFalse(pill.isVisible)
        XCTAssertNil(pill.state)
    }
}
