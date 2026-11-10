import Foundation

/// What the takeover asks of the machine, so that a test can answer in its
/// place: whether a process answers, and the one request it ever makes of
/// one, to quit. The real answers are `kill(2)`; a test's are a table.
public protocol InstanceProcesses: Sendable {
    /// Whether a process with this pid answers `kill(pid, 0)`.
    func isAlive(_ pid: Int32) -> Bool
    /// Asks the process to quit (SIGTERM, which a running copy turns into a
    /// graceful shutdown). The only signal the takeover ever sends.
    func terminate(_ pid: Int32)
}

public struct SystemProcesses: InstanceProcesses {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

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

    public static let system = InstanceClock(now: { Date() }, pause: { usleep(UInt32($0 * 1_000_000)) })
}
