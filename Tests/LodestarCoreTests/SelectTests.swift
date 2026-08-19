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

    /// The pieces a landed span covers, or nil if the effect was not one.
    private func pieces(_ effect: SelectCore.Effect) -> [SelectCore.Match]? {
        guard case .selected(let pieces) = effect else { return nil }
        return pieces
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

    func testTheChipWindowSlidesToTheAnchor() {
        // Forty matches and an anchor past all of them: chips belong where
        // the work is, not at the top of the page.
        let text = Array(repeating: "xy", count: 40).joined(separator: " ") + " target"
        var c = core([text])
        for ch in "target" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.key("a", shift: true), .anchored)
        for ch in "xy" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.matches.count, SelectCore.displayCap)
        XCTAssertEqual(c.totalMatches, 40, "and the band still counts them all")
        XCTAssertEqual(c.matches.first?.range.location, 30, "the eleventh xy, not the first")
        XCTAssertEqual(c.matches.last?.range.location, 117, "through the fortieth")
    }

    func testWithNoAnchorTheChipsStartAtTheTop() {
        let text = Array(repeating: "xy", count: 40).joined(separator: " ")
        var c = core([text])
        for ch in "xy" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.matches.first?.range.location, 0, "stage one reads from the top")
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
        guard let span = pieces(c.key("a", shift: true)), span.count == 1 else {
            return XCTFail("second capital must select")
        }
        XCTAssertEqual(span[0].element, 0)
        // start of "quick" (4) through end of "fox" (19).
        XCTAssertEqual(span[0].range, NSRange(location: 4, length: 15))
    }

    func testBackwardAnchorsNormalizeBecauseDirectionDoesNotExist() {
        var c = core(["the quick brown fox jumps"])
        for ch in "fox" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true)
        for ch in "quick" { _ = c.key(String(ch), shift: false) }
        guard let span = pieces(c.key("a", shift: true)), span.count == 1 else {
            return XCTFail()
        }
        XCTAssertEqual(span[0].range, NSRange(location: 4, length: 15),
                       "two anchors make a span; order of placement is nobody's business")
    }

    func testStageTwoStillSearchesEverything() {
        // The far end lives wherever the eye finds it. Text arrives cut
        // into per-line runs constantly — a diff, a chat log, most of any
        // web page — and confining stage two to the anchor's own run made
        // "the line you started on" an invisible wall.
        var c = core(["alpha beta", "beta gamma"])
        for ch in "gamma" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true) // anchored in element 1
        for ch in "beta" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.matches.map(\.element), [0, 1],
                       "both elements answer; a span may cross them")
    }

    func testASpanAcrossElementsTakesTailWholesAndHead() {
        var c = core(["first line here", "middle line", "last line there"])
        for ch in "here" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true) // anchor at "here", end of element 0
        for ch in "last" { _ = c.key(String(ch), shift: false) }
        guard let span = pieces(c.key("a", shift: true)) else { return XCTFail() }
        XCTAssertEqual(span.map(\.element), [0, 1, 2],
                       "everything between, in document order")
        let texts = span.map { piece -> String in
            let text = ["first line here", "middle line", "last line there"][piece.element]
            return (text as NSString).substring(with: piece.range)
        }
        XCTAssertEqual(texts, ["here", "middle line", "last"],
                       "tail of the first, the middle whole, head of the last")
    }

    func testACrossElementSpanNormalizesLikeAnyOther() {
        var c = core(["first line here", "last line there"])
        for ch in "there" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true) // anchored in the LAST element
        for ch in "first" { _ = c.key(String(ch), shift: false) }
        guard let span = pieces(c.key("a", shift: true)) else { return XCTFail() }
        XCTAssertEqual(span.map(\.element), [0, 1], "document order, not typing order")
        XCTAssertEqual(span[0].range, NSRange(location: 0, length: 15))
        XCTAssertEqual(span[1].range, NSRange(location: 0, length: 15))
    }

    func testEmptyElementsBetweenAreNotPieces() {
        var c = core(["alpha here", "", "omega there"])
        for ch in "here" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true)
        for ch in "omega" { _ = c.key(String(ch), shift: false) }
        guard let span = pieces(c.key("a", shift: true)) else { return XCTFail() }
        XCTAssertEqual(span.map(\.element), [0, 2], "nothing has no rectangle to draw")
    }

    func testTheAnchorIsTheWholeWordFromTheMomentItLands() {
        // What the highlight shows is what ⌘C would take — so the anchor
        // is a word, not the two characters that named it.
        var c = core(["the quick brown fox jumps"])
        for ch in "ui" { _ = c.key(String(ch), shift: false) }
        XCTAssertEqual(c.key("a", shift: true), .anchored)
        XCTAssertEqual(c.anchor?.range, NSRange(location: 4, length: 5), "'quick', whole")
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
        guard let span = pieces(c.key("a", shift: true)), span.count == 1 else {
            return XCTFail()
        }
        XCTAssertEqual(span[0].range, NSRange(location: 4, length: 15),
                       "'uick' means from quick; 'fo' means through fox")
    }

    func testWordSnapTreatsATokenAsOneWord() {
        // Whitespace-delimited, so a URL or identifier comes out whole.
        var c = core(["see github.com/lodestar for more"])
        for ch in "hub" { _ = c.key(String(ch), shift: false) }
        _ = c.key("a", shift: true)
        for ch in "hub" { _ = c.key(String(ch), shift: false) }
        guard let span = pieces(c.key("a", shift: true)), span.count == 1 else {
            return XCTFail()
        }
        let text = "see github.com/lodestar for more" as NSString
        XCTAssertEqual(text.substring(with: span[0].range), "github.com/lodestar")
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

    func testCommandCTakesTheAnchoredWordAndEndsTheMode() {
        _ = press("/", held: true)
        let effects = core.keyDown(key: "c", held: false, shift: false, command: true,
                                   world: world)
        XCTAssertTrue(world.calls.contains("selectCopy"))
        XCTAssertEqual(effects, [.exitSelect], "one word costs one pick and a ⌘C")
        XCTAssertEqual(core.state, .idle)
    }

    func testCommandCWithNothingAnchoredLeavesTheModeStanding() {
        world.selectCopyStep = .pending
        _ = press("/", held: true)
        XCTAssertEqual(core.keyDown(key: "c", held: false, shift: false, command: true,
                                    world: world), [],
                       "swallowed like every other key here")
        XCTAssertEqual(core.state, .select, "nothing to take, nothing to end")
    }

    func testPlainCIsStillTyping() {
        _ = press("/", held: true)
        XCTAssertEqual(press("c"), [])
        XCTAssertTrue(world.calls.contains("selectKey:c"))
        XCTAssertFalse(world.calls.contains("selectCopy"), "the modifier is the whole gesture")
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
