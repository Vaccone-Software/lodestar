import XCTest
@testable import LodestarCore

/// The graph offered to somebody who has none. It is the first decision
/// Lodestar asks a new user to trust, so being wrong here is expensive.
final class StarterGraphTests: XCTestCase {
    private func graph(_ pairs: [String: String]) -> GraphNode {
        var problems: [String] = []
        let table = pairs.mapValues { ConfigValue.string($0) }
        return GraphNode.build(from: table, path: "", problems: &problems)
    }

    func testInitialsWhereTheyAreFree() {
        let proposals = StarterGraph.propose(running: ["Ghostty", "Slack", "Messages"],
                                            existing: GraphNode())
        XCTAssertEqual(proposals, [
            .init(letter: "g", app: "Ghostty"),
            .init(letter: "s", app: "Slack"),
            .init(letter: "m", app: "Messages"),
        ])
    }

    func testItNeverTakesALetterTheGraphAlreadyUses() {
        let existing = graph(["g": "Ghostty", "s": "Slack"])
        let proposals = StarterGraph.propose(running: ["Safari", "Music"], existing: existing)
        // Safari's initial is spoken for, so the next letter of its own name.
        XCTAssertEqual(proposals, [
            .init(letter: "a", app: "Safari"),
            .init(letter: "m", app: "Music"),
        ])
    }

    func testReservedVerbsAreOffLimits() {
        // Nothing is off limits any more: every verb moved off its letter
        // by 0.17, so each app simply keeps its own initial.
        let proposals = StarterGraph.propose(running: ["Xcode", "Zoom", "Obsidian"],
                                            existing: GraphNode(),
                                            reserved: Config.reservedTopLevel)
        XCTAssertEqual(proposals, [
            .init(letter: "x", app: "Xcode"),
            .init(letter: "z", app: "Zoom"),
            .init(letter: "o", app: "Obsidian"),
        ])
    }

    func testAnAppAlreadyBoundIsNotProposedAgain() {
        let existing = graph(["e": "Ghostty"])
        let proposals = StarterGraph.propose(running: ["Ghostty", "Slack"], existing: existing)
        XCTAssertEqual(proposals, [.init(letter: "s", app: "Slack")])
    }

    func testAnAppWhoseEveryLetterIsTakenIsSkippedRatherThanGivenAnything() {
        // A letter from outside the name would have to be memorised instead of
        // recalled, which is worse than having no address at all.
        let existing = graph(["m": "Mail", "a": "Asana", "c": "Claude"])
        let proposals = StarterGraph.propose(running: ["Cam", "Slack"], existing: existing)
        XCTAssertEqual(proposals, [.init(letter: "s", app: "Slack")])
    }

    func testTheFurnitureOfEveryMacIsIgnored() {
        let proposals = StarterGraph.propose(
            running: ["Finder", "System Settings", "lodestar", "Dock", "Ghostty"],
            existing: GraphNode())
        XCTAssertEqual(proposals, [.init(letter: "g", app: "Ghostty")])
    }

    func testItStopsAtTheLimitAndKeepsTheOrderItWasGiven() {
        let proposals = StarterGraph.propose(
            running: ["Ghostty", "Slack", "Messages", "Telegram", "Brave", "Notes"],
            existing: GraphNode(), limit: 3)
        XCTAssertEqual(proposals.map(\.app), ["Ghostty", "Slack", "Messages"])
    }

    func testNoProposalsWhenThereIsNothingWorthProposing() {
        XCTAssertTrue(StarterGraph.propose(running: [], existing: GraphNode()).isEmpty)
        XCTAssertTrue(StarterGraph.propose(running: ["Finder"], existing: GraphNode()).isEmpty)
    }
}
