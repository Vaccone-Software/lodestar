import Foundation

/// The coach: policy over the advisor's findings. Which one to offer,
/// whether now is the time, what the chip says, and how "no" is
/// remembered. Pure — the controller owns cameras, glass, and clocks;
/// this owns every decision, so every decision is testable.
///
/// The shape of the policy is progressive overload: one learning habit at
/// a time, and the next suggestion releases when the current one's curve
/// bends, not when a calendar says so. Someone who adopts fast is coached
/// fast; a slow month is not nagged through. Declines are graded and none
/// is forever — a parked suggestion returns when the evidence materially
/// strengthens, because the data kept moving even while the answer was no.
public enum Coach {
    /// Floor between any two offers, even for the fastest learner —
    /// consolidation is not instant.
    public static let minDaysBetweenOffers = 3.0
    /// An accepted habit that never bends stops blocking the queue.
    public static let stallWeeks = 3
    /// Completions at the new binding before its curve counts as bent.
    public static let bentCompletions = 15
    /// Offers of one suggestion before it parks on its own.
    public static let maxOffers = 3
    /// Days between showings of the same suggestion.
    public static let retryCooldownDays = 2.0
    /// "Not this one" sleeps this long...
    public static let neverSleepWeeks = 13
    /// ...unless the predicted value grows past this multiple of what was
    /// declined — the world changed, so the question may be asked again.
    public static let neverOverrideFactor = 2.0
    /// A parked suggestion re-enters after this long, or sooner when its
    /// value grows past this multiple.
    public static let parkedSleepWeeks = 8
    public static let parkedOverrideFactor = 1.5
    /// The first offer ever sets the channel's reputation: it waits for a
    /// clearly strong finding. Modest on purpose — approachable, not
    /// monumental.
    public static let debutFloorSecondsPerWeek = 30.0

    /// Where a suggestion lands best: right after its cost was felt.
    public enum Cue: Equatable {
        case app(String)
        case host(String)
    }

    /// The chip's three lines. Everything here obeys the voice rules: the
    /// user can verify every clause from their own experience, dots
    /// delimit, and the model's machinery is never quoted.
    public struct Chip: Equatable {
        public let headline: String
        public let evidence: String
        public let footer: String
    }

    // MARK: - The offer

    /// The one suggestion worth standing behind right now, or nil — and
    /// nil is the common, correct answer.
    public static func standingOffer(observations: Observations,
                                     recommendations: [Recommendation],
                                     now: Date) -> Recommendation? {
        guard !slotBusy(observations: observations, now: now) else { return nil }
        let ledger = observations.ledger
        if let lastOffer = ledger.map(\.lastOfferedAt).max(), lastOffer != .distantPast,
           now.timeIntervalSince(lastOffer) < minDaysBetweenOffers * 86_400 {
            return nil
        }
        let debut = ledger.allSatisfy { $0.offers == 0 }
        let week = Observations.week(now)

        let eligible = recommendations.filter { rec in
            guard rec.edit != nil else { return false }
            if debut, rec.secondsPerWeek < debutFloorSecondsPerWeek { return false }
            guard let entry = ledger.first(where: { $0.id == "\(rec.kind.rawValue):\(rec.target)" })
            else { return true }
            if entry.status == "accepted" || entry.adoptedWeek != nil { return false }
            if entry.status == "never" {
                // Asleep, not dead: long enough quiet, or the evidence
                // outgrew the answer.
                let slept = week - (entry.neverWeek ?? week) >= neverSleepWeeks
                let outgrew = rec.secondsPerWeek
                    >= entry.predictedSecondsPerWeek * neverOverrideFactor
                return slept || outgrew
            }
            if entry.offers >= maxOffers {
                let slept = week - entry.lastOfferedWeek >= parkedSleepWeeks
                let outgrew = rec.secondsPerWeek
                    >= entry.predictedSecondsPerWeek * parkedOverrideFactor
                return slept || outgrew
            }
            return now.timeIntervalSince(entry.lastOfferedAt) >= retryCooldownDays * 86_400
        }
        return eligible.max { $0.secondsPerWeek * $0.probability
            < $1.secondsPerWeek * $1.probability }
    }

