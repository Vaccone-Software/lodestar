import XCTest
@testable import lodestar

/// A main thread that answers is left alone; one that does not is
/// reported inside the ceiling, on the watchdog's own thread.
final class MainThreadWatchdogTests: XCTestCase {
    func testAStalledMainThreadIsReportedInsideTheCeiling() {
        let watchdog = MainThreadWatchdog(interval: 0.1, ceiling: 0.3)
        let stalled = expectation(description: "stall reported")
        watchdog.onStall = { _ in stalled.fulfill() }
        watchdog.start()
        // Hold the main thread past the ceiling. The expectation is
        // fulfilled from the watchdog's thread while we sleep.
        Thread.sleep(forTimeInterval: 0.6)
        watchdog.stop()
        wait(for: [stalled], timeout: 1)
    }

    func testAResponsiveMainThreadIsLeftAlone() {
        let watchdog = MainThreadWatchdog(interval: 0.05, ceiling: 0.3)
        var stalls = 0
        watchdog.onStall = { _ in stalls += 1 }
        watchdog.start()
        // Keep answering for longer than several intervals.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        watchdog.stop()
        XCTAssertEqual(stalls, 0)
    }
}
