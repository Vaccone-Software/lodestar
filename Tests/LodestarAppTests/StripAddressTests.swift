import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The strip's addresses are keymaps, so they are drawn as the keys they
/// are: the shared cap on every card and every pin.
final class StripAddressTests: XCTestCase {
    func testEveryCardWearsTheSharedCap() {
        let stage = Stage()
        stage.seedClip("one")
        stage.seedClip("two")
        stage.openStrip()
        for card in stage.engine.strip.shownCards.values {
            let cap = card.subviews.first { $0 is Keycaps.CapView }
            XCTAssertNotNil(cap, "the address is a key")
            XCTAssertEqual(cap?.frame.height, BarTheme.chipHeight)
        }
        stage.press("escape")
    }

    func testTheBandIsTheHandsFace() {
        XCTAssertTrue(BarTheme.stripInputFont.isFixedPitch)
    }
}
