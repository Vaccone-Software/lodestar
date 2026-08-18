import XCTest
@testable import LodestarCore

/// The select grammar: lowercase searches, capitals pick, two anchors make
/// a span, and the span is whatever lies between them — no direction
/// exists to get wrong. These tests are the contract that keeps typed text
/// meaning search and nothing else.
final class SelectCoreTests: XCTestCase {
    private func core(_ texts: [String], alphabet: String = "asdfghjkl") -> SelectCore {
        SelectCore(elements: texts.enumerated().map {
            SelectCore.Element(id: $0.offset, text: $0.element)
        }, alphabet: alphabet)
    }

    // MARK: - Searching

    func testLowercaseSearchesCaseInsensitively() {
        var c = core(["The Invoice total· the INVOICE again"])
        for ch in "invoice" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.query, "invoice")
        XCTAssertEqual(c.matches.count, 2, "case is folded; both invoices found")
        XCTAssertEqual(c.labels.count, 2)
    }

    func testShiftedSymbolsAndDigitsAreSearchCharacters() {
        // Labels are letters only, so ⇧4 can never be a pick — "$100"
        // types exactly as seen.
        var c = core(["pay $100 now"])
        _ = c.key("4", shift: true)
        _ = c.key("1", shift: false)
        XCTAssertEqual(c.query, "$1")
        XCTAssertEqual(c.matches.count, 1)
        XCTAssertEqual(c.matches.first?.range, NSRange(location: 4, length: 2))
    }

    func testSpaceSearchesAcrossWords() {
        var c = core(["one two· one three"])
        for key in ["o", "n", "e", "space", "t"] { _ = c.key(key, shift: false) }
        XCTAssertEqual(c.matches.count, 2, "phrases are addresses too")
    }

    func testMatchesSpanElementsInReadingOrder() {
        var c = core(["alpha beta", "beta gamma"])
        for ch in "beta" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.matches.map(\.element), [0, 1])
    }

    func testDisplayIsCappedButCountingContinues() {
        let text = Array(repeating: "ab", count: 80).joined(separator: " ")
        var c = core([text])
        _ = c.key("a", shift: false)
        _ = c.key("b", shift: false)
        XCTAssertEqual(c.matches.count, SelectCore.displayCap, "chips are not confetti")
        XCTAssertEqual(c.totalMatches, 80, "but the band can still say how many")
    }

    func testUnknownKeysMeanNothing() {
        var c = core(["text"])
        XCTAssertEqual(c.key("tab", shift: false), .none)
        XCTAssertEqual(c.key("left", shift: false), .none)
        XCTAssertEqual(c.query, "")
    }

    // MARK: - Picking

    func testCapitalAnchorsThenSecondCapitalSelects() {
        var c = core(["the quick brown fox jumps"])
        for ch in "quick" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.key("a", shift: true), .anchored, "first capital = start")
        XCTAssertEqual(c.query, "", "the query resets for the far end")
        for ch in "fox" { _ = c.key(String(ch), shift: false) }
        guard case .selected(let element, let range) = c.key("a", shift: true) else {
            return XCTFail("second capital must select")
        }
        XCTAssertEqual(element, 0)
        // start of "quick" (4) through end of "fox" (19).
        XCTAssertEqual(range, NSRange(location: 4, length: 15))
    }

    func testBackwardAnchorsNormalizeBecauseDirectionDoesNotExist() {
        var c = core(["the quick brown fox jumps"])
        for ch in "fox" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true)
        for ch in "quick" { _ = c.key(String(ch), shift: false) }
        guard case .selected(_, let range) = c.key("a", shift: true) else {
            return XCTFail()
        }
        XCTAssertEqual(range, NSRange(location: 4, length: 15),
                       "two anchors make a span; order of placement is nobody's business")
    }

    func testStageTwoConfinesItselfToTheAnchorsElement() {
        var c = core(["alpha beta", "beta gamma"])
        for ch in "gamma" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true) // anchored in element 1
        for ch in "beta" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.matches.map(\.element), [1],
                       "a span cannot cross elements, so element 0 makes no promises")
    }

    func testTwoLetterLabelsPickInTwoCapitals() {
        // Twelve matches on a nine-letter alphabet: labels go uniform pairs.
        let text = Array(repeating: "xy", count: 12).joined(separator: " ")
        var c = core([text], alphabet: "asd")
        _ = c.key("x", shift: false)
        _ = c.key("y", shift: false)
        XCTAssertTrue(c.labels.allSatisfy { $0.count == 2 })
        XCTAssertEqual(c.key("a", shift: true), .updated, "first capital narrows")
        XCTAssertEqual(c.typedLabel, "a")
        XCTAssertEqual(c.key("s", shift: true), .anchored, "second completes the label")
    }

    func testShiftOpensThePickAndPlainLettersFinishIt() {
        // Shift is the door, not a hold: once a label is underway, every
        // further letter can only be finishing it — labels are prefix-free.
        let text = Array(repeating: "xy", count: 12).joined(separator: " ")
        var c = core([text], alphabet: "asd")
        _ = c.key("x", shift: false)
        _ = c.key("y", shift: false)
        XCTAssertEqual(c.key("a", shift: true), .updated, "shift opens the pick")
        XCTAssertEqual(c.key("s", shift: false), .anchored,
                       "the second letter needs no shift")
        // And a symbol mid-pick abandons back to searching.
        var d = core([text], alphabet: "asd")
        _ = d.key("x", shift: false)
        _ = d.key("y", shift: false)
        _ = d.key("a", shift: true)
        XCTAssertEqual(d.key("1", shift: false), .updated)
        XCTAssertEqual(d.typedLabel, "", "the pending label yields to the query")
        XCTAssertEqual(d.query, "xy1")
    }

    func testASingleCharacterQueryMatchesOnlyStandaloneWords() {
        // "i" as a substring is confetti; "I" the word is a destination.
        var c = core(["I think it is illegal in Illinois"])
        _ = c.key("i", shift: false)
        XCTAssertEqual(c.matches.count, 1, "only the standalone I")
        XCTAssertEqual(c.matches.first?.range, NSRange(location: 0, length: 1))
        var d = core(["a cat ate a banana"])
        _ = d.key("a", shift: false)
        XCTAssertEqual(d.matches.count, 2, "the two standalone a words")
        // Two characters cross the threshold back into substring matching.
        var e = core(["I think it is illegal"])
        _ = e.key("i", shift: false)
        _ = e.key("t", shift: false)
        XCTAssertEqual(e.totalMatches, 1, "two characters return to substring matching")
    }

    func testCapitalMatchingNothingIsDropped() {
        var c = core(["only one match"])
        for ch in "only" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.labels, ["a"])
        XCTAssertEqual(c.key("z", shift: true), .none, "not a label — ignored, not typed")
        XCTAssertEqual(c.query, "only", "and the query is untouched")
    }

    func testTheSpanSnapsToWordBoundaries() {
        // Two typed characters name a word; they do not dissect it.
        var c = core(["the quick brown fox jumps"])
        for ch in "uick" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true)
        for ch in "fo" { _ = c.key(String(ch), shift: false) }
        guard case .selected(_, let range) = c.key("a", shift: true) else {
            return XCTFail()
        }
        XCTAssertEqual(range, NSRange(location: 4, length: 15),
                       "'uick' means from quick; 'fo' means through fox")
    }

    func testWordSnapTreatsATokenAsOneWord() {
        // Whitespace-delimited, so a URL or identifier comes out whole.
        var c = core(["see github.com/lodestar for more"])
        for ch in "hub" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true)
        for ch in "hub" { _ = c.key(String(ch), shift: false) }
        guard case .selected(_, let range) = c.key("a", shift: true) else {
            return XCTFail()
        }
        let text = "see github.com/lodestar for more" as NSString
        XCTAssertEqual(text.substring(with: range), "github.com/lodestar")
    }

    // MARK: - Backspace

    func testBackspaceWalksAllTheWayBack() {
        var c = core(["alpha beta"])
        for ch in "beta" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true)
        for ch in "al" { _ = c.key(String(ch), shift: false) }
        _ = c.backspace()
        _ = c.backspace()
        XCTAssertEqual(c.query, "")
        XCTAssertNotNil(c.anchor)
        _ = c.backspace()
        XCTAssertNil(c.anchor, "one more ⌫ from an empty second stage re-opens the start")
        XCTAssertEqual(c.backspace(), .none, "and the floor is quiet")
    }
}

