import XCTest
@testable import LodestarCore

/// The graph diff the epoch log is written from — and the move it can now
/// see, which is what the universal redirect rests on.
final class GraphEpochsTests: XCTestCase {
    private func changes(_ out: [GraphEpochs.Change], _ change: String) -> [String] {
        out.filter { $0.change == change }.map { Observations.key($0.address) }
    }

    func testAddedRetargetedRemoved() {
        let old = ["s": "Slack", "b x": "Brave (Xonar)", "g": "Ghostty"]
        let new = ["s": "Slack", "b x": "Brave (Work)", "z": "Zoom"]
        let out = GraphEpochs.diff(old: old, new: new)
        XCTAssertEqual(changes(out, "added"), ["z"])
        XCTAssertEqual(changes(out, "retargeted"), ["b x"])
        XCTAssertEqual(changes(out, "removed"), ["g"])
        XCTAssertEqual(changes(out, "moved"), [], "a retarget is not a move")
    }

    func testAHandMoveIsSeenAsOne() {
        // The user edited the config: Brave (Xonar) left b x and appeared
        // at x. Removed and added still fire — the curves and the retire
        // logic need them — and the move rides beside them.
        let old = ["b x": "Brave (Xonar)", "g": "Ghostty"]
        let new = ["x": "Brave (Xonar)", "g": "Ghostty"]
        let out = GraphEpochs.diff(old: old, new: new)
        XCTAssertEqual(changes(out, "added"), ["x"])
        XCTAssertEqual(changes(out, "removed"), ["b x"])
        let move = out.first { $0.change == "moved" }
        XCTAssertEqual(move?.address, ["b", "x"])
        XCTAssertEqual(move?.to, ["x"])
    }

    func testAnAmbiguousMoveIsNotGuessed() {
        // One target removed from one place and added at two: which is
        // the signpost? Neither — an ambiguous signpost is worse than a
        // plain miss.
        let old = ["b x": "Brave (Xonar)"]
        let new = ["x": "Brave (Xonar)", "w": "Brave (Xonar)"]
        XCTAssertEqual(changes(GraphEpochs.diff(old: old, new: new), "moved"), [])
    }

    func testARetirementIsNotAMove() {
        let old = ["q": "Quicken"]
        XCTAssertEqual(changes(GraphEpochs.diff(old: old, new: [:]), "moved"), [])
        XCTAssertEqual(changes(GraphEpochs.diff(old: old, new: [:]), "removed"), ["q"])
    }
}
