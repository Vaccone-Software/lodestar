import XCTest
@testable import LodestarCore

/// The keycode ↔ name tables. The reverse map feeds ⌘V synthesis and the
/// scroll dead-man guard, so which keycode a name resolves to has to be
/// both deterministic and the one the user asked for.
final class KeysTests: XCTestCase {
    override func tearDown() {
        Keys.apply(overrides: [:])
        super.tearDown()
    }

    /// The built-in table has no two keycodes sharing a name, so the
    /// tie-break rule cannot disturb any existing mapping.
    func testDefaultTableHasNoDuplicateNames() {
        var byName: [String: [Int64]] = [:]
        for (code, name) in Keys.names { byName[name, default: []].append(code) }
        XCTAssertEqual(byName.filter { $0.value.count > 1 }, [:])
    }

    /// An override renames a keycode onto a name the built-in table
    /// already owns — a non-ANSI layout doing exactly what the config
    /// documents. It must win the reverse lookup: resolving the name back
    /// to the built-in keycode would post the wrong key.
    func testAnOverrideOutranksTheBuiltInEntryItCollidesWith() {
        XCTAssertEqual(Keys.codes["v"], 9, "the ANSI keycode, before any override")
        Keys.apply(overrides: [50: "v"])
        XCTAssertEqual(Keys.name(for: 50), "v")
        XCTAssertEqual(Keys.codes["v"], 50, "the override is the point of writing it")
    }

    /// Two overrides claiming one name resolve the same way every launch.
    func testCollidingOverridesResolveDeterministically() {
        for _ in 0..<20 {
            Keys.apply(overrides: [50: "v", 42: "v"])
            XCTAssertEqual(Keys.codes["v"], 42, "lowest keycode breaks the tie, every time")
        }
    }

    /// Clearing the overrides puts the built-in answer back.
    func testReloadRebuildsFromTheBuiltInTable() {
        Keys.apply(overrides: [50: "v"])
        XCTAssertEqual(Keys.codes["v"], 50)
        Keys.apply(overrides: [:])
        XCTAssertEqual(Keys.codes["v"], 9)
        XCTAssertEqual(Keys.name(for: 50), "`")
    }
}
