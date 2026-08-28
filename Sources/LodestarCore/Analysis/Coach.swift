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
    /// ...unless the chip demonstrably stood its whole life and was still
    /// not answered. That is a different fact, and until v0.24.4 it could
    /// not be told apart from the common case: chips were being erased by
    /// the next chain and billed anyway, so "unanswered" almost always
    /// meant "never readable". Now a full standing is evidence the offer
    /// was seen and passed over, and the leash it earns is the long one.
    public static let ignoredRetryDays = 4.0
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
    /// How long a superseded address goes on saying where it went, when
    /// the curve never bends to retire it sooner.
    ///
    /// A backstop, not the rule. The redirect is a transition aid, and the
    /// honest measure of a finished transition is the hand, not the
    /// calendar — so `bentCompletions` at the new address ends it first in
    /// every case where the switch actually happened. This catches the
    /// other case: an address so rarely used that the curve never bends at
    /// all, where the redirect would otherwise outlive anyone's memory of
    /// agreeing to it and start reading as archaeology.
    ///
    /// Nine weeks is Lally's 66-day median to habit automaticity, rounded
    /// to the week the rest of the curriculum counts in. Past it, a hand
    /// that has not moved is not going to be moved by a flash.
    public static let supersedeCutoffWeeks = 9

    /// The first offer ever sets the channel's reputation: it waits for a
    /// clearly strong finding. Modest on purpose — approachable, not
    /// monumental.
    public static let debutFloorSecondsPerWeek = 30.0

    /// What a suggestion must be worth to be offered at all, ever.
    ///
    /// The debut floor above only guards the first offer; past it there was
    /// no floor at all, so a finding worth six seconds a week — five
    /// minutes a year — earned the same three chips as one worth three
    /// minutes a week. A chip costs a minute of glass and a decision, so a
    /// suggestion that cannot repay the attention its own offers cost is
    /// not a suggestion, and silence is the better answer.
    public static let offerFloorSecondsPerWeek = 10.0

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
    /// How long the hand must rest after a boundary before the chip is
    /// drawn.
    ///
    /// A boundary is not a resting point. It is the moment a navigation
    /// completed, and the hand that just navigated is the hand most likely
    /// to navigate again within the second — the next chain erases the
    /// panel, so a chip painted on the boundary itself is drawn into the
    /// one moment it is least likely to survive. Measured over five
    /// thousand real boundaries: painting immediately, 46% of chips still
    /// stand at `seenSeconds`; waiting five, 67%. The wait costs candidate
    /// moments and there is no shortage of those — a boundary arrives
    /// thousands of times to the coach's twice a week — so it buys the
    /// only thing that is scarce, which is a chip that gets read.
    public static let settleSeconds: TimeInterval = 5
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

    /// Was this showing read, and may the curriculum charge for it?
    ///
    /// The rule the code always claimed and did not enforce: an offer is
    /// spent by being read, not by being drawn. Three things have to hold
    /// at the checkpoint, and the middle one is the one that was missing —
    /// the chip must still be the thing on the glass. A chip the engine
    /// ordered off two hundred milliseconds after it appeared was never
    /// read, however faithfully a timer went on counting for it.
    public static func offerCounts(stoodFor: TimeInterval, ownsSurface: Bool,
                                   present: Bool) -> Bool {
        stoodFor >= seenSeconds && ownsSurface && present
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
        /// This suggestion's last showing stood its whole life unanswered.
        public var thisStoodFull: Bool
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
                    thisStoodFull: Bool = false,
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
            self.thisStoodFull = thisStoodFull
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
    ///
    /// A chip that stood its full life takes the long leash even on the
    /// debut. The debut's shortcut exists because a first chip is the one
    /// most likely to be missed outright — but a chip that held the glass
    /// for a solid minute was not missed, and the shortcut has nothing
    /// left to correct for.
    public static func retryDays(channelOffers: Int, thisOffers: Int,
                                 stoodFull: Bool = false) -> Double {
        if stoodFull { return ignoredRetryDays }
        return channelOffers == 1 && thisOffers == 1 ? debutRetryDays : retryCooldownDays
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
                                               thisOffers: moment.thisOffers,
                                               stoodFull: moment.thisStoodFull) * 86_400 {
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
                                 thisOffers: entry.offers,
                                 stoodFull: entry.lastShowingStood ?? false)
            wait = max(wait, days * 86_400 - now.timeIntervalSince(entry.lastOfferedAt))
        }
        return max(0, wait)
    }

    // MARK: - The offer

    /// How well this kind of intervention has actually worked on this
    /// user — the curriculum's own calibration, read off the ledger.
    ///
    /// A trial is an answered offer of the kind; a win is an accept whose
    /// habit demonstrably took (the curve bent, judged by the same
    /// `bentCompletions` every other maturity gate uses), or an accept of
    /// an edit that needs no learning. A "never" is a trial with no win. An
    /// accept still young enough to be learning is neither — it must not
    /// count against a kind for being recent. The result multiplies the
    /// *ranking* only, never the gates: evidence decides what may be
    /// offered; history decides what is offered first. Bounded in
    /// (0.5, 1.5) with a two-trial prior, so one bad accept cannot silence
    /// a kind and one good one cannot crown it.
    public static func kindWeight(observations: Observations,
                                  kind: Recommendation.Kind, now: Date = Date()) -> Double {
        var trials = 0
        var wins = 0
        for entry in observations.ledger where entry.kind == kind.rawValue {
            switch entry.status {
            case "accepted":
                if requiresLearning(entry.kind) {
                    let bent = entry.chain
                        .map { (observations.addresses[$0]?.trigger.n ?? 0)
                            >= bentCompletions } ?? false
                    if bent {
                        trials += 1
                        wins += 1
                    } else if let accepted = entry.acceptedWeek,
                              Observations.week(now) - accepted >= stallWeeks {
                        // Old enough to have bent and it did not: a loss.
                        trials += 1
                    }
                } else {
                    trials += 1
                    wins += 1
                }
            case "never":
                trials += 1
            default:
                break
            }
        }
        return 0.5 + (Double(wins) + 1) / (Double(trials) + 2)
    }

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
            // The floor is denominated in seconds saved, so it can only
            // judge suggestions that save seconds. A retirement saves none
            // and never claimed to: what it buys back is a letter, and the
            // zero it carries is the absence of a seconds figure rather
            // than a measurement of worthlessness. Judging it by this floor
            // silenced the whole kind.
            if rec.kind != .retire,
               rec.secondsPerWeek < offerFloorSecondsPerWeek { return false }
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
        // Value times confidence, weighted by how this kind of
        // intervention has historically fared on this user.
        func score(_ rec: Recommendation) -> Double {
            rec.secondsPerWeek * rec.probability
                * kindWeight(observations: observations, kind: rec.kind, now: now)
        }
        return eligible.max { score($0) < score($1) }
    }

    /// The address that replaced this one, shown, while saying so is still
    /// doing a job. Nil for an address that was simply never bound.
    ///
    /// Nothing is stored to answer this: an accepted superseding entry
    /// already holds the old address in `target` and the new one in
    /// `chain`, so the redirect is a view over the ledger rather than a
    /// second copy that could disagree with it.
    ///
    /// It expires, and the reason is worth writing down because the first
    /// build of this did not. The redirect is true forever — the address
    /// really did move — but truth is not the standard, usefulness at the
    /// moment it is read is. Its whole job is carrying a hand through a
    /// transition, and once the hand is through, a permanent signpost
    /// keeps a decommissioned address meaningful when the goal was for it
    /// to stop being a place at all. Read a year later by someone who has
    /// forgotten agreeing to any of it, "moved" is archaeology, and the
    /// plain miss is the clearer answer.
    public static func supersededBy(observations: Observations, letters: [String],
                                    now: Date = Date()) -> String? {
        let key = Observations.key(letters)
        guard let entry = observations.ledger.first(where: {
            $0.target == key && $0.status == "accepted"
                && Recommendation.Kind(rawValue: $0.kind)?.supersedes == true
        }), let chain = entry.chain, !chain.isEmpty else { return nil }
        // The hand arrived: the same bent curve the slot waits on.
        let completions = observations.addresses[chain]?.trigger.n ?? 0
        if completions >= bentCompletions { return nil }
        // Or it never will. An undated accept cannot be aged, and absence
        // of a date is not grounds for silence — the curve still governs.
        if let accepted = entry.acceptedWeek,
           Observations.week(now) - accepted >= supersedeCutoffWeeks { return nil }
        return chain.split(separator: " ").map { $0.uppercased() }.joined(separator: " ")
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
        case .shorten, .rebind:
            // A rebind's felt cost is the stumble, and the stumble ends at
            // the destination — so the chip lands seconds after arriving
            // there, when the wrong press is still in the fingers.
            if case .supersede(_, _, let target)? = rec.edit {
                return .app((rec.display ?? target).lowercased())
            }
            if case .bindTarget(_, let target)? = rec.edit {
                return .app((rec.display ?? target).lowercased())
            }
            return nil
        case .route: return .host(rec.target)
        case .meetings: return .meeting
        case .retire, .breath: return nil
        }
    }

    // MARK: - The chip

    public static func chip(for rec: Recommendation, observations: Observations) -> Chip {
        let accept: String
        let headline: String
        var evidence = rec.detail
        switch rec.kind {
        case .nudge,
             .rebind where rec.edit == nil,
             .breath where rec.edit == nil:
            // Report-only findings: the chip can only offer what it can
            // commit, so these point at the report instead.
            headline = rec.target
            accept = "see lodestar observations"
        case .breath:
            // The one accept that composes rather than writes: the apps
            // arrange side by side and the layout saves at the address.
            if case .composeBreath(_, let path)? = rec.edit {
                headline = "lode ' \(path.uppercased()) → \(rec.display ?? rec.target)"
            } else {
                headline = rec.target
            }
            accept = "tap lode twice to save them side by side"
        case .bind, .shorten, .rebind:
            // Both land on "the address you will type next", which for a
            // supersede is the new chain rather than the one being given
            // up — the chip names the gain, not the loss.
            let landing: (chain: [String], target: String)?
            switch rec.edit {
            case .bindTarget(let chain, let target): landing = (chain, target)
            case .supersede(_, let new, let target): landing = (new, target)
            default: landing = nil
            }
            if let (chain, target) = landing {
                let shown = chain.map { $0.uppercased() }.joined(separator: " ")
                // The label, never the config value: a chip saying
                // "lode X → brave:xonar" quotes the machinery at someone
                // who only ever asked for their browser.
                headline = "lode \(shown) → \(rec.display ?? target)"
            } else {
                headline = rec.target
            }
            // "bind" is honest for a bind and a lie for a supersede: the
            // old address stops working, and a user who was told only that
            // something was being added did not agree to that. The verb
            // matches the one the old address will use when it is pressed
            // afterwards, so the two surfaces tell one story.
            if case .supersede? = rec.edit {
                accept = "tap lode twice to move it"
            } else {
                accept = "tap lode twice to bind it"
            }
            if rec.kind == .bind, let record = observations.apps[rec.target.lowercased()] {
                // The observed span, not the pruned week ring: the count is
                // lifetime, so the weeks beside it must be too, or the chip
                // tells a six-month user their history is twelve weeks old.
                let weeks = observations.observedWeeks(app: rec.target)
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
            // The same population the advisor priced: deliberate choices
            // only. Counting pass-throughs let the evidence contradict the
            // recommendation — or name "pass" as the winning profile.
            if let record = observations.hosts[rec.target],
               let (_, hits) = record.chosenProfiles.max(by: { $0.value < $1.value }) {
                let total = record.chosenProfiles.values.reduce(0, +)
                evidence = "opened there \(hits) of \(total) times"
                    + secondsClause(rec.secondsPerWeek)
            }
            accept = "tap lode twice to add the route"
        case .meetings:
            headline = "meetings at the door"
            evidence = rec.detail + secondsClause(rec.secondsPerWeek)
            accept = "tap lode twice to turn it on"
        }
        return Chip(headline: headline, evidence: evidence,
                    footer: "\(accept) · lode ⌫ not this one · fades on its own")
    }

    private static func secondsClause(_ secondsPerWeek: Double) -> String {
        guard secondsPerWeek >= 5 else { return "" }
        return " · about \(Int(secondsPerWeek.rounded())) seconds a week"
    }
}