    /// One learning habit at a time. A habit occupies the slot from
    /// acceptance (or hand adoption) until its curve bends or it stalls;
    /// writes that need no learning — a route, a retirement — never
    /// occupy it.
    public static func slotBusy(observations: Observations, now: Date) -> Bool {
        let week = Observations.week(now)
        for entry in observations.ledger where requiresLearning(entry.kind) {
            let startedWeek: Int
            if entry.status == "accepted", let accepted = entry.acceptedWeek {
                startedWeek = accepted
            } else if let adopted = entry.adoptedWeek {
                startedWeek = adopted
            } else {
                continue
            }
            guard week - startedWeek < stallWeeks else { continue }
            guard let chain = entry.chain else { continue }
            let completions = observations.addresses[chain]?.trigger.n ?? 0
            if completions < bentCompletions { return true }
        }
        return false
    }

    static func requiresLearning(_ kind: String) -> Bool {
        kind == Recommendation.Kind.bind.rawValue
            || kind == Recommendation.Kind.shorten.rawValue
            || kind == Recommendation.Kind.rebind.rawValue
    }

    /// Where this suggestion lands best, if it has such a place. The cue
    /// is a scheduling preference, never a permission — a suggestion with
    /// no cue, or whose cue does not come, goes out at a quiet boundary.
    public static func cue(for rec: Recommendation) -> Cue? {
        switch rec.kind {
        case .bind, .nudge: return .app(rec.target)
        case .shorten:
            if case .bindTarget(_, let target)? = rec.edit {
                return .app((rec.display ?? target).lowercased())
            }
            return nil
        case .route: return .host(rec.target)
        case .rebind, .retire, .breath: return nil
        }
    }

    // MARK: - The chip

    public static func chip(for rec: Recommendation, observations: Observations) -> Chip {
        let accept: String
        let headline: String
        var evidence = rec.detail
        switch rec.kind {
        case .bind, .shorten:
            if case .bindTarget(let chain, let target)? = rec.edit {
                let shown = chain.map { $0.uppercased() }.joined(separator: " ")
                // The label, never the config value: a chip saying
                // "lode X → brave:xonar" quotes the machinery at someone
                // who only ever asked for their browser.
                headline = "lode \(shown) → \(rec.display ?? target)"
            } else {
                headline = rec.target
            }
            accept = "tap lode twice to bind it"
            if rec.kind == .bind, let record = observations.apps[rec.target.lowercased()] {
                let weeks = max(1, observations.activeWeeks(app: rec.target))
                evidence = "you searched for it \(record.searcher) times"
                    + " across \(weeks) week\(weeks == 1 ? "" : "s")"
                    + secondsClause(rec.secondsPerWeek)
            } else if rec.kind == .shorten,
                      let record = observations.addresses[rec.target] {
                let shownOld = rec.target.split(separator: " ")
                    .map { $0.uppercased() }.joined(separator: " ")
                evidence = "lode \(shownOld) has fired \(record.completions) times"
                    + secondsClause(rec.secondsPerWeek)
            }
        case .retire:
            let shown = rec.target.split(separator: " ")
                .map { $0.uppercased() }.joined(separator: " ")
            headline = "retire lode \(shown)"
            evidence = "bound and never typed · the letter frees up"
            accept = "tap lode twice to retire it"
        case .route:
            if case .addRoute(let pattern, let profileKey)? = rec.edit {
                headline = "\(pattern) → \(profileKey)"
            } else {
                headline = rec.target
            }
            if let record = observations.hosts[rec.target],
               let (_, hits) = record.profiles.max(by: { $0.value < $1.value }) {
                evidence = "opened there \(hits) of \(record.count) times"
                    + secondsClause(rec.secondsPerWeek)
            }
            accept = "tap lode twice to add the route"
        case .rebind, .nudge, .breath:
            headline = rec.target
            accept = "see lodestar observations"
        }
        return Chip(headline: headline, evidence: evidence,
                    footer: "\(accept) · lode ⌫ not this one · fades on its own")
    }

    private static func secondsClause(_ secondsPerWeek: Double) -> String {
        guard secondsPerWeek >= 5 else { return "" }
        return " · about \(Int(secondsPerWeek.rounded())) seconds a week"
    }
}
