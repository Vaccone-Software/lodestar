import XCTest
@testable import LodestarCore

final class JsonTests: XCTestCase {
    // MARK: - Parsing

    func testParsesEveryScalarShape() throws {
        let root = try Json.parse("""
        {"a": "text", "b": true, "c": 1800, "d": 0.4, "e": {"f": "nested"}}
        """)
        XCTAssertEqual(root["a"], .string("text"))
        XCTAssertEqual(root["b"], .bool(true))
        XCTAssertEqual(root["c"], .int(1800))
        XCTAssertEqual(root["d"], .double(0.4))
        XCTAssertEqual(root["e"], .table(["f": .string("nested")]))
    }

    func testBooleansAreNotNumbers() throws {
        let root = try Json.parse("{\"a\": true, \"b\": 1}")
        XCTAssertEqual(root["a"], .bool(true))
        XCTAssertEqual(root["b"], .int(1))
    }

    func testRejectsCommentsAndNonObjects() {
        XCTAssertThrowsError(try Json.parse("// note\n{}"))
        XCTAssertThrowsError(try Json.parse("[1, 2]"))
        XCTAssertThrowsError(try Json.parse("not json"))
    }

    func testFragmentsReadNaturally() {
        XCTAssertEqual(Json.parseFragment("true"), .bool(true))
        XCTAssertEqual(Json.parseFragment("1800"), .int(1800))
        XCTAssertEqual(Json.parseFragment("0.4"), .double(0.4))
        XCTAssertEqual(Json.parseFragment("\"quoted\""), .string("quoted"))
        // A bare word is a string — agents should not need shell quoting
        // gymnastics for `config set lode.trigger raw-hyper`.
        XCTAssertEqual(Json.parseFragment("raw-hyper"), .string("raw-hyper"))
    }

    // MARK: - Canonical emission

