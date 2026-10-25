import Stoic
import StoicTesting
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
    ///
    /// The watchdog asks a queue this test holds, not main: XCTest's main
    /// thread is not always free to answer inside a test, and twice in CI
    /// an ask went unanswered for ten seconds while the test ran the run
    /// loop, which read as a freeze. Holding a queue is exact: it answers
    /// the moment it is resumed, whatever else the machine is doing.
    func testALateAnswerIsReportedWithItsLength() {
        let target = DispatchQueue(label: "watchdog-test.main")
        let watchdog = MainThreadWatchdog(interval: 0.05, ceiling: 10, launchCeiling: 10, lateThreshold: 0.2,
                                          target: target)
        let lock = NSLock()
        var late: [(seconds: TimeInterval, launch: Bool)] = []
        var stalls = 0
        watchdog.onLate = { seconds, launch in lock.withLock { late.append((seconds, launch)) } }
        watchdog.onStall = { _ in lock.withLock { stalls += 1 } }
        // Each report is waited for, not slept for: the watchdog's utility
        // thread can be scheduled late when the suite's shards all run.
        func waitFor(within seconds: TimeInterval, _ done: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while !done(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        }
        func hitch(_ seen: [(seconds: TimeInterval, launch: Bool)]) -> (seconds: TimeInterval, launch: Bool)? {
            seen.first { !$0.launch && $0.seconds >= 0.3 }
        }
        // A slow launch: held from before the first ask, long against the
        // 0.2 s threshold and short of the allowance.
        target.suspend()
        watchdog.start()
        Thread.sleep(forTimeInterval: 0.6)
        target.resume()
        waitFor(within: 5) { !lock.withLock { late }.isEmpty }
        // A hitch while running, held until an ask has been waiting on it
        // for longer than the 0.3 s asserted below.
        waitFor(within: 1) { false }
        target.suspend()
        Thread.sleep(forTimeInterval: 0.8)
        target.resume()
        waitFor(within: 5) { hitch(lock.withLock { late }) != nil }
        watchdog.stop()
        let seen = lock.withLock { late }
        XCTAssertEqual(lock.withLock { stalls }, 0, "late is not frozen")
        XCTAssertEqual(seen.first?.launch, true, "the launch's own")
        XCTAssertEqual(seen.filter(\.launch).count, 1, "and only the launch's")
        XCTAssertNotNil(hitch(seen), "then one while running, with how long it held: \(seen)")
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

    // MARK: - The clock

    private typealias Instant = AnyClock.Instant
    private func at(_ seconds: Double) -> Instant { Instant(offset: .seconds(seconds)) }

    /// The decision reads two instants and nothing else, so it can be
    /// held against any clock.
    func testTheVerdictFollowsTheClockReadings() {
        let ceiling = Duration.seconds(8), late = Duration.seconds(1)
        func judge(now: Double, answered: Double?) -> MainThreadWatchdog.Verdict {
            MainThreadWatchdog.judge(asked: at(10), now: at(now), answered: answered.map(at),
                                     limit: ceiling, lateThreshold: late)
        }
        XCTAssertEqual(judge(now: 10.05, answered: nil), .waiting)
        XCTAssertEqual(judge(now: 17.9, answered: nil), .waiting)
        XCTAssertEqual(judge(now: 18, answered: nil), .stalled)
        XCTAssertEqual(judge(now: 10.1, answered: 10.02), .answered(late: nil))
        XCTAssertEqual(judge(now: 12, answered: 11.5), .answered(late: .seconds(1.5)))
        // An answer that arrived is an answer, even when the allowance
        // ran out while the thread was looking.
        XCTAssertEqual(judge(now: 30, answered: 10.2), .answered(late: nil))
    }

    /// A Mac that sleeps with a ping outstanding wakes to hours of wall
    /// time and none on the clock that stands still while it sleeps. The
    /// wall time here is a real 90 ms against a 30 ms ceiling; the clock
    /// does not move, so it is not a stall.
    func testWallTimeThatTheClockDidNotCountIsNotAStall() {
        let clock = TestClock()
        let watchdog = MainThreadWatchdog(interval: 0.02, ceiling: 0.03, launchCeiling: 0.03,
                                          lateThreshold: 0.02, clock: clock.erased)
        let lock = NSLock()
        var stalls = 0, lates = 0
        watchdog.onStall = { _ in lock.withLock { stalls += 1 } }
        watchdog.onLate = { _, _ in lock.withLock { lates += 1 } }
        watchdog.start()
        Thread.sleep(forTimeInterval: 0.09)             // main unanswering, the way sleep leaves it
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        watchdog.stop()
        XCTAssertEqual(lock.withLock { stalls }, 0)
        XCTAssertEqual(lock.withLock { lates }, 0)
    }

    /// And the other way: time the clock counts is a stall, however little
    /// wall time passed. Main is held on a semaphore until the stall is
    /// reported, while the clock is advanced from outside.
    func testTimeTheClockCountedIsAStall() {
        let clock = TestClock()
        let watchdog = MainThreadWatchdog(interval: 0.02, ceiling: 8, launchCeiling: 8, clock: clock.erased)
        let reported = DispatchSemaphore(value: 0)
        watchdog.onStall = { _ in reported.signal() }
        watchdog.start()
        let stop = Flag()
        Task.detached {
            while !stop.isSet {
                await clock.advance(by: .seconds(9))
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let result = reported.wait(timeout: .now() + 3)   // main blocked, not answering
        stop.set()
        watchdog.stop()
        XCTAssertEqual(result, .success, "a clock that moved past the ceiling is a stall")
    }

    /// Safe mode: the stall is written down and the process lives. (If the
    /// default response aborted, this test would take the shard with it.)
    func testSafeModeLogsAStallInsteadOfAborting() {
        let clock = TestClock()
        let watchdog = MainThreadWatchdog(interval: 0.02, ceiling: 8, launchCeiling: 8, clock: clock.erased)
        XCTAssertEqual(watchdog.response, .abort, "the default is still a crash")
        watchdog.response = .logOnly
        let logged = DispatchSemaphore(value: 0)
        watchdog.onLogged = { logged.signal() }
        watchdog.start()
        let stop = Flag()
        Task.detached {
            while !stop.isSet {
                await clock.advance(by: .seconds(9))
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let result = logged.wait(timeout: .now() + 3)
        stop.set()
        watchdog.stop()
        XCTAssertEqual(result, .success)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
