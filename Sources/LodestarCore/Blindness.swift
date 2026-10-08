import Foundation

/// When the instrument could not see.
///
/// A quiet stretch in the health record was ambiguous: the hands may
/// have rested, or the keys may simply not have reached the instrument.
/// These spans say which. Each records what kind of blindness it was and
/// when it began and ended, and nothing else: not which app held secure
/// input (that would log where and when passwords were typed), not what
/// the person was doing. An analysis excludes the spans; it never reads
/// them as rest.
public enum BlindKind: String, Codable, CaseIterable, Sendable {
    /// macOS secure event input was on (a password field): the key tap
    /// receives no keys. Sampled, so its edges carry a `resolution`.
    case secureInput
    /// The key tap was switched off, by macOS or found off by the
    /// watchdog, until it was switched on again.
    case tapOff
    /// Accessibility trust was gone: no tap at all until it returned.
    case untrusted
    /// `observations.health` was off.
    case healthOff
    /// Lodestar was not running: from a quit, or from the last moment a
    /// crashed run was seen alive, to the next launch.
    case notRunning
    /// The Mac was asleep.
    case asleep

    /// How the printout names it.
    public var words: String {
        switch self {
        case .secureInput: return "secure input"
        case .tapOff: return "tap off"
        case .untrusted: return "no accessibility"
        case .healthOff: return "health off"
        case .notRunning: return "not running"
        case .asleep: return "asleep"
        }
    }
}

/// One span, carried by a `blind` event whose `t` is the span's start.
public struct BlindSpan: Codable, Equatable, Sendable {
    /// A `BlindKind`'s raw value, kept as a string so a kind added later
    /// still reads in an older build.
    public var kind: String
    public var end: Date
    /// The start is a bound, not an observed moment: the last time the
    /// instrument was known to see. Blindness began at or after it.
    public var startBound: Bool?
    /// The end is a bound: a crashed run's last sign of life, past which
    /// nothing is known. Blindness lasted at least until it.
    public var endBound: Bool?
    /// For a sampled kind, how far each edge can sit from the true one:
    /// the span covers the true span to within this many seconds at
    /// each end, erring wide.
    public var resolution: Double?

    public init(kind: BlindKind, end: Date, startBound: Bool? = nil, endBound: Bool? = nil,
                resolution: Double? = nil) {
        self.kind = kind.rawValue
        self.end = end
        self.startBound = startBound
        self.endBound = endBound
        self.resolution = resolution
    }

    public var blindKind: BlindKind? { BlindKind(rawValue: kind) }

    public static func event(_ kind: BlindKind, from start: Date, to end: Date, startBound: Bool = false,
                             endBound: Bool = false, resolution: Double? = nil) -> ObservationEvent {
        var event = ObservationEvent(t: start, kind: .blind)
        event.blind = BlindSpan(kind: kind, end: max(start, end), startBound: startBound ? true : nil,
                                endBound: endBound ? true : nil, resolution: resolution)
        return event
    }
}

/// The spans open now, and enough about the last run to close what it
/// left open. Kept on disk beside the health record (`blind.json`), so a
/// span open at a quit or a crash is closed on the next launch: at the
/// quit's own moment, or at the crashed run's last heartbeat, marked as a
/// bound. Never left open-ended, never stretched past what was seen.
public struct BlindLedger: Codable, Equatable {
    public struct Open: Codable, Equatable {
        public var start: Date
        public var startBound: Bool
        public var resolution: Double?
    }

    public struct Stop: Codable, Equatable {
        public var at: Date
        /// `notRunning` for a quit, `healthOff` for the switch.
        public var kind: String
    }

    public private(set) var open: [String: Open] = [:]
    /// The last moment the instrument was known to be seeing: a heartbeat
    /// written once a minute while it runs.
    public private(set) var lastSeen: Date?
    /// A clean stop, and why. Nil while running, and after a crash.
    public private(set) var stopped: Stop?

    public init() {}

    /// A span of `kind` begins. False when one is already open.
    @discardableResult
    public mutating func begin(_ kind: BlindKind, at start: Date, startBound: Bool = false,
                               resolution: Double? = nil) -> Bool {
        guard open[kind.rawValue] == nil else { return false }
        open[kind.rawValue] = Open(start: start, startBound: startBound, resolution: resolution)
        return true
    }

