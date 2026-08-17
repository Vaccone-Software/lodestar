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
    /// Bind an app at a chain (bind and shorten both land here).
    case bindApp(chain: [String], app: String)
    /// Remove a binding (retire).
    case removeChain(chain: [String])
    /// One route line: pattern → profile registry key.
    case addRoute(pattern: String, profileKey: String)
}

public struct Recommendation: Codable, Equatable {
    public enum Kind: String, Codable {
        /// An app searched for often that has no address.
        case bind
        /// The hand keeps pressing a different letter than the graph holds.
        case rebind
        /// A deep chain frequent enough to earn a shorter one.
        case shorten
        /// Bound, and never once typed.
        case retire
        /// The address exists; the launcher keeps winning anyway.
        case nudge
        /// Apps that travel together and could be one gesture.
        case breath
        /// A host that always lands in the same profile, one rule away.
        case route
    }

    public var kind: Kind
    public var target: String
    /// The one sentence a surface would show.
    public var detail: String
    public var secondsPerWeek: Double
    /// Posterior probability the change saves net time over the horizon.
    public var probability: Double
    public var evidence: [String]
    /// The write this recommendation proposes, when it is one config line.
    /// Nil means report-only: the chip never offers what it cannot commit.
    public var edit: ConfigEdit?

    public init(kind: Kind, target: String, detail: String, secondsPerWeek: Double,
                probability: Double, evidence: [String], edit: ConfigEdit? = nil) {
        self.kind = kind
        self.target = target
        self.detail = detail
        self.secondsPerWeek = secondsPerWeek
        self.probability = probability
        self.evidence = evidence
        self.edit = edit
    }
}

public enum Advisor {
    public struct Context {
        public var observations: Observations
        public var events: [ObservationEvent]
        /// Bound chains and their target labels, from the live graph.
        public var leaves: [(chain: [String], label: String)]
        /// The web route table, so an already-covered host stays quiet.
        public var webRoutes: [String: String]
        /// Observed profile identity ("brave:Work") → registry key ("work"),
        /// so a route recommendation can name the key a config line needs.
        public var profileKeys: [String: String]
        public var now: Date

