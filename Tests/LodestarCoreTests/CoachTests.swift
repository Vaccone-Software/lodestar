import XCTest
@testable import LodestarCore

/// The coach's policy: one habit at a time, paced by demonstrated
/// capacity, every "no" remembered and none forever. These tests are the
/// contract that keeps the coach a coach and not a nag.
final class CoachTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func later(_ weeks: Int = 0, _ seconds: TimeInterval = 0) -> Date {
        start.addingTimeInterval(Double(weeks) * 604_800 + seconds)
    }

    private func bindRec(_ app: String = "facetime", slot: String = "f",
                         seconds: Double = 45, probability: Double = 0.95)
        -> Recommendation {
        Recommendation(kind: .bind, target: app,
                       detail: "\(app) is searched often", secondsPerWeek: seconds,
                       probability: probability, evidence: [],
                       edit: .bindTarget(chain: [slot], target: app))
    }

    private func routeRec(seconds: Double = 12) -> Recommendation {
        Recommendation(kind: .route, target: "github.com",
                       detail: "always lands in work", secondsPerWeek: seconds,
                       probability: 0.9, evidence: [],
                       edit: .addRoute(pattern: "github.com", profileKey: "work"))
    }

    private func coachEvent(action: String, rec: Recommendation, at date: Date)
        -> ObservationEvent {
        var event = ObservationEvent(t: date, kind: .coach)
        event.action = action
        event.rec = rec.kind.rawValue
        event.app = rec.target
        event.seconds = rec.secondsPerWeek
        if case .bindTarget(let chain, _)? = rec.edit {
            event.address = Observations.key(chain)
        }
        return event
    }

    // MARK: - Selection

    func testTheDebutWaitsForAClearlyStrongFinding() {
        let o = Observations()
        let weak = bindRec("music", slot: "m", seconds: 10)
        XCTAssertNil(Coach.standingOffer(observations: o, recommendations: [weak],
                                         now: start),
                     "the first appearance sets the channel's reputation")
        let strong = bindRec(seconds: 45)
        XCTAssertEqual(Coach.standingOffer(observations: o,
                                           recommendations: [weak, strong],
                                           now: start)?.target, "facetime")
    }

    func testReportOnlyKindsNeverReachTheChip() {
        let o = Observations()
        let nudge = Recommendation(kind: .nudge, target: "slack",
                                   detail: "use the address", secondsPerWeek: 100,
                                   probability: 0.99, evidence: [])
        XCTAssertNil(Coach.standingOffer(observations: o, recommendations: [nudge],
                                         now: start),
                     "the chip only offers what one config line can commit")
    }

    func testTheBestOfferWinsByValueTimesConfidence() {
        var o = Observations()
        // Past the debut: something was offered before.
        o.apply(coachEvent(action: "offered", rec: routeRec(), at: later(-8)))
        let small = routeRec(seconds: 12)
        let big = bindRec(seconds: 60)
        XCTAssertEqual(Coach.standingOffer(observations: o,
                                           recommendations: [small, big],
                                           now: start)?.target, "facetime")
    }

    // MARK: - One habit at a time

    func testAnAcceptedBindOccupiesTheSlotUntilItsCurveBends() {
        var o = Observations()
        let rec = bindRec()
        o.apply(coachEvent(action: "offered", rec: rec, at: start))
        o.apply(coachEvent(action: "accepted", rec: rec, at: start))
        XCTAssertTrue(Coach.slotBusy(observations: o, now: later(1)))
        let next = bindRec("music", slot: "m", seconds: 50)
        XCTAssertNil(Coach.standingOffer(observations: o, recommendations: [next],
                                         now: later(1)),
                     "one habit at a time — interference is real")
        // The hand compiles the address: fifteen blind uses later the
        // slot frees.
        for _ in 0..<Coach.bentCompletions {
            var chain = ObservationEvent(t: later(1), kind: .chain)
            chain.chain = ["f"]
            chain.gaps = [0.2]
            o.apply(chain)
        }
        XCTAssertFalse(Coach.slotBusy(observations: o, now: later(1)))
        XCTAssertEqual(Coach.standingOffer(observations: o, recommendations: [next],
                                           now: later(1))?.target, "music",
                       "pace is gated by demonstrated capacity, not a calendar")
    }

    func testAStalledHabitStopsBlockingTheQueue() {
        var o = Observations()
        let rec = bindRec()
        o.apply(coachEvent(action: "offered", rec: rec, at: start))
        o.apply(coachEvent(action: "accepted", rec: rec, at: start))
        XCTAssertTrue(Coach.slotBusy(observations: o, now: later(1)))
        XCTAssertFalse(Coach.slotBusy(observations: o, now: later(Coach.stallWeeks)),
                       "an unlearned habit is a fact, not a dam")
    }

    func testARouteNeedsNoLearningAndFreesTheSlotInstantly() {
        var o = Observations()
        let rec = routeRec()
        o.apply(coachEvent(action: "offered", rec: rec, at: start))
        o.apply(coachEvent(action: "accepted", rec: rec, at: start))
        XCTAssertFalse(Coach.slotBusy(observations: o, now: later(0, 60)))
    }

    // MARK: - Cooldowns and declines

    func testAnUnansweredOfferKeepsStandingForTheMenu() {
        var o = Observations()
        let rec = bindRec()
        o.apply(coachEvent(action: "offered", rec: rec, at: start))
        XCTAssertEqual(Coach.standingOffer(observations: o, recommendations: [rec],
                                           now: later(0, 3600))?.target, "facetime",
                       "a missed chip parks in the menu; it does not evaporate")
    }

    func testTheMomentGatePacesShowingsNotTheSlot() {
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceOffered: 3600)), .offerQuiet,
                       "two chips never share a day")
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceOffered: 90_000,
                                               sinceThisOffered: 90_000,
                                               channelOffers: 2, thisOffers: 1)),
                       .retryCooldown,
                       "the same suggestion waits out its own cooldown")
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceOffered: 3 * 86_400,
                                               sinceThisOffered: 3 * 86_400,
                                               channelOffers: 2, thisOffers: 1)),
                       .speak)
    }

    func testAnAnswerBuysDaysOfQuietEitherWayItWent() {
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceAnswered: 86_400)), .answerQuiet,
                       "an accept is consolidating and a no deserves its silence")
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceAnswered: 4 * 86_400)), .speak)
    }

    func testTheDebutAloneRetriesADaySooner() {
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceOffered: 90_000,
                                               sinceThisOffered: 90_000,
                                               channelOffers: 1, thisOffers: 1)),
                       .speak,
                       "the first chip ever is the likeliest missed outright")
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceOffered: 90_000,
                                               sinceThisOffered: 90_000,
                                               channelOffers: 2, thisOffers: 1)),
                       .retryCooldown,
                       "past the debut the ordinary cooldown holds")
    }

    func testTheSameSuggestionRetriesThenParksThenReturns() {
        var o = Observations()
        let rec = bindRec()
        for offer in 0..<Coach.maxOffers {
            o.apply(coachEvent(action: "offered", rec: rec,
                               at: later(0, Double(offer) * 4 * 86_400)))
        }
        let afterThird = later(0, 3 * 4 * 86_400 + 4 * 86_400)
        XCTAssertNil(Coach.standingOffer(observations: o, recommendations: [rec],
                                         now: afterThird),
                     "three unanswered offers park the suggestion")
        XCTAssertNotNil(Coach.standingOffer(observations: o, recommendations: [rec],
                                            now: later(Coach.parkedSleepWeeks + 1)),
                        "parked, not buried — quiet time re-opens it")
        let outgrown = bindRec(seconds: rec.secondsPerWeek * 2)
        XCTAssertNotNil(Coach.standingOffer(observations: o,
                                            recommendations: [outgrown],
                                            now: afterThird),
                        "or the evidence outgrows the silence sooner")
    }

    func testNeverSleepsLongAndWakesOnlyForStrongerEvidence() {
        var o = Observations()
        let rec = bindRec()
        o.apply(coachEvent(action: "offered", rec: rec, at: start))
        o.apply(coachEvent(action: "never", rec: rec, at: start))
        XCTAssertNil(Coach.standingOffer(observations: o, recommendations: [rec],
                                         now: later(4)),
                     "no means no for a season")
        XCTAssertNotNil(Coach.standingOffer(observations: o, recommendations: [rec],
                                            now: later(Coach.neverSleepWeeks + 1)),
                        "but the data kept moving, so the season ends")
        let doubled = bindRec(seconds: rec.secondsPerWeek * 2.5)
        XCTAssertNotNil(Coach.standingOffer(observations: o, recommendations: [doubled],
                                            now: later(4)),
                        "or the world changed enough to ask again")
    }

    func testAnAcceptedSuggestionIsNeverOfferedAgain() {
        var o = Observations()
        let rec = routeRec()
        o.apply(coachEvent(action: "offered", rec: rec, at: start))
        o.apply(coachEvent(action: "accepted", rec: rec, at: start))
        XCTAssertNil(Coach.standingOffer(observations: o, recommendations: [rec],
                                         now: later(2)))
    }

    // MARK: - Cues

    func testCuesNameTheMomentTheCostWasFelt() {
        XCTAssertEqual(Coach.cue(for: bindRec()), .app("facetime"))
        XCTAssertEqual(Coach.cue(for: routeRec()), .host("github.com"))
        let retire = Recommendation(kind: .retire, target: "q",
                                    detail: "never typed", secondsPerWeek: 0,
                                    probability: 0.95, evidence: [],
                                    edit: .removeChain(chain: ["q"]))
        XCTAssertNil(Coach.cue(for: retire), "no cue exists and none is needed")
    }

    // MARK: - The chip

    func testChipCopyIsExperientialAndHyphenFree() {
        var o = Observations()
        var reach = ObservationEvent(t: start, kind: .reach)
        reach.app = "facetime"
        reach.route = "searcher"
        reach.typed = 3
        for _ in 0..<31 { o.apply(reach) }
        let chip = Coach.chip(for: bindRec(seconds: 40), observations: o)
        XCTAssertEqual(chip.headline, "lode F → facetime")
        XCTAssertTrue(chip.evidence.contains("you searched for it 31 times"),
                      "the user can verify every clause from experience")
        XCTAssertTrue(chip.evidence.contains("about 40 seconds a week"))
        XCTAssertTrue(chip.footer.contains("tap lode twice"))
        for line in [chip.headline, chip.evidence, chip.footer] {
            XCTAssertFalse(line.contains("—"), "no dashes in the coach's voice")
            XCTAssertFalse(line.contains(" - "))
        }
    }

    func testRetireChipSaysWhatItFrees() {
        let retire = Recommendation(kind: .retire, target: "q",
                                    detail: "never typed", secondsPerWeek: 0,
                                    probability: 0.95, evidence: [],
                                    edit: .removeChain(chain: ["q"]))
        let chip = Coach.chip(for: retire, observations: Observations())
        XCTAssertEqual(chip.headline, "retire lode Q")
        XCTAssertTrue(chip.footer.contains("to retire it"))
    }
}

