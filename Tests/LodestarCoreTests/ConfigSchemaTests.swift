import XCTest
@testable import LodestarCore

final class ConfigSchemaTests: XCTestCase {
    let schema = SchemaNode.table([
        "lode": .table([
            "trigger": .string(allowed: ["right-command", "raw-hyper"], description: ""),
        ], description: ""),
        "scroll": .table([
            "smooth": .boolean(description: ""),
            "speed": .number(min: 200, max: 4000, description: ""),
        ], description: ""),
        "graph": .graph(description: ""),
        "routes": .freeTable(value: .string(allowed: nil, description: ""), description: ""),
    ], description: "")

    func testCleanConfigHasNoFindings() throws {
        let root = try Json.parse("""
        {
          "lode": {"trigger": "right-command"},
          "scroll": {"smooth": true, "speed": 1800},
          "graph": {"s": "Slack", "e": {"o": "Outlook"}},
          "routes": {"acme": "work"}
        }
        """)
        XCTAssertEqual(ConfigSchema.validate(root, against: schema), [])
    }

    func testUnknownKeyWithTypoHint() throws {
        let root = try Json.parse(#"{"scroll": {"smoothe": true}}"#)
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].contains("scroll.smoothe"))
        XCTAssertTrue(findings[0].contains("did you mean 'smooth'"))
    }

    func testUnknownTopLevelSection() throws {
        let root = try Json.parse(#"{"scrolling": {"speed": 100}}"#)
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertTrue(findings.contains { $0.contains("unknown key 'scrolling'") && $0.contains("scroll") })
    }

    func testTypeMismatch() throws {
        let root = try Json.parse(#"{"scroll": {"smooth": 12}}"#)
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertTrue(findings.contains { $0.contains("scroll.smooth") && $0.contains("true or false") })
    }

    func testEnumViolation() throws {
        let root = try Json.parse(#"{"lode": {"trigger": "left-command"}}"#)
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertTrue(findings.contains { $0.contains("right-command") })
    }

    func testRangeViolation() throws {
        let root = try Json.parse(#"{"scroll": {"speed": 9000}}"#)
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertTrue(findings.contains { $0.contains("200–4000") })
    }

    func testGraphAcceptsNestingAndStrings() throws {
        let root = try Json.parse(#"{"graph": {"a": {"b": {"c": "Deep App"}}}}"#)
        XCTAssertEqual(ConfigSchema.validate(root, against: schema), [])
    }

    func testFreeTableAcceptsAnyKeys() throws {
        let root = try Json.parse(#"{"routes": {"anything.at.all": "somewhere"}}"#)
        XCTAssertEqual(ConfigSchema.validate(root, against: schema), [])
    }

    // MARK: - Dotted addresses

    /// Ordinary paths keep splitting on every dot.
    func testFixedPathsSplitOnEveryDot() {
        XCTAssertEqual(ConfigSchema.path(for: "scroll.speed", in: schema), ["scroll", "speed"])
        XCTAssertEqual(ConfigSchema.path(for: "lode.trigger", in: schema), ["lode", "trigger"])
        XCTAssertEqual(ConfigSchema.path(for: "graph", in: schema), ["graph"])
    }

    /// A free table's keys are the user's, so their dots are theirs too.
    /// `web.routes.github.com` is one route, not a section named `github`.
    func testFreeTableKeysKeepTheirDots() {
        XCTAssertEqual(ConfigSchema.path(for: "routes.github.com", in: schema),
                       ["routes", "github.com"])
        XCTAssertEqual(ConfigSchema.path(for: "routes.acme", in: schema), ["routes", "acme"])
        XCTAssertEqual(ConfigSchema.path(for: "routes.a.b.c.d", in: schema),
                       ["routes", "a.b.c.d"])
    }

    /// Graph letters never contain a dot, so the chain keeps splitting.
    func testGraphChainsSplitPerLetter() {
        XCTAssertEqual(ConfigSchema.path(for: "graph.e.o", in: schema), ["graph", "e", "o"])
    }

    /// The real schema is what the CLI resolves against — these are the
    /// addresses `lodestar config set` could not write before.
    func testRealSchemaResolvesHostsAndBundleIds() {
        XCTAssertEqual(ConfigSchema.path(for: "web.routes.github.com", in: Config.schema),
                       ["web", "routes", "github.com"])
        XCTAssertEqual(ConfigSchema.path(for: "clipboard.exclude-apps.com.1password.1password",
                                         in: Config.schema),
                       ["clipboard", "exclude-apps", "com.1password.1password"])
        XCTAssertEqual(ConfigSchema.path(for: "scroll.speed", in: Config.schema),
                       ["scroll", "speed"])
        XCTAssertEqual(ConfigSchema.path(for: "double-tap.right-cmd", in: Config.schema),
                       ["double-tap", "right-cmd"])
    }

    /// A free table whose values are tables still addresses its fields —
    /// even when the user's key has dots in it.
    func testFreeTableOfTablesAddressesFieldsPastADottedKey() {
        XCTAssertEqual(ConfigSchema.path(for: "web.links.gh.url", in: Config.schema),
                       ["web", "links", "gh", "url"])
        XCTAssertEqual(ConfigSchema.path(for: "web.links.my.site.url", in: Config.schema),
                       ["web", "links", "my.site", "url"])
        XCTAssertEqual(ConfigSchema.path(for: "web.links.gh", in: Config.schema),
                       ["web", "links", "gh"])
    }

    /// An unknown section is addressed literally so the schema walk can
    /// report it, rather than being silently reshaped here.
    func testUnknownSectionsAreLeftAlone() {
        XCTAssertEqual(ConfigSchema.path(for: "nope.at.all", in: schema), ["nope", "at", "all"])
    }

    func testJSONSchemaEmission() {
        let json = ConfigSchema.jsonSchema(for: schema, title: "test")
        XCTAssertEqual(json["title"] as? String, "test")
        XCTAssertNotNil(json["definitions"])
        let properties = (json["properties"] as? [String: Any])
        XCTAssertNotNil(properties?["lode"])
        XCTAssertNotNil(properties?["graph"])
    }

    /// A section holding only comments parses as null and means
    /// all-defaults — the emitted schema must not flag it in editors.
    func testJSONSchemaContainersAcceptNull() {
        let json = ConfigSchema.jsonSchema(for: schema, title: "test")
        let properties = json["properties"] as? [String: Any]
        for section in ["lode", "graph", "routes"] {
            let type = (properties?[section] as? [String: Any])?["type"] as? [String]
            XCTAssertEqual(type, ["object", "null"], "section \(section)")
        }
        XCTAssertEqual(json["type"] as? [String], ["object", "null"])
    }
}
