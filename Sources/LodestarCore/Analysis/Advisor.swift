import Foundation

/// The policy layer: reads the models, enumerates the config actions the
/// data can price, and returns the ones that survive the gates. Pure
/// computation — nothing here draws, flashes, or decides *when* to speak.
/// A recommendation is worth surfacing iff the posterior probability that
/// it saves net time clears the bar AND it survives false-discovery
/// control across everything else being tested. Thin data self-suppresses
/// through wide uncertainty; there is no minimum-samples constant hiding
/// the same decision less honestly.
/// The one config line a recommendation would write. This is what makes a
/// chip actionable: the coach's verb is exactly one line, and anything
/// that cannot be one line stays in the report.
public enum ConfigEdit: Codable, Equatable {
    /// Bind a graph target at a chain (bind and shorten both land here).
    /// `target` is what the config line writes — an app name, or
    /// `brave:xonar` for a browser profile. Never a display label.
    case bindTarget(chain: [String], target: String)
    /// Remove a binding (retire).
    case removeChain(chain: [String])
    /// Replace one address with another in a single write: bind `new`,
    /// remove `old`.
    ///
    /// Deliberately not "shorten". The replacement need not be shorter —
    /// a swap of the same length can win by no longer fighting the hand —
    /// so what this names is the supersession, not the saving.
    ///
    /// The removal is the point, not tidiness. Leaving the old address
    /// bound leaves the hand a way to keep the habit, and the hand takes
    /// it: with both paths open, Grossman et al. (CHI 2007) measured
    /// 28.9% expert use against 72.8% when the old path was closed, and
    /// half their control group never made the transition at all.
    case supersede(old: [String], new: [String], target: String)
    /// One route line: pattern → profile registry key.
    case addRoute(pattern: String, profileKey: String)
    /// The one line `meetings.enabled: true`. The permission ask is not
    /// here: the subsystem, finding itself enabled but unauthorized, runs
    /// its own prime-then-prompt — so this edit stays exactly one line.
    case enableMeetings
    /// Close the launcher road to an app that already has an address:
    /// until the address's curve bends, a launcher pick of that app asks
    /// once more. Not a config line — a ledger fact, read the way a
    /// supersede's redirect is read — because the closure is a
    /// transition aid with an expiry, and config has no expiry. Grossman
    /// et al. (CHI 2007): closing the old path is what moves hands; the
    /// chip alone tests below doing nothing.
    case closeRoad(app: String, chain: [String])
    /// Arrange these apps side by side right now and save the layout as a
    /// breath at `path`. The one accept that is state rather than a config
    /// line — a breath has no line to write — settled deliberately: one
    /// gesture, one receipt (the saved address), and the chip's copy says
    /// a layout will appear. The shell refuses when an app has no window,
    /// because composing must never mean launching things behind someone.
    case composeBreath(apps: [String], path: String)
}

public struct Recommendation: Codable, Equatable {
    public enum Kind: String, Codable {
        /// An app searched for often that has no address.
        case bind
        /// The hand keeps pressing a different letter than the graph holds.
        case rebind
        /// A deep chain frequent enough to earn a shorter one.
        case shorten
        /// A chain whose starts keep failing — depth read as the defect.
        case flatten
        /// Bound, and never once typed.
        case retire
        /// The address exists; the launcher keeps winning anyway.
        case nudge
        /// Apps that travel together and could be one gesture.
        case breath
        /// A host that always lands in the same profile, one rule away.
        case route
        /// Meetings joined by hand that the chip could hand over.
        case meetings

        /// Does accepting this replace one address with another?
        ///
        /// The old address is then not missing but moved, and the ledger
        /// entry already says where: a superseding recommendation carries
        /// the old address as its `target` and the new one as its `chain`.
        /// That is the whole tombstone, kept where the coach already keeps
        /// what it said and what became of it, so nothing has to be stored
        /// beside the config or in it.
        public var supersedes: Bool {
            self == .shorten || self == .rebind || self == .flatten
        }
    }

    public var kind: Kind
    public var target: String
    /// The one sentence a surface would show.
    public var detail: String
    public var secondsPerWeek: Double
    /// Posterior probability the change saves net time over the horizon.
    public var probability: Double
    public var evidence: [String]
    /// What to call the target on screen, when that differs from what the
    /// edit writes: a browser profile shows as "Brave (Xonar)" and commits
    /// "brave:xonar". Nil means the edit's own target already reads as a
    /// name a person would recognise.
    public var display: String?
    /// The write this recommendation proposes, when it is one config line.
    /// Nil means report-only: the chip never offers what it cannot commit.
    public var edit: ConfigEdit?

    public init(kind: Kind, target: String, detail: String, secondsPerWeek: Double,
                probability: Double, evidence: [String], display: String? = nil,
                edit: ConfigEdit? = nil) {
        self.kind = kind
        self.target = target
        self.detail = detail
        self.secondsPerWeek = secondsPerWeek
        self.probability = probability
        self.evidence = evidence
        self.display = display
        self.edit = edit
    }
}

public enum Advisor {
    /// One bound address, as the advisor needs to see it.
    public struct Leaf {
        public let chain: [String]
        /// What a person calls it — mnemonic letters and chip text come
        /// from here.
        public let label: String
        /// What a config line writes to bind the same target. For a browser
        /// profile the two differ ("Brave (Xonar)" against "brave:xonar"),
        /// and an edit that commits the label silently binds plain Brave.
        public let value: String

        public init(chain: [String], label: String, value: String) {
            self.chain = chain
            self.label = label
            self.value = value
        }
    }

