import Foundation

/// What Lodestar knows about how you reach things: the materialized view
/// over the event log, and the substrate every model reads.
///
/// v2 changed the deal. v1 kept counts and per-chain medians; the medians
/// turned out to confound chain length with fluency, and because the
/// aggregation happened at write time the mistake was frozen into the data.
/// Now the raw signal lives in `events.jsonl` (see `EventLog`), this struct
/// is rebuildable from it (`rebuild(from:)`), and every mutation flows
/// through one entry point — `apply(_:)` — so the live view and a replay can
/// never disagree.
///
/// Everything here stays on this machine. The file records app names, graph
/// letters, timings, and the hosts you open — never a window title, a URL
/// path, a clipboard, or a typed query beyond its first two characters.
public struct Observations: Codable, Equatable {
    public static let currentVersion = 2

    /// A pause longer than this is not a recall event: chains wait
    /// indefinitely by design, so an interruption would otherwise put
    /// minutes into the statistics. Ten seconds, learned the hard way —
    /// two discarded exactly the slow addresses worth finding.
    public static let recallCeiling: TimeInterval = 10.0
    static let recentCap = 64
    static let firstCap = 30
    static let weekCap = 12
    static let transitionAppCap = 24
    static let hostCap = 120
    static let confusionCap = 12
    static let prefixCap = 12
    static let ledgerCap = 100

    // MARK: - Building blocks

    /// Running sufficient statistics: enough for a mean, a variance, and a
    /// standard error forever, in constant space. Latencies go in as
    /// log-seconds — the scale where typing speed is additive and one
    /// interruption cannot drag an average.
    public struct Moments: Codable, Equatable {
        public var n = 0
        public var sum = 0.0
        public var sumSq = 0.0

        public init() {}

        public mutating func add(_ x: Double) {
            n += 1
            sum += x
            sumSq += x * x
        }

        public var mean: Double? { n > 0 ? sum / Double(n) : nil }
        public var variance: Double? {
            guard n > 1, let mean else { return nil }
            return max(0, (sumSq - Double(n) * mean * mean) / Double(n - 1))
        }
        public var sd: Double? { variance.map(sqrt) }
        /// Standard error of the mean.
        public var se: Double? {
            guard let sd, n > 0 else { return nil }
            return sd / sqrt(Double(n))
        }
    }

    /// Use intensity at three timescales. Three exponentials at spaced
    /// half-lives approximate the power-law forgetting kernel (ACT-R's
    /// base-level activation) without storing a single timestamp beyond the
    /// last touch.
    public struct MultiScale: Codable, Equatable {
        public static let halfLives: [TimeInterval] = [86_400, 604_800, 6 * 604_800]
        public var values: [Double] = [0, 0, 0]
        public var at = Date.distantPast

        public init() {}

        public mutating func bump(at now: Date) {
            decay(to: now)
            for i in values.indices { values[i] += 1 }
        }

        public mutating func decay(to now: Date) {
            guard at != .distantPast, now > at else { at = max(at, now); return }
            let dt = now.timeIntervalSince(at)
            for (i, halfLife) in Self.halfLives.enumerated() {
                values[i] *= pow(0.5, dt / halfLife)
            }
            at = now
        }

        /// Current value at a scale, decayed to `now` without mutating.
        public func value(scale: Int, at now: Date) -> Double {
            guard values.indices.contains(scale) else { return 0 }
            guard at != .distantPast, now > at else { return values[scale] }
            return values[scale] * pow(0.5, now.timeIntervalSince(at) / Self.halfLives[scale])
        }
    }

    /// One timed pause, tagged with everything the models condition on.
    /// Position matters because trigger→first-letter is recall while
    /// letter→letter is motor; the ordinal is the x-axis of the learning
    /// curve; the epoch scopes it to the binding that existed at the time.
    public struct GapSample: Codable, Equatable {
        /// log-seconds.
        public var log: Double
        /// 0 = trigger→first letter; n = the gap before letter n+1.
        public var pos: Int
        /// The map was up before the first letter — a labeled
        /// "reconstruction, not recall" for the mixture model.
        public var peeked: Bool
        public var week: Int
        public var epoch: Int
        /// Which completion this was (1-based), for the curve.
        public var ordinal: Int

        public init(log: Double, pos: Int, peeked: Bool, week: Int, epoch: Int, ordinal: Int) {
            self.log = log
            self.pos = pos
            self.peeked = peeked
            self.week = week
            self.epoch = epoch
            self.ordinal = ordinal
        }
    }

