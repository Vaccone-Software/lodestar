import XCTest
@testable import LodestarCore

/// What the coach is worth interrupting for, and how long it waits after
/// being ignored.
///
/// Both of these were unmeasured corners of the curriculum. There was a
/// floor on the debut and none afterwards, so a finding worth five minutes
/// a year drew the same three chips as one worth three minutes a week. And
/// the retry leash was priced on the assumption that an unanswered chip
/// had probably never been readable — true while chips were being erased
/// by the next chain, false the moment that was fixed.
final class CoachPacingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func shortenRec(_ target: String, seconds: Double,
                            probability: Double = 0.97) -> Recommendation {
        Recommendation(kind: .shorten, target: target,
                       detail: "\(target) has earned a shorter address",
                       secondsPerWeek: seconds, probability: probability,
                       evidence: [],
                       edit: .bindTarget(chain: ["x"], target: "brave (xonar)"))
    }

    private func observations(_ entries: [Observations.LedgerEntry]) -> Observations {
        var o = Observations()
        o.ledger = entries
        return o
    }

    // MARK: - The standing floor

    /// The regression this exists to prevent: a statistically certain
    /// finding worth six seconds a week is still not worth a chip.
    func testATrivialSuggestionIsNeverOffered() {
        let rec = shortenRec("e p", seconds: 6, probability: 1.0)
        XCTAssertNil(Coach.standingOffer(observations: observations([]),
                                         recommendations: [rec], now: start))
    }

    func testTheFloorAppliesLongAfterTheDebut() {
        // A channel with offers behind it is past its debut, so only the
        // standing floor is left to do the work.
        let spent = Observations.LedgerEntry(
            id: "shorten:v z", kind: "shorten", target: "v z",
            predictedSecondsPerWeek: 40, firstOfferedWeek: 2950,
            lastOfferedWeek: 2950, offers: 3, status: "offered")
        let rec = shortenRec("e p", seconds: 6)
        XCTAssertNil(Coach.standingOffer(observations: observations([spent]),
                                         recommendations: [rec], now: start))
    }

    func testAWorthwhileSuggestionStillStands() {
        let rec = shortenRec("b x", seconds: 171)
        XCTAssertEqual(Coach.standingOffer(observations: observations([]),
                                           recommendations: [rec], now: start)?.target,
                       "b x")
    }

    /// The debut floor is the higher of the two and still governs the
    /// first offer, so clearing the standing floor alone is not enough.
    func testTheDebutStillWantsMoreThanTheFloor() {
        let rec = shortenRec("v z", seconds: 20)
        XCTAssertGreaterThan(rec.secondsPerWeek, Coach.offerFloorSecondsPerWeek)
        XCTAssertLessThan(rec.secondsPerWeek, Coach.debutFloorSecondsPerWeek)
        XCTAssertNil(Coach.standingOffer(observations: observations([]),
                                         recommendations: [rec], now: start))
    }

    /// A retirement carries `secondsPerWeek: 0` — not because it is
    /// worthless but because its worth is a freed letter, which the
    /// seconds floor cannot read. Judging it by that floor silenced every
    /// retirement the advisor could ever make.
    func testARetirementIsNotJudgedByTheSecondsFloor() {
        let retire = Recommendation(
            kind: .retire, target: "q w",
            detail: "lode Q W has never been typed",
            secondsPerWeek: 0, probability: 0.95, evidence: [],
            edit: .removeChain(chain: ["q", "w"]))
        // Past the debut, where the higher bar no longer applies.
        let spent = Observations.LedgerEntry(
            id: "shorten:v z", kind: "shorten", target: "v z",
            predictedSecondsPerWeek: 40, firstOfferedWeek: 2950,
            lastOfferedWeek: 2950, offers: 3, status: "offered")
        XCTAssertEqual(Coach.standingOffer(observations: observations([spent]),
                                           recommendations: [retire], now: start)?.kind,
                       .retire)
    }

    func testTheFloorSitsBelowTheDebutBar() {
        XCTAssertLessThan(Coach.offerFloorSecondsPerWeek, Coach.debutFloorSecondsPerWeek)
    }

    // MARK: - The leash after a chip that stood

    func testAChipThatStoodItsWholeLifeGetsTheLongLeash() {
        XCTAssertEqual(Coach.retryDays(channelOffers: 4, thisOffers: 2, stoodFull: true),
                       Coach.ignoredRetryDays)
    }

    func testAChipTakenEarlyKeepsTheShortLeash() {
        XCTAssertEqual(Coach.retryDays(channelOffers: 4, thisOffers: 2, stoodFull: false),
                       Coach.retryCooldownDays)
    }

    /// The debut's shortcut exists because a first chip is the one most
    /// likely to be missed outright. A chip that held the glass for a full
    /// minute was not missed, so the shortcut has nothing left to correct.
    func testAFullStandingOverridesTheDebutShortcut() {
        XCTAssertEqual(Coach.retryDays(channelOffers: 1, thisOffers: 1, stoodFull: true),
                       Coach.ignoredRetryDays)
        XCTAssertEqual(Coach.retryDays(channelOffers: 1, thisOffers: 1, stoodFull: false),
                       Coach.debutRetryDays)
    }

    func testBeingIgnoredBuysMoreQuietThanBeingMissed() {
        XCTAssertGreaterThan(Coach.ignoredRetryDays, Coach.retryCooldownDays)
        XCTAssertGreaterThan(Coach.ignoredRetryDays, Coach.debutRetryDays)
    }

    /// The gate has to read the flag, not just carry it.
    func testTheMomentGateHoldsAnIgnoredSuggestionLonger() {
        let twoAndAHalfDays: TimeInterval = 2.5 * 86_400
        let stood = Coach.Moment(sinceThisOffered: twoAndAHalfDays,
                                 channelOffers: 4, thisOffers: 2, thisStoodFull: true)
        XCTAssertEqual(Coach.hold(stood), .retryCooldown)

        let missed = Coach.Moment(sinceThisOffered: twoAndAHalfDays,
                                  channelOffers: 4, thisOffers: 2, thisStoodFull: false)
        XCTAssertEqual(Coach.hold(missed), .speak)
    }

    // MARK: - The ledger remembers which it was

    func testAFullStandingIsRecordedWithoutAnsweringTheOffer() {
        var o = Observations()
        let rec = shortenRec("b x", seconds: 171)
        var offered = ObservationEvent(t: start, kind: .coach)
        offered.action = "offered"
        offered.rec = rec.kind.rawValue
        offered.app = rec.target
        offered.seconds = rec.secondsPerWeek
        o.apply(offered)

        var ignored = ObservationEvent(t: start.addingTimeInterval(60), kind: .coach)
        ignored.action = "ignored"
        ignored.rec = rec.kind.rawValue
        ignored.app = rec.target
        o.apply(ignored)

        let entry = o.ledger.first { $0.id == "shorten:b x" }
        XCTAssertEqual(entry?.lastShowingStood, true)
        XCTAssertEqual(entry?.ignores, 1)
        // Still on offer: being passed over is not a decline, and it must
        // not spend an offer or stamp an answer.
        XCTAssertEqual(entry?.status, "offered")
        XCTAssertEqual(entry?.offers, 1)
        XCTAssertNil(entry?.lastAnsweredAt)
    }

    /// The flag describes the most recent showing, never the history — a
    /// new chip has not stood yet however the last one ended.
    func testANewShowingClearsTheFlag() {
        var o = Observations()
        for (offset, action) in [(0.0, "offered"), (60.0, "ignored"), (86_400.0, "offered")] {
            var event = ObservationEvent(t: start.addingTimeInterval(offset), kind: .coach)
            event.action = action
            event.rec = "shorten"
            event.app = "b x"
            event.seconds = 171
            o.apply(event)
        }
        let entry = o.ledger.first { $0.id == "shorten:b x" }
        XCTAssertEqual(entry?.lastShowingStood, false)
        XCTAssertEqual(entry?.ignores, 1, "the count is history and survives")
        XCTAssertEqual(entry?.offers, 2)
    }

    // MARK: - Track record buying airtime

    /// The two channel quiets scale with the kind's record. Only those
    /// two: the evidence gates and the per-suggestion retry leash keep
    /// the book rate, because they price different things.
    func testAProvenKindWaitsOutShorterQuiets() {
        var moment = Coach.Moment(sinceAnswered: 2 * 86_400)
        XCTAssertEqual(Coach.hold(moment), .answerQuiet, "book rate: three days of quiet")
        moment.pacingScale = 0.5
        XCTAssertEqual(Coach.hold(moment), .speak,
                       "a proven kind is through in a day and a half")
    }

    func testALosingKindWaitsLonger() {
        var moment = Coach.Moment(sinceAnswered: 3.5 * 86_400)
        XCTAssertEqual(Coach.hold(moment), .speak)
        moment.pacingScale = 1.5
        XCTAssertEqual(Coach.hold(moment), .answerQuiet,
                       "the coach's response to no is to get quieter, not louder")
    }

    func testPacingScaleReadsTheLedger() {
        // Untried: the two-trial prior alone, so the book rate holds.
        XCTAssertEqual(Coach.pacingScale(observations: observations([]),
                                         kind: .shorten, now: start), 1.0, accuracy: 0.001)
        // A "never" is a loss; the kind waits longer for its next ask.
        let never = Observations.LedgerEntry(
            id: "shorten:b x", kind: "shorten", target: "b x",
            predictedSecondsPerWeek: 40, firstOfferedWeek: 0,
            lastOfferedWeek: 0, offers: 1, status: "never", neverWeek: 0)
        XCTAssertGreaterThan(Coach.pacingScale(observations: observations([never]),
                                               kind: .shorten, now: start), 1.0)
        // An accept whose curve bent is a win; the kind earns airtime.
        var o = observations([Observations.LedgerEntry(
            id: "shorten:b x", kind: "shorten", target: "b x", chain: "x",
            predictedSecondsPerWeek: 40, firstOfferedWeek: 0,
            lastOfferedWeek: 0, offers: 1, status: "accepted",
            acceptedWeek: Observations.week(start))])
        for i in 0..<Coach.bentCompletions {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i)),
                                         kind: .chain)
            event.chain = ["x"]
            event.gaps = [0.3]
            o.apply(event)
        }
        XCTAssertLessThan(Coach.pacingScale(observations: o, kind: .shorten, now: start),
                          1.0)
    }

    /// The report's clock and the moment gate read the same scale, so the
    /// two can never disagree about when a proven kind may speak.
    func testShowingWaitScalesWithTheKindsRecord() {
        var o = observations([Observations.LedgerEntry(
            id: "shorten:b x", kind: "shorten", target: "b x", chain: "x",
            predictedSecondsPerWeek: 40, firstOfferedWeek: 0,
            lastOfferedWeek: 0, offers: 1, status: "accepted",
            acceptedWeek: Observations.week(start),
            // A day ago, not two: that one accept also opens a run, which
            // halves every quiet, and the proven kind's must still be
            // running for the comparison to say anything.
            lastAnsweredAt: start.addingTimeInterval(-1 * 86_400))])
        for i in 0..<Coach.bentCompletions {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i)),
                                         kind: .chain)
            event.chain = ["x"]
            event.gaps = [0.3]
            o.apply(event)
        }
        let proven = Coach.showingWait(observations: o,
                                       rec: shortenRec("e p", seconds: 171), now: start)
        let untried = Coach.showingWait(
            observations: o,
            rec: Recommendation(kind: .route, target: "github.com", detail: "",
                                secondsPerWeek: 40, probability: 0.95, evidence: [],
                                edit: .addRoute(pattern: "github.com", profileKey: "work")),
            now: start)
        XCTAssertLessThan(proven, untried,
                          "the kind with a bent curve behind it waits out less of the quiet")
    }

    // MARK: - Acceptance buys airtime

    private func answered(_ id: String, kind: String, status: String, at: Date) -> Observations.LedgerEntry {
        var entry = Observations.LedgerEntry(
            id: id, kind: kind, target: String(id.split(separator: ":").last ?? ""),
            predictedSecondsPerWeek: 40, firstOfferedWeek: Observations.week(at),
            lastOfferedWeek: Observations.week(at), offers: 1, status: status,
            acceptedWeek: status == "accepted" ? Observations.week(at) : nil,
            neverWeek: status == "never" ? Observations.week(at) : nil)
        entry.lastAnsweredAt = at
        return entry
    }

    func testEachAcceptInARowHalvesTheQuiets() {
        let day = 86_400.0
        let two = observations([
            answered("breath:a + b", kind: "breath", status: "accepted", at: start.addingTimeInterval(-3 * day)),
            answered("breath:c + d", kind: "breath", status: "accepted", at: start.addingTimeInterval(-1 * day)),
        ])
        XCTAssertEqual(Coach.acceptStreak(observations: two), 2)
        XCTAssertEqual(Coach.pacingScale(observations: two, kind: .shorten, now: start),
                       0.25, accuracy: 0.001, "two accepts: a quarter of the book rate")
        let three = observations([
            answered("breath:a + b", kind: "breath", status: "accepted", at: start.addingTimeInterval(-3 * day)),
            answered("breath:c + d", kind: "breath", status: "accepted", at: start.addingTimeInterval(-2 * day)),
            answered("breath:e + f", kind: "breath", status: "accepted", at: start.addingTimeInterval(-1 * day)),
            answered("breath:g + h", kind: "breath", status: "accepted", at: start.addingTimeInterval(-0.5 * day)),
        ])
        XCTAssertEqual(Coach.pacingScale(observations: three, kind: .shorten, now: start),
                       0.125, accuracy: 0.001, "an eighth is the floor, however long the run")
    }

    func testOneNoPutsTheBookRateBack() {
        let day = 86_400.0
        let o = observations([
            answered("breath:a + b", kind: "breath", status: "accepted", at: start.addingTimeInterval(-3 * day)),
            answered("breath:c + d", kind: "breath", status: "accepted", at: start.addingTimeInterval(-2 * day)),
            answered("shorten:b x", kind: "shorten", status: "never", at: start.addingTimeInterval(-1 * day)),
        ])
        XCTAssertEqual(Coach.acceptStreak(observations: o), 0, "the newest answer was a no")
        // The kind's own record still buys what it bought; only the run's
        // halving is gone.
        XCTAssertEqual(Coach.pacingScale(observations: o, kind: .breath, now: start),
                       2.0 - Coach.kindWeight(observations: o, kind: .breath, now: start),
                       accuracy: 0.001)
        XCTAssertEqual(Coach.streakScale(observations: o), 1.0)
    }

    func testUndatedAnswersDoNotCountInTheRun() {
        let undated = Observations.LedgerEntry(
            id: "breath:a + b", kind: "breath", target: "a + b",
            predictedSecondsPerWeek: 40, firstOfferedWeek: 0, lastOfferedWeek: 0,
            offers: 1, status: "accepted", acceptedWeek: 0)
        XCTAssertEqual(Coach.acceptStreak(observations: observations([undated])), 0)
    }
}
