import Foundation

/// What Lodestar notices about how you reach things, so it can eventually
/// tell you something useful about it.
///
/// The rule the whole design turns on is **counts, not content**. This
/// records that an address was typed, how long the pauses inside it were, and
/// which route reached an app. It never records a window title, a URL, a
/// clipboard, or what you typed into the searcher: the number of characters
/// is enough to know what a search cost you, and the characters themselves
/// are yours. Nothing leaves the machine, ever, and the file lives in
/// `~/.local/share` rather than the config, which people commit to
/// dotfiles repositories.
///
/// Two measurements do most of the work, and neither needs a counterfactual:
///
/// - **Pauses.** An address you own is typed at motor speed; one you are
///   reconstructing has a gap in it. That is as close to "has this compiled
///   into muscle memory" as you can get without asking.
/// - **Abandons.** A chain you started and escaped out of is unambiguous in a
///   way a slow chain is not, because a slow chain might be a phone call.
public struct Observations: Codable, Equatable {
    public static let currentVersion = 1

    /// A pause longer than this is not a recall event. Chains wait
    /// indefinitely by design, so one interruption would otherwise put
    /// minutes into an average and make every statistic here a lie.
    ///
    /// Ten seconds, not two. Two was the first guess and it was wrong in the
    /// direction that mattered: a genuine "which letter was it again" pause
    /// runs several seconds, so a tight ceiling silently discarded exactly the
    /// slow addresses worth finding and left only the fluent ones in the
    /// average. Interruptions are minutes, not seconds, so the wider ceiling
    /// still excludes them.
    public static let recallCeiling: TimeInterval = 10.0
    /// The first samples are kept forever, because a learning curve needs its
    /// beginning; the recent ones roll, because fluency is a present-tense
    /// question.
    static let earlyCap = 10
    static let recentCap = 20
    /// Eight weeks is enough to answer "did this hold across two weeks" and
    /// short enough that the file cannot become a history of your year.
    static let weekCap = 8

    /// How an app was reached. The distinction is the whole recommendation
    /// engine: searching for something you have an address for means the
    /// address is not learned, and searching for something you do not have an
    /// address for means it wants one.
    public enum Route: String, Codable, Equatable {
        case graph, searcher, breath, other
    }

    public struct AddressRecord: Codable, Equatable {
        public var completions = 0
        public var abandons = 0
        public var wrongLetters = 0
        /// Median pause per completion, in order, first ten.
        public var early: [TimeInterval] = []
        /// Median pause per completion, most recent twenty.
        public var recent: [TimeInterval] = []
        /// Week index (weeks since the epoch) to completions in it.
        public var weeks: [Int: Int] = [:]
        public var lastUsed = Date.distantPast

        public init() {}
    }

    public struct AppRecord: Codable, Equatable {
        public var graph = 0
        public var searcher = 0
        public var breath = 0
        public var other = 0
        /// Characters typed before picking, most recent twenty. Measured
        /// rather than assumed: what a search actually cost, not what we
        /// imagine it would have.
        public var typed: [Int] = []
        public var weeks: [Int: Int] = [:]
        public var lastUsed = Date.distantPast

        public init() {}

        public var reaches: Int { graph + searcher + breath + other }
    }

    public var version = Observations.currentVersion
    /// Addresses keyed by their chain, lowercased and space separated.
    public var addresses: [String: AddressRecord] = [:]
    /// Apps keyed by name, which is what the graph and the config already use.
    public var apps: [String: AppRecord] = [:]
    /// Verb name to times used, so a feature nobody touches can say so.
    public var verbs: [String: Int] = [:]
    /// When collection began, so a report can say how much it is speaking from.
    public var since = Date.distantPast
    public var updated = Date.distantPast

    public init() {}

    // MARK: - Keys

    public static func key(_ letters: [String]) -> String {
        letters.map { $0.lowercased() }.joined(separator: " ")
    }

