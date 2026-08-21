import Foundation

/// The durable monthly archive: what survives the ring.
///
/// `events.jsonl` holds ninety rolling days, and the quarterly
/// retrospective speaks from quarters — so once a calendar month
/// completes, its summary is written down before compaction lets the raw
/// events go. What is written is **sufficient statistics, never fitted
/// models**: the v1 lesson (a write-time median froze a mistake into the
/// data) holds hardest here, where there is no replaying once the ring
/// moves on. Counts, sums, and log-moments — later models derive what
/// they like from those, and a log-normal world reads its median off the
/// log-mean anyway.
///
/// What is never archived: launcher query prefixes, ranks, list lengths —
/// anything the ring keeps only for the short-horizon models. Hosts keep
/// the same standing they have in the observations: local, bounded by
/// real use, never a path or query.
///
/// Months are bucketed on the UTC calendar, deliberately: a rollup
/// computed in one timezone and read in another must be the same rollup,
/// and a few boundary hours of blur is a price a monthly narrative never
/// notices.
public struct Rollup: Codable, Equatable {
    public static let currentVersion = 1
    public static let defaultFile = Paths.data.appendingPathComponent("rollups.json")

    public var version = Rollup.currentVersion
    public var months: [String: Month] = [:]

    public init() {}

    /// Sufficient statistics of one sample: enough to merge, enough to
    /// give later models a mean and a variance, nothing frozen.
    public struct Stat: Codable, Equatable {
        public var n = 0
        public var sum = 0.0
        public var sumSquares = 0.0

        public init() {}

        public mutating func add(_ value: Double) {
            n += 1
            sum += value
            sumSquares += value * value
        }

        public var mean: Double? { n > 0 ? sum / Double(n) : nil }
    }

    public struct AddressMonth: Codable, Equatable {
        public var completions = 0
        public var peeked = 0
        /// Log-seconds, trigger → first letter: the recall that learns.
        public var trigger = Stat()
        /// Log-seconds between letters: the motor floor.
        public var inner = Stat()
        public var abandons = 0
        public var hoverSum = 0.0
        public var wrongKeys = 0
        public var confusion: [String: Int] = [:]
        public init() {}
    }

    public struct AppMonth: Codable, Equatable {
        /// Route → count: which road reached it, how often.
        public var reaches: [String: Int] = [:]
        public var focuses = 0
        /// Log-seconds, launcher open → commit — the road's measured price.
        public var launcherCommit = Stat()
        public init() {}
    }

    public struct WebMonth: Codable, Equatable {
        public var opens = 0
        /// Host → profile → count: the routing facts, exactly what the
        /// observations already keep and nothing more.
        public var hostProfiles: [String: [String: Int]] = [:]
        public var sources: [String: Int] = [:]
        public var rows: [String: Int] = [:]
        public init() {}
    }

    public struct MeetingMonth: Codable, Equatable {
        public var actions: [String: Int] = [:]
        /// Seconds from the meeting's start at join, negative is early.
        public var joinedLead = Stat()
        public init() {}
    }

    /// One suggestion's month of answers, keyed "kind:target".
    public struct CoachMonth: Codable, Equatable {
        public var offered = 0
        public var accepted = 0
        public var never = 0
        /// The predicted weekly saving the last time it was offered.
        public var seconds: Double?
        /// The proposed chain, when the suggestion carried one.
        public var address: String?
        public init() {}
    }

    public struct Month: Codable, Equatable {
        public var events = 0
        /// Distinct days that produced at least one event — the honesty
        /// mark for a month the ring only partially covered.
        public var days = 0
        public var firstEvent: Date
        public var lastEvent: Date
        public var apps: [String: AppMonth] = [:]
        public var addresses: [String: AddressMonth] = [:]
        public var verbs: [String: Int] = [:]
        public var launcherAbandons = 0
        public var web = WebMonth()
        public var meetings = MeetingMonth()
        public var coach: [String: CoachMonth] = [:]
        /// Graph epoch changes: added / removed / retargeted → count.
        public var epochs: [String: Int] = [:]
        public var selectActions: [String: Int] = [:]
        public var selectSources: [String: Int] = [:]
        public var selectRows: [String: Int] = [:]

        public init(firstEvent: Date, lastEvent: Date) {
            self.firstEvent = firstEvent
            self.lastEvent = lastEvent
        }
    }