    public struct AddressRecord: Codable, Equatable {
        public var completions = 0
        public var abandons = 0
        public var wrongKeys = 0
        /// Wrong key → count: which letter the hand believed in.
        public var confusion: [String: Int] = [:]
        /// How long the hand hovered before an escape, log-seconds.
        public var hover = Moments()
        /// Trigger→first-letter gaps, log-seconds, this epoch.
        public var trigger = Moments()
        /// Letter→letter gaps, log-seconds, this epoch.
        public var inner = Moments()
        /// The first samples of the current epoch — the learning curve's
        /// beginning, kept past the event ring. Cleared when the binding
        /// changes, because a rebind restarts the curve.
        public var first: [GapSample] = []
        /// The rolling present.
        public var recent: [GapSample] = []
        /// Completions whose first letter waited for the map.
        public var peeked = 0
        public var weeks: [Int: Int] = [:]
        /// The week this record first appeared — the honest denominator
        /// for its lifetime counters, which outlive the pruned week ring.
        /// Optional so records written before the field decode unchanged.
        public var firstWeek: Int?
        public var usage = MultiScale()
        /// The config generation this binding has had since.
        public var epoch = 0
        public var lastUsed = Date.distantPast

        public init() {}
    }

    /// How an app was reached. The distinction is the recommendation
    /// engine: searching for something that has an address means the
    /// address is not learned; searching for something that has none means
    /// it wants one.
    public enum Route: String, Codable, Equatable {
        case graph, searcher, breath, chooser, other
    }

    /// What one launcher pick cost, measured at the moment it was paid.
    public struct LauncherCost: Codable, Equatable {
        public var typed: Int
        /// The first two characters of the query — the name in the head.
        public var prefix: String
        /// Row picked, 0-based: rank 0 means the top hit.
        public var rank: Int
        public var listLength: Int
        public var openToFirstKey: Double?
        public var openToCommit: Double?

        public init(typed: Int, prefix: String, rank: Int, listLength: Int,
                    openToFirstKey: Double? = nil, openToCommit: Double? = nil) {
            self.typed = typed
            self.prefix = prefix
            self.rank = rank
            self.listLength = listLength
            self.openToFirstKey = openToFirstKey
            self.openToCommit = openToCommit
        }
    }

    public struct AppRecord: Codable, Equatable {
        public var graph = 0
        public var searcher = 0
        public var breath = 0
        public var chooser = 0
        public var other = 0
        /// Characters typed before picking.
        public var typed = Moments()
        /// Row rank at pick (0 = top).
        public var rank = Moments()
        public var listLength = Moments()
        /// Bar-open → commit, log-seconds: the road's true price.
        public var commit = Moments()
        /// Bar-open → first key, log-seconds: the thinking part.
        public var firstKey = Moments()
        /// First two characters typed when searching for this app.
        public var prefixes: [String: Int] = [:]
        public var weeks: [Int: Int] = [:]
        /// See `AddressRecord.firstWeek`.
        public var firstWeek: Int?
        /// 8 buckets: 4 six-hour dayparts × weekday/weekend.
        public var dayparts: [Int] = Array(repeating: 0, count: 8)
        public var usage = MultiScale()
        public var lastUsed = Date.distantPast

        public init() {}

        public var reaches: Int { graph + searcher + breath + chooser + other }
    }

    /// How select behaves per app: where it succeeds, where it gets
    /// abandoned, which sensor served it, how ambiguous its screens are.
    /// Deliberately as deep as AppRecord — weeks for the habit gates,
    /// multi-scale usage for recency, running moments for costs — because
    /// the recommendation engine prices everything else from exactly these
    /// shapes and select must not be the register it cannot reason about.
    public struct SelectRecord: Codable, Equatable {
        public var completed = 0
        public var abandoned = 0
        public var ocr = 0
        public var ax = 0
        public var native = 0
        public var held = 0
        /// Query characters per session — the road's price in keys.
        public var typed = Moments()
        /// Seconds per session — the road's price in time.
        public var seconds = Moments()
        /// Matches on screen at the end — how ambiguous this app's
        /// screens are for typed anchors.
        public var matches = Moments()
        public var weeks: [Int: Int] = [:]
        public var usage = MultiScale()
        public var lastUsed = Date.distantPast

