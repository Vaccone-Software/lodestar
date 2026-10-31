import XCTest
@testable import LodestarCore

final class PointerFollowTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let monitor = CGRect(x: 1512, y: -400, width: 2560, height: 1440)
    private var both: [CGRect] { [laptop, monitor] }

    func testAWindowOnTheOtherDisplayTakesThePointerToItsMiddle() {
        let window = CGRect(x: 1512, y: -400, width: 1280, height: 1440)
        XCTAssertEqual(PointerFollow.destination(pointer: CGPoint(x: 700, y: 500), window: window, displays: both),
                       CGPoint(x: 2152, y: 320))
    }

    func testAWindowOnThePointersDisplayLeavesThePointerAlone() {
        let window = CGRect(x: 0, y: 0, width: 756, height: 982)
        XCTAssertNil(PointerFollow.destination(pointer: CGPoint(x: 1400, y: 900), window: window, displays: both),
                     "within one display the pointer is the hand's own")
    }

    func testAWindowAcrossTheSeamBelongsWhereMostOfItIs() {
        let window = CGRect(x: 1400, y: 100, width: 800, height: 600)
        let point = PointerFollow.destination(pointer: CGPoint(x: 200, y: 200), window: window, displays: both)
        XCTAssertEqual(point, CGPoint(x: 1856, y: 400), "the middle of the part on the monitor")
        XCTAssertNil(PointerFollow.destination(pointer: CGPoint(x: 3000, y: 0), window: window, displays: both))
    }

    func testAParkedWindowIsNotFollowed() {
        let parked = CGRect(x: 4200, y: 1200, width: 800, height: 600)
        XCTAssertNil(PointerFollow.destination(pointer: CGPoint(x: 10, y: 10), window: parked, displays: both))
    }

    func testOneDisplayNeverMovesThePointer() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertNil(PointerFollow.destination(pointer: CGPoint(x: 1, y: 1), window: window, displays: [laptop]))
    }
}
