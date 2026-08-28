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
/// notices. Hours of day and weekdays inside a month are *local*, equally
/// deliberately — "morning" and "weekend" are facts about the person.
///
/// v2 adds what the ring alone could never answer a year later: the
/// health pulse (input counts and moments), the focus structure
/// (transitions, dwell, checking loops, hour shape), the instrument's own
/// latencies, and weekly health sub-rollups — a monthly histogram cannot
/// show the week everything changed, and weeks are the unit the
/// curriculum already thinks in. v1 archives decode with the new fields
/// empty; a v2 file is left untouched by a v1 binary via the version
/// probe, as ever.
public struct Rollup: Codable, Equatable {
    public static let currentVersion = 2
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

        /// Fold in already-summed statistics — how a pulse's inter-key
        /// moments join the month without replaying keystrokes that were
        /// never stored.
        public mutating func merge(n: Int, sum: Double, sumSquares: Double) {
            self.n += n
            self.sum += sum
            self.sumSquares += sumSquares
        }

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
    /// The hands, one month: pure counts and moments from the pulses.
    /// The hard line travels with the data — no key identities, ever.
    public struct HealthMonth: Codable, Equatable {
        public var keys = 0
        public var backspaces = 0
        public var clicks = 0
        public var scrolls = 0
        public var activeMinutes = 0
        /// Inter-key gaps, seconds — the typing rhythm's moments.
        public var interKey = Stat()
        /// Active minutes by local hour, 24 buckets: the day's shape.
        public var activeHours = [Int](repeating: 0, count: 24)
        /// Active minutes by local weekday (1 = Sunday), 7 buckets.
        public var weekdays = [Int](repeating: 0, count: 7)
        /// Completed continuous active stretches, minutes.
        public var stretchMinutes = Stat()
        /// Gaps between active stretches, minutes — 20 minutes to 4
        /// hours; longer is a day boundary, not a break.
        public var breakMinutes = Stat()

        public init() {}

        var isEmpty: Bool { self == HealthMonth() }
    }

    /// One week's health sub-rollup, keyed by the epoch-week ordinal the
    /// rest of the curriculum counts in. Monthly histograms cannot show
    /// "the week everything changed"; these can, forever.
    public struct WeekHealth: Codable, Equatable {
        public var keys = 0
        public var backspaces = 0
        public var clicks = 0
        public var scrolls = 0
        public var activeMinutes = 0
        /// Focus changes between different apps.
        public var switches = 0
        /// Returned to the app just left within fifteen seconds.
        public var checkingLoops = 0
        public var interKey = Stat()
        /// Log-seconds spent in an app before the next switch.
        public var dwell = Stat()

        public init() {}
    }

    public struct CoachMonth: Codable, Equatable {
        public var offered = 0
        public var accepted = 0
        public var never = 0
        /// Stood its whole minute, read, and passed over — not an answer,
        /// but the fact the retry leash is priced on.
        public var ignored = 0
        /// The predicted weekly saving the last time it was offered.
        public var seconds: Double?
        /// The proposed chain, when the suggestion carried one.
        public var address: String?
        public init() {}

        /// v1 archives predate `ignored`; a missing key reads as zero
        /// rather than refusing the whole file.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            offered = try container.decodeIfPresent(Int.self, forKey: .offered) ?? 0
            accepted = try container.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
            never = try container.decodeIfPresent(Int.self, forKey: .never) ?? 0
            ignored = try container.decodeIfPresent(Int.self, forKey: .ignored) ?? 0
            seconds = try container.decodeIfPresent(Double.self, forKey: .seconds)
            address = try container.decodeIfPresent(String.self, forKey: .address)
        }
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
        // v2: the health pulse and the focus structure.
        public var health = HealthMonth()
        /// Focus changes by local hour, 24 buckets.
        public var hours = [Int](repeating: 0, count: 24)
        /// App → app focus-change counts, capped like the live view's.
        public var transitions: [String: [String: Int]] = [:]
        /// Log-seconds in an app before the next switch (1s to 2h).
        public var dwell = Stat()
        /// Returned to the app just left within fifteen seconds.
        public var checkingLoops = 0
        /// The instrument's own warmups: surface → log-seconds.
        public var latency: [String: Stat] = [:]
        /// Week ordinal (as a string key, for JSON) → that week's health.
        public var weeks: [String: WeekHealth] = [:]

        public init(firstEvent: Date, lastEvent: Date) {
            self.firstEvent = firstEvent
            self.lastEvent = lastEvent
        }

