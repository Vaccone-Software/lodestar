import XCTest
@testable import LodestarCore

/// Commit-on-unique: a search narrowed to exactly one match picks it
/// without the capital, because a keystroke whose only legal meaning is
/// confirmation carries no information. The hand is usually mid-word when
/// that fires, so the word's unclaimed tail is absorbed as confirmation —
/// the swallow is what keeps planned typing from polluting the far end's
/// search, and these tests are its contract.
final class SelectCommitTests: XCTestCase {
    private func auto(_ texts: [String]) -> SelectCore {
        SelectCore(elements: texts.enumerated().map {
            SelectCore.Element(id: $0.offset, text: $0.element)
        }, alphabet: "asdfghjkl", autoAnchor: true)
    }

    private func type(_ core: inout SelectCore, _ text: String) -> SelectCore.Effect {
        var last = SelectCore.Effect.none
        for ch in text { last = core.key(String(ch), shift: false) }
        return last
    }

    // MARK: - The start anchor

    func testUniqueSearchAnchorsWithoutTheCapital() {
        var c = auto(["the configuration file", "plain words here"])
        let effect = type(&c, "co")
        XCTAssertEqual(effect, .anchored, "one match on screen is the pick")
        XCTAssertNotNil(c.anchor)
        XCTAssertEqual(c.query, "", "the far end's search starts clean")
    }

    func testAutoAnchorSnapsToTheWholeWord() {
        var c = auto(["the configuration file", "plain words here"])
        _ = type(&c, "co")
        guard let anchor = c.anchor else { return XCTFail("no anchor") }
        let text = "the configuration file" as NSString
        XCTAssertEqual(text.substring(with: anchor.range), "configuration",
                       "two characters name a word, they do not dissect it")
    }

    func testContinuationLettersAreAbsorbed() {
        var c = auto(["the configuration file", "plain words here"])
        _ = type(&c, "co")
        // The hand was typing "config"; the tail is confirmation.
        _ = type(&c, "nfig")
        XCTAssertEqual(c.query, "", "the word's own letters extend nothing")
        XCTAssertNotNil(c.anchor, "and disturb nothing")
    }

    func testTheFirstForeignLetterStartsTheEndSearch() {
        var c = auto(["the configuration file", "plain words here"])
        _ = type(&c, "conf")
        _ = type(&c, "w")
        XCTAssertEqual(c.query, "w",
                       "a letter that is not the word's next one is new intent, whole")
    }

    func testAnExhaustedContinuationStopsAbsorbing() {
        var c = auto(["it co none nano", "plain words here"])
        _ = type(&c, "co")
        XCTAssertEqual(c.key("n", shift: false), .updated)
        XCTAssertEqual(c.query, "n", "a finished word has nothing left to confirm")
    }

    func testContinuationFoldsCaseAndConfusions() {
        // OCR stored "va1ue"; the hand types "value". The l confirms the 1
        // the same way a search for it would have found it.
        var c = auto(["pay va1ue now", "other stuff"])
        _ = type(&c, "va")
        XCTAssertNotNil(c.anchor)
        _ = type(&c, "lue")
        XCTAssertEqual(c.query, "", "the fold runs on both sides of the confirmation")
    }

    func testBackspaceDropsTheContinuation() {
        var c = auto(["the configuration file", "plain words here"])
        _ = type(&c, "co")
        _ = c.backspace()
        _ = type(&c, "n")
        XCTAssertEqual(c.query, "n",
                       "⌫ discards the invisible bookkeeping and acts on what the eye sees")
    }

    // MARK: - The end anchor

    func testEndAnchorCompletesItself() {
        var c = auto(["alpha configuration done", "bravo words zebra"])
        _ = type(&c, "co")
        let effect = type(&c, "ze")
        guard case .selected(let pieces) = effect else {
            return XCTFail("a unique far end completes the span, got \(effect)")
        }
        XCTAssertEqual(pieces.count, 2, "the span crosses to the second element")
    }

    func testACompletedSpanHandsOutTheEndWordsTail() {
        var c = auto(["alpha configuration done", "bravo words zebra"])
        _ = type(&c, "co")
        _ = type(&c, "ze")
        guard var tail = c.lastAutoContinuation else {
            return XCTFail("the end word's tail travels with the span")
        }
        XCTAssertTrue(tail.consume("b"))
        XCTAssertTrue(tail.consume("r"))
        XCTAssertTrue(tail.consume("a"))
        XCTAssertTrue(tail.exhausted)
        XCTAssertFalse(tail.consume("q"), "a foreign letter is never eaten")
    }

    func testACapitalPickHandsOutNoTail() {
        var c = auto(["alpha configuration done", "bravo zebra zebra"])
        _ = type(&c, "co")
        _ = type(&c, "zebra")
        XCTAssertEqual(c.matches.count, 2, "two zebras — nothing is unique")
        guard case .selected = c.key("a", shift: true) else {
            return XCTFail("the capital completes the span")
        }
        XCTAssertNil(c.lastAutoContinuation,
                     "a deliberate capital was watched; there is no tail to protect")
    }

    // MARK: - The doors that must not have it

    func testDefaultCoreNeverAutoAnchors() {
        var c = SelectCore(elements: [.init(id: 0, text: "the configuration file")],
                           alphabet: "asdfghjkl")
        let effect = type(&c, "co")
        XCTAssertEqual(effect, .updated)
        XCTAssertNil(c.anchor, "the click door picks only on a capital — a pick is a click")
    }

    func testReplayNeverAutoAnchors() {
        var c = auto(["the configuration file", "plain words here"])
        _ = c.key("c", shift: false, allowAutoAnchor: false)
        let effect = c.key("o", shift: false, allowAutoAnchor: false)
        XCTAssertEqual(effect, .updated)
        XCTAssertNil(c.anchor,
                     "keys buffered against a partial world commit nothing by themselves")
    }

    func testSeedNeverAutoAnchors() {
        var c = auto(["the configuration file", "plain words here"])
        c.seed(query: "co")
        XCTAssertNil(c.anchor,
                     "a world that just changed shape is when momentary uniqueness means least")
        XCTAssertEqual(c.matches.count, 1, "the search itself still lands")
    }

    func testManualPickStillWorksWithAutoOn() {
        var c = auto(["one alpha two alpha", "three alpha"])
        _ = type(&c, "alpha")
        XCTAssertEqual(c.matches.count, 3, "no uniqueness, no auto")
        XCTAssertNil(c.anchor)
        _ = c.key("a", shift: true)
        XCTAssertNotNil(c.anchor, "the capital picks exactly as it always did")
    }
}
