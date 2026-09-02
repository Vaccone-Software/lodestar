import XCTest
@testable import LodestarCore

/// Which road a focus change took: the hand's most recent act inside the
/// window is charged with it, and nothing the tap could name is `other`.
final class RoadsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testASummonIsChargedWithTheFocusItCauses() {
        var roads = FocusRoads()
        roads.summoned(via: .graph, at: start)
        XCTAssertEqual(roads.road(at: start.addingTimeInterval(0.2)), "graph")
    }

    func testCmdTabAndClickAreNamed() {
        var roads = FocusRoads()
        roads.cmdTabbed(at: start)
        XCTAssertEqual(roads.road(at: start.addingTimeInterval(0.5)), FocusRoads.cmdTab)
        roads.clicked(at: start.addingTimeInterval(1))
        XCTAssertEqual(roads.road(at: start.addingTimeInterval(1.1)), FocusRoads.click,
                       "the most recent act wins")
    }

    func testAStaleActIsNotACause() {
        var roads = FocusRoads()
        roads.clicked(at: start)
        XCTAssertEqual(roads.road(at: start.addingTimeInterval(FocusRoads.window + 1)),
                       FocusRoads.other,
                       "a focus change nothing preceded is the system's own")
    }

    func testNothingStampedIsOther() {
        XCTAssertEqual(FocusRoads().road(at: start), FocusRoads.other)
    }

    func testAnActFromTheFutureIsIgnored() {
        // Clock skew between the stamps' sources must not invent a road.
        var roads = FocusRoads()
        roads.clicked(at: start.addingTimeInterval(5))
        XCTAssertEqual(roads.road(at: start), FocusRoads.other)
    }
}
