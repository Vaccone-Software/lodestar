import XCTest
@testable import LodestarCore

final class EditorReadCostTests: XCTestCase {
    func testReadsAreSaidPerAppWhenTheHandMovesOn() {
        var cost = EditorReadCost()
        XCTAssertNil(cost.add(app: "Brave Browser", ms: 4))
        XCTAssertNil(cost.add(app: "Brave Browser", ms: 12))
        XCTAssertNil(cost.add(app: "Brave Browser", ms: 6))
        let brave = cost.add(app: "Slack", ms: 2)
        XCTAssertEqual(brave?.app, "Brave Browser")
        XCTAssertEqual(brave?.reads, 3)
        XCTAssertEqual(brave?.p50, 6)
        XCTAssertEqual(brave?.max, 12)
        XCTAssertEqual(brave?.totalMs, 22)
        XCTAssertEqual(cost.flush()?.app, "Slack", "the app in hand is said on flush")
        XCTAssertNil(cost.flush(), "and only once")
    }

    func testALongSessionIsSaidInBatches() {
        var cost = EditorReadCost(batch: 3)
        XCTAssertNil(cost.add(app: "Slack", ms: 1))
        XCTAssertNil(cost.add(app: "Slack", ms: 1))
        XCTAssertEqual(cost.add(app: "Slack", ms: 1)?.reads, 3)
        XCTAssertNil(cost.flush())
    }
}
