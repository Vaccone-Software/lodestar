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

    // MARK: - Layout adoption

    /// A fully ASCII layout (Dvorak's shape) adopts wholesale: every key
    /// is named by what it types, and no name is lost or doubled.
    func testAFullPermutationAdoptsWholesale() {
        let codes = Keys.characterCodes.sorted()
        var rotated: [Int64: String] = [:]
        for (index, code) in codes.enumerated() {
            rotated[code] = Keys.ansi[codes[(index + 1) % codes.count]]
        }
        let overlay = Keys.layoutOverlay(translated: rotated)
        XCTAssertEqual(overlay.count, codes.count, "every character key adopted")
        Keys.apply(layout: overlay)
        defer { Keys.apply(layout: [:]) }
        XCTAssertEqual(Keys.name(for: codes[0]), Keys.ansi[codes[1]],
                       "the key is named by what it types")
        XCTAssertEqual(Set(Keys.names.values), Set(Keys.ansi.values),
                       "no name lost, none invented")
    }

    /// A layout with a few non-ASCII keys (QWERTZ's umlauts) adopts its
    /// letters and digits; punctuation stays positional, so the gestures
    /// bound to punctuation names keep their keys.
    func testUmlautLayoutAdoptsLettersAndKeepsPunctuationPositional() {
        var translated: [Int64: String] = [:]
        for code in Keys.characterCodes {
            translated[code] = Keys.ansi[code] // most keys type their ANSI name
        }
        translated[6] = "y"    // z and y trade places
        translated[16] = "z"
        translated[41] = "ö"   // umlauts where ; ' [ live
        translated[39] = "ä"
        translated[33] = "ü"
        translated[30] = "+"   // the + key where ] lives
        let overlay = Keys.layoutOverlay(translated: translated)
        Keys.apply(layout: overlay)
        defer { Keys.apply(layout: [:]) }
        XCTAssertEqual(Keys.name(for: 6), "y")
        XCTAssertEqual(Keys.name(for: 16), "z")
        XCTAssertEqual(Keys.name(for: 41), ";", "punctuation stays positional")
        XCTAssertEqual(Keys.name(for: 30), "]", "no name may be displaced by +")
    }

    /// A layout that cannot keep the name set intact (AZERTY moves m onto
    /// the ; key while , takes m's place) adopts nothing: half a table
    /// would mean two keys named m and none named ; at all.
    func testIncoherentLayoutFallsBackToTheFloor() {
        XCTAssertEqual(Keys.layoutOverlay(translated: [41: "m", 46: ","]), [:])
    }

    /// The config's `keys:` stays the last word over the layout.
    func testOverridesOutrankTheLayout() {
        Keys.apply(layout: [6: "y", 16: "z"])
        Keys.apply(overrides: [6: "b"])
        defer {
            Keys.apply(layout: [:])
            Keys.apply(overrides: [:])
        }
        XCTAssertEqual(Keys.name(for: 6), "b", "the user outranks the machine")
        XCTAssertEqual(Keys.name(for: 16), "z", "the layout holds where no override speaks")
    }
}
