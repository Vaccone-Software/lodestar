import Foundation
import StoicStore
import Synchronization

/// Only one copy of Lodestar runs. A copy that is running holds an exclusive
/// lock (`FileLock`, `flock(2)`) on a file in the data folder for as long as
/// it lives, and the kernel lets go of it when the process ends, however it
/// ends. That is the proof that a copy is running, and the lack of it the proof
/// that none is: there is no stale lock to detect, and no number to trust.
///
/// A launching copy takes the lock. If another holds it, that holder is asked
/// to quit and waited for, and the lock is taken when it goes.
///
/// ## Who is asked to quit
///
/// The lock says that a copy runs, not which process it is, and quitting needs
/// a pid. The holder writes who it is into the lock file, in place, once it
/// holds the lock: its pid and the time that process began. A pid is only
/// asked to quit when it is alive and began at exactly that time, so a pid the
/// system has since given to another process (a crash leaves the number
/// behind) is not that process, whatever the pid file says. A holder is alive
/// for as long as it holds the lock, so a live process that wrote the record is
/// the holder. A record that does not name a live process of that start is a
/// holder that has not written yet, and is waited for, not guessed at.
///
/// ## The pid file
///
/// The pid file is written as ever, a bare pid, for what reads it: the update
/// watchdog, `lodestar reload`, an older build taking over. It is not what a
/// copy is found by here, except for a copy that holds no lock, an older
/// build (or one that came up without the lock), which is found by it and
/// only when the process is the one that wrote it: it is called what this
/// process is called, and it began no later than the file was last written,
/// which a process that has been given a dead copy's pid since cannot have
/// done.
///
/// ## The handover
///
/// An update's successor is a launching copy like any other: the old copy
/// holds the lock until it has exited, restoring its windows on its way, and
/// the successor takes it then, so the two overlap while only one holds it.
public final class SingleInstance: Sendable {
    /// Where the lock and the pid file are.
    public struct Files: Equatable, Sendable {
        public var lock: URL
        public var pid: URL

        public init(lock: URL, pid: URL) {
            self.lock = lock
            self.pid = pid
        }
    }

    /// What a launch found and did.
    public struct Outcome: Equatable, Sendable {
        /// This copy holds the lock. False only when the lock could not be had
        /// in the wait, or at all, and the launch went on without it.
        public var holdsLock = false
        /// A copy that was asked to quit and has gone.
        public var replaced: Int32?
        /// A copy that was asked to quit and was still there when the wait ended.
        /// The launch goes on: two copies run, as they always have in this case.
        public var standing: Int32?
        /// Why the lock was not had, when it was not.
        public var unlockedBecause: String?

        public init(holdsLock: Bool = false, replaced: Int32? = nil, standing: Int32? = nil, unlockedBecause: String? = nil) {
            self.holdsLock = holdsLock
            self.replaced = replaced
            self.standing = standing
            self.unlockedBecause = unlockedBecause
        }
    }

    /// How long the outgoing copy has to go. It restores parked windows on
    /// its way out, which is unbounded accessibility work.
    public static let wait: TimeInterval = 5

    /// The record's width: written over itself, never shorter, so that there is
    /// no moment in which the file is empty.
    static let recordWidth = 64
    /// How much later than a process began its pid file may have been written
    /// and still be its own: the clocks agree, but a file system's time is only
    /// so fine.
    static let slack: Int64 = 1_000_000

    public let files: Files
    let selfPid: Int32
    private let processes: any InstanceProcesses
    private let clock: InstanceClock
    private let lock: FileLock
    private let fileSystem: any FileSystem

    public init(files: Files, selfPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                processes: any InstanceProcesses = SystemProcesses(), clock: InstanceClock = .system,
                fileSystem: any FileSystem = OwnerOnly.fileSystem) {
        self.files = files
        self.selfPid = selfPid
        self.processes = processes
        self.clock = clock
        self.fileSystem = fileSystem
        lock = FileLock(path: files.lock.path, fileSystem: fileSystem)
    }

    /// Whether this copy holds the lock. It holds it until the process ends.
    public var holdsLock: Bool { lock.isHeld }

    /// The instances that hold the lock, kept for the life of the process: a
    /// `FileLock` lets go when it is dropped, so that a launch that forgot to keep
    /// its instance would run without the lock and say nothing. Nothing but the
    /// process ending (or `release()`, for a test) lets go of it.
    private static let holders = Mutex<[SingleInstance]>([])

