import XCTest
@testable import LodestarCore

final class GraphJsonEditorTests: XCTestCase {
    private let base: [String: ConfigValue] = [
        "version": .string("0.9.10"),
        "graph": .table([
            "b": .table(["x": .string("brave:xonar")]),
            "g": .string("Ghostty"),
        ]),
    ]

    func testAddsALeafAndABranch() throws {
        let one = try GraphJsonEditor.addingPath(["s"], target: "Slack", in: base)
        XCTAssertEqual(one["graph"]?.table?["s"], .string("Slack"))
        let two = try GraphJsonEditor.addingPath(["e", "o"], target: "Microsoft Outlook", in: one)
        XCTAssertEqual(two["graph"]?.table?["e"]?.table?["o"], .string("Microsoft Outlook"))
        XCTAssertEqual(two["version"], .string("0.9.10")) // the rest of the tree rides untouched
    }

    func testAddsIntoAnExistingBranchCaseInsensitively() throws {
        // Uppercase input lands on the existing lowercase branch, and new
        // keys are stored lowercase — the grammar's own case.
        let out = try GraphJsonEditor.addingPath(["B", "G"], target: "brave:google", in: base)
        XCTAssertEqual(out["graph"]?.table?["b"]?.table?["g"], .string("brave:google"))
        XCTAssertEqual(out["graph"]?.table?["b"]?.table?["x"], .string("brave:xonar"))
    }

    func testRefusesTakenAndBlockedPaths() {
        XCTAssertThrowsError(try GraphJsonEditor.addingPath(["g"], target: "Ghostty", in: base)) {
            XCTAssertEqual($0 as? GraphJsonEditor.EditError, .taken("G"))
        }
        XCTAssertThrowsError(try GraphJsonEditor.addingPath(["g", "h"], target: "Anything", in: base)) {
            XCTAssertEqual($0 as? GraphJsonEditor.EditError, .blockedByLeaf("G"))
        }
    }

    func testWorksFromNoGraphSectionAtAll() throws {
        let out = try GraphJsonEditor.addingPath(["s"], target: "Slack", in: ["version": .string("0.9.10")])
        XCTAssertEqual(out["graph"]?.table?["s"], .string("Slack"))
    }

    func testDeletesALeafAndPrunesTheBranch() throws {
        let out = try GraphJsonEditor.deletingPath(["b", "x"], in: base)
        // b held only x — the childless branch goes with it.
        XCTAssertNil(out["graph"]?.table?["b"])
        XCTAssertEqual(out["graph"]?.table?["g"], .string("Ghostty"))
    }

    func testDeleteRefusesMissingPathsAndBranches() {
        XCTAssertThrowsError(try GraphJsonEditor.deletingPath(["q"], in: base)) {
            XCTAssertEqual($0 as? GraphJsonEditor.EditError, .missing("Q"))
        }
        // Deleting a branch by its prefix would take children the caller
        // never named.
        XCTAssertThrowsError(try GraphJsonEditor.deletingPath(["b"], in: base))
    }

    func testSugarKeysElsewhereSurviveEdits() throws {
        var tree = base
        tree["graph"] = .table(["eo": .string("Microsoft Outlook")])
        let out = try GraphJsonEditor.addingPath(["s"], target: "Slack", in: tree)
        XCTAssertEqual(out["graph"]?.table?["eo"], .string("Microsoft Outlook"))
        XCTAssertEqual(out["graph"]?.table?["s"], .string("Slack"))
    }

    func testAddThenDeleteRestoresTheTree() throws {
        let added = try GraphJsonEditor.addingPath(["v", "z"], target: "Zoom", in: base)
        let restored = try GraphJsonEditor.deletingPath(["v", "z"], in: added)
        XCTAssertEqual(restored["graph"], base["graph"])
    }
}
