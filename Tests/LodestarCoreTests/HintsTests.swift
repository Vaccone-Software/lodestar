import XCTest
@testable import LodestarCore

final class HintLabelsTests: XCTestCase {
    func testSinglesWhileTheySuffice() {
        XCTAssertEqual(HintLabels.labels(count: 3, alphabet: "asdfghjkl"), ["a", "s", "d"])
        XCTAssertEqual(HintLabels.labels(count: 9, alphabet: "asdfghjkl").count, 9)
    }

    func testPairsBeyondTheAlphabet() {
        let labels = HintLabels.labels(count: 12, alphabet: "asdf")
        XCTAssertEqual(labels.count, 12)
        XCTAssertTrue(labels.allSatisfy { $0.count == 2 }, "uniform length — never mixed")
        XCTAssertEqual(labels[0], "aa")
    }

    func testLabelsArePrefixFreeAndUnique() {
        for count in [1, 5, 9, 10, 40, 81] {
            let labels = HintLabels.labels(count: count, alphabet: "asdfghjkl")
            XCTAssertEqual(Set(labels).count, labels.count, "unique at \(count)")
            for a in labels {
                for b in labels where a != b {
                    XCTAssertFalse(b.hasPrefix(a), "'\(a)' shadows '\(b)'")
                }
            }
        }
    }

    func testSanitizeDedupesAndFallsBack() {
        XCTAssertEqual(HintLabels.sanitize("AaSsDdFf"), ["a", "s", "d", "f"])
        XCTAssertEqual(HintLabels.sanitize("a1b!c"), Array("asdfghjkl"), "3 letters is too few")
        XCTAssertEqual(HintLabels.sanitize(""), Array("asdfghjkl"))
    }

    func testCapacityIsAlphabetSquared() {
        XCTAssertEqual(HintLabels.capacity(alphabet: "asdfghjkl"), 81)
        XCTAssertEqual(HintLabels.capacity(alphabet: "xx"), 81, "fallback alphabet")
    }

    func testEverythingWearsAChipWhileSinglesSuffice() {
        // The small window's whole experience: a dialog's three buttons,
        // each on one keystroke, whether or not the tree could name them.
        let chipped = HintLabels.chipped(unreachable: [false, true, false],
                                         alphabet: "asdfghjkl")
        XCTAssertEqual(chipped, [0, 1, 2])
    }

    func testPastTheAlphabetOnlyTheWordlessKeepChips() {
        // Twelve targets against nine letters: the three the screen paints
        // no word inside keep the chips; the nine with a word on them are
        // typed instead.
        var unreachable = [Bool](repeating: false, count: 12)
        unreachable[2] = true
        unreachable[7] = true
        unreachable[11] = true
        XCTAssertEqual(HintLabels.chipped(unreachable: unreachable, alphabet: "asdfghjkl"),
                       [2, 7, 11])
    }

    func testChipsHoldReadingOrderAndStopAtCapacity() {
        let unreachable = [Bool](repeating: true, count: 500)
        let chipped = HintLabels.chipped(unreachable: unreachable, alphabet: "asdf")
        XCTAssertEqual(chipped.count, 16, "alphabet squared, never past it")
        XCTAssertEqual(chipped, Array(0..<16), "the order the harvest walked in")
    }

    func testAWindowOfNamedTargetsDrawsNoChips() {
        let unreachable = [Bool](repeating: false, count: 40)
        XCTAssertTrue(HintLabels.chipped(unreachable: unreachable, alphabet: "asdfghjkl").isEmpty,
                      "everything here is reachable by typing it")
    }

    // MARK: - which targets typing can reach

    func testAWordInsideTheTargetIsItsAddress() {
        let button = CGRect(x: 100, y: 100, width: 80, height: 24)
        let label = CGRect(x: 108, y: 104, width: 60, height: 16)
        XCTAssertTrue(HintLabels.paintsWord(target: button, words: [label]))
    }

