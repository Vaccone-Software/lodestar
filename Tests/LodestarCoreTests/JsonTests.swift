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

    // MARK: - Sparse pruning

    func testPrunesDefaultsAndEmptyTables() {
        let pruned = Json.pruned([
            "lode": .table(["trigger": .string("right-command")]),
            "scroll": .table(["speed": .int(2200), "smooth": .bool(true)]),
            "gestures": .table(["scroll": .bool(false), "hints": .bool(true)]),
            "web": .table(["links": .table([:])]),
            "graph": .table(["g": .string("Ghostty")]),
        ], defaults: ConfigDefaults.tree)
        XCTAssertNil(pruned["lode"])
        XCTAssertEqual(pruned["scroll"], .table(["speed": .int(2200)]))
        XCTAssertEqual(pruned["gestures"], .table(["scroll": .bool(false)]))
        XCTAssertNil(pruned["web"]) // an empty table says nothing
        XCTAssertEqual(pruned["graph"], .table(["g": .string("Ghostty")]))
    }

    func testPruningComparesNumbersByValueAndKeepsUnknownKeys() {
        let pruned = Json.pruned([
            "scroll": .table(["speed": .double(1800.0)]),
            "mystery": .string("kept for validation to flag"),
        ], defaults: ConfigDefaults.tree)
        XCTAssertNil(pruned["scroll"])
        XCTAssertEqual(pruned["mystery"], .string("kept for validation to flag"))
    }

    // MARK: - Merge

    func testMergeOverlaysDeepAndCarriesUnknowns() {
        let merged = Json.merged(defaults: ConfigDefaults.tree, overlay: [
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

    /// The drift guard: defaults emitted, parsed, and pruned against
    /// themselves must vanish entirely — if ConfigDefaults.tree ever
    /// disagrees with itself through the round trip, this breaks.
    func testDefaultsRoundTripPrunesToNothing() throws {
        let reparsed = try Json.parse(Json.emit(ConfigDefaults.tree))
        XCTAssertTrue(Json.pruned(reparsed, defaults: ConfigDefaults.tree).isEmpty)
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

    // MARK: - The sparse shape

    /// A config of the real shape prunes to exactly the user's intent —
    /// defaults gone, customizations intact. This is what every write
    /// funnels through, so the shape it lands in is the file's contract.
    func testFullConfigPrunesToSparseIntent() throws {
        let text = """
        {
          "$schema": "lodestar-schema.json",
          "version": "0.9.7",
          "hyper": {"trigger": "right-command"},
          "gestures": {"searcher": true, "scroll": true},
          "app": {"auto-reload": false, "auto-update": true},
          "profiles": {"brave": {"default": "Default", "work": "Work"}},
          "graph": {"b": {"x": "brave:work"}, "g": "Ghostty"},
          "web": {
            "fallback": "most-recent",
            "search-url": "https://search.brave.com/search?q=%s",
            "links": null,
            "routes": null
          },
          "scroll": {"smooth": true, "speed": 2200, "step": 60}
        }
        """
        var root = try Json.parse(text)
        root.removeValue(forKey: "version")
        root.removeValue(forKey: "$schema")
        let sparse = Json.pruned(ConfigDefaults.normalized(root), defaults: ConfigDefaults.tree)
        XCTAssertEqual(Set(sparse.keys), ["graph", "scroll"])
        XCTAssertEqual(sparse["scroll"], .table(["speed": .int(2200)]))
        XCTAssertEqual(sparse["graph"]?.table?["g"], .string("Ghostty"))
        // The retired registry translated its reference on the way out.
        XCTAssertEqual(sparse["graph"]?.table?["b"]?.table?["x"], .string("brave:Work"))
    }

    // MARK: - Values this config cannot hold

    /// `-1e400` is accepted by JSONSerialization (only positive overflow
    /// is rejected) and arrives as -infinity. Carrying it meant the next
    /// write emitted the bare token `-inf`, which is not JSON: the config
    /// stopped parsing and the file was lost on the write after that.
    func testNonFiniteNumberIsRefusedAndReported() throws {
        var problems: [String] = []
        let root = try Json.parse(#"{"scroll": {"speed": -1e400}}"#, problems: &problems)
        XCTAssertNil(root.value(at: ["scroll", "speed"]))
        XCTAssertTrue(problems.contains { $0.contains("scroll.speed") && $0.contains("finite") },
                      "\(problems)")
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

    /// Pre-0.9.11 files named the lode key "hyper" — the old section reads
    /// as the new. The raw-hyper value itself retired in 0.22 and folds
    /// into the default, so after pruning nothing remains of either.
    func testLegacyHyperSectionReadsAsLode() {
        let normalized = ConfigDefaults.normalized(["hyper": .table(["trigger": .string("raw-hyper")])])
        XCTAssertNil(normalized["hyper"])
        XCTAssertEqual(normalized["lode"]?.table?["trigger"], .string("right-command"))
        let sparse = Json.pruned(normalized, defaults: ConfigDefaults.tree)
        XCTAssertNil(sparse["lode"]?.table?["trigger"])
        // A lode section already present wins; the stray legacy one is dropped.
        let both = ConfigDefaults.normalized([
            "hyper": .table(["trigger": .string("raw-hyper")]),
            "lode": .table(["trigger": .string("right-command")]),
        ])
        XCTAssertEqual(both["lode"]?.table?["trigger"], .string("right-command"))
    }

    /// The register renamed; the switch survives under the new word.
    func testLegacyMenuSearchToggleReadsAsCommands() {
        let normalized = ConfigDefaults.normalized(
            ["gestures": .table(["menu-search": .bool(false)])])
        XCTAssertEqual(normalized["gestures"]?.table?["commands"], .bool(false))
        XCTAssertNil(normalized["gestures"]?.table?["menu-search"])
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
