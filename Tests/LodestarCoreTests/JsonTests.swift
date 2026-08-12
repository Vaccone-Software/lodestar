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
        // gymnastics for `config set hyper.trigger raw-hyper`.
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
        XCTAssertEqual(keys, ["$schema", "version", "graph", "scroll", "zebra"])
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
            "hyper": .table(["trigger": .string("right-command")]),
            "scroll": .table(["speed": .int(2200), "smooth": .bool(true)]),
            "gestures": .table(["scroll": .bool(false), "hints": .bool(true)]),
            "profiles": .table(["brave": .table([:])]),
            "graph": .table(["g": .string("Ghostty")]),
        ], defaults: ConfigDefaults.tree)
        XCTAssertNil(pruned["hyper"])
        XCTAssertEqual(pruned["scroll"], .table(["speed": .int(2200)]))
        XCTAssertEqual(pruned["gestures"], .table(["scroll": .bool(false)]))
        XCTAssertNil(pruned["profiles"]) // an empty registry says nothing
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
        XCTAssertEqual(merged["hints"]?.table?["letters"], .string("asdfghjkl"))
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
        let removed = Json.removing(tree, path: ["web", "links", "yt"])
        XCTAssertEqual(removed, [:])
        XCTAssertNil(Json.removing(tree, path: ["web", "routes"]))
    }

    // MARK: - The migration shape

    /// A YAML config of the real shape converts to sparse JSON holding
    /// exactly the user's intent — defaults gone, customizations intact.
    func testYamlMigratesToSparseIntent() throws {
        let yaml = """
        # yaml-language-server: $schema=lodestar-schema.json
        version: "0.9.7"
        hyper:
          trigger: right-command
        gestures:
          searcher: true
          scroll: true
        app:
          auto-reload: false
          auto-update: true
        profiles:
          brave:
            default: Default
            work: Work
        graph:
          b:
            x: brave:work
          g: Ghostty
        web:
          fallback: most-recent
          search-url: https://search.brave.com/search?q=%s
          links:
          routes:
        scroll:
          smooth: true
          speed: 2200
          step: 60
        """
        var root = try Yaml.parse(yaml)
        root.removeValue(forKey: "version")
        let sparse = Json.pruned(root, defaults: ConfigDefaults.tree)
        XCTAssertEqual(Set(sparse.keys), ["profiles", "graph", "scroll"])
        XCTAssertEqual(sparse["scroll"], .table(["speed": .int(2200)]))
        XCTAssertEqual(sparse["graph"]?.table?["g"], .string("Ghostty"))
        XCTAssertEqual(sparse["profiles"]?.table?["brave"]?.table?["work"], .string("Work"))
    }
}