        public init() {}
    }

    public struct HostRecord: Codable, Equatable {
        public var count = 0
        /// Profile key → times it landed there.
        public var profiles: [String: Int] = [:]
        /// typed | clicked.
        public var sources: [String: Int] = [:]
        public var weeks: [Int: Int] = [:]
        /// See `AddressRecord.firstWeek`.
        public var firstWeek: Int?
        public var lastUsed = Date.distantPast

        public init() {}

        /// The deliberate choices only — "pass" is a clicked link that
        /// matched no rule, evidence of nothing. One definition, shared by
        /// the advisor's pricing and the chip's evidence, so the two can
        /// never disagree about the population again.
        public var chosenProfiles: [String: Int] {
            profiles.filter { $0.key != "pass" }
        }
    }

    /// One recommendation's life, as a view over coach events: offered,
    /// then answered — accepted by the tap, declined outright, or adopted
    /// by hand later. This record is what lets the coach remember "no",
    /// pace itself, and eventually be scored against what it predicted.
    public struct LedgerEntry: Codable, Equatable {
        /// kind:target — one entry per recommendation identity.
        public var id: String
        public var kind: String
        public var target: String
        /// The proposed chain key, when the recommendation names one.
        public var chain: String?
        public var predictedSecondsPerWeek: Double
        public var firstOfferedWeek: Int
        public var lastOfferedWeek: Int
        /// Day-grain, because retry cooldowns are days and weeks are too
        /// coarse to say "not twice in one afternoon".
        public var lastOfferedAt = Date.distantPast
        public var offers: Int
        /// offered | accepted | never.
        public var status: String
        public var acceptedWeek: Int?
        /// The user did it by hand: an epoch event matched this entry.
        public var adoptedWeek: Int?
        public var neverWeek: Int?
        /// Day-grain like the offer stamp: the channel's quiet after an
        /// answer is priced in days, and weeks cannot say "yesterday".
        /// Optional so ledgers written before the field decode unchanged.
        public var lastAnsweredAt: Date?
        /// The chip stood its whole life and was still not answered — seen
        /// and passed over, as distinct from never readable. Reset by each
        /// new showing, so it always describes the most recent one.
        /// Optional for the same back-compatibility reason.
        public var lastShowingStood: Bool?
        /// How many times that has happened, for the report.
        public var ignores: Int?

        public init(id: String, kind: String, target: String, chain: String? = nil,
                    predictedSecondsPerWeek: Double, firstOfferedWeek: Int,
                    lastOfferedWeek: Int, offers: Int, status: String,
                    acceptedWeek: Int? = nil, adoptedWeek: Int? = nil,
                    neverWeek: Int? = nil, lastAnsweredAt: Date? = nil,
                    lastShowingStood: Bool? = nil, ignores: Int? = nil) {
            self.id = id
            self.kind = kind
            self.target = target
            self.chain = chain
            self.predictedSecondsPerWeek = predictedSecondsPerWeek
            self.firstOfferedWeek = firstOfferedWeek
            self.lastOfferedWeek = lastOfferedWeek
            self.offers = offers
            self.status = status
            self.acceptedWeek = acceptedWeek
            self.adoptedWeek = adoptedWeek
            self.neverWeek = neverWeek
            self.lastAnsweredAt = lastAnsweredAt
            self.lastShowingStood = lastShowingStood
            self.ignores = ignores
        }
    }

    // MARK: - State

    public var version = Observations.currentVersion
    /// Addresses keyed by their chain, lowercased and space separated.
    public var addresses: [String: AddressRecord] = [:]
    /// Apps keyed by lowercased name, which the graph and config already use.
    public var apps: [String: AppRecord] = [:]
    /// Verb name → times used, so a feature nobody touches can say so.
    public var verbs: [String: Int] = [:]
    /// Host → where it went. What makes route recommendations possible.
    public var hosts: [String: HostRecord] = [:]
    /// App → how select fares there.
    public var selects: [String: SelectRecord] = [:]
    /// App → app decayed transition counts: the co-use structure breaths
    /// are recommended from. Halved weekly so it stays present-tense.
    public var transitions: [String: [String: Double]] = [:]
    var transitionsDecayedAt = Date.distantPast
    var lastApp: String?
    public var launcherAbandons = 0
    public var launcherAbandonTyped = Moments()
    /// The config generation, bumped whenever a graph binding changes.
    public var epoch = 0
    public var ledger: [LedgerEntry] = []
    public var since = Date.distantPast
    public var updated = Date.distantPast