    public struct Context {
        public var observations: Observations
        public var events: [ObservationEvent]
        /// Bound chains and their targets, from the live graph.
        public var leaves: [Leaf]
        /// The web route table, so an already-covered host stays quiet.
        public var webRoutes: [String: String]
        /// Observed profile identity ("brave:Work") → registry key ("work"),
        /// so a route recommendation can name the key a config line needs.
        public var profileKeys: [String: String]
        /// The meetings offer retires the moment the feature is on.
        public var meetingsEnabled: Bool
        /// Saved breath paths, so a breath offer can name a free letter.
        public var breathPaths: [String]
        public var now: Date

        public init(observations: Observations, events: [ObservationEvent],
                    leaves: [Leaf],
                    webRoutes: [String: String] = [:],
                    profileKeys: [String: String] = [:],
                    meetingsEnabled: Bool = false,
                    breathPaths: [String] = [], now: Date = Date()) {
            self.observations = observations
            self.events = events
            self.leaves = leaves
            self.webRoutes = webRoutes
            self.profileKeys = profileKeys
            self.meetingsEnabled = meetingsEnabled
            self.breathPaths = breathPaths
            self.now = now
        }
    }

    /// Half a year, discounted: a demonstrated habit projects forward, but
    /// the far weeks — where it may not survive — count for less. The
    /// discounting is what keeps a four-week fad from buying a permanent
    /// letter.
    static let horizonWeeks = 26
    static let horizonHalfLife = 12.0
    static let probabilityGate = 0.9

    /// A stable seed for the Monte Carlo. `hashValue` cannot do this job:
    /// Swift randomises it per process, so seeding from it made every run
    /// draw a different sample — the precise opposite of what `Random`
    /// promises below, and enough to make a candidate sitting near the
    /// gate appear and vanish between runs. FNV-1a over the bytes is
    /// stable, and total (`abs()` on `Int.min` would have trapped).
    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Deterministic LCG so the Monte Carlo is replayable in tests.
    struct Random {
        private var state: UInt64
        init(seed: UInt64 = 0x5DEECE66D) { state = seed }
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        /// Box–Muller.
        mutating func normal(mean: Double, sd: Double) -> Double {
            let u1 = max(1e-12, next())
            let u2 = next()
            return mean + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    /// One entry per hypothesis a generator entertained. The distinction
    /// this carries is what makes the FDR control honest: a candidate that
    /// was tested but failed its own decision gates stays in the family —
    /// removed first, `m` counts only survivors, and Benjamini–Hochberg
    /// on the remainder is post-selection, which controls nothing.
    struct Candidate {
        let rec: Recommendation
        /// The test's p-value, when a null was actually tested. Nil for
        /// rule-based candidates (retire), which state a fact — four
        /// weeks, zero completions — rather than reject a chance
        /// explanation; a constant stand-in p was previously injected
        /// here and distorted the thresholds for the real tests.
        let p: Double?
        /// Whether the decision-theoretic gates passed. Only offerable
        /// survivors surface; the rest exist to be counted.
        let offerable: Bool
    }

    public static func recommend(_ context: Context) -> [Recommendation] {
        let o = context.observations
        let latency = LatencyModel.fit(samples: LatencyModel.samples(from: context.events))
        let curve = LearningCurve.fit(observations: o)
        let learningCost = curve?.typicalLearningCost() ?? 60

        var candidates: [Candidate] = []
        candidates += bindCandidates(context, latency: latency, learningCost: learningCost)
        candidates += rebindCandidates(context)
        candidates += shortenCandidates(context, latency: latency, learningCost: learningCost)
        candidates += flattenCandidates(context, latency: latency, learningCost: learningCost)
        candidates += retireCandidates(context)
        candidates += nudgeCandidates(context, latency: latency)
        candidates += breathCandidates(context)
        candidates += routeCandidates(context)
        candidates += meetingsCandidates(context)

        // One gate across everything *tested* at once: the report's
        // credibility is a budget, spent by every claim it makes, and the
        // family is every hypothesis a generator ran — offerable or not.
        // Rule-based candidates carry no p and stand outside it.
        let tested = candidates.indices.filter { candidates[$0].p != nil }
        let surviving = Maths.benjaminiHochberg(
            tested.map { candidates[$0].p! }, q: 0.1)
        let cleared = Set(surviving.map { tested[$0] })
        return candidates.indices
            .filter { candidates[$0].offerable
                && (candidates[$0].p == nil || cleared.contains($0)) }
            .map { candidates[$0].rec }
            .sorted { $0.secondsPerWeek * $0.probability > $1.secondsPerWeek * $1.probability }
    }

    // MARK: - Shared

    /// Letters the grammar itself owns — the coach must never offer what
    /// the grammar reserves, found the hard way when Zoom's mnemonic Z
    /// nearly cleared the gates. Read from `Gestures`, never copied: this
    /// constant drifted out of date behind two separate key moves.
    static let reservedLetters: Set<String> = Gestures.reservedLetters

    static func freeLetters(_ context: Context) -> Set<String> {
        let taken = Set(context.leaves.compactMap { $0.chain.first })
        let alphabet = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        return Set(alphabet).subtracting(taken).subtracting(reservedLetters)
    }

    /// Whether a proposed chain can be bound without colliding: no leaf
    /// equals it, sits under it, or stands over it — except the one a
    /// supersede is about to remove.
    static func chainFree(_ proposed: [String], leaves: [Leaf],
                          ignoring: [String]? = nil) -> Bool {
        guard let first = proposed.first, !reservedLetters.contains(first) else {
            return false
        }
        let key = Observations.key(proposed)
        for leaf in leaves {
            if let ignoring, leaf.chain == ignoring { continue }
            let bound = Observations.key(leaf.chain)
            if bound == key || bound.hasPrefix(key + " ") || key.hasPrefix(bound + " ") {
                return false
            }
        }
        return true
    }

    /// Every name under which an app is already addressable. The labels
    /// alone missed half the truth: a browser-profile leaf is labeled
    /// "Brave (Xonar)" while the launcher records a reach for the app
    /// index's "Brave Browser", so an app fully covered by profile
    /// bindings looked unaddressed and could be offered a letter it
    /// already had several of.
    static func addressedNames(_ leaves: [Leaf]) -> Set<String> {
        var names = Set(leaves.map { $0.label.lowercased() })
        for leaf in leaves {
            if let profile = BrowserProfile.parse(reference: leaf.value) {
                names.insert(profile.browser.appName.lowercased())
            }
        }
        return names
    }

    /// The letters a name could plausibly live under: word initials first,
    /// then what the user actually types into the launcher to find it.
    static func mnemonicLetters(app: String, record: Observations.AppRecord?) -> [String] {
        var letters: [String] = []
        // Split on anything that is not a letter or digit, and take each
        // word's first *letter* rather than its first character. Splitting
        // on spaces alone dropped every parenthesised word — and Lodestar
        // writes those itself (`Graph.Target.label` renders a browser
        // profile as "Brave (Xonar)"), so the distinguishing half of every
        // profile name was invisible here. The same slip hid "1Password"
        // behind its digit.
        for word in app.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let first = word.first(where: { $0.isLetter }) { letters.append(String(first)) }
        }
        if let prefixes = record?.prefixes {
            for (prefix, _) in prefixes.sorted(by: { $0.value > $1.value }) {
                if let first = prefix.first(where: { $0.isLetter }) {
                    letters.append(String(first))
                }
            }
        }
        var seen = Set<String>()
        return letters.filter { seen.insert($0).inserted }
    }

