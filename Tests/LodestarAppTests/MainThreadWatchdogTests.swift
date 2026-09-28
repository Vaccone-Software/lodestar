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
        // Launch answers first; the first ping has an allowance of its own.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
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

    /// Launch holds main from the first ping until it returns, and a slow
    /// launch is not a hang: it gets the launch allowance, and the
    /// ordinary ceiling holds from the next ping on.
    func testASlowLaunchIsNotAStallButALaterStallIs() {
        let watchdog = MainThreadWatchdog(interval: 0.05, ceiling: 0.3, launchCeiling: 2)
        let lock = NSLock()
        var stalls = 0
        watchdog.onStall = { _ in lock.withLock { stalls += 1 } }
        watchdog.start()
        Thread.sleep(forTimeInterval: 0.8)  // the launch: past the ceiling, inside the allowance
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(lock.withLock { stalls }, 0, "a slow launch is left alone")
        Thread.sleep(forTimeInterval: 0.6)  // after launch: a real stall
        watchdog.stop()
        XCTAssertGreaterThan(lock.withLock { stalls }, 0, "the ordinary ceiling is back")
    }
}
