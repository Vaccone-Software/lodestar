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
///
/// The pacing distinguishes a chip that was answered from one that merely
/// stood: an answer buys days of quiet, but an unanswered showing is a
/// chip on glass, not a chip read, and the attention budget is only truly
/// spent by chips a person noticed. So unanswered showings retry on a
/// short leash before parking, while the long silences are reserved for
/// what was actually declined.
public enum Coach {
    /// Quiet after an answer, whichever answer it was — an accept is
    /// consolidating and a no deserves its silence, and neither wants a
    /// new question tomorrow.
    public static let answerQuietDays = 3.0
    /// Floor between any two counted showings, so two chips never share a
    /// day and each appearance stays rare enough to mean something.
    public static let offerQuietDays = 1.0
    /// An accepted habit that never bends stops blocking the queue.
    public static let stallWeeks = 3
    /// Completions at the new binding before its curve counts as bent.
    public static let bentCompletions = 15
    /// Showings of one suggestion before it parks on its own.
    public static let maxOffers = 3
    /// Days between showings of the same suggestion. Unanswered is not
    /// declined — decay is "later" — so the retry is short enough that
    /// "later" arrives while the evidence is still warm.
    public static let retryCooldownDays = 2.0
    /// The channel's first showing ever is the one most likely to be
    /// missed outright — nothing has yet taught the eye that the register
    /// exists — so the debut alone retries a day sooner.
    public static let debutRetryDays = 1.0
    /// "Not this one" sleeps this long...
    public static let neverSleepWeeks = 13
    /// ...unless the predicted value grows past this multiple of what was
    /// declined — the world changed, so the question may be asked again.
    public static let neverOverrideFactor = 2.0
    /// A parked suggestion re-enters after this long, or sooner when its
    /// value grows past this multiple. Parked is exhaustion, never a no:
    /// nobody declined it, so it sleeps a month, not a season.
    public static let parkedSleepWeeks = 4
    public static let parkedOverrideFactor = 1.5
    /// The first offer ever sets the channel's reputation: it waits for a
    /// clearly strong finding. Modest on purpose — approachable, not
    /// monumental.
    public static let debutFloorSecondsPerWeek = 30.0

    /// Where a suggestion lands best: right after its cost was felt.
    public enum Cue: Equatable {
        case app(String)
        case host(String)
        /// Any meeting activity: a meeting host opened, or focus landing
        /// on a native meeting app — the seconds after a manual join.
        case meeting
    }

    /// The chip's three lines. Everything here obeys the voice rules: the
    /// user can verify every clause from their own experience, dots
    /// delimit, and the model's machinery is never quoted.
    public struct Chip: Equatable {
        public let headline: String
        public let evidence: String
        public let footer: String
    }

    // MARK: - The moment

    /// How long a chip stands before fading to "later". A minute, because
    /// the chip must survive the seconds of focused work between its
    /// boundary and the eye's next saccade to the glass — a chip that fades
    /// in half a thought teaches the user they hallucinated it.
    public static let chipSeconds: TimeInterval = 60
    /// How long it must stand unclaimed before the offer is spent. A chip
    /// the engine takes off the glass in its first seconds was never read,
    /// and the curriculum must not charge for what nobody saw.
    public static let seenSeconds: TimeInterval = 10
    /// A showing that never counted may try again — but not at once. A chip
    /// that flickers at every boundary is noise, not an offer.
    public static let reshowSeconds: TimeInterval = 120
    /// How stale the last hardware key may be before the chair counts as
    /// empty. Generous, because on the path that matters this is never near
    /// the limit: a navigation boundary is itself keyboard-driven, so the
    /// stamp is milliseconds old. The ceiling only bites where no key was
    /// involved at all — a URL some other app opened.
    public static let presenceCeiling: TimeInterval = 120

    /// `kCGEventSourceStateHIDSystemState`, named here so this layer need
    /// not import CoreGraphics for one integer.
    public static let hidSystemStateID: Int64 = 1

    /// Did hardware make this event, or did something post it?
    ///
    /// Measured, all four cases. Real hardware reports source id 1 and
    /// posting pid 0. Ordinary automation reports a private source id and
    /// its own pid. Automation that forges the source id to 1 defeats a
    /// source-only check — but cannot forge the pid: the system stamps it,
    /// and an explicit `setIntegerValueField(.eventSourceUnixProcessID, 0)`
    /// is overwritten. The pid is the load-bearing half; the source id is
    /// kept because it costs 2ns and catches the lazy case a step earlier.
    ///
    /// The ceiling this cannot pass: it answers "was this injected by a
    /// userspace process", never "was a finger involved". Anything injecting
    /// at the driver level reads as hardware, and must — that is how a
    /// remapper delivers real keystrokes.
    public static func isHumanOrigin(sourceStateID: Int64, postingPID: Int64) -> Bool {
        postingPID == 0 && sourceStateID == hidSystemStateID
    }

    /// Is a person at the machine?
    ///
    /// `humanIdle` must come from a clock stamped only by hardware-origin
    /// events. The system's own idle clock cannot do this job: posted events
    /// reset `CGEventSource.secondsSinceLastEventType` — through either tap,
    /// under both source states — so a machine being driven by an agent
    /// holds it at zero all day, and it reports a present user most
    /// confidently in exactly the case where nobody is there.
    public static func isPresent(humanIdle: TimeInterval, screenLocked: Bool,
                                 displayAsleep: Bool, onConsole: Bool) -> Bool {
        humanIdle < presenceCeiling && !screenLocked && !displayAsleep && onConsole
    }