/// The engine's side of the mode: entry on plain /, every key its own,
/// escape and lode verbs exit.
final class SelectEngineTests: XCTestCase {
    private var core = EngineCore()
    private var world = WorldStub()

    private func press(_ key: String, held: Bool = false, shift: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, world: world)
    }

    func testPlainSlashEntersSelectAndShiftSlashStaysCheat() {
        XCTAssertEqual(press("/", held: true), [.hideBars])
        XCTAssertEqual(core.state, .select)
        XCTAssertTrue(world.calls.contains("enterSelect"))

        var fresh = EngineCore()
        XCTAssertEqual(fresh.keyDown(key: "/", held: true, shift: true, world: world),
                       [.toggleCheat], "? is untouched")
    }

    func testEntryFailureFlashesAndStaysIdle() {
        world.selectEnterSucceeds = false
        let effects = press("/", held: true)
        XCTAssertEqual(effects, [.hideBars, .flash("✕ no focused window to select in")])
        XCTAssertEqual(core.state, .idle)
    }

    func testKeysAreSwallowedAndRoutedToTheWorld() {
        _ = press("/", held: true)
        XCTAssertEqual(press("a"), [], "swallowed — typed text never reaches the app")
        XCTAssertTrue(world.calls.contains("selectKey:a"))
        world.selectOutcomes["selectKey:Sa"] = .done
        XCTAssertEqual(press("a", shift: true), [.exitSelect])
        XCTAssertEqual(core.state, .idle, "a landed selection ends the mode")
    }

    func testEscapeAndBackspace() {
        _ = press("/", held: true)
        XCTAssertEqual(press("delete"), [.selectBackspace])
        XCTAssertEqual(press("escape"), [.exitSelect])
        XCTAssertEqual(core.state, .idle)
    }

    func testAnotherLodeVerbExitsAndExecutes() {
        _ = press("/", held: true)
        let effects = press("g", held: true)
        XCTAssertEqual(effects.first, .exitSelect, "the mode yields before the verb runs")
        XCTAssertEqual(core.state, .idle)
    }

    func testDisabledSlashPassesThrough() {
        core.disabledGestures = ["/"]
        XCTAssertEqual(press("/", held: true), [.passThrough])
        XCTAssertEqual(core.state, .idle)
    }
}
