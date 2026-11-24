import XCTest
@testable import LodestarCore

final class GesturesTests: XCTestCase {
    func testNamesAreUnique() {
        let names = Gestures.roster.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testTheWholeAlphabetBelongsToTheGraph() {
        XCTAssertEqual(Gestures.graphLetters.count, 26)
        XCTAssertTrue(Gestures.reservedLetters.isEmpty,
                      "every verb lives on a key the graph cannot want")
        for returned in ["o", "x", "z"] {
            XCTAssertTrue(Gestures.graphLetters.contains(returned),
                          "\(returned) rejoined the graph when its verb moved")
        }
    }

    /// Every idle-state key the engine dispatches is owned by exactly one
    /// toggle — no verb is orphaned, no key claimed twice.
    ///
    /// This asks the engine rather than restating it. The hand-written list
    /// this replaces drifted in lockstep with the roster: when 0.14.2 moved
    /// the flip off O, both the roster and this test kept saying "o", so the
    /// test went on asserting the stale mapping was correct and the broken
    /// `flip-orientation` toggle survived two releases.
    func testRosterOwnsExactlyTheKeysTheEngineClaims() {
        var claimed = Set<String>()
        for key in Set(Keys.ansi.values) {
            var core = EngineCore()
            let effects = core.keyDown(key: key, held: true, shift: false,
                                       world: WorldStub())
            if effects != [.passThrough] { claimed.insert(key) }
        }
        var owned = Set<String>()
        for verb in Gestures.roster {
            for key in verb.keys {
                XCTAssertTrue(owned.insert(key).inserted, "key '\(key)' claimed twice")
            }
        }
        XCTAssertEqual(claimed, owned)
    }

    func testDisabledKeysMapsFalseTogglesOnly() {
        let keys = Gestures.disabledKeys(from: ["scroll": false, "hints": true,
                                                "display-move": false, "unknown": false])
        XCTAssertEqual(keys, ["`", "[", "]"])
    }

    func testDisablingGraphFreesChainStarters() {
        let keys = Gestures.disabledKeys(from: ["graph": false])
        XCTAssertEqual(keys.count, 26)
        XCTAssertTrue(keys.contains("a"))
        XCTAssertTrue(keys.contains("z"), "Z is the graph's since undo moved")
    }
}