    /// The free alphabet in reach order — home row first, top row next,
    /// the bottom row last — for promotions whose mnemonics are all
    /// taken. An arbitrary bare key compiles fine (a fresh one has been
    /// measured outrunning a chain with thousands of uses behind it), but
    /// a stretch is a stretch on every press forever, so reach breaks the
    /// tie.
    static let reachOrderedLetters: [String] =
        "asdfghjklqwertyuiopzxcvbnm".map(String.init)

    /// The letter a promotion lands on: the target's own mnemonics first,
    /// then anything free by reach. Nil only when the alphabet is truly
    /// spent.
    static func promotionSlot(app: String, record: Observations.AppRecord?,
                              free: Set<String>) -> String? {
        (mnemonicLetters(app: app, record: record) + reachOrderedLetters)
            .first(where: { free.contains($0) })
    }

    /// P(net benefit > 0) by parametric bootstrap over the uncertain
    /// pieces, and the expected weekly saving.
    static func netBenefit(perUseSavedMean: Double, perUseSavedSD: Double,
                           usesPerWeek: Double, usesPerWeekSE: Double,
                           oneOffCost: Double, seed: UInt64)
        -> (secondsPerWeek: Double, probability: Double) {
        var rng = Random(seed: seed)
        let horizon = (0..<horizonWeeks).reduce(0.0) {
            $0 + pow(0.5, Double($1) / horizonHalfLife)
        }
        var wins = 0
        let draws = 400
        for _ in 0..<draws {
            let saved = rng.normal(mean: perUseSavedMean, sd: perUseSavedSD)
            let uses = max(0, rng.normal(mean: usesPerWeek, sd: usesPerWeekSE))
            if saved * uses * horizon - oneOffCost > 0 { wins += 1 }
        }
        let weekly = perUseSavedMean * usesPerWeek - oneOffCost / horizon
        return (weekly, Double(wins) / Double(draws))
    }

    // MARK: - Candidates

    /// Meetings joined by hand: web opens on meeting hosts, plus focus
    /// arrivals on native meeting apps. One join can produce both — a
    /// clicked Zoom link routes through us and lands on the Zoom app — so
    /// all stamps sessionize together: within thirty minutes is one
    /// meeting, however many signals it threw.
    ///
    /// The per-join saving is a conservative prior, not a measurement:
    /// digging the link out of a calendar event and riding its redirect
    /// page is work the ledger cannot time directly. The one-off cost is
    /// the permission flow. Both are stated in the evidence, because a
    /// priced claim the user cannot audit is not this product's voice.
    static func meetingsCandidates(_ context: Context) -> [Candidate] {
        guard !context.meetingsEnabled else { return [] }
        var stamps: [Date] = []
        for event in context.events {
            switch event.kind {
            case .web:
                if let host = event.host, Meetings.isMeetingHost(host) {
                    stamps.append(event.t)
                }
            case .focus:
                if let app = event.app, Meetings.meetingApps.contains(app) {
                    stamps.append(event.t)
                }
            default:
                continue
            }
        }
        // Sorted first, then sessionized once, globally: a re-focus
        // mid-call, the web-plus-app echo of one clicked link, and two
        // providers in one call all collapse the same way, and the answer
        // cannot depend on the order events arrived in. The gap is judged
        // against the previous signal, not the session's start — a long
        // call keeps refreshing its own session, so an hour of re-focuses
        // stays one join rather than becoming one every thirty minutes.
        var joins: [Date] = []
        var previous: Date?
        for stamp in stamps.sorted() {
            defer { previous = stamp }
            if let previous, stamp.timeIntervalSince(previous) < 1800 { continue }
            joins.append(stamp)
        }
        var byWeek: [Int: Int] = [:]
        for join in joins { byWeek[Observations.week(join), default: 0] += 1 }
        guard let first = byWeek.keys.min() else { return [] }
        let current = Observations.week(context.now)
        guard current >= first else { return [] }
        let counts = (first...current).map { byWeek[$0] ?? 0 }
        guard let demand = Demand.fit(weeklyCounts: counts),
              demand.perWeek >= 1, demand.weeks >= 2 else { return [] }
        let value = netBenefit(perUseSavedMean: 20, perUseSavedSD: 8,
                               usesPerWeek: demand.perWeek, usesPerWeekSE: demand.se,
                               oneOffCost: 120, seed: seed("meetings"))
        let weekly = Int(demand.perWeek.rounded())
        return [Candidate(rec: Recommendation(
            kind: .meetings, target: "meetings",
            detail: "about \(weekly) meeting\(weekly == 1 ? "" : "s") a week joined by hand",
            secondsPerWeek: value.secondsPerWeek,
            probability: value.probability,
            evidence: [
                "\(joins.count) manual joins across \(demand.weeks) week\(demand.weeks == 1 ? "" : "s")",
                "per-join saving is a prior (20s), not a measurement",
                "one-off cost priced as the permission flow (120s)",
            ],
            display: "meetings at the door",
            edit: .enableMeetings), p: 1 - value.probability,
            offerable: value.probability >= probabilityGate)]
    }

