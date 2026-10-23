import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A partial capital is seen on the chips it narrows: the letters already
/// typed are dimmed in the keys that stand, and the chips that can no
/// longer be picked are gone. Nothing of it reaches the pill.
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

    /// A hint is a name to type, not a key to find: its letters share one key.
    private func keys(_ mark: NSView) -> [Key] { mark.subviews.compactMap { $0 as? Key } }

    func testAHintIsOneKeyHoldingItsLettersSetTight() {
        let mark = KeyMark.key("afg")
        XCTAssertEqual(keys(mark).map(\.legend), ["afg"], "as typed: lowercase, one key")
        XCTAssertEqual(mark.frame.width, keys(mark)[0].width, "the hint is as wide as its key")
        XCTAssertEqual(keys(KeyMark.key("a"))[0].width, 24, "a single letter is square")
        XCTAssertTrue(keys(mark)[0].overContent)
    }

    func testAMarkTheHandHasBegunTypingKeepsTheKeyStandingAndQuietsTheTypedLetters() {
        let typed = keys(KeyMark.key("af", typed: "a"))[0], resting = keys(KeyMark.key("af"))[0]
        XCTAssertEqual(typed.state, .resting, "the key stands")
        XCTAssertEqual(typed.quietPrefix, 1, "its first letter is quiet")
        XCTAssertEqual(resting.quietPrefix, 0)
        XCTAssertEqual(typed.standing.faceColor, BarTheme.markFill.cgColor, "no accent: the same cap")
        XCTAssertEqual(typed.standing.faceColor, resting.standing.faceColor)
        XCTAssertEqual(typed.standing.sideColor, resting.standing.sideColor, "the side is the resting side")
        XCTAssertEqual(typed.standing.rimColor, resting.standing.rimColor, "and the rim")
        XCTAssertEqual(typed.standing.visibleSide, Ceramic.Side.control, "on its side, inside its frame")
    }

    func testTheLettersAlreadyTypedGoQuietAndTheRestKeepTheMarksInk() {
        let mark = keys(KeyMark.key("afg", typed: "af"))[0]
        XCTAssertEqual(mark.legend, "afg", "the label is whole, as typed")
        XCTAssertEqual(mark.legendInk(at: 0), BarTheme.secondaryColor, "typed, quiet")
        XCTAssertEqual(mark.legendInk(at: 1), BarTheme.secondaryColor)
        XCTAssertEqual(mark.legendInk(at: 2), BarTheme.ink, "still to press, at full strength")
        XCTAssertEqual(keys(KeyMark.key("af"))[0].legendInk(at: 0), BarTheme.ink, "nothing typed, nothing quiet")
        XCTAssertEqual(keys(KeyMark.key("af", typed: "AF"))[0].quietPrefix, 2, "typed compares without case")
        XCTAssertEqual(keys(KeyMark.key("af", typed: "k"))[0].quietPrefix, 0, "a prefix the label lacks quiets nothing")
    }

    func testTypingNeverChangesTheKeysSize() {
        XCTAssertEqual(KeyMark.key("afg", typed: "af").frame.size, KeyMark.key("afg").frame.size, "nothing moves")
        XCTAssertEqual(KeyMark.key("af", typed: "a").frame.size, KeyMark.key("af").frame.size)
        XCTAssertEqual(KeyMark.tag(letter: "af", word: "receive", typed: "a").frame.size,
                       KeyMark.tag(letter: "af", word: "receive").frame.size)
    }

    /// Contrast of ink over a fill, the ink's own alpha laid over the fill
    /// first: the caption grey is a translucent colour.
    private func contrast(_ text: NSColor, on fill: NSColor) -> Double {
        let f = fill.usingColorSpace(.sRGB)!
        let t = (text.usingColorSpace(.sRGB)!).withAlphaComponent(1)
        let alpha = text.usingColorSpace(.sRGB)!.alphaComponent
        let r = t.redComponent * alpha + f.redComponent * (1 - alpha)
        let g = t.greenComponent * alpha + f.greenComponent * (1 - alpha)
        let b = t.blueComponent * alpha + f.blueComponent * (1 - alpha)
        return Readability.contrast(
            Readability.luminance(red: r, green: g, blue: b),
            Readability.luminance(red: f.redComponent, green: f.greenComponent, blue: f.blueComponent))
    }

    /// The dim letters are still letters: read against the cap in both
    /// looks, they hold the contrast a caption needs.
    func testTheDimLettersStayReadableOnTheCapInBothLooks() {
        let app = NSApplication.shared
        let before = app.appearance
        defer { app.appearance = before }
        for look in [NSAppearance.Name.darkAqua, .aqua] {
            app.appearance = NSAppearance(named: look)
            NSAppearance(named: look)!.performAsCurrentDrawingAppearance {
                let dim = contrast(BarTheme.secondaryColor, on: BarTheme.markFill)
                let full = contrast(BarTheme.markLetter, on: BarTheme.markFill)
                XCTAssertGreaterThanOrEqual(dim, 4.5, "\(look.rawValue) dim letters")
                XCTAssertGreaterThan(full, dim, "\(look.rawValue) the rest stands out")
            }
        }
    }

    func testALensTagCarriesTheKeyAndTheFix() {
        let tag = KeyMark.tag(letter: "j", word: "receive")
        let words = tag.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
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
