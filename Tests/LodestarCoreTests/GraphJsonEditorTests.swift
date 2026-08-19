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

    /// The ⌘K card's rows come from the expanded trie, so it offers
    /// "remove lode E O" for a sugar key — and this walk has to find it.
    /// It used to look only for a single-letter key at each level, so the
    /// card answered "lode E O is not in the config" about a line sitting
    /// in the file, and the chain could only be removed by hand.
    func testDeletesASugarChain() throws {
        var tree = base
        tree["graph"] = .table(["eo": .string("Microsoft Outlook"), "g": .string("Ghostty")])
        let out = try GraphJsonEditor.deletingPath(["e", "o"], in: tree)
        XCTAssertNil(out["graph"]?.table?["eo"])
        XCTAssertEqual(out["graph"]?.table?["g"], .string("Ghostty"), "neighbours are untouched")
    }

    /// Sugar can start part-way down a real branch.
    func testDeletesSugarNestedUnderABranch() throws {
        var tree = base
        tree["graph"] = .table(["w": .table(["gg": .string("Slack")])])
        let out = try GraphJsonEditor.deletingPath(["w", "g", "g"], in: tree)
        XCTAssertNil(out["graph"]?.table?["w"], "the emptied branch is pruned")
    }

    /// Case folds, and a chain that genuinely is not there still says so.
    func testSugarDeletionIsCaseInsensitiveAndStillRefusesMisses() throws {
        var tree = base
        tree["graph"] = .table(["EO": .string("Microsoft Outlook")])
        let out = try GraphJsonEditor.deletingPath(["e", "o"], in: tree)
        XCTAssertEqual(out["graph"]?.table?.isEmpty, true)

        XCTAssertThrowsError(try GraphJsonEditor.deletingPath(["e", "p"], in: tree))
    }

    /// A dead nesting must not hide live sugar.
    ///
    /// `GraphNode.build` now prunes branches that lead nowhere, so in
    /// `{"e": {"o": {}}, "eo": "X"}` the chain E O resolves through the
    /// sugar — the nesting is pruned away. Removal has to find the same
    /// binding the user can actually reach; letting the nested descent's
    /// "not in the config" end the search would refuse a live chain.
    func testDeadNestingDoesNotHideLiveSugar() throws {
        var tree = base
        tree["graph"] = .table([
            "e": .table(["o": .table([:])]),
            "eo": .string("Microsoft Outlook"),
        ])
        let out = try GraphJsonEditor.deletingPath(["e", "o"], in: tree)
        XCTAssertNil(out["graph"]?.table?["eo"], "the reachable binding is the one removed")
    }

    /// And when neither spelling holds the chain, it still says so.
    func testNeitherSpellingPresentStillReportsMissing() {
        var tree = base
        tree["graph"] = .table(["e": .table(["z": .string("Zoom")])])
        XCTAssertThrowsError(try GraphJsonEditor.deletingPath(["e", "o"], in: tree))
    }

    /// Both spellings present is a collision the builder resolves in the
    /// nesting's favour, so removal has to take the same one.
    func testNestedSpellingWinsOverSugarWhenBothExist() throws {
        var tree = base
        tree["graph"] = .table([
            "e": .table(["o": .string("Nested")]),
            "eo": .string("Sugar"),
        ])
        let out = try GraphJsonEditor.deletingPath(["e", "o"], in: tree)
        XCTAssertNil(out["graph"]?.table?["e"], "the live nested binding goes")
        XCTAssertEqual(out["graph"]?.table?["eo"], .string("Sugar"), "the shadowed sugar stays")
    }
}
