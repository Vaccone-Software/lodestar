import XCTest
@testable import LodestarCore

final class YamlTests: XCTestCase {
    func testConfigShapedDocument() throws {
        let doc = """
        # lodestar config
        hyper:
          trigger: right-command   # trailing comment
          shim-includes-shift: true

        graph:
          s: Slack
          d: MongoDB Compass
          e:                       # email
            o: Microsoft Outlook
            p: Proton Mail
          w:
            p: brave:Personal
            k: brave:Work Workspace
        """
        let root = try Yaml.parse(doc)
        XCTAssertEqual(Yaml.value(at: ["hyper", "trigger"], in: root)?.string, "right-command")
        XCTAssertEqual(Yaml.value(at: ["hyper", "shim-includes-shift"], in: root)?.bool, true)
        XCTAssertEqual(Yaml.value(at: ["graph", "s"], in: root)?.string, "Slack")
        XCTAssertEqual(Yaml.value(at: ["graph", "d"], in: root)?.string, "MongoDB Compass")
        XCTAssertEqual(Yaml.value(at: ["graph", "e", "p"], in: root)?.string, "Proton Mail")
        XCTAssertEqual(Yaml.value(at: ["graph", "w", "p"], in: root)?.string, "brave:Personal")
        XCTAssertEqual(Yaml.value(at: ["graph", "w", "k"], in: root)?.string, "brave:Work Workspace")
    }

    func testUnquotedValueKeepsInnerColons() throws {
        let root = try Yaml.parse("k: brave:Some Profile")
        XCTAssertEqual(root["k"]?.string, "brave:Some Profile")
    }

    func testQuotedStringsAndEscapes() throws {
        let root = try Yaml.parse(#"name: "a # b \"q\"""#)
        XCTAssertEqual(root["name"]?.string, "a # b \"q\"")
    }

    func testNumbersAndBools() throws {
        let root = try Yaml.parse("i: -4\nd: 0.25\nb: false")
        XCTAssertEqual(root["i"]?.int, -4)
        XCTAssertEqual(root["d"]?.double, 0.25)
        XCTAssertEqual(root["b"]?.bool, false)
        XCTAssertEqual(root["i"]?.double, -4.0)
    }

    func testSiblingAfterNestedMapClosesIt() throws {
        let doc = """
        a:
          x: 1
        b: 2
        """
        let root = try Yaml.parse(doc)
        XCTAssertEqual(Yaml.value(at: ["a", "x"], in: root)?.int, 1)
        XCTAssertEqual(root["b"]?.int, 2)
    }

    func testDeeplyNested() throws {
        let doc = """
        a:
          b:
            c:
              d: deep
        """
        let root = try Yaml.parse(doc)
        XCTAssertEqual(Yaml.value(at: ["a", "b", "c", "d"], in: root)?.string, "deep")
    }

    func testTabsThrow() {
        XCTAssertThrowsError(try Yaml.parse("a:\n\tb: 1"))
    }

    func testDuplicateKeyThrows() {
        XCTAssertThrowsError(try Yaml.parse("a: 1\na: 2"))
    }

    func testMissingColonThrows() {
        XCTAssertThrowsError(try Yaml.parse("just words"))
    }
}
