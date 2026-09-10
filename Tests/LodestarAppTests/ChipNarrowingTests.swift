import AppKit
import XCTest
@testable import lodestar

/// A partial capital is seen on the chips it narrows: the letters already
/// typed wear the accent, and the chips that can no longer be picked are
/// gone. Nothing of it reaches the pill.
final class ChipNarrowingTests: XCTestCase {
    private func chip(_ label: String) -> SelectOverlay.Chip {
        SelectOverlay.Chip(label: label, frames: [CGRect(x: 0, y: 0, width: 10, height: 10)])
    }

    func testOnlyTheChipsTheTypedLettersCanCompleteRemain() {
        let chips = [chip("af"), chip("ag"), chip("b"), chip("sa")]
        XCTAssertEqual(SelectOverlay.narrowed(chips, typed: "a").map(\.label), ["af", "ag"])
        XCTAssertEqual(SelectOverlay.narrowed(chips, typed: "ag").map(\.label), ["ag"])
        XCTAssertEqual(SelectOverlay.narrowed(chips, typed: "").map(\.label), ["af", "ag", "b", "sa"], "nothing typed, nothing narrowed")
        XCTAssertEqual(SelectOverlay.narrowed(chips, typed: "z").map(\.label), [], "a letter no label starts with leaves nothing")
    }

    func testTheTypedLettersWearTheAccentOnTheChip() {
        let (_, label) = GlassChip.make("af", lit: 1)
        let string = label.attributedStringValue
        let first = string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let second = string.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(first, BarTheme.readableAccent, "the letter already typed")
        XCTAssertNotEqual(second, BarTheme.readableAccent, "the letter still to type")
        XCTAssertEqual(string.string, "AF")
    }

    func testAChipWithNothingTypedWearsNoAccent() {
        let (_, label) = GlassChip.make("af")
        let first = label.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(first, BarTheme.readableAccent)
    }

    func testLitNeverExceedsTheLabel() {
        let (_, label) = GlassChip.make("a", lit: 5)
        XCTAssertEqual(label.attributedStringValue.string, "A")
    }
}
