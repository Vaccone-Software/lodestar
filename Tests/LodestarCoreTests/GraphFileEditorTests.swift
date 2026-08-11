import XCTest
@testable import LodestarCore

final class GraphFileEditorTests: XCTestCase {
    private let base = """
    version: 3
    # ── The graph ──
    graph:
      b:
        g: Ghostty       # terminal
        p: ProtonMail
      l: Lodestar
      s: Slack

    web:
      fallback: most-recent
    """

    // MARK: - Add

    func testAddTopLevelAlphabetical() throws {
        let out = try GraphFileEditor.addingPath(["m"], target: "Mail", in: base)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[7], "  m: Mail")
        XCTAssertEqual(lines[8], "  s: Slack")
        XCTAssertTrue(out.contains("# terminal"))
    }

    func testAddAfterAllSiblings() throws {
        let out = try GraphFileEditor.addingPath(["z"], target: "Zed", in: base)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[7], "  s: Slack")
        XCTAssertEqual(lines[8], "  z: Zed")
        XCTAssertEqual(lines[9], "")
        XCTAssertEqual(lines[10], "web:")
    }

    func testAddNestedUnderExistingBranch() throws {
        let out = try GraphFileEditor.addingPath(["b", "m"], target: "Mail", in: base)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[4], "    g: Ghostty       # terminal")
        XCTAssertEqual(lines[5], "    m: Mail")
        XCTAssertEqual(lines[6], "    p: ProtonMail")
    }

    func testAddCreatesIntermediateBranches() throws {
        let out = try GraphFileEditor.addingPath(["e", "d", "x"], target: "Xcode", in: base)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[6], "  e:")
        XCTAssertEqual(lines[7], "    d:")
        XCTAssertEqual(lines[8], "      x: Xcode")
        XCTAssertEqual(lines[9], "  l: Lodestar")
    }

    func testAddIntoEmptyGraph() throws {
        let text = "graph:\n\nweb:\n  fallback: most-recent"
        let out = try GraphFileEditor.addingPath(["s"], target: "Slack", in: text)
        XCTAssertEqual(out, "graph:\n  s: Slack\n\nweb:\n  fallback: most-recent")
    }

    func testAddBacksOverCommentGluedToDisplacedSibling() throws {
        let text = """
        graph:
          b: Brave
          # the one true app
          l: Lodestar
        """
        let out = try GraphFileEditor.addingPath(["g"], target: "Ghostty", in: text)
        XCTAssertEqual(out, """
        graph:
          b: Brave
          g: Ghostty
          # the one true app
          l: Lodestar
        """)
    }

    func testAddTakenThrows() {
        XCTAssertThrowsError(try GraphFileEditor.addingPath(["l"], target: "X", in: base)) {
            XCTAssertEqual($0 as? GraphFileEditor.EditError, .taken("L"))
        }
        XCTAssertThrowsError(try GraphFileEditor.addingPath(["b"], target: "X", in: base)) {
            XCTAssertEqual($0 as? GraphFileEditor.EditError, .taken("B"))
        }
    }

    func testAddBlockedByLeafThrows() {
        XCTAssertThrowsError(try GraphFileEditor.addingPath(["l", "p"], target: "X", in: base)) {
            XCTAssertEqual($0 as? GraphFileEditor.EditError, .blockedByLeaf("L"))
        }
    }

    func testAddSugarConflictThrows() {
        let text = "graph:\n  ep: Slack"
        XCTAssertThrowsError(try GraphFileEditor.addingPath(["e", "p"], target: "X", in: text)) {
            XCTAssertEqual($0 as? GraphFileEditor.EditError, .taken("E P"))
        }
    }

    func testAddNoGraphSectionThrows() {
        XCTAssertThrowsError(try GraphFileEditor.addingPath(["a"], target: "X", in: "web:\n  fallback: most-recent")) {
            XCTAssertEqual($0 as? GraphFileEditor.EditError, .noGraphSection)
        }
    }

    func testAddQuotesUnsafeTargets() throws {
        let out = try GraphFileEditor.addingPath(["t"], target: "Things: Pro #3", in: base)
        XCTAssertTrue(out.contains(#"  t: "Things: Pro #3""#))
        let parsed = try Yaml.parse(out)
        let graph = Yaml.value(at: ["graph"], in: parsed)?.table
        XCTAssertEqual(graph?["t"]?.string, "Things: Pro #3")
    }

    // MARK: - Delete

    func testDeleteLeafKeepsSiblings() throws {
        let out = try GraphFileEditor.deletingPath(["b", "g"], in: base)
        XCTAssertFalse(out.contains("Ghostty"))
        XCTAssertTrue(out.contains("    p: ProtonMail"))
        XCTAssertTrue(out.contains("  b:"))
    }

    func testDeletePrunesChildlessAncestors() throws {
        let text = """
        graph:
          e:
            d:
              x: Xcode
          l: Lodestar
        """
        let out = try GraphFileEditor.deletingPath(["e", "d", "x"], in: text)
        XCTAssertEqual(out, "graph:\n  l: Lodestar")
    }

    func testDeleteStopsPruningAtSurvivingBranch() throws {
        let text = """
        graph:
          e:
            d:
              x: Xcode
            l: Lodestar
        """
        let out = try GraphFileEditor.deletingPath(["e", "d", "x"], in: text)
        XCTAssertEqual(out, "graph:\n  e:\n    l: Lodestar")
    }

    func testDeleteSugarLine() throws {
        let text = "graph:\n  ep: Slack\n  l: Lodestar"
        let out = try GraphFileEditor.deletingPath(["e", "p"], in: text)
        XCTAssertEqual(out, "graph:\n  l: Lodestar")
    }

    func testDeleteNestedSugarLine() throws {
        let text = "graph:\n  e:\n    pl: Slack\n    x: Xcode"
        let out = try GraphFileEditor.deletingPath(["e", "p", "l"], in: text)
        XCTAssertEqual(out, "graph:\n  e:\n    x: Xcode")
    }

    func testDeleteLastPathLeavesEmptySection() throws {
        let text = "graph:\n  l: Lodestar\n\nweb:\n  fallback: most-recent"
        let out = try GraphFileEditor.deletingPath(["l"], in: text)
        XCTAssertEqual(out, "graph:\n\nweb:\n  fallback: most-recent")
        let parsed = try Yaml.parse(out)
        XCTAssertNotNil(parsed["graph"])
    }

    func testDeleteMissingThrows() {
        XCTAssertThrowsError(try GraphFileEditor.deletingPath(["q"], in: base)) {
            XCTAssertEqual($0 as? GraphFileEditor.EditError, .missing("Q"))
        }
        XCTAssertThrowsError(try GraphFileEditor.deletingPath(["b"], in: base)) {
            XCTAssertEqual($0 as? GraphFileEditor.EditError, .missing("B"))
        }
        XCTAssertThrowsError(try GraphFileEditor.deletingPath(["b", "g", "x"], in: base)) {
            XCTAssertEqual($0 as? GraphFileEditor.EditError, .missing("B G X"))
        }
    }

    // MARK: - Round trip

    func testEditedFileStillBuildsTheExpectedTrie() throws {
        var text = base
        text = try GraphFileEditor.addingPath(["e", "x"], target: "Xcode", in: text)
        text = try GraphFileEditor.deletingPath(["b", "p"], in: text)
        let parsed = try Yaml.parse(text)
        var problems: [String] = []
        let graph = GraphNode.build(from: Yaml.value(at: ["graph"], in: parsed)!.table!,
                                    path: "", registry: [:], problems: &problems)
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        XCTAssertEqual(graph.resolve(["e", "x"]),
                       isLeaf: "Xcode")
        XCTAssertEqual(graph.resolve(["b", "g"]), isLeaf: "Ghostty")
        if case .miss = graph.resolve(["b", "p"]) {} else {
            XCTFail("b p should be gone")
        }
        // Untouched sections survive byte-for-byte.
        XCTAssertTrue(text.contains("web:\n  fallback: most-recent"))
        XCTAssertTrue(text.contains("# ── The graph ──"))
    }
}

private func XCTAssertEqual(_ resolution: GraphNode.Resolution, isLeaf app: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    if case .leaf(.app(let name)) = resolution, name == app { return }
    XCTFail("expected leaf \(app), got \(resolution)", file: file, line: line)
}