    /// The span of `kind` ends: its event, or nil when none was open.
    public mutating func end(_ kind: BlindKind, at end: Date) -> ObservationEvent? {
        guard let span = open.removeValue(forKey: kind.rawValue) else { return nil }
        return BlindSpan.event(kind, from: span.start, to: end, startBound: span.startBound,
                               resolution: span.resolution)
    }

    public func isOpen(_ kind: BlindKind) -> Bool { open[kind.rawValue] != nil }

    public mutating func heartbeat(at now: Date) { lastSeen = now }

    /// A clean stop, noted and nothing more: the spans open now end at
    /// this moment, and the time away begins at it, but both are written
    /// at the next start. At a stop the record may already be closing
    /// (health switched off, the app quitting), and a span written into a
    /// closed record would be lost.
    public mutating func stop(_ kind: BlindKind, at now: Date) {
        stopped = Stop(at: now, kind: kind.rawValue)
        lastSeen = now
    }

    /// Seeing again, at `now`. After a clean stop, the spans open at the
    /// stop end there, and one span runs from the stop to now, of the
    /// stop's kind, every edge seen. (Health switched off and the app
    /// quit while it was off is one `healthOff` span: it began as that.)
    /// After a crash (spans
    /// may be open, no stop was written), every open span ends at the
    /// last heartbeat, marked as a bound, and the time from that heartbeat
    /// to now is a `notRunning` span whose start is a bound. With no
    /// history at all, nothing: the instrument never saw before.
    public mutating func start(at now: Date) -> [ObservationEvent] {
        var events: [ObservationEvent] = []
        if let stop = stopped {
            for (raw, span) in open.sorted(by: { $0.key < $1.key }) {
                guard let kind = BlindKind(rawValue: raw) else { continue }
                events.append(BlindSpan.event(kind, from: span.start, to: max(span.start, stop.at),
                                              startBound: span.startBound, resolution: span.resolution))
            }
            let kind = BlindKind(rawValue: stop.kind) ?? .notRunning
            if now > stop.at { events.append(BlindSpan.event(kind, from: stop.at, to: now)) }
        } else if let seen = lastSeen {
            for (raw, span) in open.sorted(by: { $0.key < $1.key }) {
                guard let kind = BlindKind(rawValue: raw) else { continue }
                events.append(BlindSpan.event(kind, from: span.start, to: max(span.start, seen),
                                              startBound: span.startBound, endBound: true,
                                              resolution: span.resolution))
            }
            if now > seen { events.append(BlindSpan.event(.notRunning, from: seen, to: now, startBound: true)) }
        }
        open = [:]
        stopped = nil
        lastSeen = now
        return events
    }
}

/// The printout's line: how long the instrument could not see, by kind,
/// over the last `days`, largest first, the way the rest of the health
/// section is read.
public enum BlindSummary {
    public struct Row: Equatable {
        public let kind: String
        public let spans: Int
        public let seconds: Double
    }

    public static func rows(events: [ObservationEvent], days: Int, now: Date = Date()) -> [Row] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var spans: [String: Int] = [:]
        var seconds: [String: Double] = [:]
        for event in events where event.kind == .blind && event.t >= since {
            guard let span = event.blind else { continue }
            spans[span.kind, default: 0] += 1
            seconds[span.kind, default: 0] += max(0, span.end.timeIntervalSince(event.t))
        }
        return spans.keys.map { Row(kind: $0, spans: spans[$0] ?? 0, seconds: seconds[$0] ?? 0) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.kind < $1.kind }
    }

    /// "2h 05m", "4m", "under a minute".
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// The line itself, or nil when nothing was unseen.
    public static func line(_ rows: [Row]) -> String? {
        guard !rows.isEmpty else { return nil }
        let total = rows.reduce(0) { $0 + $1.seconds }
        let parts = rows.map { row in
            let name = BlindKind(rawValue: row.kind)?.words ?? row.kind
            return "\(name) \(duration(row.seconds)) (\(row.spans))"
        }
        return "\(duration(total)) unseen · " + parts.joined(separator: " · ")
    }
}