    static func bindCandidates(_ context: Context, latency: LatencyModel?,
                               learningCost: Double) -> [Candidate] {
        let o = context.observations
        let addressed = addressedNames(context.leaves)
        let free = freeLetters(context)
        // One walk of the ring for every app together — per-app rescans
        // made this pass O(apps × events).
        let searcherWeeks = Demand.weeklySearcherCountsByApp(events: context.events)
        var out: [Candidate] = []
        for (app, record) in o.apps where !addressed.contains(app) {
            guard record.searcher >= 8, o.activeWeeks(app: app) >= 2,
                  let launcherMean = record.commit.mean else { continue }
            let counts = Demand.series(byWeek: searcherWeeks[app] ?? [:], now: context.now)
            guard let demand = Demand.fit(weeklyCounts: counts), demand.perWeek > 0 else {
                continue
            }
            guard let slot = mnemonicLetters(app: app, record: record).first(where: {
                free.contains($0)
            }) else { continue }
            let launcherSeconds = exp(launcherMean)
            let chainSeconds = latency?.chainSeconds([slot]) ?? 0.6
            let saved = launcherSeconds - chainSeconds
            guard saved > 0 else { continue }
            let launcherSD = launcherSeconds * (record.commit.se ?? 0.5)
            let value = netBenefit(perUseSavedMean: saved,
                                   perUseSavedSD: max(0.1, launcherSD),
                                   usesPerWeek: demand.perWeek, usesPerWeekSE: demand.se,
                                   oneOffCost: learningCost,
                                   seed: seed(app))
            out.append(Candidate(rec: Recommendation(
                kind: .bind, target: app,
                detail: "\(app) is searched \(String(format: "%.1f", demand.perWeek))×/week"
                    + " with no address · lode \(slot.uppercased()) would pay for itself",
                secondsPerWeek: value.secondsPerWeek, probability: value.probability,
                evidence: [
                    "\(record.searcher) launcher reaches across \(o.observedWeeks(app: app, now: context.now)) weeks",
                    String(format: "launcher costs %.2fs; lode %@ predicted %.2fs",
                           launcherSeconds, slot.uppercased(), chainSeconds),
                    String(format: "learning bill ≈ %.0fs, from your own curves", learningCost),
                ], edit: .bindTarget(chain: [slot], target: app)), p: 1 - value.probability,
                offerable: value.probability >= probabilityGate))
        }
        return out
    }

    /// Wrong keys attach to the *prefix* where the hand stumbled — often
    /// an internal node, never a leaf. The first cut iterated leaves and
    /// was structurally blind to its own best evidence (a real user's
    /// strongest confusion lived entirely at two prefixes); this walks
    /// every record that accumulated wrong keys, wherever it sits in the
    /// trie.
    ///
    /// The wrong key names the address the hand believes in, but not the
    /// destination it wanted — so alone it can only report. The events
    /// carry the missing half: what the hand did in the seconds after
    /// each stumble. When one destination dominates those recoveries, the
    /// finding becomes an edit — the errors are proposals, and the
    /// proposal is to bind the destination at the address already being
    /// pressed, closing the old one the way every supersede does.
    static func rebindCandidates(_ context: Context) -> [Candidate] {
        let o = context.observations
        let recoveries = rebindRecoveries(context.events)
        var out: [Candidate] = []
        for (key, record) in o.addresses {
            guard record.wrongKeys >= 5,
                  let (letter, count) = record.confusion.max(by: { $0.value < $1.value })
            else { continue }
            let share = Double(count) / Double(record.wrongKeys)
            let lower = Maths.wilsonLower(successes: count, trials: record.wrongKeys)
            // The null: wrong letters scatter across a few plausible keys.
            // One letter absorbing them all is what needs explaining. The
            // test runs whenever the trials exist; share and the Wilson
            // floor decide offerability, never membership in the family.
            let p = Maths.binomialTail(atLeast: count, n: record.wrongKeys, p: 0.25)
            let shown = key.isEmpty
                ? "lode"
                : "lode " + key.split(separator: " ")
                    .map { $0.uppercased() }.joined(separator: " ")
            let weeks = o.observedWeeks(addressKey: key, now: context.now)
            let weekly = Double(record.wrongKeys) / Double(weeks) * 1.5
            var detail = "at \(shown) your hand keeps pressing \(letter.uppercased()) · "
                + "the name in your head disagrees with the graph"
            var evidence = ["\(count) of \(record.wrongKeys) wrong keys were "
                + letter.uppercased()]
            var edit: ConfigEdit?
            var display: String?
            let prefix = key.isEmpty ? [] : key.split(separator: " ").map(String.init)
            let proposed = prefix + [letter]
            if let resolved = dominantRecovery(recoveries["\(key)|\(letter)"],
                                               context: context, proposed: proposed) {
                edit = resolved.edit
                display = resolved.label
                let shownNew = proposed.map { $0.uppercased() }.joined(separator: " ")
                detail = "your hand keeps pressing lode \(shownNew) for \(resolved.label) · "
                    + "the graph could agree with it"
                evidence.append(resolved.evidence)
            }
            out.append(Candidate(rec: Recommendation(
                kind: .rebind, target: key.isEmpty ? "lode" : key,
                detail: detail,
                secondsPerWeek: weekly, probability: lower,
                evidence: evidence, display: display, edit: edit), p: p,
                offerable: share >= 0.6 && lower > 0.4))
        }
        return out
    }