    public init() {}

    // MARK: - Keys

    public static func key(_ letters: [String]) -> String {
        letters.map { $0.lowercased() }.joined(separator: " ")
    }

    /// Weeks since the epoch: no locale, no time zone, monotonic.
    public static func week(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 604_800)
    }

    /// 0–7: four six-hour dayparts, weekday then weekend. Local time on
    /// purpose — "morning" is a fact about the person, not about UTC.
    public static func daypart(_ date: Date, calendar: Calendar = .current) -> Int {
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let weekend = weekday == 1 || weekday == 7
        return (weekend ? 4 : 0) + min(3, max(0, hour / 6))
    }

    // MARK: - The one mutation

    /// Every event, live or replayed, lands here. The store appends the
    /// event to the log and calls this; `rebuild(from:)` calls only this.
    /// Keeping one entry point is what makes the view provably a view.
    public mutating func apply(_ event: ObservationEvent) {
        let now = event.t
        switch event.kind {
        case .chain:
            guard let letters = event.chain, !letters.isEmpty else { return }
            touch(now)
            let key = Self.key(letters)
            var record = addresses[key] ?? AddressRecord()
            record.firstWeek = record.firstWeek ?? Self.week(now)
            record.completions += 1
            record.lastUsed = now
            record.weeks[Self.week(now), default: 0] += 1
            Self.prune(&record.weeks)
            record.usage.bump(at: now)
            let peeked = event.peeked ?? false
            if peeked { record.peeked += 1 }
            for (pos, gap) in (event.gaps ?? []).enumerated()
                where gap > 0 && gap <= Self.recallCeiling {
                let sample = GapSample(log: Foundation.log(gap), pos: pos,
                                       peeked: peeked && pos == 0,
                                       week: Self.week(now), epoch: record.epoch,
                                       ordinal: record.completions)
                if pos == 0 { record.trigger.add(sample.log) } else { record.inner.add(sample.log) }
                if record.first.count < Self.firstCap { record.first.append(sample) }
                record.recent.append(sample)
                if record.recent.count > Self.recentCap { record.recent.removeFirst() }
            }
            addresses[key] = record

        case .abandon:
            guard let letters = event.chain, !letters.isEmpty else { return }
            touch(now)
            let key = Self.key(letters)
            var record = addresses[key] ?? AddressRecord()
            record.firstWeek = record.firstWeek ?? Self.week(now)
            record.abandons += 1
            if let hover = event.hover, hover > 0 {
                record.hover.add(Foundation.log(min(hover, Self.recallCeiling)))
            }
            addresses[key] = record

        case .wrongKey:
            touch(now)
            let key = event.chain.map(Self.key) ?? ""
            var record = addresses[key] ?? AddressRecord()
            record.firstWeek = record.firstWeek ?? Self.week(now)
            record.wrongKeys += 1
            if let pressed = event.pressed, !pressed.isEmpty {
                if record.confusion[pressed] != nil || record.confusion.count < Self.confusionCap {
                    record.confusion[pressed, default: 0] += 1
                }
            }
            addresses[key] = record

        case .reach:
            guard let name = event.app?.lowercased(), !name.isEmpty,
                  let routeRaw = event.route, let route = Route(rawValue: routeRaw) else { return }
            touch(now)
            var record = apps[name] ?? AppRecord()
            record.firstWeek = record.firstWeek ?? Self.week(now)
            switch route {
            case .graph: record.graph += 1
            case .searcher: record.searcher += 1
            case .breath: record.breath += 1
            case .chooser: record.chooser += 1
            case .other: record.other += 1
            }
            record.lastUsed = now
            record.weeks[Self.week(now), default: 0] += 1
            Self.prune(&record.weeks)
            record.dayparts[Self.daypart(now)] += 1
            record.usage.bump(at: now)
            if route == .searcher {
                if let typed = event.typed, typed >= 0 { record.typed.add(Double(typed)) }
                if let rank = event.rank, rank >= 0 { record.rank.add(Double(rank)) }
                if let length = event.listLength, length >= 0 {
                    record.listLength.add(Double(length))
                }
                if let seconds = event.openToCommit, seconds > 0 {
                    record.commit.add(Foundation.log(seconds))
                }
                if let seconds = event.openToFirstKey, seconds > 0 {
                    record.firstKey.add(Foundation.log(seconds))
                }
                if let prefix = event.queryPrefix, !prefix.isEmpty {
                    if record.prefixes[prefix] != nil || record.prefixes.count < Self.prefixCap {
                        record.prefixes[prefix, default: 0] += 1
                    }
                }
            }
            apps[name] = record

        case .launcherAbandon:
            touch(now)
            launcherAbandons += 1
            if let typed = event.typed, typed >= 0 { launcherAbandonTyped.add(Double(typed)) }

        case .verb:
            guard let verb = event.verb, !verb.isEmpty else { return }
            touch(now)
            verbs[verb, default: 0] += 1

        case .web:
            touch(now)
            guard let host = event.host?.lowercased(), !host.isEmpty else { return }
            var record = hosts[host] ?? HostRecord()
            if hosts[host] == nil && hosts.count >= Self.hostCap {
                // Full: evict the least-visited host rather than refuse the
                // new one, so the table follows the present.
                if let coldest = hosts.min(by: { $0.value.count < $1.value.count }),
                   coldest.value.count <= 1 {
                    hosts.removeValue(forKey: coldest.key)
                } else {
                    return
                }
            }
            record.firstWeek = record.firstWeek ?? Self.week(now)
            record.count += 1
            record.lastUsed = now
            record.weeks[Self.week(now), default: 0] += 1
            Self.prune(&record.weeks)
            if let profile = event.profile, !profile.isEmpty {
                record.profiles[profile, default: 0] += 1
            }
            if let source = event.source, !source.isEmpty {
                record.sources[source, default: 0] += 1
            }
            hosts[host] = record

        case .focus:
            guard let app = event.app?.lowercased(), !app.isEmpty else { return }
            touch(now)
            defer { lastApp = app }
            guard let previous = lastApp, previous != app else { return }
            decayTransitions(to: now)
            // The cap audit walks every key in the table, so it runs only
            // when this arrival could actually grow it — a seen pair, the
            // overwhelmingly common case on this every-app-switch path,
            // pays a lookup and nothing else. Both endpoints are audited:
            // checking only the destination let a capped-out app slip in
            // as a row key and grow the matrix past its bound anyway.
            if transitions[previous]?[app] == nil {
                let known = Set(transitions.keys).union(transitions.values.flatMap(\.keys))
                let need = (known.contains(app) ? 0 : 1)
                    + (known.contains(previous) ? 0 : 1)
                if need > 0, known.count + need > Self.transitionAppCap { return }
            }
            transitions[previous, default: [:]][app, default: 0] += 1

        case .epoch:
            touch(now)
            epoch = max(epoch, event.epoch ?? epoch + 1)
            guard let address = event.address else { return }
            var record = addresses[address] ?? AddressRecord()
            // A changed binding restarts its learning curve: the fluency of
            // the old letters says nothing about the new ones.
            record.epoch = epoch
            record.first = []
            record.trigger = Moments()
            record.inner = Moments()
            record.peeked = 0
            addresses[address] = record
            if event.change == "added" || event.change == "retargeted" {
                markAdopted(address: address, at: now)
            }

        case .select:
            guard let name = event.app?.lowercased(), !name.isEmpty,
                  let action = event.action else { return }
            touch(now)
            var record = selects[name] ?? SelectRecord()
            if action == "completed" { record.completed += 1 } else { record.abandoned += 1 }
            if event.source == "ocr" { record.ocr += 1 } else { record.ax += 1 }
            if event.row == "native" || event.row == "grounded" { record.native += 1 }
            if event.row == "held" { record.held += 1 }
            if let typed = event.typed, typed >= 0 { record.typed.add(Double(typed)) }
            if let seconds = event.seconds, seconds > 0, seconds < 120 {
                record.seconds.add(seconds)
            }
            if let matches = event.listLength, matches >= 0 {
                record.matches.add(Double(matches))
            }
            record.weeks[Self.week(now), default: 0] += 1
            Self.prune(&record.weeks)
            record.usage.bump(at: now)
            record.lastUsed = now
            selects[name] = record

        case .meeting:
            // Kept in the log for the retrospective and for lead-time
            // calibration, both of which read events directly. The live
            // view needs nothing from it yet — aggregate at read time.
            touch(now)

        case .coach:
            touch(now)
            guard let action = event.action, let kind = event.rec,
                  let target = event.app else { return }
            let id = "\(kind):\(target)"
            let week = Self.week(now)
            let existing = ledger.firstIndex { $0.id == id }
            var entry = existing.map { ledger[$0] } ?? LedgerEntry(
                id: id, kind: kind, target: target, chain: event.address,
                predictedSecondsPerWeek: event.seconds ?? 0,
                firstOfferedWeek: week, lastOfferedWeek: week, offers: 0,
                status: "offered")
            switch action {
            case "offered":
                entry.offers += 1
                entry.lastOfferedWeek = week
                entry.lastOfferedAt = now
                // A fresh offer supersedes a stale answer: a "never" that
                // the coach deliberately re-opened must read as offered
                // again, or a later hand-adoption is invisible to
                // markAdopted. The neverWeek stamp survives for the
                // sleep arithmetic.
                entry.status = "offered"
                // A fresh showing has not stood yet; the flag describes the
                // most recent one, never the history.
                entry.lastShowingStood = false
                if let seconds = event.seconds { entry.predictedSecondsPerWeek = seconds }
                if let chain = event.address { entry.chain = chain }
            case "ignored":
                // Not an answer, so no lastAnsweredAt and no status change:
                // the suggestion is still on offer. What changed is what is
                // known about the last showing — it was read and passed
                // over — and that buys the long retry instead of the short.
                entry.lastShowingStood = true
                entry.ignores = (entry.ignores ?? 0) + 1
            case "accepted":
                entry.status = "accepted"
                entry.acceptedWeek = week
                entry.lastAnsweredAt = now
            case "never":
                entry.status = "never"
                entry.neverWeek = week
                entry.lastAnsweredAt = now
            default:
                return
            }
            if let existing { ledger.remove(at: existing) }
            ledger.append(entry)
            if ledger.count > Self.ledgerCap { ledger.removeFirst(ledger.count - Self.ledgerCap) }
        }
    }

    /// Fold the log. The proof that the view is a view: applying every
    /// event to a fresh struct must equal the struct the store carried.
    public static func rebuild(from events: [ObservationEvent]) -> Observations {
        var observations = Observations()
        for event in events { observations.apply(event) }
        return observations
    }

    // MARK: - Ledger

    /// An offered suggestion whose proposed binding just appeared in the
    /// config by hand is adopted all the same — the flywheel closes
    /// without the user filing anything.
    private mutating func markAdopted(address: String, at now: Date) {
        for index in ledger.indices
            where ledger[index].adoptedWeek == nil && ledger[index].status == "offered"
            && (ledger[index].chain == address || ledger[index].target == address) {
            ledger[index].adoptedWeek = Self.week(now)
        }
    }

    // MARK: - Reading

    /// Median recent pause in seconds at a position class, and the samples
    /// it rests on. Position-scoped because trigger→letter and
    /// letter→letter are different events; mixing them was v1's confound.
    public func fluency(_ letters: [String], pos: Int? = nil, minimumSamples: Int = 5)
        -> (median: TimeInterval, samples: Int)? {
        guard let record = addresses[Self.key(letters)] else { return nil }
        let samples = record.recent.filter { pos == nil || $0.pos == pos }
        guard samples.count >= minimumSamples,
              let median = Self.median(samples.map(\.log)) else { return nil }
        return (exp(median), samples.count)
    }

    /// The share of completions that never needed the map. As direct a
    /// measure of "the hand owns this" as exists here.
    public func blindRate(_ letters: [String], minimumSamples: Int = 5) -> Double? {
        guard let record = addresses[Self.key(letters)],
              record.completions >= minimumSamples else { return nil }
        return 1 - Double(record.peeked) / Double(record.completions)
    }

    /// Abandons ÷ starts for a prefix and everything under it. v1 asked
    /// each leaf and got silence, because escapes attach to the prefix
    /// where the hand stalled — aggregation over the subtree is the fix.
    public func abandonRate(prefix: [String], minimumEvents: Int = 5) -> Double? {
        let key = Self.key(prefix)
        var completions = 0
        var abandons = 0
        for (address, record) in addresses
            where address == key || address.hasPrefix(key.isEmpty ? "" : key + " ") {
            completions += record.completions
            abandons += record.abandons
        }
        let total = completions + abandons
        guard total >= minimumEvents else { return nil }
        return Double(abandons) / Double(total)
    }

    /// The share of an app's reaches that went through the launcher.
    public func routeShare(_ app: String, minimumReaches: Int = 5) -> Double? {
        guard let record = apps[app.lowercased()], record.reaches >= minimumReaches else {
            return nil
        }
        return Double(record.searcher) / Double(record.reaches)
    }

    /// What searching for this app costs in seconds, if timed; the median
    /// character count as the fallback story.
    public func launcherSeconds(_ app: String) -> Double? {
        guard let mean = apps[app.lowercased()]?.commit.mean else { return nil }
        return exp(mean)
    }

    public func medianTyped(_ app: String) -> Int? {
        guard let mean = apps[app.lowercased()]?.typed.mean else { return nil }
        return Int(mean.rounded())
    }

    /// Distinct active weeks. A signal that holds across two is a habit.
    /// A gate, not a denominator: the week ring is pruned to `weekCap`, so
    /// this saturates — dividing a lifetime counter by it inflates every
    /// weekly rate once a record outlives the ring.
    public func activeWeeks(address letters: [String]) -> Int {
        addresses[Self.key(letters)]?.weeks.values.filter { $0 > 0 }.count ?? 0
    }

    public func activeWeeks(app: String) -> Int {
        apps[app.lowercased()]?.weeks.values.filter { $0 > 0 }.count ?? 0
    }

    /// Weeks a record has been observed, from its first sighting — the
    /// denominator that matches a lifetime numerator. Records from before
    /// `firstWeek` existed fall back to their retained active weeks, which
    /// is the old (saturating) reading, gone as soon as they are touched.
    static func observedWeeks(firstWeek: Int?, weeks: [Int: Int], now: Date) -> Int {
        if let firstWeek { return max(1, week(now) - firstWeek + 1) }
        return max(1, weeks.values.filter { $0 > 0 }.count)
    }

    public func observedWeeks(address letters: [String], now: Date = Date()) -> Int {
        observedWeeks(addressKey: Self.key(letters), now: now)
    }

    public func observedWeeks(addressKey: String, now: Date = Date()) -> Int {
        let record = addresses[addressKey]
        return Self.observedWeeks(firstWeek: record?.firstWeek,
                                  weeks: record?.weeks ?? [:], now: now)
    }

    public func observedWeeks(app: String, now: Date = Date()) -> Int {
        let record = apps[app.lowercased()]
        return Self.observedWeeks(firstWeek: record?.firstWeek,
                                  weeks: record?.weeks ?? [:], now: now)
    }

    public func observedWeeks(host: String, now: Date = Date()) -> Int {
        let record = hosts[host]
        return Self.observedWeeks(firstWeek: record?.firstWeek,
                                  weeks: record?.weeks ?? [:], now: now)
    }

    /// This person's own median trigger pause across fluent addresses —
    /// the baseline fluency is judged against, because a fixed threshold
    /// would insult fast typists and flatter slow ones.
    public func typicalPause(minimumSamples: Int = 5) -> TimeInterval? {
        let medians = addresses.values.compactMap { record -> Double? in
            let samples = record.recent.filter { $0.pos == 0 }
            guard samples.count >= minimumSamples else { return nil }
            return Self.median(samples.map(\.log))
        }
        return Self.median(medians).map(exp)
    }

    /// Addresses bound in the config and never completed here.
    public func unused(among bound: [[String]]) -> [[String]] {
        bound.filter { (addresses[Self.key($0)]?.completions ?? 0) == 0 }
    }

    // MARK: - Internals

    private mutating func touch(_ now: Date) {
        if since == .distantPast { since = now }
        updated = now
    }

    private mutating func decayTransitions(to now: Date) {
        guard transitionsDecayedAt != .distantPast else { transitionsDecayedAt = now; return }
        let weeks = now.timeIntervalSince(transitionsDecayedAt) / 604_800
        guard weeks > 0 else { return }
        let factor = pow(0.5, weeks)
        guard factor < 0.999 else { return }
        for (from, row) in transitions {
            var decayed = row.mapValues { $0 * factor }
            decayed = decayed.filter { $0.value > 0.01 }
            if decayed.isEmpty { transitions.removeValue(forKey: from) } else {
                transitions[from] = decayed
            }
        }
        transitionsDecayedAt = now
    }

    private static func prune(_ weeks: inout [Int: Int]) {
        guard weeks.count > weekCap else { return }
        for key in weeks.keys.sorted().prefix(weeks.count - weekCap) {
            weeks.removeValue(forKey: key)
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
