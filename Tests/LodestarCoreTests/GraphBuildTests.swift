import XCTest
@testable import LodestarCore

/// GraphNode.build semantics, pinned: merging, sugar, shadowing, and the
/// problems each malformation reports. The graph section is the config's
/// most-edited surface; its failure modes must stay stable.
final class GraphBuildTests: XCTestCase {
    private func build(_ json: String) throws -> (GraphNode, [String]) {
        var problems: [String] = []
        let root = try Json.parse(json)
        let node = GraphNode.build(from: root.value(at: ["graph"])!.table!,
                                   path: "", problems: &problems)
        return (node, problems)
    }

    private func assertLeaf(_ node: GraphNode, _ letters: [String], app: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard case .leaf(.app(let name)) = node.resolve(letters), name == app else {
            return XCTFail("expected leaf \(app) at \(letters)", file: file, line: line)
        }
    }

    // MARK: - Shapes

    func testLeavesBranchesAndResolution() throws {
        let (node, problems) = try build("""
        {"graph": {
          "s": "Slack",
          "e": {"o": "Outlook"}
        }}
        """)
        XCTAssertTrue(problems.isEmpty)
        assertLeaf(node, ["s"], app: "Slack")
        assertLeaf(node, ["e", "o"], app: "Outlook")
        guard case .deeper = node.resolve(["e"]) else { return XCTFail("e is a branch") }
        guard case .miss = node.resolve(["q"]) else { return XCTFail("q is a miss") }
        guard case .miss = node.resolve(["e", "z"]) else { return XCTFail("e z is a miss") }
    }