    /// One walk of the ring: for each (prefix, wrong key), what the hand
    /// reached within ten seconds — a completed chain, or a launcher pick.
    /// Keys are "prefixKey|letter"; values are "chain:<key>" or
    /// "app:<name>" tallies.
    static func rebindRecoveries(_ events: [ObservationEvent]) -> [String: [String: Int]] {
        var out: [String: [String: Int]] = [:]
        let ordered = events.sorted { $0.t < $1.t }
        for (index, event) in ordered.enumerated() where event.kind == .wrongKey {
            guard let pressed = event.pressed else { continue }
            let prefix = event.chain.map(Observations.key) ?? ""
            for follower in ordered.dropFirst(index + 1) {
                guard follower.t.timeIntervalSince(event.t) <= 10 else { break }
                if follower.kind == .chain, let chain = follower.chain {
                    let winner = "chain:\(Observations.key(chain))"
                    out["\(prefix)|\(pressed)", default: [:]][winner, default: 0] += 1
                    break
                }
                if follower.kind == .reach, follower.route == "searcher",
                   let app = follower.app {
                    out["\(prefix)|\(pressed)", default: [:]]["app:\(app)", default: 0] += 1
                    break
                }
            }
        }
        return out
    }

    /// The destination the recoveries agree on, as an edit — or nil when
    /// they scatter, the proposed address is not free, or the destination
    /// cannot be named as a config value.
    private static func dominantRecovery(_ tally: [String: Int]?, context: Context,
                                         proposed: [String])
        -> (edit: ConfigEdit, label: String, evidence: String)? {
        guard let tally, !tally.isEmpty else { return nil }
        let total = tally.values.reduce(0, +)
        guard total >= 3,
              let (winner, count) = tally.max(by: { $0.value < $1.value }),
              Double(count) / Double(total) >= 0.6 else { return nil }
        if winner.hasPrefix("chain:") {
            let key = String(winner.dropFirst(6))
            guard let leaf = context.leaves.first(where: {
                Observations.key($0.chain) == key
            }), leaf.chain != proposed,
                chainFree(proposed, leaves: context.leaves, ignoring: leaf.chain)
            else { return nil }
            return (.supersede(old: leaf.chain, new: proposed, target: leaf.value),
                    leaf.label,
                    "\(count) of \(total) stumbles ended at \(leaf.label)")
        }
        let app = String(winner.dropFirst(4))
        // A launcher recovery: the app may already be bound elsewhere — a
        // supersede — or not bound at all, which is a bind at the address
        // the hand already presses.
        if let leaf = context.leaves
            .filter({ $0.label.lowercased() == app })
            .min(by: { $0.chain.count < $1.chain.count }) {
            guard leaf.chain != proposed,
                  chainFree(proposed, leaves: context.leaves, ignoring: leaf.chain)
            else { return nil }
            return (.supersede(old: leaf.chain, new: proposed, target: leaf.value),
                    leaf.label,
                    "\(count) of \(total) stumbles ended at \(leaf.label)")
        }
        guard chainFree(proposed, leaves: context.leaves) else { return nil }
        return (.bindTarget(chain: proposed, target: app), app,
                "\(count) of \(total) stumbles ended at \(app) via the launcher")
    }

    static func shortenCandidates(_ context: Context, latency: LatencyModel?,
                                  learningCost: Double) -> [Candidate] {
        let o = context.observations
        let free = freeLetters(context)
        var out: [Candidate] = []
        for leaf in context.leaves where leaf.chain.count >= 2 {
            let key = Observations.key(leaf.chain)
            guard let record = o.addresses[key], record.completions >= 20,
                  let latency else { continue }
            let weeks = Double(o.observedWeeks(address: leaf.chain, now: context.now))
            let weekly = Double(record.completions) / weeks
            // A demand floor, not the economics: the priced gates below
            // (the offer floor, the probability gate) already reject a
            // chain too cold to repay its relearning. The old floor of
            // ten a week mostly restated the seconds floor and silenced
            // every mid-frequency chain the pricing would have passed.
            guard weekly >= 3 else { continue }
            guard let slot = promotionSlot(app: leaf.label,
                                           record: o.apps[leaf.label.lowercased()],
                                           free: free) else { continue }
            let current = latency.chainSeconds(leaf.chain, address: key)
            let proposed = latency.chainSeconds([slot])
            let saved = current - proposed
            guard saved > 0.05 else { continue }
            // The saving is a difference of two *means*, so what matters is
            // how well each mean is known — not how much a single keystroke
            // varies. Pricing it as `residualSD * saved` made
            // P(saves time) = Φ(1 / residualSD) for every candidate alike:
            // a constant, unmoved by the size of the saving or by the
            // evidence behind it, and at this user's spread it sat at 0.85
            // against a 0.9 gate, so no shorten could ever be offered.
            // The chain being replaced has been completed this many times,
            // so its mean tightens as √n; the proposed chain has never been
            // typed at all, so it keeps the full population spread.
            //
            // Count *completions*, not `latency.fluency[key]?.n`: that is one
            // sample per keystroke gap, so a two-letter chain would claim √2
            // more evidence than it has — and the gaps inside one completion
            // are correlated anyway, so they are not independent draws.
            let currentSD = current * latency.residualSD
                / Double(max(1, record.completions)).squareRoot()
            let proposedSD = proposed * latency.residualSD
            let savedSD = (currentSD * currentSD + proposedSD * proposedSD).squareRoot()
            // The rate is a mean over `weeks` weeks of Poisson counts, so
            // its SE shrinks as √weeks — the same discipline Demand.fit
            // gives the bind path. √weekly alone is the spread of a single
            // week, not of the estimate.
            let value = netBenefit(perUseSavedMean: saved, perUseSavedSD: savedSD,
                                   usesPerWeek: weekly,
                                   usesPerWeekSE: (weekly / weeks).squareRoot(),
                                   oneOffCost: learningCost,
                                   seed: seed(key))
            let shown = "lode " + leaf.chain.map { $0.uppercased() }.joined(separator: " ")
            out.append(Candidate(rec: Recommendation(
                kind: .shorten, target: key,
                detail: "\(shown) fires \(Int(weekly))×/week · it has earned "
                    + "lode \(slot.uppercased())",
                secondsPerWeek: value.secondsPerWeek, probability: value.probability,
                evidence: [String(format: "%.2fs now vs %.2fs shortened, %d completions",
                                  current, proposed, record.completions)],
                display: leaf.label,
                edit: .supersede(old: leaf.chain, new: [slot], target: leaf.value)),
                p: 1 - value.probability,
                offerable: value.probability >= probabilityGate))
        }
        return out
    }