/// The assent gesture: two quick taps of lode, nothing else.
final class LodeTapTests: XCTestCase {
    func testTwoQuickTapsFire() {
        var detector = LodeTapDetector()
        XCTAssertFalse(detector.lodeChanged(held: true, at: 0))
        XCTAssertFalse(detector.lodeChanged(held: false, at: 0.1))
        XCTAssertFalse(detector.lodeChanged(held: true, at: 0.3))
        XCTAssertTrue(detector.lodeChanged(held: false, at: 0.4))
    }

    func testAHoldIsThePeekNotATap() {
        var detector = LodeTapDetector()
        _ = detector.lodeChanged(held: true, at: 0)
        XCTAssertFalse(detector.lodeChanged(held: false, at: 0.6), "held too long")
        _ = detector.lodeChanged(held: true, at: 0.7)
        XCTAssertFalse(detector.lodeChanged(held: false, at: 0.8),
                       "a hold voids the sequence; the next tap starts fresh")
    }

    func testAKeystrokeMakesItAChainAndPoisonsTheGesture() {
        var detector = LodeTapDetector()
        _ = detector.lodeChanged(held: true, at: 0)
        detector.keyDown() // lode G — a summon, not a tap
        XCTAssertFalse(detector.lodeChanged(held: false, at: 0.1))
        _ = detector.lodeChanged(held: true, at: 0.2)
        XCTAssertFalse(detector.lodeChanged(held: false, at: 0.3),
                       "the poisoned press never counts as the first tap")
    }