    /// Lets go of the lock. The app never does: a copy holds it until it ends, so
    /// that the next launch takes it only when this one is gone. For tests, and
    /// for nothing else.
    public func release() {
        Log.attempt("instance lock: could not release it") { try lock.release() }
        Self.holders.withLock { $0.removeAll { $0 === self } }
    }

    // MARK: Launching

    /// Takes the lock, asking the holder to quit if there is one, then makes
    /// this copy the one the pid file names. Blocks for at most `wait` for a
    /// holder, and again for a copy that holds no lock: a launch that cannot
    /// have the lock goes on without it, as a launch that could not replace
    /// the old copy always did, and says so.
    @discardableResult
    public func takeOver(wait: TimeInterval = SingleInstance.wait, poll: TimeInterval = 0.025) -> Outcome {
        var outcome = Outcome()
        guard !lock.isHeld else {
            outcome.holdsLock = true
            return outcome
        }
        Log.attempt("instance lock: could not make its folder") {
            try FileManager.default.createDirectory(
                at: files.lock.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        let taken = acquire(wait: wait, poll: poll)
        outcome.holdsLock = taken.held
        if taken.held {
            Self.holders.withLock { $0.append(self) }
            // At once, before the wait for an older copy below: a copy that
            // launches in the meantime must find who holds the lock.
            writeRecord()
            outcome.replaced = taken.asked
            if let older = replaceCopyWithoutLock(wait: wait, poll: poll) {
                if older.gone { outcome.replaced = older.pid } else { outcome.standing = older.pid }
            }
        } else if let why = taken.failure {
            // The lock itself cannot be had (a folder that will not take it).
            // The rule that stood before it still can be kept.
            Log.error("instance lock unavailable (\(why)) — running without it")
            outcome.unlockedBecause = why
            if let older = replaceCopyWithoutLock(wait: wait, poll: poll) {
                if older.gone { outcome.replaced = older.pid } else { outcome.standing = older.pid }
            }
        } else if let holder = taken.asked {
            Log.error("previous lodestar (pid \(holder)) did not exit in \(Int(wait))s — continuing anyway")
            outcome.standing = holder
            outcome.unlockedBecause = "the holder did not exit"
        } else {
            Log.error("another lodestar holds the lock and could not be identified — continuing anyway")
            outcome.unlockedBecause = "the holder could not be identified"
        }
        Log.attempt("instance lock: could not write the pid file") {
            try "\(selfPid)".write(to: files.pid, atomically: true, encoding: .utf8)
        }
        return outcome
    }

    private struct Taken {
        var held: Bool
        var asked: Int32?
        var failure: String?
    }

    /// The lock, asking its holder to quit when the holder can be told from
    /// the record, once for each holder.
    private func acquire(wait: TimeInterval, poll: TimeInterval) -> Taken {
        let deadline = clock.now().addingTimeInterval(wait)
        var asked: Int32?
        while true {
            do {
                if try lock.tryAcquire() { return Taken(held: true, asked: asked) }
            } catch {
                return Taken(held: false, asked: asked, failure: "\(error)")
            }
            if let holder = Self.holder(of: files, excluding: selfPid, processes: processes), holder != asked {
                Log.info("replacing running lodestar (pid \(holder))")
                processes.terminate(holder)
                asked = holder
            }
            if clock.now() >= deadline { return Taken(held: false, asked: asked) }
            clock.pause(poll)
        }
    }

    /// An older copy holds no lock, and is found by the pid file. It is asked
    /// to quit and waited for, as a holder is. Nothing when there is none.
    private func replaceCopyWithoutLock(wait: TimeInterval, poll: TimeInterval) -> (pid: Int32, gone: Bool)? {
        guard let pid = Self.copyWithoutLock(in: files, excluding: selfPid, processes: processes) else { return nil }
        Log.info("replacing running lodestar (pid \(pid)), which holds no lock")
        processes.terminate(pid)
        let deadline = clock.now().addingTimeInterval(wait)
        while processes.isAlive(pid), clock.now() < deadline { clock.pause(poll) }
        if processes.isAlive(pid) {
            Log.error("previous lodestar (pid \(pid)) did not exit in \(Int(wait))s — continuing anyway")
            return (pid, false)
        }
        Log.info("previous lodestar exited; taking over")
        return (pid, true)
    }

    // MARK: The record

    /// Who holds the lock, written by the holder into the lock file: its pid and
    /// the time the process began, in a fixed width so that it is written over
    /// itself in one piece. In place: a lock file that was replaced by another
    /// would be a different file under the same name.
    private func writeRecord() {
        guard let me = processes.identity(of: selfPid) else {
            Log.error("instance lock: this process could not be identified, so a later launch cannot ask it to quit")
            return
        }
        var text = "\(selfPid) \(me.started)\n"
        text += String(repeating: " ", count: max(0, Self.recordWidth - text.utf8.count))
        do {
            let file = try fileSystem.open(files.lock.path, mode: .readWrite)
            defer { Log.attempt("instance lock: could not close the lock file after writing the holder") { try fileSystem.close(file) } }
            try fileSystem.write(file, Array(text.utf8), at: 0)
        } catch {
            Log.error("instance lock: the holder's record was not written (\(error))")
        }
    }

    static func record(in lock: URL) -> (pid: Int32, started: Int64)? {
        guard let text = try? String(contentsOf: lock, encoding: .utf8) else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, let pid = Int32(words[0]), let started = Int64(words[1]) else { return nil }
        return (pid, started)
    }

    // MARK: Finding the running copy

    /// The process that holds the lock, when the lock is held by another and
    /// the record names a process that is alive and began when the record says.
    static func holder(of files: Files, excluding me: Int32, processes: any InstanceProcesses) -> Int32? {
        guard let record = record(in: files.lock), record.pid != me,
              processes.isAlive(record.pid), processes.identity(of: record.pid)?.started == record.started
        else { return nil }
        return record.pid
    }

    /// The copy that holds no lock and wrote the pid file: alive, called what
    /// this process is called, and begun no later than the file was written. A
    /// stale file's pid, given to another process since, is never that.
    static func copyWithoutLock(in files: Files, excluding me: Int32, processes: any InstanceProcesses) -> Int32? {
        guard let text = try? String(contentsOf: files.pid, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != me, processes.isAlive(pid),
              let theirs = processes.identity(of: pid), let mine = processes.identity(of: me),
              theirs.name == mine.name,
              let written = (try? FileManager.default.attributesOfItem(atPath: files.pid.path))?[.modificationDate] as? Date,
              theirs.started <= Int64((written.timeIntervalSince1970 * 1_000_000).rounded()) + slack
        else { return nil }
        return pid
    }

    /// The running copy that is not this process, for what has to end it (an
    /// uninstall): the holder of the lock, or else the copy that holds none.
    /// Nothing when none runs. Never a process that merely has a number the pid
    /// file names.
    public static func runningCopy(files: Files, selfPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                   processes: any InstanceProcesses = SystemProcesses(),
                                   fileSystem: any FileSystem = OwnerOnly.fileSystem) -> Int32? {
        // The lock is looked at, never made: a folder that is gone has no one in it.
        if FileManager.default.fileExists(atPath: files.lock.path) {
            let looking = FileLock(path: files.lock.path, fileSystem: fileSystem)
            if let free = try? looking.tryAcquire() {
                if free { Log.attempt("instance lock: could not release the lock taken to look") { try looking.release() } }
                else if let holder = holder(of: files, excluding: selfPid, processes: processes) { return holder }
            }
        }
        return copyWithoutLock(in: files, excluding: selfPid, processes: processes)
    }

    /// Asks the running copy, if there is one, to quit. Whether one was asked.
    @discardableResult
    public static func stopRunningCopy(files: Files, selfPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                       processes: any InstanceProcesses = SystemProcesses()) -> Bool {
        guard let pid = runningCopy(files: files, selfPid: selfPid, processes: processes) else { return false }
        processes.terminate(pid)
        return true
    }

    /// Waits for the running copy to be gone: true when none runs, false when
    /// one still does at the end of `timeout`.
    public static func awaitNoRunningCopy(files: Files, timeout: TimeInterval = 10, poll: TimeInterval = 0.05,
                                          selfPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                          processes: any InstanceProcesses = SystemProcesses(),
                                          clock: InstanceClock = .system) -> Bool {
        let deadline = clock.now().addingTimeInterval(timeout)
        while runningCopy(files: files, selfPid: selfPid, processes: processes) != nil, clock.now() < deadline {
            clock.pause(poll)
        }
        return runningCopy(files: files, selfPid: selfPid, processes: processes) == nil
    }
}
