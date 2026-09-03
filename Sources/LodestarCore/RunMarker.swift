import Foundation

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