    func testAnIconButtonPaintsNoWordAndSoEarnsAChip() {
        // The defect this rule was written for: a 32x32 icon button is an
        // AXButton like any other, and for a year that was taken to mean
        // the hand could type it. There is nothing on it to type.
        let icon = CGRect(x: 300, y: 40, width: 32, height: 32)
        let elsewhere = [CGRect(x: 10, y: 400, width: 90, height: 16),
                         CGRect(x: 500, y: 40, width: 70, height: 16)]
        XCTAssertFalse(HintLabels.paintsWord(target: icon, words: elsewhere))
    }

    func testAWordBesideACheckboxBelongsToTheLabel() {
        // The box and its caption are two targets; the caption's word must
        // not make the box look typeable, or the box loses its only door.
        let box = CGRect(x: 100, y: 100, width: 14, height: 14)
        let caption = CGRect(x: 120, y: 100, width: 80, height: 14)
        XCTAssertFalse(HintLabels.paintsWord(target: box, words: [caption]))
        XCTAssertTrue(HintLabels.paintsWord(target: caption, words: [caption]))
    }

    func testAWordClippedByTheTargetsEdgeIsNotItsAddress() {
        // A row that happens to overlap the last letters of a heading
        // above it has not been named by that heading.
        let row = CGRect(x: 0, y: 200, width: 400, height: 40)
        let heading = CGRect(x: 0, y: 170, width: 200, height: 40)
        XCTAssertFalse(HintLabels.paintsWord(target: row, words: [heading]),
                       "half a word inside is not an address")
    }

    func testNoWordsAtAllMeansNothingIsTypeable() {
        // A window the recognizer has not answered for yet: every target
        // is wordless, which is what makes the chips wait for the words.
        XCTAssertFalse(HintLabels.paintsWord(target: CGRect(x: 0, y: 0, width: 50, height: 20),
                                             words: []))
    }

    func testAnEmptyTargetIsNeverTypeable() {
        XCTAssertFalse(HintLabels.paintsWord(target: .null, words: [CGRect(x: 0, y: 0, width: 9, height: 9)]))
        XCTAssertFalse(HintLabels.paintsWord(target: .zero, words: [CGRect(x: 0, y: 0, width: 9, height: 9)]))
    }

    // MARK: - when the chips may be spent

    func testNoHarvestNoChips() {
        XCTAssertFalse(HintLabels.spendChipsNow(harvested: nil, alphabet: 26,
                                                words: 400, forced: true),
                       "the tree has not answered; there is nothing to label")
    }

    func testASmallHarvestNeedsNoWords() {
        // The dialog's three buttons, answered the instant the tree does:
        // everything wears a single letter, so no word decides anything.
        XCTAssertTrue(HintLabels.spendChipsNow(harvested: 3, alphabet: 26,
                                               words: 0, forced: false))
    }

    func testALargeHarvestWaitsForTheWords() {
        // The defect this guards: spending on the tree's answer alone
        // chips every target, then takes most of them back when the words
        // land — and a chip that moves under a reading hand is worse than
        // one that came late.
        XCTAssertFalse(HintLabels.spendChipsNow(harvested: 107, alphabet: 26,
                                                words: 0, forced: false))
    }

    func testTheWordsReleaseTheChips() {
        XCTAssertTrue(HintLabels.spendChipsNow(harvested: 107, alphabet: 26,
                                               words: 76, forced: false))
    }

    func testAWindowWithNoWordsComingIsNotMadeToWaitForever() {
        // An image, a canvas, a tree that never answers: the deadline
        // forces the decision rather than leaving the door chipless.
        XCTAssertTrue(HintLabels.spendChipsNow(harvested: 107, alphabet: 26,
                                               words: 0, forced: true))
    }

    func testMatchTiers() {
        let labels = ["aa", "as", "d"]
        XCTAssertEqual(HintLabels.match(typed: "d", labels: labels), .exact(2))
        XCTAssertEqual(HintLabels.match(typed: "a", labels: labels), .partial)
        XCTAssertEqual(HintLabels.match(typed: "q", labels: labels), .none)
        XCTAssertEqual(HintLabels.match(typed: "aa", labels: labels), .exact(0))
    }
}

final class EngineHintsTests: XCTestCase {
    var core = EngineCore()
    var world = WorldStub()

    override func setUp() {
        core = EngineCore()
        world = WorldStub()
    }