    /// The failure gradient read as a proposal. Bare keys misfire at
    /// essentially zero while prefixed chains measurably do not (0% bare
    /// against 8–41% under prefixes, in the audit that motivated this),
    /// and every misfire is a recovery the address taxes forever. Where a
    /// leaf's starts keep failing — its own wrong keys and abandons, plus
    /// its completion-weighted share of the stumbles on the prefixes
    /// above it — the depth itself is the defect, and the offer is the
    /// same supersede a shorten performs: the leaf moves to a free
    /// letter, the old chain redirects until the new curve bends.
    ///
    /// Distinct from a rebind, which needs the wrong keys to agree on one
    /// letter — a hand with a different address in its head. This fires
    /// on diffuse failure, where no single belief is wrong but the
    /// address keeps costing. A leaf may clear both this and the shorten
    /// gate; that is one finding wearing two kinds of evidence, and the
    /// coach offers one chip at a time either way.
    static let flattenRecoverySeconds = 1.5

    static func flattenCandidates(_ context: Context, latency: LatencyModel?,
                                  learningCost: Double) -> [Candidate] {
        let o = context.observations
        guard let latency else { return [] }
        let free = freeLetters(context)
        var out: [Candidate] = []
        for leaf in context.leaves where leaf.chain.count >= 2 {
            let key = Observations.key(leaf.chain)
            guard let record = o.addresses[key], record.completions >= 10 else { continue }
            var failures = Double(record.wrongKeys + record.abandons)
            // A prefix's stumbles belong to every leaf beneath it; this
            // leaf's share is its share of the subtree's completions.
            for depth in 1..<leaf.chain.count {
                let prefixKey = Observations.key(Array(leaf.chain.prefix(depth)))
                guard let prefix = o.addresses[prefixKey],
                      prefix.wrongKeys + prefix.abandons > 0 else { continue }
                var subtree = 0
                for (address, entry) in o.addresses
                    where address == prefixKey || address.hasPrefix(prefixKey + " ") {
                    subtree += entry.completions
                }
                guard subtree > 0 else { continue }
                failures += Double(prefix.wrongKeys + prefix.abandons)
                    * Double(record.completions) / Double(subtree)
            }
            let failed = Int(failures.rounded())
            let attempts = record.completions + failed
            guard failed > 0, attempts >= 20 else { continue }
            let rate = Double(failed) / Double(attempts)
            // The null: this chain misfires at the bare-key baseline,
            // which is near zero. A persistent excess is what needs
            // explaining. Tested whenever the attempts exist; the rate
            // and Wilson floors gate the offer, never the family.
            let p = Maths.binomialTail(atLeast: failed, n: attempts, p: 0.02)
            let lower = Maths.wilsonLower(successes: failed, trials: attempts)
            let weeks = Double(o.observedWeeks(addressKey: key, now: context.now))
            let weekly = Double(attempts) / weeks
            let slot = promotionSlot(app: leaf.label,
                                     record: o.apps[leaf.label.lowercased()],
                                     free: free)
            let current = latency.chainSeconds(leaf.chain, address: key)
            let proposed = latency.chainSeconds([slot ?? "j"])
            // Every attempt pays the chain; the failed share also pays
            // its recovery. Both end at a bare letter.
            let saved = max(0, current - proposed) + rate * Self.flattenRecoverySeconds
            let currentSD = current * latency.residualSD
                / Double(max(1, record.completions)).squareRoot()
            let proposedSD = proposed * latency.residualSD
            let savedSD = (currentSD * currentSD + proposedSD * proposedSD).squareRoot()
            let value = netBenefit(perUseSavedMean: saved, perUseSavedSD: savedSD,
                                   usesPerWeek: weekly,
                                   usesPerWeekSE: (weekly / weeks).squareRoot(),
                                   oneOffCost: learningCost,
                                   seed: seed("flatten " + key))
            let shown = "lode " + leaf.chain.map { $0.uppercased() }.joined(separator: " ")
            let detail: String
            if let slot {
                detail = "\(shown) misfires \(Int((rate * 100).rounded()))% of its starts · "
                    + "lode \(slot.uppercased()) would end the stumbles"
            } else {
                detail = "\(shown) misfires \(Int((rate * 100).rounded()))% of its starts · "
                    + "no letter is free to move it to"
            }
            out.append(Candidate(rec: Recommendation(
                kind: .flatten, target: key,
                detail: detail,
                secondsPerWeek: value.secondsPerWeek, probability: value.probability,
                evidence: [
                    "\(failed) failed starts across \(attempts), with the prefix's share counted",
                    String(format: "%.2fs now vs %.2fs at a bare key", current, proposed),
                ],
                display: leaf.label,
                edit: slot.map { .supersede(old: leaf.chain, new: [$0], target: leaf.value) }),
                p: p,
                offerable: rate >= 0.08 && lower > 0.04
                    && value.probability >= probabilityGate))
        }
        return out
    }

