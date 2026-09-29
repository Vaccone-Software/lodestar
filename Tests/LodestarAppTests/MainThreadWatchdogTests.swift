import XCTest
@testable import lodestar

/// A main thread that answers is left alone; one that does not is
/// reported inside the ceiling, on the watchdog's own thread.
final class MainThreadWatchdogTests: XCTestCase {
    func testAStalledMainThreadIsReportedInsideTheCeiling() {
        // No launch allowance here: under a loaded run the first ping can
        // miss the 0.2 s it is given, and a 60 s allowance then swallowed
        // the stall this test is about. The launch has its own test.
        let watchdog = MainThreadWatchdog(interval: 0.1, ceiling: 0.3, launchCeiling: 0.3)
        let stalled = expectation(description: "stall reported")
        stalled.assertForOverFulfill = false
        watchdog.onStall = { _ in stalled.fulfill() }
        watchdog.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        // Hold the main thread well past the ceiling: the watchdog's thread
        // runs at utility and, with the suite's shards all running, can be
        // scheduled late — a 0.6 s hold was sometimes over before it looked.
        // The expectation is fulfilled from the watchdog's thread while we
        // sleep, and the watchdog is stopped only once it has.
        Thread.sleep(forTimeInterval: 1.5)
        wait(for: [stalled], timeout: 3)
        watchdog.stop()
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
        // Holds are long against the ceilings, and the stall is waited for
        // with main still held: the watchdog's utility thread is scheduled
        // late when the suite's shards all run, and a short hold could end
        // before it looked.
        let watchdog = MainThreadWatchdog(interval: 0.05, ceiling: 0.3, launchCeiling: 3)
        let lock = NSLock()
        var stalls = 0
        watchdog.onStall = { _ in lock.withLock { stalls += 1 } }
        watchdog.start()
        Thread.sleep(forTimeInterval: 1.0)  // the launch: past the ceiling, inside the allowance
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(lock.withLock { stalls }, 0, "a slow launch is left alone")
        let held = Date()                   // after launch: a real stall, held until it is seen
        while lock.withLock({ stalls }) == 0, Date().timeIntervalSince(held) < 4 {
            Thread.sleep(forTimeInterval: 0.1)
        }
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
        // A hitch while running, long against the 0.3 s asserted below: a
        // late-scheduled watchdog can send its ask partway into the hitch.
        Thread.sleep(forTimeInterval: 1.0)
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
        // The default stall is abort(): on a loaded runner main can be
        // starved past this ceiling, and that took the whole shard with it.
        watchdog.onStall = { _ in }
        watchdog.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        watchdog.stop()
        XCTAssertEqual(lock.withLock { late }, 0)
    }
}
