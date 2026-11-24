import XCTest
@testable import lodestar

/// The test clock a controller can outlive: read after the test that owned it
/// has let it go, it answers the moment it was handed out and schedules nothing, where an
/// unowned read ended the whole shard process.
final class VirtualClockTests: XCTestCase {
    func testAClockWhoseOwnerIsGoneStandsStillAndSchedulesNothing() {
        let start = Date(timeIntervalSince1970: 1_794_225_600)
        var owner: VirtualClock? = VirtualClock(start: start)
        let clock = owner!.clock
        owner = nil
        XCTAssertEqual(clock.now(), start)
        var ran = false
        clock.after(1, DispatchWorkItem { ran = true })
        XCTAssertFalse(ran)
    }
}
