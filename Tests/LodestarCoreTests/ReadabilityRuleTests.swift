import XCTest
@testable import LodestarCore

/// The rules the eye is owed, asked without a screen.
final class ReadabilityRuleTests: XCTestCase {
    func testContrastRunsFromOneToTwentyOne() {
        let white = Readability.luminance(red: 1, green: 1, blue: 1)
        let black = Readability.luminance(red: 0, green: 0, blue: 0)
        XCTAssertEqual(Readability.contrast(white, black), 21, accuracy: 0.01)
        XCTAssertEqual(Readability.contrast(black, white), 21, accuracy: 0.01, "order does not matter")
        XCTAssertEqual(Readability.contrast(white, white), 1, accuracy: 0.001)
    }

    func testCharcoalAndPaperAreTheGroundsTheyClaimToBe() {
        let charcoal = Readability.luminance(red: 0.1, green: 0.1, blue: 0.1)
        let paper = Readability.luminance(red: 0.92, green: 0.92, blue: 0.92)
        let white = Readability.luminance(red: 1, green: 1, blue: 1)
        let ink = Readability.luminance(red: 0, green: 0, blue: 0)
        XCTAssertGreaterThan(Readability.contrast(white, charcoal), 13, "label on charcoal, as measured")
        XCTAssertGreaterThan(Readability.contrast(ink, paper), 15)
    }

    func testAMarkNeedsThreeToOne() {
        XCTAssertEqual(Readability.markFloor, 3)
        // Orange on charcoal clears it; orange on paper does not.
        let orange = Readability.luminance(red: 1, green: 0.58, blue: 0)
        XCTAssertGreaterThan(Readability.contrast(orange, Readability.luminance(red: 0.1, green: 0.1, blue: 0.1)), 3)
        XCTAssertLessThan(Readability.contrast(orange, Readability.luminance(red: 0.92, green: 0.92, blue: 0.92)), 3)
    }

    func testAFlashStaysAsLongAsItTakesToRead() {
        XCTAssertEqual(Readability.flashSeconds(for: "⌂ saved to the card"), 1.4, accuracy: 0.001, "short ones get the floor")
        XCTAssertEqual(Readability.flashSeconds(for: "press ⌘V to paste, this field blocks synthetic input"),
                       1.4 + Double(52 - 20) * 0.05, accuracy: 0.001)
        XCTAssertEqual(Readability.flashSeconds(for: String(repeating: "x", count: 400)), 4.0, "and never lingers")
        XCTAssertEqual(Readability.flashSeconds(for: ""), 1.4)
    }
}
