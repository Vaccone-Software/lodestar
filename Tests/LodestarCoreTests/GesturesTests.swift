import XCTest
@testable import LodestarCore

final class GesturesTests: XCTestCase {
    func testNamesAreUnique() {
        let names = Gestures.roster.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testGraphLettersExcludeReservedVerbs() {
        XCTAssertEqual(Gestures.graphLetters.count, 23)
        for reserved in ["o", "x", "z"] {
            XCTAssertFalse(Gestures.graphLetters.contains(reserved))
        }
    }

    /// Every idle-state key the engine dispatches is owned by exactly one
    /// toggle — no verb is orphaned, no key claimed twice.
    func testKeysAreDisjointAndCoverTheIdleDispatch(){
        var seen = Set<String>()
        for verb in Gestures.roster {
            for key in verb.keys {
                XCTAssertTrue(seen.insert(key).inserted, "key '\(key)' claimed twice")
            }
        }
        // No "`": marks retired in 0.9.14 and the key is unbound.
        let dispatched = Set(["space", "tab", "return", ".", ",", ";", "=",
                              "'", "0", "o", "x", "z", "[", "]", "/"]
            + (1...9).map(String.init)
            + "abcdefghijklmnopqrstuvwxyz".map(String.init))
        XCTAssertEqual(seen, dispatched)
    }

    func testDisabledKeysMapsFalseTogglesOnly() {
        let keys = Gestures.disabledKeys(from: ["scroll": false, "hints": true,
                                                "display-move": false, "unknown": false])
        XCTAssertEqual(keys, [",", "[", "]"])
    }

    func testDisablingGraphFreesChainStarters() {
        let keys = Gestures.disabledKeys(from: ["graph": false])
        XCTAssertEqual(keys.count, 23)
        XCTAssertTrue(keys.contains("a"))
        XCTAssertFalse(keys.contains("o"))
    }
}
