import Foundation
import Stoic

/// Stoic's own events (a retry given up on, an abandoned call, a launch
/// that could not be recorded, a store that recovered from a corrupt file)
/// go to the unified log and nowhere else, so the one file Lodestar's
/// owner reads when something went wrong never mentioned them. This sink
/// forwards the ones at warning and above to `Log`, as `stoic.<name>`.
///
/// Fields Stoic marks private (strings and error descriptions, which can
/// carry a path or a person's words) are written as `<private>`, as its own
/// sinks redact them: `lodestar diagnose` pastes the tail of this log into
/// public bug reports. The event's name, label and public fields (counts,
/// durations, flags) are written as they are.
///
/// `alsoInfoFor` names events written at info too, by prefix: the XPC
/// services' lifecycle (`xpc.`: a run started, ended or exited idle) is how
/// the log says when the models service came and went, which the hand-written
/// client used to say line by line.
public struct StoicLog: Instrumentation {
    private let infoPrefixes: [String]

    public init(alsoInfoFor infoPrefixes: [String] = []) {
        self.infoPrefixes = infoPrefixes
    }

    public func isEnabled(_ level: Event.Level) -> Bool {
        level >= .warning || (level >= .info && !infoPrefixes.isEmpty)
    }

    public func record(_ event: Event) {
        guard isEnabled(event.level) else { return }
        if event.level < .warning {
            let name = "\(event.name)"
            guard event.level == .info, infoPrefixes.contains(where: { name.hasPrefix($0) }) else { return }
        }
        let line = Self.format(event)
        if event.level >= .error {
            Log.error(line.event, fields: line.fields)
        } else if event.level >= .warning {
            Log.warning(line.event, fields: line.fields)
        } else {
            Log.info(line.event, fields: line.fields)
        }
    }

    /// The log line for an event: its name, then its label, then its fields
    /// in the order Stoic recorded them, the private ones redacted.
    static func format(_ event: Event) -> (event: String, fields: [(key: String, value: Any)]) {
        var fields: [(key: String, value: Any)] = []
        if let label = event.label { fields.append(("label", label)) }
        for field in event.fields {
            fields.append((field.key, field.privacy == .private ? "<private>" : field.value))
        }
        return ("stoic.\(event.name)", fields)
    }
}
