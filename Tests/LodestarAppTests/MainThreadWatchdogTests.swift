import Stoic
import StoicTesting
import XCTest
@testable import lodestar

/// The watchdog on time the test owns.
///
/// It keeps two times, so the rig has two clocks. `wall` is what its own
/// thread sleeps on, set through `pause`; `counted` is what an ask is
/// measured against. Each tick moves the thread to its next wake and
/// waits for it to be back asleep, so everything it did in between has
/// happened and the next look is at an exact moment: no sleeping, and no
/// tolerance. Main is a queue the rig holds, which answers the instant it
/// is let go, whatever else the machine is doing.
private final class WatchdogRig {
    let wall = TestClock()
    let counted = TestClock()
    let target = DispatchQueue(label: "watchdog-test.main")
    private(set) var held = false

    private let lock = NSLock()
    private var stalled: [TimeInterval] = []
    private var late: [(seconds: TimeInterval, launch: Bool)] = []
    private var logged = 0
    var stalls: [TimeInterval] { lock.withLock { stalled } }
    var lates: [(seconds: TimeInterval, launch: Bool)] { lock.withLock { late } }
    var logs: Int { lock.withLock { logged } }

    private var watchdog: MainThreadWatchdog?

    /// The watchdog's sleep, on the wall clock.
    private func pause(_ seconds: TimeInterval) {
        let woke = DispatchSemaphore(value: 0)
        let wall = wall
        Task.detached {
            try? await wall.sleep(for: .milliseconds(Int((seconds * 1000).rounded())))
            woke.signal()
        }
        woke.wait()
    }

    /// A watchdog on the rig's clocks, started and waited for until its
    /// thread has made its first ask and gone to sleep on it.
    @discardableResult
    func start(interval: TimeInterval = 0.1, ceiling: TimeInterval, launchCeiling: TimeInterval? = nil,
               lateThreshold: TimeInterval = 1, response: MainThreadWatchdog.Response? = nil) async -> MainThreadWatchdog {
        let watchdog = MainThreadWatchdog(interval: interval, ceiling: ceiling, launchCeiling: launchCeiling ?? ceiling,
                                          lateThreshold: lateThreshold, clock: counted.erased,
                                          pause: { [unowned self] in pause($0) }, target: target)
        if let response {
            watchdog.response = response
            watchdog.onLogged = { [unowned self] in lock.withLock { logged += 1 } }
        } else {
            watchdog.onStall = { [unowned self] seconds in lock.withLock { stalled.append(seconds) } }
        }
        watchdog.onLate = { [unowned self] seconds, launch in lock.withLock { late.append((seconds, launch)) } }
        self.watchdog = watchdog
        watchdog.start()
        await wall.waitForSleepers(timeout: .seconds(60))
        return watchdog
    }

    /// Main stops answering: asks queue up behind it.
    func hold() {
        precondition(!held)
        target.suspend()
        held = true
    }

    /// Main answers everything waiting, at the moment it is let go.
    func release() {
        precondition(held)
        target.resume()
        held = false
        target.sync {}
    }

    /// The watchdog's thread moves to its next wake, `counted` moving as far
    /// as `wall` does unless it is told it did not.
    func tick(counting: Bool = true) async {
        if !held { target.sync {} }   // the answer to the last ask is in, and was given at the ask's own moment
        let mark = wall.totalSleeps
        let next = wall.pendingDeadlines[0]
        if counting { await counted.advance(by: wall.now.duration(to: next)) }
        await wall.advanceToNextDeadline()
        await wall.waitForSleepers(newerThan: mark, timeout: .seconds(60))
    }

    func tick(_ count: Int, counting: Bool = true) async {
        for _ in 0..<count { await tick(counting: counting) }
    }

    /// Done: nothing held, and the thread let out of its last sleep to see
    /// it is stopped.
    func finish() async {
        watchdog?.stop()
        if held { release() }
        await wall.advance(by: .seconds(60))
    }
}

/// A main thread that answers is left alone; one that does not is
/// reported at the ceiling, on the watchdog's own thread. Time is the
/// test's: the one test of a real stall is at the end, and runs at the desk.
final class MainThreadWatchdogTests: XCTestCase {
    func testAStalledMainThreadIsReportedAtTheCeilingAndNotBefore() async {
        let rig = WatchdogRig()
        rig.hold()
        await rig.start(ceiling: 0.3)
        await rig.tick(5)
        XCTAssertEqual(rig.stalls, [], "0.25 s of silence is inside the ceiling")
        await rig.tick()
        XCTAssertEqual(rig.stalls, [0.3], "0.3 s of it is the ceiling")
        await rig.finish()
    }

    func testAResponsiveMainThreadIsLeftAlone() async {
        let rig = WatchdogRig()
        await rig.start(interval: 0.05, ceiling: 0.3)
        await rig.tick(120)   // six seconds, a few hundred asks
        XCTAssertEqual(rig.stalls, [])
        XCTAssertEqual(rig.lates.count, 0)
        await rig.finish()
    }

