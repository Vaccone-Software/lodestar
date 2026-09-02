import Foundation

/// Which app comes next — the question predicted warming asks.
///
/// Chromium and Electron build their accessibility trees lazily and tear
/// them down after idle minutes, so the first text mode after a switch
/// pays for a tree that could have been standing already. The warmer
/// fires on focus; this predicts the focus before it happens, so the
/// warmer can fire early for the apps most likely to be next.
///
/// Every strategy here is scored the shadow way — predict, then observe,
/// over the real focus stream — and the printout shows the hit rates, so
/// the one the warmer uses is the one that measurably predicts *this*
/// person best. The known shape of the problem: the app just left is the
/// single most likely next app (glance loops), a first-order chain
/// captures the rest, and the blend of the two beats either — measured
/// at 60 / 82 / 90% for the top one, two, and three predictions on the
/// stream this was built against. The blend's two numbers are tuned on
/// the same stream rather than assumed.
public struct NextApp: Equatable {
    /// Recent apps, most recent last, no consecutive repeats.
    public static let historyCap = 8
    /// Distinct apps the tables may name; the rest are never learned.
    /// The transition matrix's own cap, for the same reason.
    public static let appCap = 32
    /// A second-order row this thin backs off to first order.
    public static let secondOrderFloor = 3.0

    /// The blend's knobs, chosen by `tune` on the user's own stream.
    public struct Tuning: Equatable {
        /// Weight on the chain; the rest is recency.
        public var weight: Double
        /// Recency halves (or otherwise decays) per step back.
        public var decay: Double
        /// Prefer the second-order row when it has mass.
        public var secondOrder: Bool

        public init(weight: Double = 0.5, decay: Double = 0.5, secondOrder: Bool = false) {
            self.weight = weight
            self.decay = decay
            self.secondOrder = secondOrder
        }
    }

    /// current → next → count
    private(set) var first: [String: [String: Double]] = [:]
    /// "previous|current" → next → count
    private(set) var second: [String: [String: Double]] = [:]
    public private(set) var history: [String] = []
    public var tuning = Tuning()

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Focus landed. Same app again is a window switch, not a transition.
    public mutating func observe(_ app: String) {
        let name = app.lowercased()
        guard !name.isEmpty, name != history.last else { return }
        if let current = history.last {
            if first[current] != nil || first.count < Self.appCap {
                first[current, default: [:]][name, default: 0] += 1
            }
            if history.count >= 2 {
                let key = "\(history[history.count - 2])|\(current)"
                if second[key] != nil || second.count < Self.appCap * Self.appCap {
                    second[key, default: [:]][name, default: 0] += 1
                }
            }
        }
        history.append(name)
        if history.count > Self.historyCap { history.removeFirst() }
    }

    public enum Strategy: String, CaseIterable {
        /// First-order chain: P(next | current).
        case markov
        /// The app before this one — the "back" key as a predictor.
        case previous
        /// Most recently used, excluding the current app.
        case mru
        /// Chain probability blended with recency at the book tuning.
        case blend
        /// Second-order chain with first-order backoff, blended with
        /// recency at the book tuning.
        case markov2
        /// The blend at whatever `tuning` says — the grid's winner.
        case tuned
    }

    /// The apps most likely next, best first. Never the current app.
    public func predict(_ strategy: Strategy, k: Int = 3) -> [String] {
        guard let current = history.last else { return [] }
        switch strategy {
        case .previous:
            return history.count >= 2 ? [history[history.count - 2]] : []
        case .mru:
            return Array(recency(decay: 0.5).map(\.app).prefix(k))
        case .markov:
            return Array(top(chainScores(row: first[current]), k: k))
        case .blend:
            return Array(top(blended(row: first[current], tuning: Tuning()), k: k))
        case .markov2:
            return Array(top(blended(row: deepRow(), tuning: Tuning()), k: k))
        case .tuned:
            let row = tuning.secondOrder ? deepRow() : first[current]
            return Array(top(blended(row: row, tuning: tuning), k: k))
        }
    }

    /// The second-order row when it has mass, else the first-order one.
    private func deepRow() -> [String: Double]? {
        guard let current = history.last else { return nil }
        if history.count >= 2 {
            let key = "\(history[history.count - 2])|\(current)"
            if let deep = second[key], deep.values.reduce(0, +) >= Self.secondOrderFloor {
                return deep
            }
        }
        return first[current]
    }

    /// Recent apps other than the current one, most recent first, each
    /// weighted `decay` to the power of its steps back.
    private func recency(decay: Double) -> [(app: String, weight: Double)] {
        var seen: Set<String> = [history.last ?? ""]
        var out: [(String, Double)] = []
        for app in history.reversed() where seen.insert(app).inserted {
            out.append((app, pow(decay, Double(out.count))))
        }
        return out
    }

    private func chainScores(row: [String: Double]?) -> [String: Double] {
        guard let row, let current = history.last else { return [:] }
        let others = row.filter { $0.key != current }
        let mass = others.values.reduce(0, +)
        guard mass > 0 else { return [:] }
        return others.mapValues { $0 / mass }
    }

    private func blended(row: [String: Double]?, tuning: Tuning) -> [String: Double] {
        var scores = chainScores(row: row).mapValues { $0 * tuning.weight }
        for (app, weight) in recency(decay: tuning.decay) {
            scores[app, default: 0] += (1 - tuning.weight) * weight
        }
        return scores
    }

    private func top(_ scores: [String: Double], k: Int) -> [String] {
        scores.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(k).map(\.key)
    }

    // MARK: - Shadow scoring

