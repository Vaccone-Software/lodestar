import Foundation
import LodestarCore
import Stoic
import StoicTime

/// Which step of launch is under way, and how long each one took.
///
/// A launch on a starved Mac (2026-11-03, load 450) reached the state store
/// 58 s after it began and was aborted a second later, and nothing in the
/// log said which step held it: launch runs on main, and a main thread that
/// is not moving writes nothing. So each step is named as it begins. A step
/// that overruns says so as it ends, a launch that finishes writes them all
/// on one line, and the watchdog, which runs on its own thread, can name the
/// step it gave up in.
final class LaunchStages {
    static let shared = LaunchStages()

    /// A step this long is written down at once, not left to a summary the
    /// launch may never reach.
    static let slow: Duration = .seconds(1)

    private let clock: AnyClock
    private let write: (String, KeyValuePairs<String, Any>) -> Void
    private let lock = NSLock()
    private var running: (name: String, began: AnyClock.Instant)?
    private var ended: [(name: String, took: Duration)] = []

    init(clock: AnyClock = .suspending,
         write: @escaping (String, KeyValuePairs<String, Any>) -> Void = { Log.info($0, $1) }) {
        self.clock = clock
        self.write = write
    }

    /// The step under way; nil before launch starts and after it finishes.
    var current: String? { lock.withLock { running?.name } }

    /// Ends the running step and begins `name`.
    func enter(_ name: String) {
        endRunning(beginning: name)
    }

    /// Ends the last step and writes every step on one line.
    func finish() {
        endRunning(beginning: nil)
        let line = lock.withLock { ended.map { "\($0.name) \(Self.milliseconds($0.took))" }.joined(separator: ", ") }
        write("launch stages", ["exec-ms": Self.millisecondsSinceExec() ?? -1, "ms": line])
    }

    private func endRunning(beginning next: String?) {
        let now = clock.now
        let finished: (name: String, took: Duration)? = lock.withLock {
            defer { running = next.map { ($0, now) } }
            guard let running else { return nil }
            let step = (running.name, running.began.duration(to: now))
            ended.append(step)
            return step
        }
        if let finished, finished.took >= Self.slow {
            write("launch stage slow", ["stage": finished.name, "ms": Self.milliseconds(finished.took)])
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// How long this process has existed, which is how long it took to get
    /// from exec to `finish`: dyld and everything before the first log line
    /// are in it, and they are where 16 s went on 2026-11-03.
    private static func millisecondsSinceExec() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let began = info.kp_proc.p_starttime
        let start = TimeInterval(began.tv_sec) + TimeInterval(began.tv_usec) / 1_000_000
        return Int((Moment.now.date.timeIntervalSince1970 - start) * 1000)
    }
}