    static func retireCandidates(_ context: Context) -> [Candidate] {
        let o = context.observations
        guard o.since != .distantPast,
              context.now.timeIntervalSince(o.since) >= 28 * 86_400 else { return [] }
        // The clock that matters is the binding's, not the store's: a
        // chain bound yesterday has had no chance to be typed, and "never
        // used" must never describe something new — least of all a bind
        // the coach itself just talked someone into. Recent additions
        // carry their epoch event in the ring; anything older than the
        // ring is older than the gate by definition.
        var addedAt: [String: Date] = [:]
        for event in context.events where event.kind == .epoch {
            guard let address = event.address,
                  event.change == "added" || event.change == "retargeted" else { continue }
            addedAt[address] = event.t
        }
        return o.unused(among: context.leaves.map(\.chain)).compactMap { chain in
            guard !chain.isEmpty else { return nil }
            let key = Observations.key(chain)
            if let added = addedAt[key],
               context.now.timeIntervalSince(added) < 28 * 86_400 { return nil }
            let shown = "lode " + chain.map { $0.uppercased() }.joined(separator: " ")
            // No p: a retirement rejects no null. "Four weeks, zero
            // completions" is a fact the rules above establish, and the
            // constant stand-in p it used to carry sat inside the BH
            // family distorting the thresholds for the real tests.
            return Candidate(rec: Recommendation(
                kind: .retire, target: key,
                detail: "\(shown) has never been typed · a letter spent on nothing",
                secondsPerWeek: 0, probability: 0.95,
                evidence: ["four weeks of observation, zero completions"],
                edit: .removeChain(chain: chain)), p: nil, offerable: true)
        }
    }

    static func nudgeCandidates(_ context: Context, latency: LatencyModel?)
        -> [Candidate] {
        let o = context.observations
        var out: [Candidate] = []
        // Rescues: an abandon followed within ten seconds by a launcher
        // reach for an app under the abandoned prefix is the address
        // failing in the wild — measured, not inferred. Counted per
        // reached app, and joined below against the leaf's own app: a
        // coincidental launch of something unrelated right after an
        // abandon is not this address failing.
        var rescues: [String: [String: Int]] = [:]
        let ordered = context.events.sorted { $0.t < $1.t }
        for (index, event) in ordered.enumerated() where event.kind == .abandon {
            guard let prefix = event.chain else { continue }
            for follower in ordered.dropFirst(index + 1) {
                guard follower.t.timeIntervalSince(event.t) <= 10 else { break }
                if follower.kind == .reach, follower.route == "searcher",
                   let reached = follower.app {
                    rescues[Observations.key(prefix), default: [:]][reached, default: 0] += 1
                    break
                }
            }
        }
        for leaf in context.leaves {
            let app = leaf.label.lowercased()
            guard let record = o.apps[app], record.reaches >= 10,
                  let share = o.routeShare(app),
                  let launcherSeconds = o.launcherSeconds(app) else { continue }
            let key = Observations.key(leaf.chain)
            let chainSeconds = latency?.chainSeconds(leaf.chain, address: key) ?? 0.8
            let saved = launcherSeconds - chainSeconds
            guard saved > 0 else { continue }
            let weekly = Double(record.searcher)
                / Double(o.observedWeeks(app: app, now: context.now))
            let lower = Maths.wilsonLower(successes: record.searcher, trials: record.reaches)
            // The null: with an address in hand, searches should be the
            // exception, not the majority. Tested whenever the reaches
            // exist; the share and Wilson floors gate the offer, never
            // the family.
            let p = Maths.binomialTail(atLeast: record.searcher, n: record.reaches, p: 0.5)
            let shown = "lode " + leaf.chain.map { $0.uppercased() }.joined(separator: " ")
            var evidence = [String(format: "%d%% of %d reaches went through the launcher",
                                   Int(share * 100), record.reaches)]
            // Abandons are recorded under the full prefix where the hand
            // stopped ("w", "w g", …), so this leaf's evidence is the sum
            // over every prefix of its own chain. Reading just the first
            // letter never matched a multi-letter abandon at all — the
            // strongest rescue evidence was invisible.
            let rescued = (1...leaf.chain.count)
                .map { Observations.key(Array(leaf.chain.prefix($0))) }
                .compactMap { rescues[$0]?[app] }
                .reduce(0, +)
            if rescued > 0 {
                evidence.append("\(rescued) abandoned chains were rescued by the launcher")
            }
            // The accept closes the launcher road: the address exists and
            // the hand keeps taking the long way, so the long way gets a
            // toll until the short one is learned.
            out.append(Candidate(rec: Recommendation(
                kind: .nudge, target: app,
                detail: "\(app) has \(shown) and you search for it anyway · "
                    + String(format: "each search pays %.1fs over the chain", saved),
                secondsPerWeek: saved * weekly, probability: lower,
                evidence: evidence, display: leaf.label,
                edit: .closeRoad(app: app, chain: leaf.chain)), p: p,
                offerable: share > 0.6 && lower > 0.5))
        }
        return out
    }