    func testUppercaseKeysAreLowered() throws {
        let (node, problems) = try build(#"{"graph": {"S": "Slack"}}"#)
        XCTAssertTrue(problems.isEmpty)
        assertLeaf(node, ["s"], app: "Slack")
    }

    func testAppPrefixIsStripped() throws {
        let (node, _) = try build(#"{"graph": {"s": "app: Slack"}}"#)
        assertLeaf(node, ["s"], app: "Slack")
    }

    // MARK: - Sugar

    func testSugarBindsAChain() throws {
        let (node, problems) = try build(#"{"graph": {"eo": "Outlook"}}"#)
        XCTAssertTrue(problems.isEmpty)
        assertLeaf(node, ["e", "o"], app: "Outlook")
        guard case .deeper = node.resolve(["e"]) else { return XCTFail("e became a branch") }
    }

    func testSugarMergesIntoExistingBranch() throws {
        let (node, problems) = try build("""
        {"graph": {
          "e": {"l": "Lodestar"},
          "ep": "Slack"
        }}
        """)
        XCTAssertTrue(problems.isEmpty)
        assertLeaf(node, ["e", "l"], app: "Lodestar")
        assertLeaf(node, ["e", "p"], app: "Slack")
    }

    func testSugarShadowedByLeafIsDropped() throws {
        let (node, problems) = try build("""
        {"graph": {
          "e": "Mail",
          "ep": "Slack"
        }}
        """)
        assertLeaf(node, ["e"], app: "Mail")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("shadowed by leaf 'e'"), "\(problems)")
    }

    func testSugarCollidingWithExistingPathIsDropped() throws {
        let (node, problems) = try build("""
        {"graph": {
          "e": {"p": "First"},
          "ep": "Second"
        }}
        """)
        assertLeaf(node, ["e", "p"], app: "First")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("already bound"), "\(problems)")
    }

    /// Sugar splices its intermediate letters in before the target is
    /// resolved, so a target that does not resolve used to leave the
    /// letters behind — the chain panel showed an "E →" row leading
    /// nowhere, waiting for a letter that could never complete it.
    func testSugarWithAnUnresolvableTargetLeavesNoOrphanBranch() throws {
        let (node, problems) = try build(#"{"graph": {"eo": "brave:"}}"#)
        XCTAssertFalse(problems.isEmpty)
        guard case .miss = node.resolve(["e"]) else {
            return XCTFail("E survived as a phantom branch")
        }
        XCTAssertEqual(node.guideRows().count, 0)
        XCTAssertEqual(node.leaves().count, 0)
    }

    /// A deeper sugar chain prunes all the way back up.
    func testDeepSugarPrunesEveryIntermediateWhenTheTargetFails() throws {
        let (node, _) = try build(#"{"graph": {"abc": "", "s": "Slack"}}"#)
        guard case .miss = node.resolve(["a"]) else { return XCTFail("A survived") }
        XCTAssertEqual(node.leaves().map { $0.chain.joined() }, ["s"])
    }

    /// An empty section is not a destination either.
    func testEmptyBranchIsPruned() throws {
        let (node, _) = try build(#"{"graph": {"e": {}, "s": "Slack"}}"#)
        guard case .miss = node.resolve(["e"]) else { return XCTFail("E survived empty") }
        XCTAssertEqual(node.leaves().map { $0.chain.joined() }, ["s"])
    }

    func testSugarWithTableValueIsRejected() throws {
        let (_, problems) = try build(#"{"graph": {"ep": {"x": "Slack"}}}"#)
        XCTAssertTrue(problems.contains { $0.contains("take a target, not a table") }, "\(problems)")
    }

    // MARK: - Malformations

    func testDoubleBindingIsDeterministic() throws {
        // A duplicate can only arrive via case folding ("s" and "S" are the
        // same letter; JSON keeps the first of two literally identical
        // keys). The builder processes keys in sorted order, not file order
        // — uppercase sorts first, so its binding wins, deterministically.
        let (node, problems) = try build("""
        {"graph": {
          "s": "First",
          "S": "Second"
        }}
        """)
        assertLeaf(node, ["s"], app: "Second")
        XCTAssertTrue(problems.contains { $0.contains("bound twice") }, "\(problems)")
    }

    func testNonLetterKeyIsRejected() throws {
        let (node, problems) = try build(#"{"graph": {"3": "Slack", "e2": "Mail"}}"#)
        guard case .miss = node.resolve(["3"]) else { return XCTFail() }
        XCTAssertEqual(problems.filter { $0.contains("must be letters") }.count, 2, "\(problems)")
    }

    func testEmptyTargetIsRejected() throws {
        let (node, problems) = try build(#"{"graph": {"s": ""}}"#)
        guard case .miss = node.resolve(["s"]) else { return XCTFail() }
        XCTAssertTrue(problems.contains { $0.contains("empty target") }, "\(problems)")
    }

    func testEmptyAppPrefixTargetIsReportedNotSwallowed() throws {
        let (node, problems) = try build(#"{"graph": {"s": "app:"}}"#)
        guard case .miss = node.resolve(["s"]) else { return XCTFail() }
        XCTAssertTrue(problems.contains { $0.contains("empty target") }, "\(problems)")
    }

    // MARK: - Browser profiles

    func testBrowserProfileParsesFromTheReferenceAlone() throws {
        let (node, problems) = try build(#"{"graph": {"p": "brave:Personal"}}"#)
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        guard case .leaf(let target) = node.resolve(["p"]),
              target == .browserProfile(BrowserProfile(browser: .brave, display: "Personal")) else {
            return XCTFail("expected the referenced profile")
        }
        XCTAssertEqual(target.label, "Brave (Personal)")
        XCTAssertEqual(target.configValue, "brave:Personal", "the reference round-trips")
    }

    func testEveryBrowserPrefixResolves() throws {
        let (node, problems) = try build("""
        {"graph": {
          "w": "chrome: Work",
          "s": "edge: School"
        }}
        """)
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        guard case .leaf(let chrome) = node.resolve(["w"]) else { return XCTFail() }
        XCTAssertEqual(chrome.label, "Chrome (Work)")
        guard case .leaf(let edge) = node.resolve(["s"]) else { return XCTFail() }
        XCTAssertEqual(edge.label, "Edge (School)")
    }

    /// Whether the browser actually has the profile is the doctor's
    /// question; the graph binds what the line says.
    func testProfileExistenceIsNotTheParsersBusiness() throws {
        let (node, problems) = try build(#"{"graph": {"p": "brave:Nope"}}"#)
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        guard case .leaf = node.resolve(["p"]) else { return XCTFail() }
    }

    func testBrowserPrefixWithNoNameIsDroppedWithGuidance() throws {
        let (node, problems) = try build(#"{"graph": {"p": "brave:"}}"#)
        guard case .miss = node.resolve(["p"]) else { return XCTFail() }
        XCTAssertTrue(problems.contains { $0.contains("no profile") }, "\(problems)")
    }

    // MARK: - Guide

    func testGuideRowsNameLeavesAndBranchLetters() throws {
        let (node, _) = try build("""
        {"graph": {
          "s": "Slack",
          "e": {"o": "Outlook", "p": "Proton Mail"}
        }}
        """)
        let rows = node.guideRows().map { "\($0.0)=\($0.1)" }
        XCTAssertEqual(rows, ["E=→ O P", "S=Slack"])
    }

    // MARK: - Leaf walk (the searcher's chips and the ⌘K card ride on this)

    func testLeavesWalkEveryDestinationDepthFirstAndSorted() throws {
        let (node, _) = try build("""
        {"graph": {
          "s": "Slack",
          "e": {"o": "Outlook", "p": "Proton Mail"},
          "a": {"b": {"c": "Deep App"}}
        }}
        """)
        let walked = node.leaves().map { "\($0.chain.joined())=\($0.target.label)" }
        XCTAssertEqual(walked, ["abc=Deep App", "eo=Outlook", "ep=Proton Mail", "s=Slack"])
    }

    /// Two equal-length chains to one app must resolve the same way every
    /// run — the walk used to iterate the dictionary, so the teaching chip
    /// could change between launches.
    func testLeafOrderIsStableAcrossWalks() throws {
        let (node, _) = try build("""
        {"graph": {
          "a": {"q": "Slack"},
          "b": {"q": "Slack"}
        }}
        """)
        let first = node.leaves().map(\.chain)
        for _ in 0..<20 { XCTAssertEqual(node.leaves().map(\.chain), first) }
        XCTAssertEqual(first, [["a", "q"], ["b", "q"]])
    }

    func testChainsToAppNamedFindsEveryBindingShortestFirst() throws {
        let (node, _) = try build("""
        {"graph": {
          "s": "Slack",
          "w": {"k": "Slack"},
          "o": "Outlook"
        }}
        """)
        XCTAssertEqual(node.chains(toAppNamed: "slack"), [["s"], ["w", "k"]])
        XCTAssertEqual(node.chains(toAppNamed: "SLACK"), [["s"], ["w", "k"]], "case-insensitive")
        XCTAssertEqual(node.chains(toAppNamed: "Nothing"), [])
    }

    func testChainsToBrowserGatherTheBareAppAndItsProfiles() throws {
        // A browser row owns every binding that means it: the bare app
        // (the inherit binding) and each profile-targeted chain — never
        // another browser's, never another app's.
        let (node, problems) = try build("""
        {"graph": {
          "n": "Brave Browser",
          "b": {"p": "brave:Personal", "w": "brave:Work"},
          "c": "chrome:Home",
          "s": "Slack"
        }}
        """)
        XCTAssertTrue(problems.isEmpty)
        let bindings = node.chains(toBrowser: .brave, appNamed: "Brave Browser")
        XCTAssertEqual(bindings.map(\.chain), [["n"], ["b", "p"], ["b", "w"]],
                       "shortest first, ties on letters")
        guard case .app("Brave Browser") = bindings[0].target else {
            return XCTFail("the bare app is the inherit binding")
        }
        guard case .browserProfile(let personal) = bindings[1].target,
              personal == BrowserProfile(browser: .brave, display: "Personal") else {
            return XCTFail("profile bindings travel whole")
        }
        let chrome = node.chains(toBrowser: .chrome, appNamed: "Google Chrome")
        XCTAssertEqual(chrome.map(\.chain), [["c"]], "other browsers keep their own")
    }

    func testChainsToBrowserSeeAliasNamedBindings() throws {
        // A hand-written "brave" fuzzy-resolves to Brave Browser at summon
        // time; the card's dedupe must count it as the inherit binding.
        let (node, _) = try build(#"{"graph": {"b": "brave", "s": "Slack"}}"#)
        let bindings = node.chains(toBrowser: .brave, appNamed: "Brave Browser") {
            $0 == "brave"
        }
        XCTAssertEqual(bindings.map(\.chain), [["b"]])
        XCTAssertTrue(node.chains(toBrowser: .brave, appNamed: "Brave Browser").isEmpty,
                      "without the resolver the alias stays invisible")
    }

    func testLeavesSkipBranchNodesThatAlsoCarryTargets() throws {
        // The walk reports a branch node's children, never the letter
        // itself — the guard that keeps a node carrying both a target and
        // children honest, held even though the builder's bound-twice rule
        // no longer produces one.
        let (node, _) = try build(#"{"graph": {"e": {"o": "Outlook"}}}"#)
        XCTAssertEqual(node.leaves().map(\.chain), [["e", "o"]])
    }
}