        public init(observations: Observations, events: [ObservationEvent],
                    leaves: [(chain: [String], label: String)],
                    webRoutes: [String: String] = [:],
                    profileKeys: [String: String] = [:], now: Date = Date()) {
            self.observations = observations
            self.events = events
            self.leaves = leaves
            self.webRoutes = webRoutes
            self.profileKeys = profileKeys
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

    public static func recommend(_ context: Context) -> [Recommendation] {
        let o = context.observations
        let latency = LatencyModel.fit(samples: LatencyModel.samples(from: context.events))
        let curve = LearningCurve.fit(observations: o)
        let learningCost = curve?.typicalLearningCost() ?? 60

        var candidates: [(rec: Recommendation, p: Double)] = []
        candidates += bindCandidates(context, latency: latency, learningCost: learningCost)
        candidates += rebindCandidates(context)
        candidates += shortenCandidates(context, latency: latency, learningCost: learningCost)
        candidates += retireCandidates(context)
        candidates += nudgeCandidates(context, latency: latency)
        candidates += breathCandidates(context)
        candidates += routeCandidates(context)

        // One gate across everything tested at once: the report's
        // credibility is a budget, spent by every claim it makes.
        let surviving = Maths.benjaminiHochberg(candidates.map(\.p), q: 0.1)
        return candidates.enumerated()
            .filter { surviving.contains($0.offset) }
            .map(\.element.rec)
            .sorted { $0.secondsPerWeek * $0.probability > $1.secondsPerWeek * $1.probability }
    }

    // MARK: - Shared

    static func freeLetters(_ context: Context) -> Set<String> {
        let taken = Set(context.leaves.compactMap { $0.chain.first })
        let alphabet = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        return Set(alphabet).subtracting(taken)
    }

    /// The letters a name could plausibly live under: word initials first,
    /// then what the user actually types into the launcher to find it.
    static func mnemonicLetters(app: String, record: Observations.AppRecord?) -> [String] {
        var letters: [String] = []
        for word in app.lowercased().split(separator: " ") {
            if let first = word.first, first.isLetter { letters.append(String(first)) }
        }
        if let prefixes = record?.prefixes {
            for (prefix, _) in prefixes.sorted(by: { $0.value > $1.value }) {
                if let first = prefix.first, first.isLetter { letters.append(String(first)) }
            }
        }
        var seen = Set<String>()
        return letters.filter { seen.insert($0).inserted }
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

    static func bindCandidates(_ context: Context, latency: LatencyModel?,
                               learningCost: Double) -> [(Recommendation, Double)] {
        let o = context.observations
        let addressed = Set(context.leaves.map { $0.label.lowercased() })
        let free = freeLetters(context)
        var out: [(Recommendation, Double)] = []
        for (app, record) in o.apps where !addressed.contains(app) {
            guard record.searcher >= 8, o.activeWeeks(app: app) >= 2,
                  let launcherMean = record.commit.mean else { continue }
            let counts = Demand.weeklySearcherCounts(app: app, events: context.events,
                                                    now: context.now)
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
                                   seed: UInt64(abs(app.hashValue)))
            guard value.probability >= probabilityGate else { continue }
            out.append((Recommendation(
                kind: .bind, target: app,
                detail: "\(app) is searched \(String(format: "%.1f", demand.perWeek))×/week"
                    + " with no address · lode \(slot.uppercased()) would pay for itself",
                secondsPerWeek: value.secondsPerWeek, probability: value.probability,
                evidence: [
                    "\(record.searcher) launcher reaches across \(o.activeWeeks(app: app)) weeks",
                    String(format: "launcher costs %.2fs; lode %@ predicted %.2fs",
                           launcherSeconds, slot.uppercased(), chainSeconds),
                    String(format: "learning bill ≈ %.0fs, from your own curves", learningCost),
                ], edit: .bindApp(chain: [slot], app: app)), 1 - value.probability))
        }
        return out
    }

    static func rebindCandidates(_ context: Context) -> [(Recommendation, Double)] {
        let o = context.observations
        var out: [(Recommendation, Double)] = []
        for leaf in context.leaves {
            let key = Observations.key(leaf.chain)
            guard let record = o.addresses[key], record.wrongKeys >= 5,
                  let (letter, count) = record.confusion.max(by: { $0.value < $1.value })
            else { continue }
            let share = Double(count) / Double(record.wrongKeys)
            let lower = Maths.wilsonLower(successes: count, trials: record.wrongKeys)
            guard share >= 0.6, lower > 0.4 else { continue }
            // The null: wrong letters scatter across a few plausible keys.
            // One letter absorbing them all is what needs explaining.
            let p = Maths.binomialTail(atLeast: count, n: record.wrongKeys, p: 0.25)
            let shown = "lode " + leaf.chain.map { $0.uppercased() }.joined(separator: " ")
            let weekly = Double(record.wrongKeys)
                / max(1, Double(o.activeWeeks(address: leaf.chain))) * 1.5
            out.append((Recommendation(
                kind: .rebind, target: key,
                detail: "at \(shown) your hand keeps pressing \(letter.uppercased()) · "
                    + "the name in your head disagrees with the graph",
                secondsPerWeek: weekly, probability: lower,
                evidence: ["\(count) of \(record.wrongKeys) wrong keys were "
                    + letter.uppercased()]), p))
        }
        return out
    }

    static func shortenCandidates(_ context: Context, latency: LatencyModel?,
                                  learningCost: Double) -> [(Recommendation, Double)] {
        let o = context.observations
        let free = freeLetters(context)
        var out: [(Recommendation, Double)] = []
        for leaf in context.leaves where leaf.chain.count >= 2 {
            let key = Observations.key(leaf.chain)
            guard let record = o.addresses[key], record.completions >= 20,
                  let latency else { continue }
            let weekly = Double(record.completions)
                / max(1, Double(o.activeWeeks(address: leaf.chain)))
            guard weekly >= 10 else { continue }
            guard let slot = mnemonicLetters(app: leaf.label,
                                             record: o.apps[leaf.label.lowercased()])
                .first(where: { free.contains($0) }) else { continue }
            let current = latency.chainSeconds(leaf.chain, address: key)
            let proposed = latency.chainSeconds([slot])
            let saved = current - proposed
            guard saved > 0.05 else { continue }
            let value = netBenefit(perUseSavedMean: saved, perUseSavedSD: latency.residualSD * saved,
                                   usesPerWeek: weekly, usesPerWeekSE: weekly.squareRoot(),
                                   oneOffCost: learningCost,
                                   seed: UInt64(abs(key.hashValue)))
            guard value.probability >= probabilityGate else { continue }
            let shown = "lode " + leaf.chain.map { $0.uppercased() }.joined(separator: " ")
            out.append((Recommendation(
                kind: .shorten, target: key,
                detail: "\(shown) fires \(Int(weekly))×/week · it has earned "
                    + "lode \(slot.uppercased())",
                secondsPerWeek: value.secondsPerWeek, probability: value.probability,
                evidence: [String(format: "%.2fs now vs %.2fs shortened, %d completions",
                                  current, proposed, record.completions)],
                edit: .bindApp(chain: [slot], app: leaf.label)),
                1 - value.probability))
        }
        return out
    }

    static func retireCandidates(_ context: Context) -> [(Recommendation, Double)] {
        let o = context.observations
        guard o.since != .distantPast,
              context.now.timeIntervalSince(o.since) >= 28 * 86_400 else { return [] }
        return o.unused(among: context.leaves.map(\.chain)).compactMap { chain in
            guard !chain.isEmpty else { return nil }
            let shown = "lode " + chain.map { $0.uppercased() }.joined(separator: " ")
            return (Recommendation(
                kind: .retire, target: Observations.key(chain),
                detail: "\(shown) has never been typed · a letter spent on nothing",
                secondsPerWeek: 0, probability: 0.95,
                evidence: ["four weeks of observation, zero completions"],
                edit: .removeChain(chain: chain)), 0.05)
        }
    }

    static func nudgeCandidates(_ context: Context, latency: LatencyModel?)
        -> [(Recommendation, Double)] {
        let o = context.observations
        var out: [(Recommendation, Double)] = []
        // Rescues: an abandon followed within ten seconds by a launcher
        // reach for an app under the abandoned prefix is the address
        // failing in the wild — measured, not inferred.
        var rescues: [String: Int] = [:]
        let ordered = context.events.sorted { $0.t < $1.t }
        for (index, event) in ordered.enumerated() where event.kind == .abandon {
            guard let prefix = event.chain else { continue }
            for follower in ordered.dropFirst(index + 1) {
                guard follower.t.timeIntervalSince(event.t) <= 10 else { break }
                if follower.kind == .reach, follower.route == "searcher" {
                    rescues[Observations.key(prefix), default: 0] += 1
                    break
                }
            }
        }
        for leaf in context.leaves {
            let app = leaf.label.lowercased()
            guard let record = o.apps[app], record.reaches >= 10,
                  let share = o.routeShare(app), share > 0.6,
                  let launcherSeconds = o.launcherSeconds(app) else { continue }
            let key = Observations.key(leaf.chain)
            let chainSeconds = latency?.chainSeconds(leaf.chain, address: key) ?? 0.8
            let saved = launcherSeconds - chainSeconds
            guard saved > 0 else { continue }
            let weekly = Double(record.searcher) / max(1, Double(o.activeWeeks(app: app)))
            let lower = Maths.wilsonLower(successes: record.searcher, trials: record.reaches)
            guard lower > 0.5 else { continue }
            // The null: with an address in hand, searches should be the
            // exception, not the majority.
            let p = Maths.binomialTail(atLeast: record.searcher, n: record.reaches, p: 0.5)
            let shown = "lode " + leaf.chain.map { $0.uppercased() }.joined(separator: " ")
            var evidence = [String(format: "%d%% of %d reaches went through the launcher",
                                   Int(share * 100), record.reaches)]
            if let rescued = rescues[Observations.key(leaf.chain.prefix(1).map { $0 })],
               rescued > 0 {
                evidence.append("\(rescued) abandoned chains were rescued by the launcher")
            }
            out.append((Recommendation(
                kind: .nudge, target: app,
                detail: "\(app) has \(shown) and you search for it anyway · "
                    + String(format: "each search pays %.1fs over the chain", saved),
                secondsPerWeek: saved * weekly, probability: lower,
                evidence: evidence), p))
        }
        return out
    }

    static func breathCandidates(_ context: Context) -> [(Recommendation, Double)] {
        let pairs = Transitions.strongPairs(context.observations.transitions)
        var out: [(Recommendation, Double)] = []
        for pair in pairs.prefix(3) where pair.lift >= 3 && pair.count >= 8 {
            // The null: the pair co-occurs at the rate independence
            // predicts. Normal approximation to the Poisson tail above it.
            let expected = pair.count / pair.lift
            let z = (pair.count - expected) / max(1, expected).squareRoot()
            let p = 1 - Maths.normalCDF(z)
            let probability = min(0.95, Maths.normalCDF(z))
            out.append((Recommendation(
                kind: .breath, target: "\(pair.from) + \(pair.to)",
                detail: "\(pair.from) and \(pair.to) travel together "
                    + String(format: "%.0f× at lift %.1f · a breath would pin them side by side",
                             pair.count, pair.lift),
                secondsPerWeek: pair.count * 2,
                probability: probability,
                evidence: [String(format: "lift %.1f over independent use", pair.lift)]), p))
        }
        return out
    }

    static func routeCandidates(_ context: Context) -> [(Recommendation, Double)] {
        let o = context.observations
        var out: [(Recommendation, Double)] = []
        for (host, record) in o.hosts {
            guard record.count >= 8,
                  let (profile, hits) = record.profiles.max(by: { $0.value < $1.value })
            else { continue }
            let lower = Maths.wilsonLower(successes: hits, trials: record.count)
            guard Double(hits) / Double(record.count) >= 0.9, lower > 0.6 else { continue }
            // Already covered by a rule? Then the decision is made and quiet.
            guard WebRouting.routePattern("https://\(host)", routes: context.webRoutes) == nil
            else { continue }
            // The null: no preferred profile for this host.
            let p = Maths.binomialTail(atLeast: hits, n: record.count, p: 0.5)
            // The chip can only offer what a config line can say, and a
            // route line needs the registry key behind the observed profile.
            let edit = context.profileKeys[profile].map {
                ConfigEdit.addRoute(pattern: host, profileKey: $0)
            }
            out.append((Recommendation(
                kind: .route, target: host,
                detail: "\(host) has landed in \(profile) \(hits) of \(record.count) times · "
                    + "one route line would make it a fact instead of a habit",
                secondsPerWeek: Double(record.count)
                    / max(1, Double(record.weeks.count)) * 1.5,
                probability: lower,
                evidence: ["\(hits)/\(record.count) opens in \(profile)"], edit: edit), p))
        }
        return out
    }
}