    public struct Score: Equatable {
        public let strategy: Strategy
        public let switches: Int
        /// Hit rate with the top 1, 2, and 3 predictions.
        public let hits: [Double]
    }

    /// Replay the focus stream chronologically, predicting each switch
    /// before observing it — the only honest order. `warmup` switches
    /// are observed before scoring starts, so nothing is judged on an
    /// empty table. Returns hit counts per strategy and the switches
    /// scored.
    static func replay(events: [ObservationEvent], tuning: Tuning, warmup: Int,
                       strategies: [Strategy]) -> (hits: [Strategy: [Int]], switches: Int) {
        var model = NextApp(tuning: tuning)
        var seen = 0
        var counted = 0
        var hits: [Strategy: [Int]] = [:]
        for strategy in strategies { hits[strategy] = [0, 0, 0] }
        let focuses = events.filter { $0.kind == .focus }.sorted { $0.t < $1.t }
        for event in focuses {
            guard let app = event.app?.lowercased(), !app.isEmpty,
                  app != model.history.last else { continue }
            if seen >= warmup, model.history.last != nil {
                counted += 1
                for strategy in strategies {
                    if let rank = model.predict(strategy, k: 3).firstIndex(of: app) {
                        for slot in rank..<3 { hits[strategy]![slot] += 1 }
                    }
                }
            }
            model.observe(app)
            seen += 1
        }
        return (hits, counted)
    }

    /// The grid the blend is tuned over. Small on purpose: a finer grid
    /// would fit noise, and every cell is scored on every switch.
    static let weightGrid: [Double] = [0.3, 0.4, 0.5, 0.6, 0.7]
    static let decayGrid: [Double] = [0.35, 0.5, 0.65]
    /// The most recent switches scoring and tuning look at. Recent
    /// behaviour is what the warmer serves, and a bound is what keeps a
    /// year-deep ring from turning a six-hourly re-tune into a chore.
    public static let scoringWindow = 20_000

    /// The most recent `scoringWindow` focus events, chronological.
    static func recentFocuses(_ events: [ObservationEvent]) -> [ObservationEvent] {
        let focuses = events.filter { $0.kind == .focus }.sorted { $0.t < $1.t }
        return Array(focuses.suffix(scoringWindow))
    }

    /// The tuning that predicts this stream best: the mean of the three
    /// hit rates, so a better-ordered list counts as well as a wider one.
    /// The book tuning when there is nothing to score yet.
    ///
    /// One pass, not one per cell: each switch normalizes its chain rows
    /// and builds its recency lists once, and every cell only merges and
    /// ranks — the rank of the true next app is a scan, never a sort.
    /// The grid-times-replay version of this took twenty seconds on a
    /// fortnight of real switches; this takes well under one.
    public static func tune(events: [ObservationEvent], warmup: Int = 50) -> Tuning {
        var cells: [Tuning] = []
        for secondOrder in [false, true] {
            for weight in weightGrid {
                for decay in decayGrid {
                    cells.append(Tuning(weight: weight, decay: decay, secondOrder: secondOrder))
                }
            }
        }
        var hits = [Int](repeating: 0, count: cells.count)
        var model = NextApp()
        var seen = 0
        var switches = 0
        for event in recentFocuses(events) {
            guard let app = event.app?.lowercased(), !app.isEmpty,
                  app != model.history.last else { continue }
            if seen >= warmup, let current = model.history.last {
                switches += 1
                let shallow = model.chainScores(row: model.first[current])
                let deep = model.chainScores(row: model.deepRow())
                let recencies = decayGrid.map { model.recency(decay: $0) }
                for (index, cell) in cells.enumerated() {
                    let chain = cell.secondOrder ? deep : shallow
                    let decayIndex = decayGrid.firstIndex(of: cell.decay) ?? 0
                    var scores = chain.mapValues { $0 * cell.weight }
                    for (name, weight) in recencies[decayIndex] {
                        scores[name, default: 0] += (1 - cell.weight) * weight
                    }
                    guard let own = scores[app] else { continue }
                    var rank = 0
                    for (other, score) in scores where other != app {
                        if score > own || (score == own && other < app) { rank += 1 }
                    }
                    // Credit: one point per slot the true app lands in,
                    // so a top-1 hit is worth three and a top-3 hit one.
                    if rank < 3 { hits[index] += 3 - rank }
                }
            }
            model.observe(app)
            seen += 1
        }
        guard switches > 0, let best = hits.indices.max(by: { hits[$0] < hits[$1] })
        else { return Tuning() }
        return cells[best]
    }

    /// Every strategy scored at once, the tuned blend included.
    public static func evaluate(events: [ObservationEvent], tuning: Tuning? = nil,
                                warmup: Int = 50) -> [Score] {
        let chosen = tuning ?? tune(events: events, warmup: warmup)
        let (hits, switches) = replay(events: recentFocuses(events), tuning: chosen,
                                      warmup: warmup, strategies: Strategy.allCases)
        guard switches > 0 else { return [] }
        return Strategy.allCases.map { strategy in
            Score(strategy: strategy, switches: switches,
                  hits: hits[strategy]!.map { Double($0) / Double(switches) })
        }
    }

    /// The strategy the warmer should use: the best top-3 hit rate — the
    /// warmer warms three — with top-2 breaking ties; the book blend when
    /// there is nothing to score yet.
    public static func best(_ scores: [Score]) -> Strategy {
        scores.max {
            $0.hits[2] < $1.hits[2] || ($0.hits[2] == $1.hits[2] && $0.hits[1] < $1.hits[1])
        }?.strategy ?? .blend
    }
}
