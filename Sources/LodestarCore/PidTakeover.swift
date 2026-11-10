import Foundation

/// How a launching copy takes the place of the one that is running: it reads
/// the pid file, and if the pid answers it asks that process to quit, waits
/// for it to go, and writes its own pid. This is what `main.swift` did
/// inline; it is here so that its decisions can be pinned by tests with a
/// table in place of the machine, and with two real processes.
///
/// It trusts the pid file. A pid left by a copy that crashed names whatever
/// the system has since given that number to, and that process is sent the
/// quit.
public enum PidTakeover {
    public enum Outcome: Equatable, Sendable {
        /// No pid file, an unreadable one, or one naming this process or a
        /// process that is not there: nothing was asked to quit.
        case nothingRunning
        /// The process the file named was asked to quit and has gone.
        case replaced(pid: Int32)
        /// It was asked and was still there after the wait. The launch
        /// goes on: two copies run, as they always have in this case.
        case stuck(pid: Int32)
    }

    /// How long the outgoing copy has to go. It restores parked windows on
    /// its way out, which is unbounded accessibility work, so a number that
    /// was never long enough (600 ms) left two copies holding the state.
    public static let wait: TimeInterval = 5

    /// Takes over from the copy the pid file names, then writes `selfPid`
    /// into it. The file is written whatever happened.
    @discardableResult
    public static func run(pidFile: URL, selfPid: Int32, processes: any InstanceProcesses = SystemProcesses(),
                           clock: InstanceClock = .system, wait: TimeInterval = PidTakeover.wait,
                           poll: TimeInterval = 0.025) -> Outcome {
        var outcome = Outcome.nothingRunning
        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let oldPid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           oldPid != selfPid,
           processes.isAlive(oldPid) {
            Log.info("replacing running lodestar (pid \(oldPid))")
            processes.terminate(oldPid)
            // Wait for it to actually go, rather than for a number that
            // was never long enough: the outgoing process restores parked
            // windows on its way out, which is unbounded AX work, so a
            // fixed 600ms routinely left two instances holding state.json,
            // observations.json and events.jsonl at once — last writer
            // wins, and a coalesced write is simply lost.
            let deadline = clock.now().addingTimeInterval(wait)
            while processes.isAlive(oldPid), clock.now() < deadline {
                clock.pause(poll)
            }
            if processes.isAlive(oldPid) {
                Log.error("previous lodestar (pid \(oldPid)) did not exit in \(Int(wait))s — continuing anyway")
                outcome = .stuck(pid: oldPid)
            } else {
                Log.info("previous lodestar exited; taking over")
                outcome = .replaced(pid: oldPid)
            }
        }
        try? "\(selfPid)".write(to: pidFile, atomically: true, encoding: .utf8)
        return outcome
    }
}