    /// Launch holds main from the first ping until it returns, and a slow
    /// launch is not a hang: it gets the launch allowance, and the
    /// ordinary ceiling holds from the next ping on.
    func testASlowLaunchIsNotAStallButALaterStallIs() async {
        let rig = WatchdogRig()
        rig.hold()   // from before the first ask: the launch
        await rig.start(interval: 0.05, ceiling: 0.3, launchCeiling: 3)
        await rig.tick(20)    // the launch: a second, past the ceiling and inside the allowance
        XCTAssertEqual(rig.stalls, [], "a slow launch is left alone")
        rig.release()
        await rig.tick()      // the answer is judged; the ceiling is the ordinary one from here
        rig.hold()            // after launch: a real stall, from the next ask
        await rig.tick()      // the interval passes and the ask is made
        await rig.tick(5)
        XCTAssertEqual(rig.stalls, [], "0.25 s into it")
        await rig.tick()
        XCTAssertEqual(rig.stalls, [0.3], "the ordinary ceiling is back")
        await rig.finish()
    }

    /// An answer late enough to cost the key tap, short of the ceiling, is
    /// written down with how late it was, and the launch's is told apart.
    func testALateAnswerIsReportedWithItsLength() async {
        let rig = WatchdogRig()
        // A slow launch: held from before the first ask, long against the
        // 0.2 s threshold and short of the allowance.
        rig.hold()
        await rig.start(interval: 0.05, ceiling: 10, lateThreshold: 0.2)
        await rig.tick(12)
        rig.release()
        await rig.tick()
        XCTAssertEqual(rig.lates.map(\.seconds), [0.6])
        XCTAssertEqual(rig.lates.map(\.launch), [true], "the launch's own")
        // A hitch while running: one ask waits 0.8 s for its answer.
        rig.hold()
        await rig.tick()
        await rig.tick(16)
        rig.release()
        await rig.tick()
        XCTAssertEqual(rig.lates.map(\.seconds), [0.6, 0.8], "then one while running, with how long it held")
        XCTAssertEqual(rig.lates.map(\.launch), [true, false], "and only the launch's is the launch's")
        XCTAssertEqual(rig.stalls, [], "late is not frozen")
        await rig.finish()
    }

    /// The threshold is where an answer starts to be written down: just
    /// under it says nothing.
    func testAnAnswerUnderTheThresholdSaysNothing() async {
        let rig = WatchdogRig()
        rig.hold()
        await rig.start(interval: 0.05, ceiling: 2, lateThreshold: 0.5)
        await rig.tick(9)
        rig.release()
        await rig.tick()
        XCTAssertEqual(rig.lates.count, 0, "0.45 s is on time")
        rig.hold()
        await rig.tick()
        await rig.tick(10)
        rig.release()
        await rig.tick()
        XCTAssertEqual(rig.lates.map(\.seconds), [0.5], "0.5 s is the threshold")
        await rig.finish()
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
    /// wall here moves a quarter second against a 30 ms ceiling; the clock
    /// does not move, so it is not a stall.
    func testWallTimeThatTheClockDidNotCountIsNotAStall() async {
        let rig = WatchdogRig()
        rig.hold()                                // main unanswering, the way sleep leaves it
        await rig.start(interval: 0.02, ceiling: 0.03, lateThreshold: 0.02)
        await rig.tick(5, counting: false)
        rig.release()
        await rig.tick(counting: false)
        XCTAssertEqual(rig.stalls, [])
        XCTAssertEqual(rig.lates.count, 0)
        await rig.finish()
    }

    /// And the other way: time the clock counted is a stall, however little
    /// wall time passed.
    func testTimeTheClockCountedIsAStall() async {
        let rig = WatchdogRig()
        rig.hold()
        await rig.start(interval: 0.02, ceiling: 8)
        await rig.counted.advance(by: .seconds(9))
        await rig.tick(counting: false)           // one look, a few milliseconds of wall
        XCTAssertEqual(rig.stalls, [8], "a clock that moved past the ceiling is a stall")
        await rig.finish()
    }

    /// Safe mode: the stall is written down and the process lives. (If the
    /// default response aborted, this test would take the shard with it.)
    func testSafeModeLogsAStallInsteadOfAborting() async {
        let rig = WatchdogRig()
        XCTAssertEqual(MainThreadWatchdog().response, .abort, "the default is still a crash")
        rig.hold()
        await rig.start(interval: 0.02, ceiling: 8, response: .logOnly)
        await rig.counted.advance(by: .seconds(9))
        await rig.tick(counting: false)
        XCTAssertEqual(rig.logs, 1)
        await rig.finish()
    }

    // MARK: - Real time

    /// The one test of a real stall: a real thread on the real clock sees
    /// the real main thread held, on its own thread, inside the ceiling.
    /// Nothing else here needs a wall, and a runner shared by every shard
    /// cannot say when its utility thread will run, so it is the desk's.
    func testARealStalledMainThreadIsSeenOnTheWatchdogsOwnThread() throws {
        try TimingLane.require()
        // No launch allowance: the launch has its own test.
        let watchdog = MainThreadWatchdog(interval: 0.1, ceiling: 0.3, launchCeiling: 0.3)
        let stalled = expectation(description: "stall reported")
        stalled.assertForOverFulfill = false
        watchdog.onStall = { _ in stalled.fulfill() }
        watchdog.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        // Hold the main thread well past the ceiling: the watchdog's thread
        // runs at utility and, with the suite's shards all running, can be
        // scheduled late. The expectation is fulfilled from the watchdog's
        // thread while main sleeps, and the watchdog is stopped only once it has.
        Thread.sleep(forTimeInterval: 1.5)
        wait(for: [stalled], timeout: 3)
        watchdog.stop()
    }
}