    /// Everything a decision to speak rests on, gathered by the coat. The
    /// three ledger clocks pace the curriculum here rather than in the
    /// selection: what stands and what may be shown are different
    /// questions, and holding them apart is what lets a missed chip wait
    /// in the menu instead of evaporating.
    public struct Moment {
        public var enabled: Bool
        public var chipVisible: Bool
        /// The standing suggestion has already spent a showing.
        public var offerSpent: Bool
        public var sinceLastShown: TimeInterval
        /// Since the channel's last answer, whoever gave it.
        public var sinceAnswered: TimeInterval
        /// Since the channel's last counted showing, of anything.
        public var sinceOffered: TimeInterval
        /// Since this suggestion's own last counted showing.
        public var sinceThisOffered: TimeInterval
        /// Counted showings: the channel's total, and this suggestion's.
        public var channelOffers: Int
        public var thisOffers: Int
        public var engineQuiet: Bool
        public var cameraRunning: Bool
        public var present: Bool
        public var inputWasHuman: Bool

        public init(enabled: Bool = true, chipVisible: Bool = false,
                    offerSpent: Bool = false, sinceLastShown: TimeInterval = 3600,
                    sinceAnswered: TimeInterval = .infinity,
                    sinceOffered: TimeInterval = .infinity,
                    sinceThisOffered: TimeInterval = .infinity,
                    channelOffers: Int = 0, thisOffers: Int = 0,
                    engineQuiet: Bool = true, cameraRunning: Bool = false,
                    present: Bool = true, inputWasHuman: Bool = true) {
            self.enabled = enabled
            self.chipVisible = chipVisible
            self.offerSpent = offerSpent
            self.sinceLastShown = sinceLastShown
            self.sinceAnswered = sinceAnswered
            self.sinceOffered = sinceOffered
            self.sinceThisOffered = sinceThisOffered
            self.channelOffers = channelOffers
            self.thisOffers = thisOffers
            self.engineQuiet = engineQuiet
            self.cameraRunning = cameraRunning
            self.present = present
            self.inputWasHuman = inputWasHuman
        }
    }

    /// Speak, or the reason for the silence. Naming every hold is what lets
    /// the one veto that could be miscalibrated say so in the log.
    public enum Hold: Equatable {
        case speak
        case disabled
        case chipUp
        case offerSpent
        case tooSoon
        case answerQuiet
        case offerQuiet
        case retryCooldown
        case engineBusy
        case camera
        case absent
        case notHuman
    }

    /// The wait before one suggestion may be shown again.
    public static func retryDays(channelOffers: Int, thisOffers: Int) -> Double {
        channelOffers == 1 && thisOffers == 1 ? debutRetryDays : retryCooldownDays
    }

    /// Ordered cheapest and most certain first; every one of them is
    /// absolute, and silence remains the resting state.
    public static func hold(_ moment: Moment) -> Hold {
        if !moment.enabled { return .disabled }
        if moment.chipVisible { return .chipUp }
        if moment.offerSpent { return .offerSpent }
        if moment.sinceLastShown < reshowSeconds { return .tooSoon }
        if moment.sinceAnswered < answerQuietDays * 86_400 { return .answerQuiet }
        if moment.sinceOffered < offerQuietDays * 86_400 { return .offerQuiet }
        if moment.thisOffers > 0,
           moment.sinceThisOffered < retryDays(channelOffers: moment.channelOffers,
                                               thisOffers: moment.thisOffers) * 86_400 {
            return .retryCooldown
        }
        if !moment.engineQuiet { return .engineBusy }
        if moment.cameraRunning { return .camera }
        if !moment.present { return .absent }
        if !moment.inputWasHuman { return .notHuman }
        return .speak
    }

    /// How long the pacing clocks alone would hold this suggestion from
    /// showing — the report's answer to "why is it quiet", computed from
    /// the same ledger the moment gate reads so the two cannot drift.
    public static func showingWait(observations: Observations,
                                   rec: Recommendation, now: Date) -> TimeInterval {
        let ledger = observations.ledger
        var wait: TimeInterval = 0
        if let answered = ledger.compactMap(\.lastAnsweredAt).max() {
            wait = max(wait, answerQuietDays * 86_400 - now.timeIntervalSince(answered))
        }
        if let offered = ledger.map(\.lastOfferedAt).filter({ $0 != .distantPast }).max() {
            wait = max(wait, offerQuietDays * 86_400 - now.timeIntervalSince(offered))
        }
        if let entry = ledger.first(where: { $0.id == "\(rec.kind.rawValue):\(rec.target)" }),
           entry.offers > 0, entry.lastOfferedAt != .distantPast {
            let days = retryDays(channelOffers: ledger.reduce(0) { $0 + $1.offers },
                                 thisOffers: entry.offers)
            wait = max(wait, days * 86_400 - now.timeIntervalSince(entry.lastOfferedAt))
        }
        return max(0, wait)
    }

    // MARK: - The offer

    /// The one suggestion worth standing behind right now, or nil — and
    /// nil is the common, correct answer. Standing is not showing: an
    /// unanswered suggestion keeps standing through every cooldown, so a
    /// missed chip can wait in the menu instead of evaporating — the
    /// moment gate is what paces its next appearance on the glass.
    public static func standingOffer(observations: Observations,
                                     recommendations: [Recommendation],
                                     now: Date) -> Recommendation? {
        guard !slotBusy(observations: observations, now: now) else { return nil }
        let ledger = observations.ledger
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
            return true
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
        case .meetings: return .meeting
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
        case .meetings:
            headline = "meetings at the door"
            evidence = rec.detail + secondsClause(rec.secondsPerWeek)
            accept = "tap lode twice to turn it on"
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
