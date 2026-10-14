import Foundation
import StoicStore

/// The note a run leaves about itself, readable at the next boot: the
/// difference between "quit" and "died". Written with the pid at boot,
/// rewritten as quitting the moment a graceful shutdown begins, removed
/// when it ends. Pure, so the verdict is testable without a process.
public enum RunMarker {
    public static func alive(pid: Int32) -> String { "\(pid)" }

    /// A graceful shutdown has begun. Everything after this line is
    /// unbounded accessibility work a logout may cut short, and a run cut
    /// short there quit — it did not die.
    public static func quitting(pid: Int32) -> String { "quit \(pid)" }

    public static func pid(in contents: String) -> Int32? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = trimmed.split(separator: " ").last.map(String.init) ?? trimmed
        return Int32(last)
    }

    public static func isQuitting(_ contents: String) -> Bool {
        contents.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("quit ")
    }

    /// Whether the run that wrote this marker died: it never began a
    /// graceful shutdown, and its process is gone. A live pid is an
    /// instance still on its way out; a quitting note is a quit, however
    /// far it got; anything unreadable is nothing to recover from.
    public static func diedUncleanly(contents: String, isAlive: (Int32) -> Bool) -> Bool {
        guard !isQuitting(contents), let pid = pid(in: contents) else { return false }
        return !isAlive(pid)
    }
}

/// The crash-loop breaker, kept beside the run marker. The run marker says
/// whether the *last* run died; Stoic's `LaunchGuard` counts how many
/// launches in a row never got far enough to be called stable, so a loop
/// is told apart from one bad day. The count starts over on a stable
/// launch (up thirty seconds), a clean quit, or a different build.
extension RunMarker {
    /// Where the guard's state lives, in Lodestar's data directory.
    public static let launchGuardFile = "launch-guard"

    /// How long a launch must survive to count as good.
    public static let stableAfter: Duration = .seconds(30)

    /// What the app does differently once the loop is established. The
    /// only thing it changes: the main-thread watchdog logs a stall
    /// instead of aborting, because an abort and relaunch there is what
    /// kept a past crash loop going.
    public enum Mode: Equatable {
        case normal
        case safe(uncleanLaunches: Int)

        public init(_ verdict: LaunchGuard.Verdict) {
            switch verdict {
            case .normal: self = .normal
            case .safeMode(let unclean): self = .safe(uncleanLaunches: unclean)
            }
        }
    }

    /// The guard for this build. A new build starts the count over: an
    /// update is the way out of a loop, and what went wrong with the last
    /// build says nothing about this one.
    public static func launchGuard(in directory: URL, build: String,
                                   bootSession: String? = LaunchGuard.currentBootSession) -> LaunchGuard {
        LaunchGuard(path: directory.appendingPathComponent(launchGuardFile).path,
                    build: build.replacingOccurrences(of: " ", with: "_"),
                    bootSession: bootSession)
    }
}
