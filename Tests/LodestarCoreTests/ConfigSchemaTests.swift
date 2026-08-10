import XCTest
@testable import LodestarCore

final class ConfigSchemaTests: XCTestCase {
    let schema = SchemaNode.table([
        "hyper": .table([
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
        let root = try Yaml.parse("""
        hyper:
          trigger: right-command
        scroll:
          smooth: true
          speed: 1800
        graph:
          s: Slack
          e:
            o: Outlook
        routes:
          acme: work
        """)
        XCTAssertEqual(ConfigSchema.validate(root, against: schema), [])
    }

    func testUnknownKeyWithTypoHint() throws {
        let root = try Yaml.parse("scroll:\n  smoothe: true")
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].contains("scroll.smoothe"))
        XCTAssertTrue(findings[0].contains("did you mean 'smooth'"))
    }

    func testUnknownTopLevelSection() throws {
        let root = try Yaml.parse("scrolling:\n  speed: 100")
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertTrue(findings.contains { $0.contains("unknown key 'scrolling'") && $0.contains("scroll") })
    }

    func testTypeMismatch() throws {
        let root = try Yaml.parse("scroll:\n  smooth: 12")
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertTrue(findings.contains { $0.contains("scroll.smooth") && $0.contains("true or false") })
    }

    func testEnumViolation() throws {
        let root = try Yaml.parse("hyper:\n  trigger: left-command")
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertTrue(findings.contains { $0.contains("right-command") })
    }

    func testRangeViolation() throws {
        let root = try Yaml.parse("scroll:\n  speed: 9000")
        let findings = ConfigSchema.validate(root, against: schema)
        XCTAssertTrue(findings.contains { $0.contains("200–4000") })
    }

    func testGraphAcceptsNestingAndStrings() throws {
        let root = try Yaml.parse("graph:\n  a:\n    b:\n      c: Deep App")
        XCTAssertEqual(ConfigSchema.validate(root, against: schema), [])
    }

    func testFreeTableAcceptsAnyKeys() throws {
        let root = try Yaml.parse("routes:\n  anything.at.all: somewhere")
        XCTAssertEqual(ConfigSchema.validate(root, against: schema), [])
    }

    func testJSONSchemaEmission() {
        let json = ConfigSchema.jsonSchema(for: schema, title: "test")
        XCTAssertEqual(json["title"] as? String, "test")
        XCTAssertNotNil(json["definitions"])
        let properties = (json["properties"] as? [String: Any])
        XCTAssertNotNil(properties?["hyper"])
        XCTAssertNotNil(properties?["graph"])
    }

    /// A section holding only comments parses as null and means
    /// all-defaults — the emitted schema must not flag it in editors.
    func testJSONSchemaContainersAcceptNull() {
        let json = ConfigSchema.jsonSchema(for: schema, title: "test")
        let properties = json["properties"] as? [String: Any]
        for section in ["hyper", "graph", "routes"] {
            let type = (properties?[section] as? [String: Any])?["type"] as? [String]
            XCTAssertEqual(type, ["object", "null"], "section \(section)")
        }
        XCTAssertEqual(json["type"] as? [String], ["object", "null"])
    }
}
