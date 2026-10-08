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

    private func face(_ mark: NSView) -> CGColor? { mark.subviews.first?.layer?.backgroundColor }

    func testAMarkTheHandHasBegunTypingLights() {
        XCTAssertEqual(face(KeyMark.key("af", lit: true)), BarTheme.accent.cgColor, "lit, as the key about to be pressed")
        XCTAssertEqual(face(KeyMark.key("af", lit: false)), BarTheme.markFill.cgColor, "nothing typed, a resting key")
    }

    func testALensTagCarriesTheKeyAndTheFix() {
        let tag = KeyMark.tag(letter: "j", word: "receive", lit: false)
        let words = tag.subviews.first?.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue) ?? []
        XCTAssertEqual(words, ["receive"])
        XCTAssertGreaterThan(tag.frame.height, KeyMark.height, "the key stands inside the tag")
    }

    func testAnUndisturbedTagStandsJustAboveItsWordWithNoLine() {
        let word = NSRect(x: 100, y: 200, width: 60, height: 18)
        let placed = SelectOverlay.place(NSSize(width: 90, height: 28), above: word, avoiding: [],
                                         within: NSRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(placed.frame.minY, word.maxY + 4)
        XCTAssertNil(placed.connectorX, "nothing moved, nothing to join")
    }

    func testATagThatWouldCoverAnotherStepsUpWithAHairlineClearOfIt() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let first = SelectOverlay.place(NSSize(width: 70, height: 28), above: NSRect(x: 80, y: 200, width: 26, height: 18),
                                        avoiding: [], within: bounds).frame
        let word = NSRect(x: 112, y: 200, width: 56, height: 18)
        let second = SelectOverlay.place(NSSize(width: 90, height: 28), above: word, avoiding: [first], within: bounds)
        XCTAssertFalse(second.frame.intersects(first), "stepped clear")
        XCTAssertGreaterThan(second.frame.minY, first.maxY)
        let x = try? XCTUnwrap(second.connectorX)
        XCTAssertGreaterThan(x ?? 0, first.maxX, "the line runs clear of the tag beneath")
        XCTAssertLessThanOrEqual(x ?? .infinity, word.maxX, "and still lands on its word")
    }
}