    /// A lift-3 gate reads well until a real user arrives with 78% of
    /// their attention in three apps — there, expected co-occurrence is
    /// already so high that lift is bounded below 2 and the user's most
    /// obvious pattern can never fire. The z-score against independence
    /// carries the evidence at any concentration; lift keeps only a
    /// sanity floor.
    static func breathCandidates(_ context: Context) -> [Candidate] {
        let pairs = Transitions.strongPairs(context.observations.transitions)
        // The switches that pulled a window into view, both directions:
        // what a breath actually saves. A pair already side by side is
        // switched by focus alone, and the old count priced those too —
        // the top finding on the machine this was built on promised
        // eighteen minutes a week for a breath that already existed.
        let pulls = context.observations.transitionPulls
        var out: [Candidate] = []
        // Directional pairs, undirected suggestion: A→B and B→A are one
        // finding, kept at the stronger direction's evidence.
        var seen = Set<Set<String>>()
        // Three offers at most, but every tested pair joins the family —
        // a cap that stopped the *testing* silently shrank m.
        var offered = 0
        for pair in pairs where pair.count >= 20 {
            guard seen.insert(Set([pair.from, pair.to])).inserted else { continue }
            // The null: the pair co-occurs at the rate independence
            // predicts. Normal approximation to the Poisson tail above it.
            let expected = pair.count / pair.lift
            let z = (pair.count - expected) / max(1, expected).squareRoot()
            let p = 1 - Maths.normalCDF(z)
            let probability = min(0.95, Maths.normalCDF(z))
            let pulled = pulls.map { ($0[pair.from]?[pair.to] ?? 0) + ($0[pair.to]?[pair.from] ?? 0) }
            // The lift floor is a sanity gate, not the test (see the
            // z-score note above); the cap is presentation. Nothing pulled
            // means nothing to save: not offerable, still in the family.
            let offerable = pair.lift >= 1.3 && offered < 3 && (pulled ?? 1) > 0
            if offerable { offered += 1 }
            // The accept: compose the pair side by side and save it at a
            // free breath letter. No free letter, no edit — the finding
            // still reports.
            let edit = breathLetter(for: pair, context: context).map {
                ConfigEdit.composeBreath(apps: [pair.from, pair.to], path: $0)
            }
            out.append(Candidate(rec: Recommendation(
                kind: .breath, target: "\(pair.from) + \(pair.to)",
                detail: "\(pair.from) and \(pair.to) travel together "
                    + String(format: "%.0f× at lift %.1f", pair.count, pair.lift)
                    + (pulled.map { String(format: " · %.0f pulled into view", $0) } ?? "")
                    + " · a breath would pin them side by side",
                // A weekly-halved mass is ~a two-week window, so the rate
                // is half of it — at two seconds a transition, the count:
                // the pulled count where the table exists, since a switch
                // between two visible windows costs a breath nothing.
                secondsPerWeek: pulled ?? pair.count,
                probability: probability,
                evidence: [String(format: "lift %.1f over independent use", pair.lift)],
                display: "\(pair.from) + \(pair.to)",
                edit: edit),
                p: p, offerable: offerable))
        }
        return out
    }

    /// A mnemonic letter for the pair's breath: the apps' own initials
    /// first, then anything free. A path is free when no saved breath
    /// equals it or nests around it — and never "b", which the breath
    /// grammar reserves.
    static func breathLetter(for pair: Transitions.Pair, context: Context) -> String? {
        let taken = context.breathPaths
        func free(_ letter: String) -> Bool {
            letter != "b" && !taken.contains { $0 == letter || $0.hasPrefix(letter) }
        }
        var candidates: [String] = []
        for app in [pair.from, pair.to] {
            candidates.append(contentsOf: mnemonicLetters(app: app, record: nil))
        }
        candidates.append(contentsOf: "abcdefghijklmnopqrstuvwxyz".map(String.init))
        return candidates.first(where: free)
    }

    static func routeCandidates(_ context: Context) -> [Candidate] {
        let o = context.observations
        var out: [Candidate] = []
        for (host, record) in o.hosts {
            // Concentration is judged over deliberate profile choices
            // only; a host that is all pass-through has no preference to
            // make a rule of.
            let chosen = record.chosenProfiles
            let total = chosen.values.reduce(0, +)
            guard total >= 8,
                  let (profile, hits) = chosen.max(by: { $0.value < $1.value })
            else { continue }
            // Already covered by a rule? No hypothesis is entertained:
            // the decision is made and quiet.
            guard WebRouting.routePattern("https://\(host)", routes: context.webRoutes) == nil
            else { continue }
            let lower = Maths.wilsonLower(successes: hits, trials: total)
            // The null: no preferred profile for this host. Tested for
            // every host with enough deliberate choices; the 90% share
            // and the Wilson floor gate the offer, never the family.
            let p = Maths.binomialTail(atLeast: hits, n: total, p: 0.5)
            // The chip can only offer what a config line can say, and a
            // route line needs the registry key behind the observed profile.
            let edit = context.profileKeys[profile].map {
                ConfigEdit.addRoute(pattern: host, profileKey: $0)
            }
            out.append(Candidate(rec: Recommendation(
                kind: .route, target: host,
                detail: "\(host) has landed in \(profile) \(hits) of \(total) times · "
                    + "one route line would make it a fact instead of a habit",
                secondsPerWeek: Double(total)
                    / Double(o.observedWeeks(host: host, now: context.now)) * 1.5,
                probability: lower,
                evidence: ["\(hits)/\(total) chosen opens in \(profile)"], edit: edit),
                p: p,
                offerable: Double(hits) / Double(total) >= 0.9 && lower > 0.6))
        }
        return out
    }
}
