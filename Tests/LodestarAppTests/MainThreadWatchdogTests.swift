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

    /// An answer late enough to cost the key tap, short of the ceiling, is
    /// written down with how late it was, and the launch's is told apart.
    func testALateAnswerIsReportedWithItsLength() {
        let watchdog = MainThreadWatchdog(interval: 0.05, ceiling: 2, launchCeiling: 2, lateThreshold: 0.2)
        let lock = NSLock()
        var late: [(seconds: TimeInterval, launch: Bool)] = []
        var stalls = 0
        watchdog.onLate = { seconds, launch in lock.withLock { late.append((seconds, launch)) } }
        watchdog.onStall = { _ in lock.withLock { stalls += 1 } }
        watchdog.start()
        Thread.sleep(forTimeInterval: 0.4)                        // a slow launch
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        Thread.sleep(forTimeInterval: 0.5)                        // a hitch while running
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        watchdog.stop()
        let seen = lock.withLock { late }
        XCTAssertEqual(lock.withLock { stalls }, 0, "late is not frozen")
        XCTAssertEqual(seen.first?.launch, true, "the launch's own")
        XCTAssertEqual(seen.dropFirst().first?.launch, false, "then one while running")
        XCTAssertGreaterThanOrEqual(seen.dropFirst().first?.seconds ?? 0, 0.3, "with how long it held")
    }

    func testAnOnTimeAnswerSaysNothing() {
        let watchdog = MainThreadWatchdog(interval: 0.05, ceiling: 1, launchCeiling: 1, lateThreshold: 0.2)
        let lock = NSLock()
        var late = 0
        watchdog.onLate = { _, _ in lock.withLock { late += 1 } }
        watchdog.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        watchdog.stop()
        XCTAssertEqual(lock.withLock { late }, 0)
    }
}
