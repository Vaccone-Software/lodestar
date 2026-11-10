import XCTest
@testable import LodestarCore

/// What a launching copy does about the copy that may be running, as it was
/// before the extraction: pinned with a table in place of the machine, and
/// with real processes where the behaviour is between processes.
final class PidTakeoverTests: XCTestCase {
    /// A machine of a table of pids: those alive, and those asked to quit.
    /// A pid asked to quit goes after `exitsAfter` pauses, or never.
    private final class Machine: InstanceProcesses, @unchecked Sendable {
        private let lock = NSLock()
        private var alive: Set<Int32>
        private var asked: [Int32] = []
        private var time = Date(timeIntervalSince1970: 1_000_000)
        private var goes: [Int32: Int] = [:]
        private var pauses = 0
        var exitsAfter: Int? = 0

        init(alive: Set<Int32>) { self.alive = alive }

        var asks: [Int32] { lock.withLock { asked } }
        var waited: TimeInterval { lock.withLock { time.timeIntervalSince1970 - 1_000_000 } }

        func isAlive(_ pid: Int32) -> Bool { lock.withLock { alive.contains(pid) } }

        func terminate(_ pid: Int32) {
            lock.withLock {
                asked.append(pid)
                if let exitsAfter { goes[pid] = pauses + exitsAfter }
            }
        }

        var clock: InstanceClock {
            InstanceClock(now: { [self] in lock.withLock { time } }, pause: { [self] seconds in
                lock.withLock {
                    time = time.addingTimeInterval(seconds)
                    pauses += 1
                    for (pid, at) in goes where pauses >= at { alive.remove(pid) }
                }
            })
        }
    }

