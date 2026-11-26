import Stoic
import XCTest
@testable import lodestar

/// How often and how long the two bounded watches look. `recur` runs once at
/// once and then after each delay, so N attempts are N looks and N − 1 waits.
final class BoundedWatchTests: XCTestCase {
    /// At once and every 50 ms after: nine looks, the last at 400 ms.
    func testTheAppsCopyIsWatchedForFourHundredMilliseconds() {
        let looks = SelectController.appCopyLooks
        XCTAssertEqual(looks.maximumAttempts, 9)
        XCTAssertEqual(looks.schedule.maximalDelays(limit: 20), Array(repeating: .milliseconds(50), count: 8))
        XCTAssertEqual(looks.maximumTotalDelay, .milliseconds(400))
    }

    /// One wait before the first look (`ScrollController.discoveryInterval`),
    /// and sixteen looks: the last at four seconds.
    func testTheFocusedWindowIsLookedForForFourSeconds() {
        let looks = ScrollController.discoveryLooks
        XCTAssertEqual(looks.maximumAttempts, 16)
        XCTAssertEqual(looks.schedule.maximalDelays(limit: 20),
                       Array(repeating: ScrollController.discoveryInterval, count: 15))
        XCTAssertEqual(ScrollController.discoveryInterval + looks.maximumTotalDelay, .seconds(4))
    }
}
