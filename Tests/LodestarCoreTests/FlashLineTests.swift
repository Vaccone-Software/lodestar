import XCTest
@testable import LodestarCore

/// A flash's fact and way, and the keys inside them, read off the one
/// string a call site writes.
final class FlashLineTests: XCTestCase {
    func testTheWayFollowsTheFirstNewline() {
        XCTAssertEqual(FlashLine.split("✕ A layout holds nine windows\n[[] or []] replaces one").fact,
                       "✕ A layout holds nine windows")
        XCTAssertEqual(FlashLine.split("✕ A layout holds nine windows\n[[] or []] replaces one").way,
                       "[[] or []] replaces one")
        XCTAssertNil(FlashLine.split("⟲ Layout redone").way)
    }

    func testKeysNextToEachOtherAreOneRun() {
        XCTAssertEqual(FlashLine.parts("[⌘][V] pastes it"), [.keys(["⌘", "V"]), .words("pastes it")])
        XCTAssertEqual(FlashLine.parts("[⌘][1] to [⌘][4] replaces one"),
                       [.keys(["⌘", "1"]), .words("to"), .keys(["⌘", "4"]), .words("replaces one")])
        XCTAssertEqual(FlashLine.parts("Until [lode] [J] [K] is in your hands"),
                       [.words("Until"), .keys(["lode", "J", "K"]), .words("is in your hands")])
    }

    func testBracketKeysAreKeys() {
        XCTAssertEqual(FlashLine.parts("[[] or []] replaces the focused one"),
                       [.keys(["["]), .words("or"), .keys(["]"]), .words("replaces the focused one")])
    }

    func testALineWithNoKeysIsWords() {
        XCTAssertEqual(FlashLine.parts("Layout redone"), [.words("Layout redone")])
        XCTAssertEqual(FlashLine.plain("[⇧] and a letter selects"), "⇧ and a letter selects")
    }
}