    // MARK: - Bucketing

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// "2026-08" for any moment in that UTC month.
    public static func monthKey(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private static func dayOrdinal(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }

    // MARK: - Building

    /// Every *completed* month in `events`, aggregated. The month `now`
    /// sits in is still being written, so it is never rolled.
    public static func build(events: [ObservationEvent], now: Date) -> [String: Month] {
        let open = monthKey(now)
        var months: [String: Month] = [:]
        var daySets: [String: Set<Int>] = [:]
        for event in events {
            let key = monthKey(event.t)
            guard key != open else { continue }
            var month = months[key] ?? Month(firstEvent: event.t, lastEvent: event.t)
            month.events += 1
            month.firstEvent = min(month.firstEvent, event.t)
            month.lastEvent = max(month.lastEvent, event.t)
            daySets[key, default: []].insert(dayOrdinal(event.t))
            apply(event, to: &month)
            months[key] = month
        }
        for (key, set) in daySets { months[key]?.days = set.count }
        return months
    }

    private static func apply(_ event: ObservationEvent, to month: inout Month) {
        switch event.kind {
        case .chain:
            let key = event.chain.map(Observations.key) ?? ""
            var record = month.addresses[key] ?? AddressMonth()
            record.completions += 1
            if event.peeked == true { record.peeked += 1 }
            for (position, gap) in (event.gaps ?? []).enumerated() where gap > 0 {
                if position == 0 {
                    record.trigger.add(log(gap))
                } else {
                    record.inner.add(log(gap))
                }
            }
            month.addresses[key] = record

        case .abandon:
            let key = event.chain.map(Observations.key) ?? ""
            var record = month.addresses[key] ?? AddressMonth()
            record.abandons += 1
            record.hoverSum += event.hover ?? 0
            month.addresses[key] = record

        case .wrongKey:
            let key = event.chain.map(Observations.key) ?? ""
            var record = month.addresses[key] ?? AddressMonth()
            record.wrongKeys += 1
            if let pressed = event.pressed, !pressed.isEmpty {
                record.confusion[pressed, default: 0] += 1
            }
            month.addresses[key] = record

        case .reach:
            guard let app = event.app else { return }
            var record = month.apps[app] ?? AppMonth()
            record.reaches[event.route ?? "unknown", default: 0] += 1
            if let commit = event.openToCommit, commit > 0 {
                record.launcherCommit.add(log(commit))
            }
            month.apps[app] = record

        case .launcherAbandon:
            month.launcherAbandons += 1

        case .verb:
            guard let verb = event.verb else { return }
            month.verbs[verb, default: 0] += 1

        case .web:
            month.web.opens += 1
            if let host = event.host, let profile = event.profile {
                month.web.hostProfiles[host, default: [:]][profile, default: 0] += 1
            }
            if let source = event.source {
                month.web.sources[source, default: 0] += 1
            }
            if let row = event.row {
                month.web.rows[row, default: 0] += 1
            }

        case .focus:
            guard let app = event.app else { return }
            var record = month.apps[app] ?? AppMonth()
            record.focuses += 1
            month.apps[app] = record

        case .epoch:
            guard let change = event.change else { return }
            month.epochs[change, default: 0] += 1

        case .meeting:
            guard let action = event.action else { return }
            month.meetings.actions[action, default: 0] += 1
            if action == "joined", let lead = event.lead {
                month.meetings.joinedLead.add(lead)
            }

        case .coach:
            guard let action = event.action else { return }
            let key = "\(event.rec ?? "?"):\(event.app ?? "?")"
            var record = month.coach[key] ?? CoachMonth()
            switch action {
            case "offered":
                record.offered += 1
                if let seconds = event.seconds { record.seconds = seconds }
                if let address = event.address { record.address = address }
            case "accepted": record.accepted += 1
            case "never": record.never += 1
            default: break
            }
            month.coach[key] = record

        case .select:
            if let action = event.action {
                month.selectActions[action, default: 0] += 1
            }
            if let source = event.source {
                month.selectSources[source, default: 0] += 1
            }
            if let row = event.row {
                month.selectRows[row, default: 0] += 1
            }
        }
    }

    // MARK: - The archive on disk

    /// Add-only, forever: a stored month is never recomputed or replaced.
    /// Once its events leave the ring, the stored answer is the only one
    /// there will ever be — and a recomputation against a shrunken ring
    /// must never overwrite a fuller answer written earlier.
    public mutating func adopt(_ built: [String: Month]) -> [String] {
        var added: [String] = []
        for (key, month) in built where months[key] == nil {
            months[key] = month
            added.append(key)
        }
        return added.sorted()
    }

    private struct VersionProbe: Codable { let version: Int }

    /// What one pass did: the months newly archived, and whether the file
    /// was left alone because a different schema owns it.
    public struct Outcome: Equatable {
        public var added: [String] = []
        public var held = false
    }

    /// Archive every completed month in `events` that the file does not
    /// already hold. ISO dates and sorted keys, because this file is
    /// meant to outlive schemas and be read by eyes as well as code. A
    /// file written by a *newer* schema is left exactly as it is — an old
    /// binary decoding what it half-understands and writing it back is
    /// how archives die.
    /// `file` has no default on purpose: a write that could silently land
    /// in the user's real archive is how a test run poisoned it once.
    @discardableResult
    public static func roll(events: [ObservationEvent], file: URL,
                            now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        var archive = Rollup()
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let probe = try? decoder.decode(VersionProbe.self, from: data),
                  probe.version <= currentVersion,
                  let decoded = try? decoder.decode(Rollup.self, from: data) else {
                Log.error("rollup: \(file.lastPathComponent) is not this schema — left untouched")
                outcome.held = true
                return outcome
            }
            archive = decoded
        }
        outcome.added = archive.adopt(build(events: events, now: now))
        guard !outcome.added.isEmpty else { return outcome }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(archive) else { return outcome }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            Log.error("rollup: could not write \(file.lastPathComponent) (\(error))")
            outcome.added = []
        }
        return outcome
    }
}
