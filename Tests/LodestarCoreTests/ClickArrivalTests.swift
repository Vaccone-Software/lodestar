import XCTest
@testable import LodestarCore

final class ClickArrivalTests: XCTestCase {
    private func decide(home: CGDirectDisplayID?, active: CGDirectDisplayID = 1,
                        members: Int) -> ClickArrival {
        ClickArrivalRule.decide(browserHome: home, activeDisplay: active,
                                membersOnActiveDisplay: members)
    }

    /// The 83% case: parked, one thing on screen, nothing to protect.
    func testParkedOntoAQuietDisplayPlaces() {
        XCTAssertEqual(decide(home: nil, members: 1), .place)
    }

    /// An empty display is not an arrangement either.
    func testParkedOntoAnEmptyDisplayPlaces() {
        XCTAssertEqual(decide(home: nil, members: 0), .place)
    }

    /// The whole point of the change: an arrangement you built survives.
    func testParkedBesideAnArrangementHolds() {
        XCTAssertEqual(decide(home: nil, members: 2), .chip)
        XCTAssertEqual(decide(home: nil, members: 3), .chip)
    }

    /// Already tiled where the eyes are: the tab is the feedback, and
    /// placing would be `.replace` — which would park its co-tenant. The
    /// one case where doing nothing is the whole right answer.
    func testAlreadyOnTheActiveDisplayDoesNothing() {
        XCTAssertEqual(decide(home: 1, active: 1, members: 1), .nothing)
        XCTAssertEqual(decide(home: 1, active: 1, members: 2), .nothing)
    }

    /// Visit-don't-pull: `Placement.decide` turns this into `.visit`, so
    /// placing changes no layout on either display.
    func testOnAnotherDisplayPlacesWithoutDisturbing() {
        XCTAssertEqual(decide(home: 2, active: 1, members: 1), .place)
        XCTAssertEqual(decide(home: 2, active: 1, members: 4), .place)
    }

    /// The threshold is a property of the rule, not a number sprinkled
    /// through it: whatever `quietMembers` says, one more is an arrangement.
    func testThresholdIsTheRulesOwn() {
        let quiet = ClickArrivalRule.quietMembers
        XCTAssertEqual(decide(home: nil, members: quiet), .place)
        XCTAssertEqual(decide(home: nil, members: quiet + 1), .chip)
    }

    /// A place decision must never be reachable for a browser sitting on
    /// the active display, because that is the one that costs a co-tenant.
    func testNoArrangementIsEverFlattenedByALink() {
        for members in 2...6 {
            XCTAssertNotEqual(decide(home: nil, members: members), .place)
            XCTAssertEqual(decide(home: 1, active: 1, members: members), .nothing)
        }
    }
}
