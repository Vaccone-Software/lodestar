import Foundation

/// A clip that is only a timestamp — a Unix time out of a log, an ISO date
/// out of an API — is read as the moment it names: how long ago, as it is
/// felt, then your clock and the other zones. The reading is Lodestar's
/// note on the card, set apart from the value, which is still what pastes.
public struct ClipTime: Equatable {
    public enum Kind: Equatable {
        case unix(Unit)
        /// ISO 8601 or the date format mail and HTTP use: already a date,
        /// read into your zones.
        case written
        /// A date with no time of day.
        case day
    }

    public enum Unit: String, Equatable {
        case seconds, milliseconds, microseconds, nanoseconds
    }

    public let date: Date
    public let kind: Kind
    /// The offset from UTC the value was written in, in seconds, when it
    /// names one: a zone that reads the same is only the value again.
    public let writtenOffset: Int?

    init(date: Date, kind: Kind, writtenOffset: Int? = nil) {
        self.date = date
        self.kind = kind
        self.writtenOffset = writtenOffset
    }

    /// The moment a clip's text names, or nil. The whole text must be it:
    ///   1790342057          Unix seconds, and milliseconds, microseconds
    ///                       and nanoseconds by length, 2001 through 2033
    ///                       only (a ten-digit US phone number starts at 2,
    ///                       so it is never a time)
    ///   2026-09-25T12:34:56Z · +09:00 · .123 · a space for the T
    ///   2026-09-25          a day
    ///   Thu, 25 Sep 2026 12:34:56 +0000 · GMT   mail and HTTP
    public static func parse(_ text: String) -> ClipTime? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 40, !s.contains("\n") else { return nil }
        if let unix = unix(s) { return unix }
        if let day = day(s) { return day }
        if let written = iso(s) ?? rfc2822(s) {
            return ClipTime(date: written, kind: .written, writtenOffset: offset(s))
        }
        return nil
    }

    private static func unix(_ s: String) -> ClipTime? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, whole.allSatisfy(\.isNumber), !whole.isEmpty else { return nil }
        if parts.count == 2, !parts[1].allSatisfy(\.isNumber) || parts[1].isEmpty { return nil }
        guard let value = Double(s) else { return nil }
        let units: [(Int, Unit, Double)] = [(10, .seconds, 1), (13, .milliseconds, 1e3),
                                            (16, .microseconds, 1e6), (19, .nanoseconds, 1e9)]
        guard let (_, unit, scale) = units.first(where: { $0.0 == whole.count }) else { return nil }
        // A fraction only makes sense on seconds.
        if parts.count == 2, unit != .seconds { return nil }
        let seconds = value / scale
        guard seconds >= 1_000_000_000, seconds < 2_000_000_000 else { return nil }
        return ClipTime(date: Date(timeIntervalSince1970: seconds), kind: .unix(unit))
    }

    // The shape of each form is checked by hand before any formatter or
    // expression runs: every text clip passes through here when the strip
    // searches, and a formatter is costly to make and slow to fail.

    private static func digits(_ bytes: ArraySlice<UInt8>) -> Bool { bytes.allSatisfy { (0x30...0x39).contains($0) } }

    private static func day(_ s: String) -> ClipTime? {
        let b = Array(s.utf8)
        guard b.count == 10, b[4] == 0x2D, b[7] == 0x2D, digits(b[0..<4]), digits(b[5..<7]), digits(b[8..<10])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let numbers = s.split(separator: "-").compactMap { Int($0) }
        guard let date = calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])),
              calendar.component(.day, from: date) == numbers[2] else { return nil }
        return ClipTime(date: date, kind: .day)
    }

    /// Made once: a formatter that is never changed after it is made can
    /// be read from any thread.
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoWhole = ISO8601DateFormatter()
    private static func fixed(_ format: String, zone: TimeZone? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let zone { formatter.timeZone = zone }
        formatter.dateFormat = format
        return formatter
    }
    /// No zone written: the time is local, as a person writing it meant.
    private static let isoLocal = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]
        .map { fixed($0, zone: .autoupdatingCurrent) }
    private static let mail = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"]
        .map { fixed($0) }

    private static func iso(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 16, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x20, b[13] == 0x3A,
              digits(b[0..<4]), digits(b[11..<13]) else { return nil }
        let normalized = s.replacingOccurrences(of: " ", with: "T")
        if let date = isoFractional.date(from: normalized) ?? isoWhole.date(from: normalized) { return date }
        for formatter in isoLocal {
            if let date = formatter.date(from: normalized) { return date }
        }
        return nil
    }

    private static func rfc2822(_ s: String) -> Date? {
        // "Fri, 25 Sep 2026 13:14:17 +0000": two colons, a space, and a
        // letter somewhere, or it is not this form.
        let b = Array(s.utf8)
        guard b.count >= 20, b.filter({ $0 == 0x3A }).count == 2, b.contains(0x20),
              b.contains(where: { (0x41...0x5A).contains($0) }) else { return nil }
        for formatter in mail {
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }

    /// The zone a written value names at its end: Z, GMT or UTC, or an
    /// offset such as +09:00 or -0400.
    private static func offset(_ s: String) -> Int? {
        let upper = s.uppercased()
        if upper.hasSuffix("Z") || upper.hasSuffix(" GMT") || upper.hasSuffix(" UTC") || upper.hasSuffix(" UT") {
            return 0
        }
        guard let match = s.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) else { return nil }
        let token = s[match].replacingOccurrences(of: ":", with: "")
        guard let hours = Int(token.dropFirst().prefix(2)), let minutes = Int(token.suffix(2)) else { return nil }
        return (token.hasPrefix("-") ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    // MARK: - The note

    public struct Note: Equatable {
        /// The moment as it is felt, in Lodestar's voice: "6 hours ago",
        /// "Yesterday evening", "March 2024".
        public let voice: String
        /// Your clock: "Fri, Sep 25 at 9:14 AM", or only "9:14 AM" when the
        /// voice already names the day.
        public let local: String
        /// UTC and the zones you keep, each "1:14 PM UTC", with the
        /// weekday when that zone's day is not yours. A zone whose clock
        /// reads the same as yours or as the value's own is left out.
        public let zones: [String]
    }

    /// Within a week the voice has said which day ("6 hours ago",
    /// "Tuesday afternoon"), so your clock needs only the time, and the
    /// room it leaves goes to a zone.
    public func note(local: TimeZone = .current, zones: [TimeZone] = [], now: Date = Date(),
                     locale: Locale = .current) -> Note {
        let calendar = Calendar(identifier: .gregorian)
        let sameYear = calendar.dateComponents(in: local, from: date).year == calendar.dateComponents(in: local, from: now).year
        let full = DateFormatter()
        full.locale = locale
        full.timeZone = local
        let voice = felt(now: now, zone: local, locale: locale)
        if kind == .day {
            full.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEdMMMM" : "EEEEdMMMMy")
            return Note(voice: voice, local: full.string(from: date), zones: [])
        }
        var dayCalendar = Calendar(identifier: .gregorian)
        dayCalendar.timeZone = local
        let days = dayCalendar.dateComponents([.day], from: dayCalendar.startOfDay(for: now),
                                            to: dayCalendar.startOfDay(for: date)).day ?? 0
        full.setLocalizedDateFormatFromTemplate(abs(days) < 7 ? "jmm" : sameYear ? "EEEdMMMjmm" : "EEEdMMMyjmm")
        var shown: Set<Int> = [local.secondsFromGMT(for: date)]
        if let writtenOffset { shown.insert(writtenOffset) }
        var lines: [String] = []
        for zone in [TimeZone(identifier: "UTC")!] + zones where shown.insert(zone.secondsFromGMT(for: date)).inserted {
            let short = DateFormatter()
            short.locale = locale
            short.timeZone = zone
            let sameDay = calendar.dateComponents(in: zone, from: date).day == calendar.dateComponents(in: local, from: date).day
            short.setLocalizedDateFormatFromTemplate(sameDay ? "jmm" : "EEEjmm")
            lines.append("\(short.string(from: date)) \(Self.place(zone))")
        }
        return Note(voice: voice, local: full.string(from: date), zones: lines)
    }

    /// How far off the moment is, the way a person says it: minutes and
    /// hours while it is near, the part of the day for yesterday and the
    /// days of this week, then weeks and months, and the month and year
    /// once it is another year's. A day counts days, never hours.
    func felt(now: Date, zone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = locale
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let past = date < now
        func format(_ template: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }
        func span(_ count: Int, _ unit: String) -> String {
            if count == 1 {
                let one = unit == "hour" ? "an hour" : "a \(unit)"
                return past ? one.prefix(1).uppercased() + one.dropFirst() + " ago" : "In \(one)"
            }
            return past ? "\(count) \(unit)s ago" : "In \(count) \(unit)s"
        }
        func far() -> String {
            let count = abs(days)
            if count == 7 { return past ? "A week ago" : "A week from today" }
            if count < 14 { return span(count, "day") }
            if count < 60 { return span(count / 7, "week") }
            if count < 365 {
                let months = abs(calendar.dateComponents([.month], from: now, to: date).month ?? 2)
                return span(max(2, months), "month")
            }
            return format("MMMMy")
        }
        if kind == .day {
            switch days {
            case 0: return "Today"
            case -1: return "Yesterday"
            case 1: return "Tomorrow"
            case -6 ... -2: return "Last \(format("EEEE"))"
            case 2...6: return "This \(format("EEEE"))"
            default: return far()
            }
        }
        let seconds = abs(date.timeIntervalSince(now))
        if seconds < 60 { return past ? "Just now" : "In a moment" }
        if seconds < 3600 { return span(Int(seconds / 60), "minute") }
        if seconds < 6 * 3600 || days == 0 { return span(Int(seconds / 3600), "hour") }
        let part: String
        switch calendar.component(.hour, from: date) {
        case 5..<12: part = "morning"
        case 12..<17: part = "afternoon"
        case 17..<21: part = "evening"
        default: part = "night"
        }
        if days == -1 { return part == "night" ? "Last night" : "Yesterday \(part)" }
        if days == 1 { return "Tomorrow \(part)" }
        if abs(days) < 7 { return "\(format("EEEE")) \(part)" }
        return far()
    }

    /// A zone by the place a person knows it by: its city, or UTC.
    public static func place(_ zone: TimeZone) -> String {
        if ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains(zone.identifier) { return "UTC" }
        let city = zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
        return city.replacingOccurrences(of: "_", with: " ")
    }

    /// A zone from what a hand types: an identifier ("Asia/Tokyo"), a city
    /// ("tokyo", "new york"), or an abbreviation ("PST", "CET").
    public static func zone(named text: String) -> TimeZone? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        if let exact = TimeZone(identifier: typed) { return exact }
        let city = typed.replacingOccurrences(of: " ", with: "_").lowercased()
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: {
            $0.lowercased() == city || $0.split(separator: "/").last.map { $0.lowercased() == city } == true
        }) {
            return TimeZone(identifier: id)
        }
        if typed.count <= 5, let abbreviated = TimeZone(abbreviation: typed.uppercased()) { return abbreviated }
        return nil
    }

    /// "Tokyo · UTC+9", for the list of zones you keep.
    public static func label(_ zone: TimeZone, at date: Date = Date()) -> String {
        let offset = zone.secondsFromGMT(for: date)
        let hours = offset / 3600, minutes = abs(offset % 3600) / 60
        let sign = offset < 0 ? "−" : "+"
        let utc = offset == 0 ? "UTC" : "UTC\(sign)\(abs(hours))" + (minutes > 0 ? String(format: ":%02d", minutes) : "")
        return place(zone) == utc ? utc : "\(place(zone)) · \(utc)"
    }
}

extension Clipboard.Clip {
    /// The moment this clip names, when it is only a timestamp.
    public var time: ClipTime? {
        kind == .text ? ClipTime.parse(preview) : nil
    }
}