    private func pidFile(_ contents: String?) throws -> URL {
        let url = try instanceFolder().appendingPathComponent("lodestar.pid")
        if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    private func written(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: One process, a table of pids

    func testFirstLaunchWithNoFileAsksNobodyAndWritesItsPid() throws {
        let file = try pidFile(nil)
        let machine = Machine(alive: [])
        XCTAssertEqual(PidTakeover.run(pidFile: file, selfPid: 500, processes: machine, clock: machine.clock), .nothingRunning)
        XCTAssertEqual(machine.asks, [])
        XCTAssertEqual(written(file), "500", "the file the watchdog reads is the bare pid")
    }

    func testARunningCopyIsAskedToQuitWaitedForAndReplaced() throws {
        let file = try pidFile("400")
        let machine = Machine(alive: [400])
        machine.exitsAfter = 40  // forty pauses of 25 ms: a second of restoring windows
        XCTAssertEqual(PidTakeover.run(pidFile: file, selfPid: 500, processes: machine, clock: machine.clock), .replaced(pid: 400))
        XCTAssertEqual(machine.asks, [400], "asked once")
        XCTAssertEqual(written(file), "500")
        XCTAssertEqual(machine.waited, 1.0, accuracy: 0.05, "it waits for the copy to go, not for a fixed time")
    }

    func testAPidThatNoLongerExistsIsNotSignalled() throws {
        let file = try pidFile("400\n")
        let machine = Machine(alive: [])
        XCTAssertEqual(PidTakeover.run(pidFile: file, selfPid: 500, processes: machine, clock: machine.clock), .nothingRunning)
        XCTAssertEqual(machine.asks, [])
        XCTAssertEqual(written(file), "500")
    }

    func testAFileNamingThisProcessAsksNobody() throws {
        let file = try pidFile("500")
        let machine = Machine(alive: [500])
        XCTAssertEqual(PidTakeover.run(pidFile: file, selfPid: 500, processes: machine, clock: machine.clock), .nothingRunning)
        XCTAssertEqual(machine.asks, [])
    }

    func testAnUnreadableFileNamesNobody() throws {
        for contents in ["", "not a pid", "12 34", "-"] {
            let file = try pidFile(contents)
            let machine = Machine(alive: [12, 34])
            XCTAssertEqual(PidTakeover.run(pidFile: file, selfPid: 500, processes: machine, clock: machine.clock),
                           .nothingRunning, contents)
            XCTAssertEqual(machine.asks, [], contents)
            XCTAssertEqual(written(file), "500", contents)
        }
    }

    /// The outgoing copy has five seconds. After them the launch goes on with
    /// two copies running, and says so.
    func testACopyThatWillNotGoIsWaitedForFiveSecondsAndTheLaunchGoesOn() throws {
        let file = try pidFile("400")
        let machine = Machine(alive: [400])
        machine.exitsAfter = nil
        XCTAssertEqual(PidTakeover.run(pidFile: file, selfPid: 500, processes: machine, clock: machine.clock), .stuck(pid: 400))
        XCTAssertEqual(machine.asks, [400])
        XCTAssertEqual(machine.waited, 5.0, accuracy: 0.05)
        XCTAssertEqual(written(file), "500", "and the file names this copy all the same")
    }

    /// The gap: the file is trusted. A pid left by a copy that crashed names
    /// whatever has been given that number since, and it is asked to quit.
    func testAPidFileNamingAnyLiveProcessIsTrustedToday() throws {
        let file = try pidFile("777")  // a stranger's pid, left by a copy that crashed
        let machine = Machine(alive: [777])
        PidTakeover.run(pidFile: file, selfPid: 500, processes: machine, clock: machine.clock)
        XCTAssertEqual(machine.asks, [777], "the stranger was sent the quit")
    }

    // MARK: Two real processes

    private func copy(_ pidFile: URL, quitSeconds: Double = 0) throws -> InstanceProbe {
        try InstanceProbe(["copy", "--pid-file", pidFile.path, "--quit-seconds", "\(quitSeconds)"], from: Self.self)
    }

    /// The second launch while the first runs: the first is asked to quit
    /// (the app's handler turns it into a graceful shutdown), and the second
    /// is ready only once the first has exited.
    func testASecondLaunchAsksTheFirstToQuitAndTakesOver() throws {
        let file = try instanceFolder().appendingPathComponent("lodestar.pid")
        let first = try copy(file, quitSeconds: 0.3)
        XCTAssertNotNil(first.wait(for: "READY"), "\(first.lines)")
        XCTAssertEqual(written(file), "\(first.pid)")

        let second = try copy(file)
        XCTAssertNotNil(second.wait(for: "READY"), "\(second.lines)")

        XCTAssertEqual(first.waitForExit(), 0, "it shut down, it was not killed")
        XCTAssertTrue(first.lines.contains("TERMED \(first.pid)"), "\(first.lines)")
        let exiting = try XCTUnwrap(first.moment(of: "EXITING"))
        let ready = try XCTUnwrap(second.moment(of: "READY"))
        XCTAssertLessThan(exiting, ready, "the second one is not ready until the first has gone")
        XCTAssertEqual(written(file), "\(second.pid)", "and the first did not clear the file the second wrote")
    }

    /// The update's successor takes over from the copy that launched it: the
    /// two overlap while the old one restores its windows, the file changes
    /// hands only once it has gone, which is the verdict the watchdog reads.
    func testTheUpdateSuccessorTakesOverFromTheCopyThatLaunchedIt() throws {
        let file = try instanceFolder().appendingPathComponent("lodestar.pid")
        let old = try copy(file, quitSeconds: 1.0)
        XCTAssertNotNil(old.wait(for: "READY"))

        let successor = try copy(file)
        XCTAssertNotNil(successor.wait(for: "BOOT"))
        XCTAssertEqual(written(file), "\(old.pid)", "while they overlap the file still names the old copy")
        XCTAssertTrue(old.isRunning)

        XCTAssertNotNil(successor.wait(for: "READY"))
        XCTAssertEqual(old.waitForExit(), 0)
        XCTAssertLessThan(try XCTUnwrap(old.moment(of: "EXITING")), try XCTUnwrap(successor.moment(of: "READY")))
        XCTAssertEqual(written(file), "\(successor.pid)", "the file has changed hands")
    }

    /// A launch after a crash: the file names a copy that is not there.
    func testALaunchAfterACrashFindsAStalePidThatNoLongerExists() throws {
        let file = try instanceFolder().appendingPathComponent("lodestar.pid")
        let crashed = try copy(file)
        XCTAssertNotNil(crashed.wait(for: "READY"))
        crashed.crash()
        XCTAssertEqual(written(file), "\(crashed.pid)", "a crash leaves its pid behind")

        let launch = try copy(file)
        XCTAssertNotNil(launch.wait(for: "READY"), "it starts: \(launch.lines)")
        XCTAssertEqual(written(file), "\(launch.pid)")
    }

    /// The gap, with a real stranger: the pid left by a crash has been
    /// reused by another of the person's processes, and it is sent the quit.
    func testAStalePidFileNamingAnUnrelatedLiveProcessSignalsItToday() throws {
        let folder = try instanceFolder()
        let file = folder.appendingPathComponent("lodestar.pid")
        let signals = folder.appendingPathComponent("stranger.signals")
        let stranger = try InstanceProbe(["stranger", "--signal-log", signals.path], from: Self.self)
        XCTAssertNotNil(stranger.wait(for: "READY"))
        try "\(stranger.pid)".write(to: file, atomically: true, encoding: .utf8)

        let launch = try copy(file)
        XCTAssertNotNil(launch.wait(for: "READY"))
        let received = (try? String(contentsOf: signals, encoding: .utf8)) ?? ""
        XCTAssertTrue(received.contains("TERM"), "the unrelated process was asked to quit: \(received)")
    }
}