        /// v1 archives decode with the v2 fields at their empty defaults —
        /// a stored month must never be refused for predating a column.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            events = try container.decodeIfPresent(Int.self, forKey: .events) ?? 0
            days = try container.decodeIfPresent(Int.self, forKey: .days) ?? 0
            firstEvent = try container.decode(Date.self, forKey: .firstEvent)
            lastEvent = try container.decode(Date.self, forKey: .lastEvent)
            apps = try container.decodeIfPresent([String: AppMonth].self, forKey: .apps) ?? [:]
            addresses = try container.decodeIfPresent([String: AddressMonth].self,
                                                      forKey: .addresses) ?? [:]
            verbs = try container.decodeIfPresent([String: Int].self, forKey: .verbs) ?? [:]
            launcherAbandons = try container.decodeIfPresent(Int.self,
                                                             forKey: .launcherAbandons) ?? 0
            web = try container.decodeIfPresent(WebMonth.self, forKey: .web) ?? WebMonth()
            meetings = try container.decodeIfPresent(MeetingMonth.self,
                                                     forKey: .meetings) ?? MeetingMonth()
            coach = try container.decodeIfPresent([String: CoachMonth].self,
                                                  forKey: .coach) ?? [:]
            epochs = try container.decodeIfPresent([String: Int].self, forKey: .epochs) ?? [:]
            selectActions = try container.decodeIfPresent([String: Int].self,
                                                          forKey: .selectActions) ?? [:]
            selectSources = try container.decodeIfPresent([String: Int].self,
                                                          forKey: .selectSources) ?? [:]
            selectRows = try container.decodeIfPresent([String: Int].self,
                                                       forKey: .selectRows) ?? [:]
            health = try container.decodeIfPresent(HealthMonth.self,
                                                   forKey: .health) ?? HealthMonth()
            hours = try container.decodeIfPresent([Int].self, forKey: .hours)
                ?? [Int](repeating: 0, count: 24)
            transitions = try container.decodeIfPresent([String: [String: Int]].self,
                                                        forKey: .transitions) ?? [:]
            dwell = try container.decodeIfPresent(Stat.self, forKey: .dwell) ?? Stat()
            checkingLoops = try container.decodeIfPresent(Int.self, forKey: .checkingLoops) ?? 0
            latency = try container.decodeIfPresent([String: Stat].self, forKey: .latency) ?? [:]
            weeks = try container.decodeIfPresent([String: WeekHealth].self,
                                                  forKey: .weeks) ?? [:]
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

    /// Cross-event state the fold carries: the focus structure and the
    /// stretch machinery need the previous event, and continuity must
    /// survive a month boundary — a dwell that started in July still ends
    /// in August.
    private struct Fold {
        var lastFocusApp: String?
        var lastFocusAt: Date?
        var appBeforeLast: String?
        /// The open stretch: minutes so far, and where its last pulse sat.
        var stretchMinutes = 0
        var stretchMonth: String?
        var lastPulseEnd: Date?
    }

    /// Dwell outside these bounds is not attention: under a second is
    /// focus passing through, over two hours is a machine left on.
    static let dwellFloor: TimeInterval = 1
    static let dwellCeiling: TimeInterval = 2 * 3600
    /// Back to the app just left within this is a checking loop.
    static let checkingLoopSeconds: TimeInterval = 15
    /// Same continuity rule as `Health.stretchGap`.
    static let stretchGap: TimeInterval = 20 * 60
    /// A gap this long is a break; longer is a day boundary.
    static let breakCeiling: TimeInterval = 4 * 3600
    /// The live view's cap, kept in step by the tests.
    static let transitionAppCap = 24

    /// Every *completed* month in `events`, aggregated. The month `now`
    /// sits in is still being written, so it is never rolled — the fold's
    /// state still advances through it, so a structure straddling the
    /// boundary is not misread, but nothing is written into it.
    public static func build(events: [ObservationEvent], now: Date) -> [String: Month] {
        let open = monthKey(now)
        var months: [String: Month] = [:]
        var daySets: [String: Set<Int>] = [:]
        var fold = Fold()
        for event in events.sorted(by: { $0.t < $1.t }) {
            let key = monthKey(event.t)
            structure(event, into: &months, fold: &fold, open: open)
            guard key != open else { continue }
            var month = months[key] ?? Month(firstEvent: event.t, lastEvent: event.t)
            month.events += 1
            month.firstEvent = min(month.firstEvent, event.t)
            month.lastEvent = max(month.lastEvent, event.t)
            daySets[key, default: []].insert(dayOrdinal(event.t))
            apply(event, to: &month)
            months[key] = month
        }
        // A stretch still open at the fold's end: record it if it lives in
        // a closed month — in the open month it is still being written.
        if let month = fold.stretchMonth, month != open, fold.stretchMinutes > 0 {
            months[month]?.health.stretchMinutes.add(Double(fold.stretchMinutes))
        }
        for (key, set) in daySets { months[key]?.days = set.count }
        return months
    }