    func testTapsOutsideTheWindowAreTwoSeparateThoughts() {
        var detector = LodeTapDetector()
        _ = detector.lodeChanged(held: true, at: 0)
        _ = detector.lodeChanged(held: false, at: 0.1)
        _ = detector.lodeChanged(held: true, at: 1.0)
        XCTAssertFalse(detector.lodeChanged(held: false, at: 1.1))
    }

    func testFlagBounceCannotFabricateTaps() {
        var detector = LodeTapDetector()
        // The shim's chord can arrive as several flagsChanged with lode
        // still classified held — repeated same-state calls are one press.
        XCTAssertFalse(detector.lodeChanged(held: true, at: 0))
        XCTAssertFalse(detector.lodeChanged(held: true, at: 0.01))
        XCTAssertFalse(detector.lodeChanged(held: true, at: 0.02))
        XCTAssertFalse(detector.lodeChanged(held: false, at: 0.1))
        XCTAssertFalse(detector.lodeChanged(held: false, at: 0.11),
                       "a release with no press pending is noise")
        _ = detector.lodeChanged(held: true, at: 0.2)
        XCTAssertTrue(detector.lodeChanged(held: false, at: 0.3))
    }

    func testThirdTapStartsANewSequence() {
        var detector = LodeTapDetector()
        _ = detector.lodeChanged(held: true, at: 0)
        _ = detector.lodeChanged(held: false, at: 0.1)
        _ = detector.lodeChanged(held: true, at: 0.2)
        XCTAssertTrue(detector.lodeChanged(held: false, at: 0.3))
        _ = detector.lodeChanged(held: true, at: 0.4)
        XCTAssertFalse(detector.lodeChanged(held: false, at: 0.5),
                       "firing consumes both taps — no chaining a third into a second fire")
    }
}
