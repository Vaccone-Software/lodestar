import XCTest
@testable import LodestarCore

/// GraphNode.build semantics, pinned: merging, sugar, shadowing, and the
/// problems each malformation reports. The graph section is the config's
/// most-edited surface; its failure modes must stay stable.
final class GraphBuildTests: XCTestCase {
    private func build(_ yaml: String, registry: [String: String] = [:]) throws -> (GraphNode, [String]) {
        var problems: [String] = []
        let root = try Yaml.parse(yaml)
        let node = GraphNode.build(from: Yaml.value(at: ["graph"], in: root)!.table!,
                                   path: "", registry: registry, problems: &problems)
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
        graph:
          s: Slack
          e:
            o: Outlook
        """)
        XCTAssertTrue(problems.isEmpty)
        assertLeaf(node, ["s"], app: "Slack")
        assertLeaf(node, ["e", "o"], app: "Outlook")
        guard case .deeper = node.resolve(["e"]) else { return XCTFail("e is a branch") }
        guard case .miss = node.resolve(["q"]) else { return XCTFail("q is a miss") }
        guard case .miss = node.resolve(["e", "z"]) else { return XCTFail("e z is a miss") }
    }

    func testUppercaseKeysAreLowered() throws {
        let (node, problems) = try build("graph:\n  S: Slack")
        XCTAssertTrue(problems.isEmpty)
        assertLeaf(node, ["s"], app: "Slack")
    }

    func testAppPrefixIsStripped() throws {
        let (node, _) = try build("graph:\n  s: \"app: Slack\"")
        assertLeaf(node, ["s"], app: "Slack")
    }

    // MARK: - Sugar

    func testSugarBindsAChain() throws {
        let (node, problems) = try build("graph:\n  eo: Outlook")
        XCTAssertTrue(problems.isEmpty)
        assertLeaf(node, ["e", "o"], app: "Outlook")
        guard case .deeper = node.resolve(["e"]) else { return XCTFail("e became a branch") }
    }

    func testSugarMergesIntoExistingBranch() throws {
        let (node, problems) = try build("""
        graph:
          e:
            l: Lodestar
          ep: Slack
        """)
        XCTAssertTrue(problems.isEmpty)
        assertLeaf(node, ["e", "l"], app: "Lodestar")
        assertLeaf(node, ["e", "p"], app: "Slack")
    }

    func testSugarShadowedByLeafIsDropped() throws {
        let (node, problems) = try build("""
        graph:
          e: Mail
          ep: Slack
        """)
        assertLeaf(node, ["e"], app: "Mail")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("shadowed by leaf 'e'"), "\(problems)")
    }

    func testSugarCollidingWithExistingPathIsDropped() throws {
        let (node, problems) = try build("""
        graph:
          e:
            p: First
          ep: Second
        """)
        assertLeaf(node, ["e", "p"], app: "First")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("collides"), "\(problems)")
    }

    func testSugarWithTableValueIsRejected() throws {
        let (_, problems) = try build("graph:\n  ep:\n    x: Slack")
        XCTAssertTrue(problems.contains { $0.contains("take a target, not a table") }, "\(problems)")
    }

    // MARK: - Malformations

    func testDoubleBindingIsDeterministic() throws {
        // Yaml itself rejects duplicate keys; a duplicate can only arrive
        // via case folding ("s" and "S" are the same letter). The builder
        // processes keys in sorted order, not file order — uppercase sorts
        // first, so its binding wins, deterministically.
        let (node, problems) = try build("""
        graph:
          s: First
          S: Second
        """)
        assertLeaf(node, ["s"], app: "Second")
        XCTAssertTrue(problems.contains { $0.contains("bound twice") }, "\(problems)")
    }

    func testNonLetterKeyIsRejected() throws {
        let (node, problems) = try build("graph:\n  3: Slack\n  e2: Mail")
        guard case .miss = node.resolve(["3"]) else { return XCTFail() }
        XCTAssertEqual(problems.filter { $0.contains("must be letters") }.count, 2, "\(problems)")
    }

    func testEmptyTargetIsRejected() throws {
        let (node, problems) = try build("graph:\n  s: \"\"")
        guard case .miss = node.resolve(["s"]) else { return XCTFail() }
        XCTAssertTrue(problems.contains { $0.contains("empty target") }, "\(problems)")
    }

    func testEmptyAppPrefixTargetIsReportedNotSwallowed() throws {
        let (node, problems) = try build("graph:\n  s: \"app:\"")
        guard case .miss = node.resolve(["s"]) else { return XCTFail() }
        XCTAssertTrue(problems.contains { $0.contains("empty target") }, "\(problems)")
    }

    // MARK: - Browser profiles

    func testBrowserProfileResolvesThroughRegistry() throws {
        let (node, problems) = try build("graph:\n  p: \"brave: personal\"",
                                         registry: ["personal": "Personal"])
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        guard case .leaf(let target) = node.resolve(["p"]),
              target == .braveProfile(key: "personal", display: "Personal") else {
            return XCTFail("expected the registry profile")
        }
    }

    func testUnknownProfileIsDroppedWithGuidance() throws {
        let (node, problems) = try build("graph:\n  p: \"brave: nope\"")
        guard case .miss = node.resolve(["p"]) else { return XCTFail() }
        XCTAssertTrue(problems.contains { $0.contains("unknown profile") && $0.contains("profiles.brave") },
                      "\(problems)")
    }

    // MARK: - Guide

    func testGuideRowsNameLeavesAndBranchLetters() throws {
        let (node, _) = try build("""
        graph:
          s: Slack
          e:
            o: Outlook
            p: Proton Mail
        """)
        let rows = node.guideRows().map { "\($0.0)=\($0.1)" }
        XCTAssertEqual(rows, ["E=→ O P", "S=Slack"])
    }
}
