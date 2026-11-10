import XCTest
import StoicStore
@testable import LodestarCore

/// The one-copy rule between real processes: the kernel's lock, the probe's
/// stand-ins for a running copy (`copy --lock` holds the instance lock; `copy`
/// alone is an older build that takes over by the pid file) and an unrelated
/// process that writes down every signal it is sent.
///
/// Nothing here starts the app, and nothing signals a process this test did not
/// start: the pid files are in a folder of the test's own.
final class SingleInstanceProcessTests: XCTestCase {
    private var folder: URL!
    private var lock: URL { folder.appendingPathComponent("data/lodestar.lock") }
    private var pid: URL { folder.appendingPathComponent("config/lodestar.pid") }
    private var files: SingleInstance.Files { .init(lock: lock, pid: pid) }

    override func setUpWithError() throws {
        folder = try instanceFolder()
        for sub in ["data", "config"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    /// A copy of the new build (`locked`), or an older one.
    private func startCopy(locked: Bool = true, quitSeconds: Double = 0, wait: Double? = nil, extra: [String] = []) throws -> InstanceProbe {
        var arguments = ["copy", "--pid-file", pid.path, "--quit-seconds", "\(quitSeconds)"]
        if locked { arguments += ["--lock", lock.path] }
        if let wait { arguments += ["--wait", "\(wait)"] }
        return try InstanceProbe(arguments + extra, from: Self.self)
    }

    private func pidFile() -> String? { try? String(contentsOf: pid, encoding: .utf8) }

    /// Whether the lock is held by anyone, asked the way a launch asks: by trying.
    private func lockIsHeld() throws -> Bool {
        let other = FileLock(path: lock.path, fileSystem: OwnerOnly.fileSystem)
        return try !other.tryAcquire()
    }

    private func recorded() -> [String] {
        ((try? String(contentsOf: lock, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func signalsReceived(_ log: URL) -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    /// An unrelated process, a shell, that writes down the signals it is sent.
    private func shellStranger(log: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let traps = ["TERM", "HUP", "INT", "USR1", "USR2", "QUIT"].map { "trap 'echo \($0) >> \"\(log.path)\"' \($0);" }.joined(separator: " ")
        process.arguments = ["-c", traps + " while :; do sleep 0.1; done"]
        try process.run()
        addTeardownBlock { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        usleep(300_000)  // the traps are set
        return process
    }

    // MARK: A normal launch

    func testANormalLaunchHoldsTheLockAndNamesItselfInBothFiles() throws {
        let first = try startCopy()
        XCTAssertNotNil(first.wait(for: "READY"), "\(first.lines)")
        XCTAssertTrue(first.lines.contains("TOOK holds=true replaced=- standing=-"), "\(first.lines)")
        XCTAssertTrue(try lockIsHeld(), "held for as long as it runs")
        XCTAssertEqual(pidFile(), "\(first.pid)")
        let identity = try XCTUnwrap(SystemProcesses().identity(of: first.pid))
        XCTAssertEqual(recorded(), ["\(first.pid)", "\(identity.started)"], "the lock file says who, and the process's own start time")
        XCTAssertEqual(SingleInstance.runningCopy(files: files, selfPid: getpid()), first.pid)
    }

    // MARK: A second launch

    func testASecondLaunchAsksTheHolderToQuitAndTakesTheLockWhenItGoes() throws {
        let first = try startCopy(quitSeconds: 0.3)
        XCTAssertNotNil(first.wait(for: "READY"))
        let second = try startCopy()
        XCTAssertNotNil(second.wait(for: "READY"), "\(second.lines)")

        XCTAssertEqual(first.waitForExit(), 0, "it shut down, it was not killed")
        XCTAssertTrue(first.lines.contains("TERMED \(first.pid)"), "\(first.lines)")
        XCTAssertTrue(second.lines.contains("TOOK holds=true replaced=\(first.pid) standing=-"), "\(second.lines)")
        XCTAssertLessThan(try XCTUnwrap(first.moment(of: "EXITING")), try XCTUnwrap(second.moment(of: "READY")),
                          "the second is not ready until the first has gone")
        XCTAssertTrue(try lockIsHeld(), "and the second holds it")
        XCTAssertEqual(recorded().first, "\(second.pid)")
        XCTAssertEqual(pidFile(), "\(second.pid)", "the first did not clear the file the second wrote")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "the lock file outlives the holder that quit")
    }

    /// The test's own process as the launching copy, against a real holder: the
    /// type itself, not the probe's use of it.
    func testThisProcessTakesOverFromARealHolder() throws {
        let holder = try startCopy(quitSeconds: 0.3)
        XCTAssertNotNil(holder.wait(for: "READY"))
        let launching = SingleInstance(files: files)
        addTeardownBlock { launching.release() }
        let outcome = launching.takeOver()
        XCTAssertEqual(outcome, SingleInstance.Outcome(holdsLock: true, replaced: holder.pid))
        XCTAssertEqual(holder.waitForExit(), 0)
        XCTAssertTrue(launching.holdsLock)
        XCTAssertEqual(pidFile(), "\(getpid())")
    }

    // MARK: A launch after a crash

    func testALaunchAfterACrashFindsTheLockFreeAndAsksNobody() throws {
        let crashed = try startCopy()
        XCTAssertNotNil(crashed.wait(for: "READY"))
        crashed.crash()
        XCTAssertFalse(try lockIsHeld(), "the kernel let go of it with the process")
        XCTAssertEqual(pidFile(), "\(crashed.pid)", "the pid file is stale, as a crash leaves it")

        let launch = try startCopy()
        XCTAssertNotNil(launch.wait(for: "READY"), "\(launch.lines)")
        XCTAssertTrue(launch.lines.contains("TOOK holds=true replaced=- standing=-"), "\(launch.lines)")
        XCTAssertEqual(pidFile(), "\(launch.pid)")
    }

    /// The lock does not travel to a child of the holder: a helper that outlives
    /// a crashed copy must not make the next launch think that copy still runs.
    func testAHelperThatOutlivesACrashedHolderDoesNotKeepTheLock() throws {
        let holder = try startCopy(extra: ["--spawn-child"])
        let childLine = try XCTUnwrap(holder.wait(for: "CHILD"), "\(holder.lines)")
        let child = try XCTUnwrap(Int32(childLine.split(separator: " ").last ?? ""))
        addTeardownBlock { kill(child, SIGKILL) }
        XCTAssertNotNil(holder.wait(for: "READY"))
        XCTAssertTrue(try lockIsHeld())
        holder.crash()
        XCTAssertEqual(kill(child, 0), 0, "the helper is still running")
        XCTAssertFalse(try lockIsHeld(), "and the lock is free all the same")
    }

    // MARK: A pid file that names a stranger

    /// The pid left by a crash was given to another of the person's processes.
    /// It is never signalled, whichever way the file's own process came to be
    /// gone.
    func testAStalePidFileNamingAnUnrelatedLiveProcessSignalsNothing() throws {
        let signals = folder.appendingPathComponent("stranger.signals")
        let stranger = try shellStranger(log: signals)
        try "\(stranger.processIdentifier)".write(to: pid, atomically: true, encoding: .utf8)

        let launch = try startCopy(wait: 1)
        XCTAssertNotNil(launch.wait(for: "READY"), "\(launch.lines)")
        XCTAssertTrue(launch.lines.contains("TOOK holds=true replaced=- standing=-"), "\(launch.lines)")
        usleep(500_000)
        XCTAssertEqual(signalsReceived(signals), "", "the stranger was sent nothing")
        XCTAssertTrue(stranger.isRunning)
        XCTAssertEqual(pidFile(), "\(launch.pid)")
    }

    /// Even a process of Lodestar's own name: it began after the file was written,
    /// so it cannot be what wrote it.
    func testAStalePidFileNamingAProcessOfTheSameNameThatBeganLaterSignalsNothing() throws {
        let signals = folder.appendingPathComponent("stranger.signals")
        let stranger = try InstanceProbe(["stranger", "--signal-log", signals.path], from: Self.self)
        XCTAssertNotNil(stranger.wait(for: "READY"))
        try "\(stranger.pid)".write(to: pid, atomically: true, encoding: .utf8)
        let before = Date().addingTimeInterval(-60)  // written a minute before the stranger began
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: pid.path)

        let launch = try startCopy(wait: 1)
        XCTAssertNotNil(launch.wait(for: "READY"), "\(launch.lines)")
        usleep(500_000)
        XCTAssertEqual(signalsReceived(signals), "")
        XCTAssertTrue(stranger.isRunning)
    }

    /// What it was before: an older build trusts the pid file, and asks the stranger.
    func testAnOlderBuildAsksTheStrangerToQuitToday() throws {
        let signals = folder.appendingPathComponent("stranger.signals")
        let stranger = try shellStranger(log: signals)
        try "\(stranger.processIdentifier)".write(to: pid, atomically: true, encoding: .utf8)

        let older = try startCopy(locked: false, wait: 1)
        XCTAssertNotNil(older.wait(for: "READY"), "\(older.lines)")
        XCTAssertTrue(signalsReceived(signals).contains("TERM"), "the stranger was asked to quit")
    }

    // MARK: The update's handover

    /// Who holds the lock when: the old copy until it has exited, restoring its
    /// windows meanwhile; the successor from then on. They overlap as processes,
    /// never as holders, and the pid file changes hands last, which is the verdict
    /// the watchdog reads.
    func testTheUpdateSuccessorEndsUpHoldingTheLockAndTheOldCopyExits() throws {
        let old = try startCopy(quitSeconds: 1.0)
        XCTAssertNotNil(old.wait(for: "READY"))
        let oldIdentity = try XCTUnwrap(SystemProcesses().identity(of: old.pid))

        let successor = try startCopy()
        XCTAssertNotNil(successor.wait(for: "BOOT"))
        XCTAssertNotNil(old.wait(for: "TERMED"), "asked to quit: \(old.lines)")
        // The overlap: both are running, the old one holds the lock and the file names it.
        XCTAssertTrue(old.isRunning)
        XCTAssertNil(successor.moment(of: "READY"), "the successor is waiting")
        XCTAssertEqual(recorded(), ["\(old.pid)", "\(oldIdentity.started)"])
        XCTAssertTrue(try lockIsHeld())
        XCTAssertEqual(pidFile(), "\(old.pid)")

        XCTAssertNotNil(successor.wait(for: "READY"), "\(successor.lines)")
        XCTAssertEqual(old.waitForExit(), 0)
        XCTAssertLessThan(try XCTUnwrap(old.moment(of: "EXITING")), try XCTUnwrap(successor.moment(of: "READY")))
        let identity = try XCTUnwrap(SystemProcesses().identity(of: successor.pid))
        XCTAssertEqual(recorded(), ["\(successor.pid)", "\(identity.started)"], "the successor holds it")
        XCTAssertEqual(pidFile(), "\(successor.pid)")
        XCTAssertTrue(try lockIsHeld())

        // And the lock goes with it when it crashes.
        successor.crash()
        XCTAssertFalse(try lockIsHeld())
    }

    // MARK: Builds on either side of the lock

    /// An update from a build that has no lock: the successor holds it, and the
    /// old copy, which does not, is found by the pid file it wrote.
    func testANewBuildTakesOverFromAnOlderOneThatHoldsNoLock() throws {
        let older = try startCopy(locked: false, quitSeconds: 0.3)
        XCTAssertNotNil(older.wait(for: "READY"))
        XCTAssertFalse(try lockIsHeld(), "an older build holds nothing")

        let newer = try startCopy()
        XCTAssertNotNil(newer.wait(for: "READY"), "\(newer.lines)")
        XCTAssertEqual(older.waitForExit(), 0)
        XCTAssertTrue(newer.lines.contains("TOOK holds=true replaced=\(older.pid) standing=-"), "\(newer.lines)")
        XCTAssertTrue(try lockIsHeld())
        XCTAssertEqual(pidFile(), "\(newer.pid)")
    }

    /// A rollback: the older build reads the pid file the new one writes as ever,
    /// asks it to quit, and runs; the lock is free after it. A newer build that
    /// launches then takes the lock and replaces the older one by its pid file.
    func testAnOlderBuildTakesOverFromANewOneAndANewerOneThenFromIt() throws {
        let newer = try startCopy(quitSeconds: 0.3)
        XCTAssertNotNil(newer.wait(for: "READY"))
        XCTAssertEqual(pidFile(), "\(newer.pid)", "written as every build before it wrote it")

        let older = try startCopy(locked: false, quitSeconds: 0.3)
        XCTAssertNotNil(older.wait(for: "READY"), "\(older.lines)")
        XCTAssertEqual(newer.waitForExit(), 0, "the new build quit on the old one's SIGTERM")
        XCTAssertFalse(try lockIsHeld(), "and the older one holds no lock")
        XCTAssertEqual(pidFile(), "\(older.pid)")

        let again = try startCopy()
        XCTAssertNotNil(again.wait(for: "READY"), "\(again.lines)")
        XCTAssertEqual(older.waitForExit(), 0)
        XCTAssertTrue(again.lines.contains("TOOK holds=true replaced=\(older.pid) standing=-"), "\(again.lines)")
        XCTAssertTrue(try lockIsHeld())
    }

    // MARK: A launch that cannot have the lock

    /// A holder that will not quit: the launch waits the time it is given and goes
    /// on without the lock, as a launch that could not replace the old copy
    /// always went on. It does not hang, and the holder is not harmed.
    func testALaunchThatCannotHaveTheLockInTheWaitGoesOnWithoutIt() throws {
        let holder = try startCopy(extra: ["--ignore-term"])
        XCTAssertNotNil(holder.wait(for: "READY"))
        let began = Date()
        let launch = try startCopy(wait: 1)
        XCTAssertNotNil(launch.wait(for: "READY", timeout: 15), "\(launch.lines)")
        XCTAssertLessThan(Date().timeIntervalSince(began), 12, "bounded")
        XCTAssertTrue(launch.lines.contains("TOOK holds=false replaced=- standing=\(holder.pid)"), "\(launch.lines)")
        XCTAssertTrue(holder.lines.contains("TERMED \(holder.pid)"), "it was asked, once")
        XCTAssertEqual(holder.lines.filter { $0.hasPrefix("TERMED") }.count, 1)
        XCTAssertTrue(holder.isRunning)
        XCTAssertEqual(pidFile(), "\(launch.pid)")
    }
}