    private func press(_ key: String, held: Bool = true, shift: Bool = false,
                       control: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, control: control, world: world)
    }

    func testSemicolonEntersHints() {
        XCTAssertEqual(press(";"), [.hideBars])
        XCTAssertEqual(core.state, .hints(sticky: false))
    }

    func testShiftedSemicolonEntersSticky() {
        XCTAssertEqual(press(";", shift: true), [.hideBars])
        XCTAssertEqual(core.state, .hints(sticky: true))
    }

    func testEntryWithNoWindowFlashes() {
        world.hintsEnterSucceeds = false
        XCTAssertEqual(press(";"), [.hideBars, .flash("✕ no focused window to hint")])
        XCTAssertEqual(core.state, .idle)
    }

    func testFireExitsSingleShot() {
        _ = press(";")
        world.hintOutcomes["a"] = .fired
        XCTAssertEqual(press("a", held: false), [.exitHints])
        XCTAssertEqual(core.state, .idle)
    }

    func testFireStaysAndRescansWhenSticky() {
        _ = press(";", shift: true)
        world.hintOutcomes["a"] = .fired
        XCTAssertEqual(press("a", held: false), [.hintRescan])
        XCTAssertEqual(core.state, .hints(sticky: true), "the clicking lens stays open")
    }

    func testPendingAndIgnoredAreSwallowed() {
        _ = press(";")
        world.hintOutcomes["a"] = .pending
        XCTAssertEqual(press("a", held: false), [])
        world.hintOutcomes["q"] = .ignored
        XCTAssertEqual(press("q", held: false), [])
        XCTAssertEqual(core.state, .hints(sticky: false))
    }

    func testShiftReachesTheOracle() {
        _ = press(";")
        world.hintOutcomes["a"] = .fired
        _ = press("a", held: false, shift: true)
        XCTAssertEqual(world.calls.last, "hintType:a:shift")
    }

    func testATextInputFireEndsEvenAStickyMode() {
        // Focusing a field means "my typing goes here next" — a sticky
        // mode that stayed up would eat that typing as aiming.
        _ = press(";", shift: true) // sticky door
        world.hintOutcomes["a"] = .firedFocus
        XCTAssertEqual(press("a", held: false, shift: true), [.exitHints])
        XCTAssertTrue(core.isIdle)
    }

    func testControlRidesEachKeystrokeSeparately() {
        // ⇧ fires, ⌃⇧ fires the other button — the system's own word for
        // a secondary click. The flag travels per keystroke, so on a
        // two-letter label the completing key alone decides the button.
        _ = press(";")
        world.hintOutcomes["a"] = .pending
        world.hintOutcomes["b"] = .pending
        world.hintOutcomes["c"] = .fired
        _ = press("a", held: false, shift: true, control: true)
        XCTAssertEqual(world.calls.last, "hintType:a:shift:control")
        _ = press("b", held: false)
        XCTAssertEqual(world.calls.last, "hintType:b",
                       "the first key's control never lingers into the next")
        _ = press("c", held: false, control: true)
        XCTAssertEqual(world.calls.last, "hintType:c:control",
                       "a label-completing key carries its own control")
    }

    func testEscapeAndRepeatSemicolonExit() {
        _ = press(";")
        XCTAssertEqual(press("escape", held: false), [.exitHints])
        XCTAssertEqual(core.state, .idle)

        _ = press(";")
        XCTAssertEqual(press(";"), [.exitHints], "lode ; toggles out quietly")
        XCTAssertEqual(core.state, .idle)
    }

    func testOtherLodeVerbsExitAndExecute() {
        world.graph = ["s": .leaf]
        _ = press(";")
        XCTAssertEqual(press("s"),
                       [.exitHints, .hideGuide, .summonGraph(letters: ["s"], beside: false)])
        XCTAssertEqual(core.state, .idle)
    }

    func testDeleteBackspacesAndOthersAreSwallowed() {
        _ = press(";")
        XCTAssertEqual(press("delete", held: false), [.hintBackspace])
        XCTAssertEqual(press("3", held: false), [])
        XCTAssertEqual(press("space", held: false), [])
        XCTAssertEqual(core.state, .hints(sticky: false))
    }
}
