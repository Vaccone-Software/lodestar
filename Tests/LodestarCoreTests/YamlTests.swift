import XCTest
@testable import LodestarCore

/// The deliberate YAML subset, pinned: what parses, what throws, and the
/// exact shapes that come out. The config file format is public API.
final class YamlTests: XCTestCase {
    // MARK: - Scalars

    func testScalarTypes() throws {
        let root = try Yaml.parse("""
        a: text
        b: "quoted # not a comment"
        c: true
        d: false
        e: 42
        f: 0.4
        g: 0.9.5
        """)
        XCTAssertEqual(root["a"]?.string, "text")
        XCTAssertEqual(root["b"]?.string, "quoted # not a comment")
        XCTAssertEqual(root["c"]?.bool, true)
        XCTAssertEqual(root["d"]?.bool, false)
        XCTAssertEqual(root["e"]?.int, 42)
        XCTAssertEqual(root["f"]?.double, 0.4)
        XCTAssertEqual(root["g"]?.string, "0.9.5", "two dots is not a number")
    }

    func testIntsCoerceToDouble() throws {
        let root = try Yaml.parse("speed: 1800")
        XCTAssertEqual(root["speed"]?.double, 1800)
    }

    func testQuotedEscapes() throws {
        let root = try Yaml.parse(#"a: "line\nbreak\ttab \"q\" back\\slash""#)
        XCTAssertEqual(root["a"]?.string, "line\nbreak\ttab \"q\" back\\slash")
    }

    func testValueMayContainColons() throws {
        let root = try Yaml.parse("url: https://example.com/a:b?q=%s")
        XCTAssertEqual(root["url"]?.string, "https://example.com/a:b?q=%s")
    }

    func testInlineCommentStripped() throws {
        let root = try Yaml.parse("a: value # trailing")
        XCTAssertEqual(root["a"]?.string, "value")
    }

    // MARK: - Structure

    func testNestingAndDedent() throws {
        let root = try Yaml.parse("""
        outer:
          inner:
            deep: 1
          sibling: 2
        next: 3
        """)
        XCTAssertEqual(Yaml.value(at: ["outer", "inner", "deep"], in: root)?.int, 1)
        XCTAssertEqual(Yaml.value(at: ["outer", "sibling"], in: root)?.int, 2)
        XCTAssertEqual(root["next"]?.int, 3)
    }

    func testSingleSpaceIndentNests() throws {
        let root = try Yaml.parse("a:\n b: 1")
        XCTAssertEqual(Yaml.value(at: ["a", "b"], in: root)?.int, 1)
    }

    func testEmptySectionIsEmptyTable() throws {
        let root = try Yaml.parse("graph:\n\nweb:\n  x: 1")
        XCTAssertEqual(root["graph"]?.table?.count, 0)
        XCTAssertEqual(Yaml.value(at: ["web", "x"], in: root)?.int, 1)
    }

    func testCommentAndBlankLinesAreInvisible() throws {
        let root = try Yaml.parse("""
        # leading comment with "quotes" and: colons
        a:

          # interior comment
          b: 1
        """)
        XCTAssertEqual(Yaml.value(at: ["a", "b"], in: root)?.int, 1)
    }

    func testSameKeyAtDifferentLevelsIsFine() throws {
        let root = try Yaml.parse("a:\n  a: 1")
        XCTAssertEqual(Yaml.value(at: ["a", "a"], in: root)?.int, 1)
    }

    func testValueAtMissingHopIsNil() throws {
        let root = try Yaml.parse("a:\n  b: 1")
        XCTAssertNil(Yaml.value(at: ["a", "c"], in: root))
        XCTAssertNil(Yaml.value(at: ["a", "b", "d"], in: root), "scalars end the walk")
    }

    // MARK: - Errors

    private func assertThrows(_ text: String, containing fragment: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Yaml.parse(text), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(fragment),
                          "expected '\(fragment)' in '\(error)'", file: file, line: line)
        }
    }

    func testTabsThrowAnywhere() {
        assertThrows("a:\tv", containing: "tabs")
        assertThrows("a: v # ok\tcomment", containing: "tabs")
    }

    func testDuplicateKeyThrows() {
        assertThrows("a: 1\na: 2", containing: "duplicate key 'a'")
    }

    func testMissingColonThrows() {
        assertThrows("just words", containing: "expected")
    }

    func testEmptyKeyThrows() {
        assertThrows(": value", containing: "empty key")
    }

    func testUnterminatedStringThrows() {
        assertThrows(#"a: "open"#, containing: "unterminated")
    }

    func testTrailingCharactersAfterStringThrow() {
        assertThrows(#"a: "x" y"#, containing: "trailing")
    }

    func testUnsupportedEscapeThrows() {
        assertThrows(#"a: "\q""#, containing: "unsupported escape")
    }

    func testErrorCarriesLineNumber() {
        XCTAssertThrowsError(try Yaml.parse("a: 1\nb: 2\n: broken")) { error in
            XCTAssertTrue("\(error)".contains("line 3"), "got '\(error)'")
        }
    }
}
