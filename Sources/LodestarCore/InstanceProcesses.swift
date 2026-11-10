import Foundation
import Stoic
import StoicTime

/// Who a process is, as far as the takeover needs to know: when it began and
/// what it is called. A pid is a number the system hands out again; a pid with
/// the start time it was seen with is one process for ever.
public struct ProcessIdentity: Equatable, Sendable {
    /// Microseconds since 1970 at which the process began.
    public var started: Int64
    /// The executable's name as the kernel keeps it (`lodestar`).
    public var name: String

    public init(started: Int64, name: String) {
        self.started = started
        self.name = name
    }
}

/// What the takeover asks of the machine, so that a test can answer in its
/// place: whether a process answers, who it is, and the one request it ever
/// makes of one, to quit. The real answers are `kill(2)` and `libproc`; a
/// test's are a table.
public protocol InstanceProcesses: Sendable {
    /// Whether a process with this pid answers `kill(pid, 0)`.
    func isAlive(_ pid: Int32) -> Bool
    /// The process's identity; nil when there is no such process or it will
    /// not say.
    func identity(of pid: Int32) -> ProcessIdentity?
    /// Asks the process to quit (SIGTERM, which a running copy turns into a
    /// graceful shutdown). The only signal the takeover ever sends.
    func terminate(_ pid: Int32)
}

public struct SystemProcesses: InstanceProcesses {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    public func identity(of pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ProcessIdentity(started: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec), name: name)
    }

    public func terminate(_ pid: Int32) { kill(pid, SIGTERM) }
}

/// Time as the takeover reads it: what it is, and a pause. The real pause
/// is a sleep; a test's moves a clock it owns, so a wait of five seconds
/// costs none.
public struct InstanceClock: Sendable {
    public var now: @Sendable () -> Date
    public var pause: @Sendable (TimeInterval) -> Void

    public init(now: @escaping @Sendable () -> Date, pause: @escaping @Sendable (TimeInterval) -> Void) {
        self.now = now
        self.pause = pause
    }

    public static let system = InstanceClock(now: { Moment.now.date }, pause: { usleep(UInt32($0 * 1_000_000)) })
}