    /// Weeks since the epoch. Deliberately not a calendar week: no locale, no
    /// time zone, monotonic, and comparable by subtraction.
    static func week(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 604_800)
    }

    // MARK: - Recording

    /// A chain that resolved. `gaps` are the pauses between its keys; the
    /// median of the plausible ones becomes this completion's sample.
    public mutating func chainCompleted(_ letters: [String], gaps: [TimeInterval],
                                        at now: Date = Date()) {
        guard !letters.isEmpty else { return }
        touch(now)
        var record = addresses[Self.key(letters)] ?? AddressRecord()
        record.completions += 1
        record.lastUsed = now
        record.weeks[Self.week(now), default: 0] += 1
        Self.prune(&record.weeks)
        if let sample = Self.median(gaps.filter { $0 > 0 && $0 <= Self.recallCeiling }) {
            if record.early.count < Self.earlyCap { record.early.append(sample) }
            record.recent.append(sample)
            if record.recent.count > Self.recentCap { record.recent.removeFirst() }
        }
        addresses[Self.key(letters)] = record
    }

    /// A chain started and escaped out of. The clearest negative signal there
    /// is: the address was in the way rather than merely slow.
    public mutating func chainAbandoned(_ letters: [String], at now: Date = Date()) {
        guard !letters.isEmpty else { return }
        touch(now)
        var record = addresses[Self.key(letters)] ?? AddressRecord()
        record.abandons += 1
        addresses[Self.key(letters)] = record
    }

    /// A key that was not legal where it was pressed. Usually a collision
    /// between the graph and the name in your head.
    public mutating func wrongLetter(after letters: [String], at now: Date = Date()) {
        touch(now)
        let key = letters.isEmpty ? "" : Self.key(letters)
        var record = addresses[key] ?? AddressRecord()
        record.wrongLetters += 1
        addresses[key] = record
    }

    /// An app was reached, and by which road. `charactersTyped` applies to the
    /// searcher only, where it is the cost that was actually paid.
    public mutating func reached(_ app: String, via route: Route,
                                 charactersTyped: Int? = nil, at now: Date = Date()) {
        let name = app.lowercased()
        guard !name.isEmpty else { return }
        touch(now)
        var record = apps[name] ?? AppRecord()
        switch route {
        case .graph: record.graph += 1
        case .searcher: record.searcher += 1
        case .breath: record.breath += 1
        case .other: record.other += 1
        }
        record.lastUsed = now
        record.weeks[Self.week(now), default: 0] += 1
        Self.prune(&record.weeks)
        if let typed = charactersTyped, typed >= 0 {
            record.typed.append(typed)
            if record.typed.count > Self.recentCap { record.typed.removeFirst() }
        }
        apps[name] = record
    }

    public mutating func verbUsed(_ verb: String, at now: Date = Date()) {
        guard !verb.isEmpty else { return }
        touch(now)
        verbs[verb, default: 0] += 1
    }

    private mutating func touch(_ now: Date) {
        if since == .distantPast { since = now }
        updated = now
    }

    private static func prune(_ weeks: inout [Int: Int]) {
        guard weeks.count > weekCap else { return }
        for key in weeks.keys.sorted().prefix(weeks.count - weekCap) {
            weeks.removeValue(forKey: key)
        }
    }

    // MARK: - Reading

    /// How fluent an address is now: the median recent pause, and how many
    /// samples that rests on. Nil until there is enough to mean anything.
    public func fluency(_ letters: [String], minimumSamples: Int = 5)
        -> (median: TimeInterval, samples: Int)? {
        guard let record = addresses[Self.key(letters)],
              record.recent.count >= minimumSamples,
              let median = Self.median(record.recent) else { return nil }
        return (median, record.recent.count)
    }

    /// Whether an address is getting faster, in seconds per use, across its
    /// first uses. Negative is learning. A binding whose curve never bends is
    /// the honest version of "this one is not working out", and because it
    /// compares an address only against its own past it needs no
    /// counterfactual and no comparison to anybody else.
    public func learningTrend(_ letters: [String], minimumSamples: Int = 5) -> Double? {
        guard let record = addresses[Self.key(letters)],
              record.early.count >= minimumSamples else { return nil }
        return Self.slope(record.early)
    }

    public func abandonRate(_ letters: [String], minimumEvents: Int = 5) -> Double? {
        guard let record = addresses[Self.key(letters)] else { return nil }
        let total = record.completions + record.abandons
        guard total >= minimumEvents else { return nil }
        return Double(record.abandons) / Double(total)
    }

    /// The share of an app's reaches that went through the searcher. High, for
    /// an app that has an address, means the address is not being used.
    public func routeShare(_ app: String, minimumReaches: Int = 5) -> Double? {
        guard let record = apps[app.lowercased()], record.reaches >= minimumReaches else {
            return nil
        }
        return Double(record.searcher) / Double(record.reaches)
    }

    /// What searching for this app actually costs, in characters.
    public func medianTyped(_ app: String) -> Int? {
        guard let record = apps[app.lowercased()],
              let median = Self.median(record.typed.map(Double.init)) else { return nil }
        return Int(median.rounded())
    }

    /// Distinct weeks an address or app has appeared in. A signal that holds
    /// across two of them is a habit; one that does not is a day.
    public func activeWeeks(address letters: [String]) -> Int {
        addresses[Self.key(letters)]?.weeks.values.filter { $0 > 0 }.count ?? 0
    }

    public func activeWeeks(app: String) -> Int {
        apps[app.lowercased()]?.weeks.values.filter { $0 > 0 }.count ?? 0
    }

    /// This person's own median pause across every address with enough
    /// samples. Fluency has to be judged against this rather than a constant:
    /// typing speed varies enormously, and a fixed threshold would insult
    /// fast typists and flatter slow ones.
    public func typicalPause(minimumSamples: Int = 5) -> TimeInterval? {
        let medians = addresses.values.compactMap { record -> TimeInterval? in
            guard record.recent.count >= minimumSamples else { return nil }
            return Self.median(record.recent)
        }
        return Self.median(medians)
    }

    /// Addresses that exist in the config and have never been completed here.
    /// A letter spent on nothing.
    public func unused(among bound: [[String]]) -> [[String]] {
        bound.filter { (addresses[Self.key($0)]?.completions ?? 0) == 0 }
    }

    // MARK: - Maths

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Least squares slope against position. Enough for "is this curve
    /// bending downward", which is the only question asked of it.
    static func slope(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let n = Double(values.count)
        let meanX = (n - 1) / 2
        let meanY = values.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for (index, value) in values.enumerated() {
            let dx = Double(index) - meanX
            numerator += dx * (value - meanY)
            denominator += dx * dx
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }
}
