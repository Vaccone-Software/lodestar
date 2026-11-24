import XCTest
import StoicStore
@testable import LodestarCore

/// The rule that only one copy runs, on `FileLock`: what a launching copy
/// asks, whom, and when it gives up waiting, with a table of processes in
/// place of the machine and a real lock on a real file.
final class SingleInstanceTests: XCTestCase {
    /// A machine of a table of processes. What a process asked to quit does
    /// is the test's to say (`onTerminate`), and the clock it moves is its own.
    private final class Machine: InstanceProcesses, @unchecked Sendable {
        private let lock = NSLock()
        private var table: [Int32: ProcessIdentity] = [:]
        private var asked: [Int32] = []
        private var time = Date(timeIntervalSince1970: 1_000_000)
        private var pauses = 0
        var onTerminate: ((Int32) -> Void)?
        var onPause: ((Int) -> Void)?

        func run(_ pid: Int32, started: Int64, name: String = "lodestar") {
            lock.withLock { table[pid] = ProcessIdentity(started: started, name: name) }
        }

        func exit(_ pid: Int32) { lock.withLock { table[pid] = nil } }

        var asks: [Int32] { lock.withLock { asked } }
        var waited: TimeInterval { lock.withLock { time.timeIntervalSince1970 - 1_000_000 } }

        func isAlive(_ pid: Int32) -> Bool { lock.withLock { table[pid] != nil } }
        func identity(of pid: Int32) -> ProcessIdentity? { lock.withLock { table[pid] } }

        func terminate(_ pid: Int32) {
            lock.withLock { asked.append(pid) }
            onTerminate?(pid)
        }

        var clock: InstanceClock {
            InstanceClock(now: { [self] in lock.withLock { time } }, pause: { [self] seconds in
                let count: Int = lock.withLock {
                    time = time.addingTimeInterval(seconds)
                    pauses += 1
                    return pauses
                }
                onPause?(count)
            })
        }
    }

    private var folder: URL!
    private var files: SingleInstance.Files!
    private let me: Int32 = 500
    private let myStart: Int64 = 5_000_000_000

