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

    private func press(_ key: String, held: Bool = true, shift: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, world: world)
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

    func testEscapeAndRepeatSemicolonExit() {
        _ = press(";")
        XCTAssertEqual(press("escape", held: false), [.exitHints])
        XCTAssertEqual(core.state, .idle)

        _ = press(";")
        XCTAssertEqual(press(";"), [.exitHints], "hyper ; toggles out quietly")
        XCTAssertEqual(core.state, .idle)
    }

    func testOtherHyperVerbsExitAndExecute() {
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