    func testEmitsSectionsInSchemaOrderThenUnknownAlphabetically() throws {
        let text = Json.emit([
            "scroll": .table(["speed": .int(2000)]),
            "$schema": .string("lodestar-schema.json"),
            "zebra": .bool(true),
            "graph": .table(["g": .string("Ghostty")]),
            "version": .string("0.9.10"),
        ])
        let keys = text.split(separator: "\n").compactMap { line -> String? in
            guard let match = line.range(of: "^  \"([^\"]+)\"", options: .regularExpression) else { return nil }
            return String(line[match]).replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(keys, ["$schema", "version", "scroll", "graph", "zebra"])
        XCTAssertTrue(text.hasSuffix("}\n"))
    }

    func testWholeDoublesCanonicalizeToIntegers() {
        XCTAssertEqual(Json.emit(["a": .double(1800.0)]), "{\n  \"a\": 1800\n}\n")
        XCTAssertEqual(Json.emit(["a": .double(0.4)]), "{\n  \"a\": 0.4\n}\n")
    }

    func testEscapesStrings() throws {
        let text = Json.emit(["a": .string("line\nbreak \"quoted\" back\\slash")])
        let reparsed = try Json.parse(text)
        XCTAssertEqual(reparsed["a"], .string("line\nbreak \"quoted\" back\\slash"))
    }

    func testRoundTripIsStable() throws {
        let tree: [String: ConfigValue] = [
            "graph": .table(["b": .table(["x": .string("brave:xonar")]), "g": .string("Ghostty")]),
            "scroll": .table(["speed": .int(2200)]),
            "hints": .table(["rescan-delay": .double(0.7)]),
        ]
        let once = Json.emit(tree)
        let twice = Json.emit(try Json.parse(once))
        XCTAssertEqual(once, twice)
    }

    // MARK: - Merge

    func testMergeOverlaysDeepAndCarriesUnknowns() {
        let merged = Json.merged(defaults: ConfigFile.defaultTree, overlay: [
            "scroll": .table(["speed": .int(2200)]),
            "graph": .table(["g": .string("Ghostty")]),
            "mystery": .bool(true),
        ])
        XCTAssertEqual(merged["scroll"]?.table?["speed"], .int(2200))
        XCTAssertEqual(merged["scroll"]?.table?["smooth"], .bool(true)) // default survives beside the override
        XCTAssertEqual(merged["graph"]?.table?["g"], .string("Ghostty"))
        XCTAssertEqual(merged["mystery"], .bool(true))
        XCTAssertEqual(merged["clipboard"]?.table?["max-size-mb"], .int(500))
    }

    // MARK: - Dotted-path edits

    func testSettingCreatesAndReplaces() {
        var tree = Json.setting([:], path: ["scroll", "speed"], to: .int(2200))
        XCTAssertEqual(tree?["scroll"]?.table?["speed"], .int(2200))
        tree = Json.setting(tree!, path: ["scroll", "speed"], to: .int(2400))
        XCTAssertEqual(tree?["scroll"]?.table?["speed"], .int(2400))
        // A scalar on the path refuses silently becoming a table.
        XCTAssertNil(Json.setting(["a": .string("leaf")], path: ["a", "b"], to: .bool(true)))
    }

    func testRemovingPrunesEmptyBranches() {
        let tree: [String: ConfigValue] = ["web": .table(["links": .table(["yt": .table(["url": .string("youtube.com")])])])]
        XCTAssertEqual(Json.removing(tree, path: ["web", "links", "yt"]), .removed([:]))
        XCTAssertEqual(Json.removing(tree, path: ["web", "routes"]), .absent)
    }

    /// "Nothing there" and "something is in the way" are different answers.
    /// `unset` reported both as success, so a key that stayed in the file
    /// sent a scripted caller away with exit 0.
    func testRemovingDistinguishesAbsentFromBlocked() {
        let tree: [String: ConfigValue] = ["web": .table(["fallback": .string("most-recent")])]
        XCTAssertEqual(Json.removing(tree, path: ["web", "fallback", "deeper"]),
                       .blocked("web.fallback"))
        XCTAssertEqual(Json.removing(tree, path: ["web", "missing"]), .absent)
        XCTAssertEqual(Json.removing(tree, path: ["nope", "at", "all"]), .absent)
    }

    // MARK: - Values this config cannot hold

    /// `-1e400` was accepted by JSONSerialization (only positive overflow
    /// was rejected) and arrived as -infinity. Carrying it meant the next
    /// write emitted the bare token `-inf`, which is not JSON: the config
    /// stopped parsing and the file was lost on the write after that. The
    /// parser now refuses both overflows where they are written, with the
    /// line and column, so the value never reaches the tree.
    func testNonFiniteNumberIsRefusedWithItsPosition() throws {
        for text in [#"{"scroll": {"speed": -1e400}}"#, #"{"scroll": {"speed": 1e400}}"#] {
            XCTAssertThrowsError(try Json.parse(text), text) { error in
                guard let error = error as? Json.ParseError else { return XCTFail("\(error)") }
                XCTAssertEqual(error.line, 1)
                XCTAssertEqual(error.column, 22, "the number's own column")
                XCTAssertTrue("\(error)".hasPrefix("lodestar.json:1:22: "), "\(error)")
            }
        }
    }

    /// A parse error says which file, which line and which column, the shape
    /// editors and terminals link.
    func testAParseErrorNamesTheFileTheLineAndTheColumn() {
        let text = "{\n  \"scroll\": {\n    \"speed\": 2200,\n    // note\n  }\n}\n"
        XCTAssertThrowsError(try Json.parse(text, file: "work.json")) { error in
            guard let error = error as? Json.ParseError else { return XCTFail("\(error)") }
            XCTAssertEqual(error.line, 4)
            XCTAssertEqual(error.column, 5, "the slash that begins the comment")
            XCTAssertTrue("\(error)".hasPrefix("work.json:4:5: "), "\(error)")
        }
        XCTAssertThrowsError(try Json.parse("[1, 2]")) { error in
            XCTAssertTrue("\(error)".hasPrefix("lodestar.json:1:1: the top level must be an object"), "\(error)")
        }
    }

    /// What the old reader tolerated and the new one still does: a trailing
    /// comma, and a key written twice (the last one counts, as it does in
    /// the store the same options are the store's).
    func testATrailingCommaAndARepeatedKeyAreReadAndTheLastOneCounts() throws {
        XCTAssertEqual(try Json.parse(#"{"a": 1,}"#)["a"], .int(1))
        XCTAssertEqual(try Json.parse("{\n  \"a\": 1,\n  \"a\": 2\n}")["a"], .int(2))
    }

    /// Whatever `emit` writes, `parse` must read. This is the invariant the
    /// non-finite case broke.
    func testEmitAlwaysProducesParseableJson() throws {
        let hostile: [String: ConfigValue] = [
            "a": .double(.infinity),
            "b": .double(-.infinity),
            "c": .double(.nan),
            "d": .double(0.1),
            "e": .int(2200),
            "f": .string("quote\" back\\slash \u{1F600}\ttab"),
            "g": .table(["nested": .double(-.infinity)]),
        ]
        let text = Json.emit(hostile)
        XCTAssertNoThrow(try Json.parse(text), "emit produced JSON that parse rejects:\n\(text)")
        // A non-finite lands as null, which reads back as absent — the key
        // returns to its default rather than poisoning the file.
        let round = try Json.parse(text)
        XCTAssertNil(round["a"])
        XCTAssertEqual(round["e"], .int(2200))
        XCTAssertEqual(round["f"], hostile["f"])
    }

    /// A list is not a shape this config has. Dropping it silently meant
    /// `check` reported no problems for a line that did nothing, and the
    /// next write deleted it from disk.
    func testListIsDroppedWithAProblem() throws {
        var problems: [String] = []
        let root = try Json.parse(#"{"graph": {"s": ["Slack"]}}"#, problems: &problems)
        XCTAssertNil(root.value(at: ["graph", "s"]))
        XCTAssertTrue(problems.contains { $0.contains("graph.s") && $0.contains("list") }, "\(problems)")
    }

    /// A section with no keys spells "all defaults here" and must stay
    /// silent — the emitted JSON Schema admits null for exactly this.
    func testNullSectionIsDroppedWithoutComplaint() throws {
        var problems: [String] = []
        let root = try Json.parse(#"{"web": {"links": null}}"#, problems: &problems)
        XCTAssertNil(root.value(at: ["web", "links"]))
        XCTAssertEqual(problems, [])
    }

    // MARK: - Entry edits

    /// The bug these helpers exist to end: editing one row of a table must
    /// leave every sibling exactly as the file had it — including rows the
    /// loader rejected, which a whole-table rewrite silently erased.
    func testRemovingEntryLeavesRejectedSiblingsAlone() {
        let tree: [String: ConfigValue] = ["web": .table(["links": .table([
            "mail": .table(["url": .string("mail.google.com")]),
            "docs": .table(["profile": .string("brave:Work")]), // no url: loader rejects it
        ])])]
        let updated = Json.removingEntry(tree, path: ["web", "links", "mail"])
        XCTAssertNil(updated.value(at: ["web", "links", "mail"]))
        XCTAssertNotNil(updated.value(at: ["web", "links", "docs"]),
                        "the broken sibling is the user's to fix, not ours to erase")
    }

    func testEntryEditsFoldCaseOnTheLastHopOnly() {
        let tree: [String: ConfigValue] = ["web": .table(["routes": .table([
            "YouTube": .string("brave:Home"),
        ])])]
        // The loader folds keys, so the editor holds "youtube" while the
        // file spells "YouTube" — the file's spelling is the one edited.
        let removed = Json.removingEntry(tree, path: ["web", "routes", "youtube"])
        XCTAssertEqual(removed.value(at: ["web", "routes"]), .table([:]),
                       "left empty here; the canonical write path prunes it")
        let replaced = Json.settingEntry(tree, path: ["web", "routes", "youtube"],
                                         to: .string("brave:Work"))
        XCTAssertEqual(replaced?.value(at: ["web", "routes"])?.table?.count, 1,
                       "a case-variant never becomes a second row")
        XCTAssertEqual(replaced?.value(at: ["web", "routes", "youtube"]),
                       .string("brave:Work"))
    }

    func testSettingEntryCreatesTheTableAndRemovingMissesQuietly() {
        let made = Json.settingEntry([:], path: ["meetings", "calendars", "Work"],
                                     to: .string("brave:Work"))
        XCTAssertEqual(made?.value(at: ["meetings", "calendars", "Work"]),
                       .string("brave:Work"))
        let untouched: [String: ConfigValue] = ["web": .table([:])]
        XCTAssertEqual(Json.removingEntry(untouched, path: ["web", "links", "gone"]),
                       untouched)
    }
}