    /// The cross-event half of the fold: transitions, dwell, checking
    /// loops, stretches, and breaks. Contributions land in the month of
    /// the event that completes them, and never in the open month.
    private static func structure(_ event: ObservationEvent, into months: inout [String: Month],
                                  fold: inout Fold, open: String) {
        let key = monthKey(event.t)
        let week = "\(Observations.week(event.t))"

        func withMonth(_ mutate: (inout Month) -> Void) {
            guard key != open else { return }
            var month = months[key] ?? Month(firstEvent: event.t, lastEvent: event.t)
            mutate(&month)
            months[key] = month
        }

        switch event.kind {
        case .focus:
            guard let app = event.app else { return }
            defer {
                if fold.lastFocusApp != app {
                    fold.appBeforeLast = fold.lastFocusApp
                    fold.lastFocusApp = app
                    fold.lastFocusAt = event.t
                }
            }
            guard let previous = fold.lastFocusApp, previous != app,
                  let since = fold.lastFocusAt else { return }
            let dwell = event.t.timeIntervalSince(since)
            withMonth { month in
                if dwell >= dwellFloor, dwell <= dwellCeiling {
                    month.dwell.add(log(dwell))
                    month.weeks[week, default: WeekHealth()].dwell.add(log(dwell))
                }
                month.weeks[week, default: WeekHealth()].switches += 1
                if fold.appBeforeLast == app, dwell < checkingLoopSeconds {
                    month.checkingLoops += 1
                    month.weeks[week, default: WeekHealth()].checkingLoops += 1
                }
                // The transition matrix, under the same cap discipline the
                // live view keeps: a month cannot grow one app past the
                // bound by arriving as a destination.
                if month.transitions[previous]?[app] == nil {
                    let known = Set(month.transitions.keys)
                        .union(month.transitions.values.flatMap(\.keys))
                    let need = (known.contains(app) ? 0 : 1)
                        + (known.contains(previous) ? 0 : 1)
                    if need > 0, known.count + need > transitionAppCap { return }
                }
                month.transitions[previous, default: [:]][app, default: 0] += 1
            }

        case .pulse:
            let active = event.activeMinutes ?? 0
            // Stretches and breaks first, because they read the *previous*
            // pulse's position.
            if let end = fold.lastPulseEnd {
                let gap = event.t.timeIntervalSince(end)
                if gap <= stretchGap {
                    fold.stretchMinutes += active
                } else {
                    if let month = fold.stretchMonth, month != open, fold.stretchMinutes > 0 {
                        months[month]?.health.stretchMinutes
                            .add(Double(fold.stretchMinutes))
                    }
                    if gap <= breakCeiling {
                        withMonth { $0.health.breakMinutes.add(gap / 60) }
                    }
                    fold.stretchMinutes = active
                }
            } else {
                fold.stretchMinutes = active
            }
            fold.stretchMonth = key
            fold.lastPulseEnd = event.t.addingTimeInterval(HealthPulse.windowSeconds)

        default:
            return
        }
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
            let hour = Calendar.current.component(.hour, from: event.t)
            month.hours[min(23, max(0, hour))] += 1

        case .pulse:
            let week = "\(Observations.week(event.t))"
            let active = event.activeMinutes ?? 0
            month.health.keys += event.keys ?? 0
            month.health.backspaces += event.backspaces ?? 0
            month.health.clicks += event.clicks ?? 0
            month.health.scrolls += event.scrolls ?? 0
            month.health.activeMinutes += active
            month.health.interKey.merge(n: event.ikN ?? 0, sum: event.ikSum ?? 0,
                                        sumSquares: event.ikSumSq ?? 0)
            let hour = Calendar.current.component(.hour, from: event.t)
            month.health.activeHours[min(23, max(0, hour))] += active
            let weekday = Calendar.current.component(.weekday, from: event.t) - 1
            month.health.weekdays[min(6, max(0, weekday))] += active
            var weekly = month.weeks[week] ?? WeekHealth()
            weekly.keys += event.keys ?? 0
            weekly.backspaces += event.backspaces ?? 0
            weekly.clicks += event.clicks ?? 0
            weekly.scrolls += event.scrolls ?? 0
            weekly.activeMinutes += active
            weekly.interKey.merge(n: event.ikN ?? 0, sum: event.ikSum ?? 0,
                                  sumSquares: event.ikSumSq ?? 0)
            month.weeks[week] = weekly

        case .latency:
            guard let surface = event.verb, let seconds = event.seconds, seconds > 0
            else { return }
            month.latency[surface, default: Stat()].add(log(seconds))

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
            case "ignored": record.ignored += 1
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
