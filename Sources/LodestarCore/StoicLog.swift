import Foundation
import Stoic

/// Stoic's own events (a retry given up on, an abandoned call, a launch
/// that could not be recorded, a store that recovered from a corrupt file)
/// go to the unified log and nowhere else, so the one file Lodestar's
/// owner reads when something went wrong never mentioned them. This sink
/// forwards the ones at warning and above to `Log`, as `stoic.<name>`.
///
/// Everything an event carries is written, private fields too: this log is
/// a file in the owner's own data directory, and it already holds the
/// errors Lodestar logs itself.
public struct StoicLog: Instrumentation {
    public init() {}

    public func isEnabled(_ level: Event.Level) -> Bool { level >= .warning }

    public func record(_ event: Event) {
        guard isEnabled(event.level) else { return }
        let line = Self.format(event)
        if event.level >= .error {
            Log.error(line.event, fields: line.fields)
        } else {
            Log.warning(line.event, fields: line.fields)
        }
    }

    /// The log line for an event: its name, then its label, then its fields
    /// in the order Stoic recorded them.
    static func format(_ event: Event) -> (event: String, fields: [(key: String, value: Any)]) {
        var fields: [(key: String, value: Any)] = []
        if let label = event.label { fields.append(("label", label)) }
        for field in event.fields { fields.append((field.key, field.value)) }
        return ("stoic.\(event.name)", fields)
    }
}
