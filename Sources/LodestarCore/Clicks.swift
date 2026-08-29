import Foundation

/// The mouse, priced: clicks folded per quarter hour and per app, with a
/// histogram of what was clicked, by accessibility role. This is the
/// pool the audit could not see — the pulse counts clicks but is
/// app-blind by design, and the coach cannot recommend a lens for a
/// pool it cannot name.
///
/// The line, stated where the code can read it: **an app name and a role
/// class, never a label, a title, a coordinate, or a URL.** "button in
/// Brave" is a routing fact of the same grain the focus events already
/// keep; "the Submit button on the checkout page" is content, and it is
/// structurally unreachable here — the accumulator's API accepts a role
/// string and nothing else about the target.
///
/// A *hand trip* is a click whose previous act of input was a keystroke:
/// the hand left the keys for it. Trips against clicks is the number
/// that says whether a pointer session is a browsing session (few trips,
/// many clicks) or a keyboard flow the mouse keeps interrupting.
public struct ClickPulse: Equatable {
    public static let windowSeconds = HealthPulse.windowSeconds
    /// Distinct apps a window may name; the rest fold into `other`.
    public static let appCap = 24
    /// Distinct roles an app may name in a window; the rest fold into
    /// `other`.
    public static let roleCap = 12
    public static let other = "other"

    struct Cell: Equatable {
        var clicks = 0
        var trips = 0
        var roles: [String: Int] = [:]
    }

    var windowStart: Date?
    var cells: [String: Cell] = [:]

    public init() {}

    /// One click landed. Returns the previous window's events (one per
    /// app) when this click opens a new window.
    public mutating func click(app: String, role: String?, trip: Bool,
                               at now: Date) -> [ObservationEvent] {
        let flushed = rollIfDue(now: now)
        if windowStart == nil { windowStart = now }
        var name = app.lowercased()
        if cells[name] == nil, cells.count >= Self.appCap { name = Self.other }
        var cell = cells[name] ?? Cell()
        cell.clicks += 1
        if trip { cell.trips += 1 }
        var roleName = Self.roleName(role)
        if cell.roles[roleName] == nil, cell.roles.count >= Self.roleCap {
            roleName = Self.other
        }
        cell.roles[roleName, default: 0] += 1
        cells[name] = cell
        return flushed
    }

    /// Close the open window unconditionally — shutdown's path.
    public mutating func flush(now: Date = Date()) -> [ObservationEvent] {
        let events = build()
        windowStart = nil
        cells = [:]
        return events
    }

    /// "AXButton" → "button"; nothing → "unknown". A role is a class of
    /// control, and the class is all that is kept.
    public static func roleName(_ role: String?) -> String {
        guard let role, !role.isEmpty else { return "unknown" }
        let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return stripped.lowercased()
    }

    private mutating func rollIfDue(now: Date) -> [ObservationEvent] {
        guard let start = windowStart,
              now.timeIntervalSince(start) >= Self.windowSeconds else { return [] }
        let events = build()
        windowStart = now
        cells = [:]
        return events
    }

    /// Stamped at the window's start, one event per app, so a quarter
    /// hour lands in the hour and the month it describes.
    private func build() -> [ObservationEvent] {
        guard let start = windowStart else { return [] }
        return cells.sorted { $0.key < $1.key }.map { app, cell in
            var event = ObservationEvent(t: start, kind: .clicks)
            event.app = app
            event.clicks = cell.clicks
            event.trips = cell.trips
            event.roles = cell.roles
            return event
        }
    }
}

extension Health {
    /// Read-time view over the click events: the pool by app, with what
    /// was clicked in each.
    public struct ClickApp: Equatable {
        public var clicks = 0
        public var trips = 0
        public var roles: [String: Int] = [:]
        public init() {}
    }

    public struct Clicks: Equatable {
        public var days = 0
        public var clicks = 0
        public var trips = 0
        public var apps: [String: ClickApp] = [:]

        public var tripShare: Double? {
            clicks > 0 ? Double(trips) / Double(clicks) : nil
        }

        /// Apps by click count, descending.
        public var ranked: [(app: String, record: ClickApp)] {
            apps.sorted { $0.value.clicks > $1.value.clicks || ($0.value.clicks == $1.value.clicks && $0.key < $1.key) }
                .map { (app: $0.key, record: $0.value) }
        }
    }

    public static func clicks(events: [ObservationEvent], days: Int,
                              now: Date = Date()) -> Clicks? {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let pulses = events.filter { $0.kind == .clicks && $0.t >= cutoff }
        guard !pulses.isEmpty else { return nil }
        var out = Clicks()
        var dayOrdinals: Set<Int> = []
        for pulse in pulses {
            guard let app = pulse.app else { continue }
            var record = out.apps[app] ?? ClickApp()
            record.clicks += pulse.clicks ?? 0
            record.trips += pulse.trips ?? 0
            for (role, count) in pulse.roles ?? [:] {
                record.roles[role, default: 0] += count
            }
            out.apps[app] = record
            out.clicks += pulse.clicks ?? 0
            out.trips += pulse.trips ?? 0
            dayOrdinals.insert(Int(pulse.t.timeIntervalSince1970 / 86_400))
        }
        out.days = dayOrdinals.count
        return out
    }
}