    override func setUpWithError() throws {
        folder = try instanceFolder()
        // The data folder does not exist yet, as on a first launch.
        files = .init(lock: folder.appendingPathComponent("data/lodestar.lock"),
                      pid: folder.appendingPathComponent("config/lodestar.pid"))
        try FileManager.default.createDirectory(at: files.pid.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func machine() -> Machine {
        let machine = Machine()
        machine.run(me, started: myStart)
        return machine
    }

    private func instance(_ machine: Machine) -> SingleInstance {
        let copy = SingleInstance(files: files, selfPid: me, processes: machine, clock: machine.clock)
        addTeardownBlock { copy.release() }
        return copy
    }

    private func pidFile() -> String? { try? String(contentsOf: files.pid, encoding: .utf8) }

    /// Another copy holding the lock, as it would: a lock of its own on the file,
    /// and its record written once it holds it (when `record` is given).
    private func holding(record: String?) throws -> FileLock {
        try FileManager.default.createDirectory(at: files.lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = FileLock(path: files.lock.path, fileSystem: OwnerOnly.fileSystem)
        XCTAssertTrue(try other.tryAcquire())
        if let record { try record.write(to: files.lock, atomically: false, encoding: .utf8) }
        return other
    }

    private func recordText(_ pid: Int32, _ started: Int64) -> String { "\(pid) \(started)\n" }

    /// A pid file as the copy that wrote it left it: written at `written`.
    private func pidFile(naming pid: Int32, writtenMicros written: Int64) throws {
        try "\(pid)".write(to: files.pid, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(written) / 1_000_000)], ofItemAtPath: files.pid.path)
    }

    // MARK: A first launch

    func testFirstLaunchTakesTheLockAsksNobodyAndWritesBothFiles() throws {
        let machine = machine()
        let copy = instance(machine)
        let outcome = copy.takeOver()
        XCTAssertEqual(outcome, SingleInstance.Outcome(holdsLock: true))
        XCTAssertTrue(copy.holdsLock)
        XCTAssertEqual(machine.asks, [])
        XCTAssertEqual(pidFile(), "500", "the pid file is the bare pid, as the watchdog reads it")
        let record = try XCTUnwrap(try String(contentsOf: files.lock, encoding: .utf8))
        XCTAssertEqual(record.split(whereSeparator: \.isWhitespace).map(String.init), ["500", "\(myStart)"],
                       "and the lock file says who holds it, and when that process began")
    }

    func testTheLockFileIsOwnerOnlyInAFolderMadeForIt() throws {
        let copy = instance(machine())
        copy.takeOver()
        let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: files.lock.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        let folderMode = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: files.lock.deletingLastPathComponent().path)[.posixPermissions] as? Int)
        XCTAssertEqual(folderMode & 0o077, 0, "nobody else can reach it")
    }

    func testTheLockFileIsNeverRemovedAndTheLockLetsGoOnlyWhenTheHolderDoes() throws {
        let copy = instance(machine())
        copy.takeOver()
        let other = FileLock(path: files.lock.path, fileSystem: OwnerOnly.fileSystem)
        XCTAssertFalse(try other.tryAcquire(), "held while the copy lives")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.lock.path))
        copy.release()  // the process ending, as far as one process can say
        XCTAssertTrue(try other.tryAcquire(), "the kernel lets go with the descriptor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.lock.path), "and the file is still there")
    }

    /// A lock is lost by dropping the object that holds it. A launch that does
    /// not keep what it was given runs without the lock and says nothing; it
    /// is not left to the caller to keep it.
    func testTheLockIsKeptWhetherOrNotTheLaunchKeepsTheInstance() throws {
        let machine = machine()
        weak var dropped: SingleInstance?
        do {
            // Not through `instance(_:)`, whose teardown would keep it.
            let copy = SingleInstance(files: files, selfPid: me, processes: machine, clock: machine.clock)
            copy.takeOver()
            dropped = copy
        }
        XCTAssertNotNil(dropped, "the instance is kept for the life of the process")
        let other = FileLock(path: files.lock.path, fileSystem: OwnerOnly.fileSystem)
        XCTAssertFalse(try other.tryAcquire(), "and so is the lock")
        dropped?.release()
        XCTAssertTrue(try other.tryAcquire())
    }

    // MARK: A second launch

    func testAHolderTheRecordNamesIsAskedOnceAndWaitedFor() throws {
        let machine = machine()
        machine.run(400, started: 4_000_000_000)
        let other = try holding(record: recordText(400, 4_000_000_000))
        machine.onPause = { count in
            if count == 30 { try? other.release(); machine.exit(400) }  // 750 ms of restoring windows
        }
        let outcome = instance(machine).takeOver()
        XCTAssertEqual(outcome, SingleInstance.Outcome(holdsLock: true, replaced: 400))
        XCTAssertEqual(machine.asks, [400], "asked once, not at every poll")
        XCTAssertEqual(machine.waited, 0.75, accuracy: 0.05)
        XCTAssertEqual(pidFile(), "500")
    }

    /// The record is written once the holder holds the lock, so there is a moment
    /// when it is the last holder's. The launch waits for the holder to say who it
    /// is, and does not ask the process the old record names.
    func testAHolderThatHasNotWrittenItsRecordYetIsWaitedForNotGuessedAt() throws {
        let machine = machine()
        machine.run(300, started: 3_000_000_000)  // the last holder's number, alive: reused by a stranger
        let other = try holding(record: recordText(300, 1))
        machine.run(400, started: 4_000_000_000)
        machine.onPause = { count in
            if count == 10 { try? self.recordText(400, 4_000_000_000).write(to: self.files.lock, atomically: false, encoding: .utf8) }
            if count == 20 { try? other.release(); machine.exit(400) }
        }
        machine.onTerminate = { pid in XCTAssertEqual(pid, 400, "only the holder is asked") }
        let outcome = instance(machine).takeOver()
        XCTAssertEqual(outcome.replaced, 400)
        XCTAssertEqual(machine.asks, [400])
    }

    // MARK: A launch after a crash

    func testACrashLeavesNoLockAndAStaleRecordAndPidFileAskNobody() throws {
        let machine = machine()
        try FileManager.default.createDirectory(at: files.lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try recordText(400, 4_000_000_000).write(to: files.lock, atomically: false, encoding: .utf8)
        try pidFile(naming: 400, writtenMicros: 4_000_000_001)  // 400 is not there
        let outcome = instance(machine).takeOver()
        XCTAssertEqual(outcome, SingleInstance.Outcome(holdsLock: true))
        XCTAssertEqual(machine.asks, [])
        XCTAssertEqual(pidFile(), "500")
    }

    /// The pid left by a crash is alive again as another process.
    func testAStalePidNamingAnUnrelatedLiveProcessIsNeverAsked() throws {
        let machine = machine()
        machine.run(400, started: 9_000_000_000, name: "Slack")  // not Lodestar; written no pid file
        try pidFile(naming: 400, writtenMicros: 9_000_000_500)  // a file fresher than it began, even
        let outcome = instance(machine).takeOver()
        XCTAssertEqual(outcome, SingleInstance.Outcome(holdsLock: true))
        XCTAssertEqual(machine.asks, [])
    }

    /// A process of Lodestar's name that began after the file was written did not
    /// write it, whatever it is called.
    func testAStalePidNamingAProcessThatBeganAfterTheFileWasWrittenIsNeverAsked() throws {
        let machine = machine()
        machine.run(400, started: 9_000_000_000)  // lodestar by name: a command that was run since
        try pidFile(naming: 400, writtenMicros: 8_000_000_000)
        XCTAssertEqual(instance(machine).takeOver(), SingleInstance.Outcome(holdsLock: true))
        XCTAssertEqual(machine.asks, [])
    }

    /// A record whose pid is a live process that began at another time is that
    /// number reused, and the holder, whoever it is, is waited for.
    func testARecordWhosePidWasReusedIsNeverAskedAndTheWaitIsBounded() throws {
        let machine = machine()
        machine.run(400, started: 9_000_000_000)
        let other = try holding(record: recordText(400, 4_000_000_000))
        let outcome = instance(machine).takeOver()
        XCTAssertEqual(machine.asks, [], "the stranger was not asked")
        XCTAssertFalse(outcome.holdsLock)
        XCTAssertNil(outcome.standing)
        XCTAssertNotNil(outcome.unlockedBecause)
        XCTAssertEqual(machine.waited, SingleInstance.wait, accuracy: 0.05, "and it is a bounded wait")
        XCTAssertEqual(pidFile(), "500", "the launch goes on, as it always did when it could not replace a copy")
        XCTAssertFalse(try FileLock(path: files.lock.path, fileSystem: OwnerOnly.fileSystem).tryAcquire(), "the holder still holds it")
        _ = other
    }

    func testAHolderThatNeverSaysWhoItIsIsWaitedForAFixedTimeAndNoLongerNobodyIsAsked() throws {
        let machine = machine()
        let other = try holding(record: nil)
        let outcome = instance(machine).takeOver()
        XCTAssertEqual(machine.asks, [])
        XCTAssertEqual(outcome.holdsLock, false)
        XCTAssertEqual(machine.waited, SingleInstance.wait, accuracy: 0.05)
        _ = other
    }

    func testAHolderThatWillNotQuitIsWaitedForFiveSecondsAndTheLaunchGoesOn() throws {
        let machine = machine()
        machine.run(400, started: 4_000_000_000)
        let other = try holding(record: recordText(400, 4_000_000_000))
        let outcome = instance(machine).takeOver()
        XCTAssertEqual(machine.asks, [400])
        XCTAssertEqual(outcome, SingleInstance.Outcome(holdsLock: false, replaced: nil, standing: 400,
                                                       unlockedBecause: "the holder did not exit"))
        XCTAssertEqual(machine.waited, 5.0, accuracy: 0.05)
        XCTAssertEqual(pidFile(), "500")
        _ = other
    }

    // MARK: An older build, which holds no lock

    func testACopyThatHoldsNoLockIsFoundByThePidFileItWroteAndReplaced() throws {
        let machine = machine()
        machine.run(400, started: 4_000_000_000)
        try pidFile(naming: 400, writtenMicros: 4_000_100_000)
        machine.onTerminate = { pid in machine.onPause = { count in if count == 8 { machine.exit(pid) } } }
        let outcome = instance(machine).takeOver()
        XCTAssertEqual(outcome, SingleInstance.Outcome(holdsLock: true, replaced: 400))
        XCTAssertEqual(machine.asks, [400])
        XCTAssertEqual(pidFile(), "500")
    }

    func testAnOlderCopyThatWillNotQuitIsWaitedForFiveSecondsToo() throws {
        let machine = machine()
        machine.run(400, started: 4_000_000_000)
        try pidFile(naming: 400, writtenMicros: 4_000_100_000)
        let outcome = instance(machine).takeOver()
        XCTAssertEqual(outcome.standing, 400)
        XCTAssertTrue(outcome.holdsLock, "the lock is its own all the same")
        XCTAssertEqual(machine.waited, 5.0, accuracy: 0.05)
    }

    // MARK: A lock that cannot be had

    /// A folder that will not take the lock (here, a directory in its place): the
    /// launch does not hang, and keeps the rule that stood before the lock.
    func testALockThatCannotBeHadIsReportedAndTheLaunchGoesOn() throws {
        let machine = machine()
        try FileManager.default.createDirectory(at: files.lock, withIntermediateDirectories: true)
        machine.run(400, started: 4_000_000_000)
        try pidFile(naming: 400, writtenMicros: 4_000_100_000)
        machine.onTerminate = { pid in machine.exit(pid) }
        let outcome = instance(machine).takeOver()
        XCTAssertFalse(outcome.holdsLock)
        XCTAssertNotNil(outcome.unlockedBecause)
        XCTAssertEqual(outcome.replaced, 400, "the pid file's copy is still replaced")
        XCTAssertEqual(pidFile(), "500")
        XCTAssertLessThan(machine.waited, 1)
    }

    // MARK: Finding the running copy

    func testTheRunningCopyIsTheHolderOrTheCopyThatWroteThePidFileAndNothingElse() throws {
        let machine = machine()
        XCTAssertNil(SingleInstance.runningCopy(files: files, selfPid: me, processes: machine), "nothing yet")

        machine.run(400, started: 4_000_000_000)
        let other = try holding(record: recordText(400, 4_000_000_000))
        XCTAssertEqual(SingleInstance.runningCopy(files: files, selfPid: me, processes: machine), 400)
        XCTAssertNil(SingleInstance.runningCopy(files: files, selfPid: 400, processes: machine), "not this process")
        try other.release()
        XCTAssertNil(SingleInstance.runningCopy(files: files, selfPid: me, processes: machine),
                     "the lock is free, so the record is a past holder's")

        machine.run(600, started: 6_000_000_000, name: "Safari")
        try pidFile(naming: 600, writtenMicros: 6_000_000_100)
        XCTAssertNil(SingleInstance.runningCopy(files: files, selfPid: me, processes: machine), "a stranger with the number")

        machine.run(700, started: 7_000_000_000)
        try pidFile(naming: 700, writtenMicros: 7_000_000_100)
        XCTAssertEqual(SingleInstance.runningCopy(files: files, selfPid: me, processes: machine), 700, "an older build")
    }

    func testStoppingAndWaitingAreBoundedAndNeverReachAStranger() throws {
        let machine = machine()
        machine.run(400, started: 4_000_000_000)
        let other = try holding(record: recordText(400, 4_000_000_000))
        XCTAssertTrue(SingleInstance.stopRunningCopy(files: files, selfPid: me, processes: machine))
        XCTAssertEqual(machine.asks, [400])
        XCTAssertFalse(SingleInstance.awaitNoRunningCopy(files: files, timeout: 10, selfPid: me, processes: machine,
                                                         clock: machine.clock), "it stays")
        XCTAssertEqual(machine.waited, 10, accuracy: 0.1)
        try other.release()
        machine.exit(400)
        XCTAssertTrue(SingleInstance.awaitNoRunningCopy(files: files, selfPid: me, processes: machine, clock: machine.clock))

        machine.run(600, started: 6_000_000_000, name: "Safari")
        try pidFile(naming: 600, writtenMicros: 6_000_000_100)
        XCTAssertFalse(SingleInstance.stopRunningCopy(files: files, selfPid: me, processes: machine))
        XCTAssertEqual(machine.asks, [400], "nobody else was asked")
    }

    /// What the kernel says about a process is what the takeover reads.
    func testTheSystemKnowsWhenThisProcessBeganAndWhatItIsCalled() throws {
        let identity = try XCTUnwrap(SystemProcesses().identity(of: getpid()))
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        XCTAssertLessThan(identity.started, now)
        XCTAssertGreaterThan(identity.started, now - 24 * 3_600 * 1_000_000, "it began today")
        XCTAssertFalse(identity.name.isEmpty)
        XCTAssertNil(SystemProcesses().identity(of: 0x7ffffff0), "no such process")
    }
}
