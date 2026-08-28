import XCTest
@testable import LodestarCore

/// The coach's new powers: the rebind that follows the hand's own errors
/// to an edit, the breath that composes, and the curriculum scoring its
/// own kinds by what actually bent.
final class CoachPowersTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func wrongKey(_ prefix: [String], pressed: String, at t: Date)
        -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .wrongKey)
        event.chain = prefix
        event.pressed = pressed
        return event
    }

    private func completed(_ chain: [String], at t: Date) -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .chain)
        event.chain = chain
        event.gaps = [0.3]
        return event
    }

    private func reach(_ app: String, at t: Date) -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .reach)
        event.app = app
        event.route = "searcher"
        return event
    }

    // MARK: - Addressed names

    func testProfileLeavesCoverTheirBrowserApp() {
        let leaves = [Advisor.Leaf(chain: ["b", "x"], label: "Brave (Xonar)",
                                   value: "brave:Xonar")]
        let names = Advisor.addressedNames(leaves)
        XCTAssertTrue(names.contains("brave (xonar)"))
        XCTAssertTrue(names.contains("brave browser"),
                      "the launcher reaches the app name, so the app name is addressed")
    }

    // MARK: - Chain availability

    func testChainFreeSeesEveryCollision() {
        let leaves = [Advisor.Leaf(chain: ["b", "g"], label: "A", value: "A"),
                      Advisor.Leaf(chain: ["x"], label: "B", value: "B")]
        XCTAssertFalse(Advisor.chainFree(["b", "g"], leaves: leaves), "equal")
        XCTAssertFalse(Advisor.chainFree(["b"], leaves: leaves), "stands over a leaf")
        XCTAssertFalse(Advisor.chainFree(["x", "y"], leaves: leaves), "sits under a leaf")
        XCTAssertTrue(Advisor.chainFree(["g"], leaves: leaves))
        XCTAssertTrue(Advisor.chainFree(["b", "g"], leaves: leaves, ignoring: ["b", "g"]),
                      "the leaf a supersede removes does not collide")
    }

    // MARK: - Rebind becomes an edit

    private func rebindContext(recoveringTo follower: (Date) -> ObservationEvent,
                               leaves: [Advisor.Leaf]) -> Advisor.Context {
        var o = Observations()
        var events: [ObservationEvent] = []
        for i in 0..<6 {
            let t = start.addingTimeInterval(Double(i) * 100)
            let wrong = wrongKey([], pressed: "g", at: t)
            o.apply(wrong)
            events.append(wrong)
            events.append(follower(t.addingTimeInterval(2)))
        }
        return Advisor.Context(observations: o, events: events, leaves: leaves,
                               meetingsEnabled: false, now: start.addingTimeInterval(7 * 86_400))
    }

    func testErrorsBecomeASupersedeProposal() {
        // The hand presses G at the top level, then completes lode B G:
        // the errors propose moving that leaf to the address being pressed.
        let leaves = [Advisor.Leaf(chain: ["b", "g"], label: "Ghostty", value: "Ghostty")]
        let context = rebindContext(recoveringTo: { self.completed(["b", "g"], at: $0) },
                                    leaves: leaves)
        let candidate = Advisor.rebindCandidates(context).first
        XCTAssertEqual(candidate?.rec.edit,
                       .supersede(old: ["b", "g"], new: ["g"], target: "Ghostty"))
        XCTAssertEqual(candidate?.rec.display, "Ghostty")
        XCTAssertTrue(candidate?.rec.detail.contains("lode G") ?? false)
    }

    func testLauncherRecoveriesProposeABind() {
        // Same stumbles, but the recovery is a launcher search for an app
        // with no address at all: bind it where the hand already presses.
        let context = rebindContext(recoveringTo: { self.reach("ghostty", at: $0) },
                                    leaves: [])
        let candidate = Advisor.rebindCandidates(context).first
        XCTAssertEqual(candidate?.rec.edit,
                       .bindTarget(chain: ["g"], target: "ghostty"))
    }

    func testScatteredRecoveriesStayReportOnly() {
        var o = Observations()
        var events: [ObservationEvent] = []
        for i in 0..<6 {
            let t = start.addingTimeInterval(Double(i) * 100)
            let wrong = wrongKey([], pressed: "g", at: t)
            o.apply(wrong)
            events.append(wrong)
            // Recoveries split three ways: no destination dominates.
            events.append(completed([["b", "g"], ["x"], ["y"]][i % 3], at: t.addingTimeInterval(2)))
        }
        let context = Advisor.Context(
            observations: o, events: events,
            leaves: [Advisor.Leaf(chain: ["b", "g"], label: "Ghostty", value: "Ghostty")],
            meetingsEnabled: false, now: start.addingTimeInterval(7 * 86_400))
        XCTAssertNil(Advisor.rebindCandidates(context).first?.rec.edit,
                     "an edit needs a destination the recoveries agree on")
    }

    func testAnOccupiedAddressStaysReportOnly() {
        // G is already someone else's leaf, so the proposal cannot bind.
        let leaves = [Advisor.Leaf(chain: ["b", "g"], label: "Ghostty", value: "Ghostty"),
                      Advisor.Leaf(chain: ["g"], label: "Gmail", value: "Gmail")]
        let context = rebindContext(recoveringTo: { self.completed(["b", "g"], at: $0) },
                                    leaves: leaves)
        XCTAssertNil(Advisor.rebindCandidates(context).first?.rec.edit)
    }

    // MARK: - Breath composes

    private func breathContext(paths: [String]) -> Advisor.Context {
        var o = Observations()
        o.transitions = ["ghostty": ["brave browser": 30],
                         "brave browser": ["ghostty": 25]]
        return Advisor.Context(observations: o, events: [], leaves: [],
                               meetingsEnabled: false, breathPaths: paths, now: start)
    }

    func testBreathOfferComposesAtAFreeLetter() {
        let candidate = Advisor.breathCandidates(breathContext(paths: [])).first
        XCTAssertEqual(candidate?.offerable, true)
        guard case .composeBreath(let apps, let path)? = candidate?.rec.edit else {
            return XCTFail("a breath offer carries its compose")
        }
        XCTAssertEqual(Set(apps), Set(["ghostty", "brave browser"]))
        XCTAssertEqual(path, "g", "the mnemonic letter comes first")
    }

    func testBreathLetterAvoidsTakenPathsAndB() {
        // g taken; brave's mnemonic is b, which the breath grammar
        // reserves — so the letter walks on to the alphabet.
        let candidate = Advisor.breathCandidates(breathContext(paths: ["g"])).first
        guard case .composeBreath(_, let path)? = candidate?.rec.edit else {
            return XCTFail("still offerable at another letter")
        }
        XCTAssertEqual(path, "a")
    }

    func testBreathChipNamesTheAddressAndTheCompose() {
        guard let rec = Advisor.breathCandidates(breathContext(paths: [])).first?.rec else {
            return XCTFail()
        }
        let chip = Coach.chip(for: rec, observations: Observations())
        XCTAssertTrue(chip.headline.contains("lode ' G"), chip.headline)
        XCTAssertTrue(chip.footer.contains("save them side by side"), chip.footer)
    }

    // MARK: - Chip and cue for the rebind edit

    func testRebindChipSaysMove() {
        let rec = Recommendation(
            kind: .rebind, target: "b g", detail: "detail", secondsPerWeek: 30,
            probability: 0.9, evidence: [], display: "Ghostty",
            edit: .supersede(old: ["b", "g"], new: ["g"], target: "Ghostty"))
        let chip = Coach.chip(for: rec, observations: Observations())
        XCTAssertEqual(chip.headline, "lode G → Ghostty")
        XCTAssertTrue(chip.footer.contains("move it"),
                      "consent language: the old address stops working")
        XCTAssertEqual(Coach.cue(for: rec), .app("ghostty"))
    }

    func testReportOnlyRebindStillPointsAtTheReport() {
        let rec = Recommendation(kind: .rebind, target: "b g", detail: "detail",
                                 secondsPerWeek: 30, probability: 0.9, evidence: [])
        let chip = Coach.chip(for: rec, observations: Observations())
        XCTAssertTrue(chip.footer.contains("see lodestar observations"))
        XCTAssertNil(Coach.cue(for: rec))
    }

    // MARK: - The curriculum scores its kinds

    private func coachEvent(action: String, kind: String, target: String,
                            address: String?, at t: Date) -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .coach)
        event.action = action
        event.rec = kind
        event.app = target
        event.address = address
        event.seconds = 60
        return event
    }

    func testKindWeightRewardsBentAcceptsAndPunishesNevers() {
        var o = Observations()
        // A shorten that was accepted and whose new address bent.
        o.apply(coachEvent(action: "offered", kind: "shorten", target: "b g",
                           address: "g", at: start))
        o.apply(coachEvent(action: "accepted", kind: "shorten", target: "b g",
                           address: "g", at: start.addingTimeInterval(60)))
        for i in 0..<Coach.bentCompletions {
            var event = ObservationEvent(
                t: start.addingTimeInterval(Double(i + 2) * 60), kind: .chain)
            event.chain = ["g"]
            event.gaps = [0.3]
            o.apply(event)
        }
        // A bind that was declined outright.
        o.apply(coachEvent(action: "offered", kind: "bind", target: "slack",
                           address: "s", at: start))
        o.apply(coachEvent(action: "never", kind: "bind", target: "slack",
                           address: "s", at: start.addingTimeInterval(60)))
        let now = start.addingTimeInterval(30 * 86_400)
        let shorten = Coach.kindWeight(observations: o, kind: .shorten, now: now)
        let bind = Coach.kindWeight(observations: o, kind: .bind, now: now)
        let untried = Coach.kindWeight(observations: o, kind: .route, now: now)
        XCTAssertGreaterThan(shorten, untried)
        XCTAssertLessThan(bind, untried)
    }

    func testAYoungAcceptIsNeitherWinNorLoss() {
        var o = Observations()
        o.apply(coachEvent(action: "offered", kind: "shorten", target: "b g",
                           address: "g", at: start))
        o.apply(coachEvent(action: "accepted", kind: "shorten", target: "b g",
                           address: "g", at: start.addingTimeInterval(60)))
        // A week later, three completions: still learning.
        let now = start.addingTimeInterval(7 * 86_400)
        let weight = Coach.kindWeight(observations: o, kind: .shorten, now: now)
        XCTAssertEqual(weight, Coach.kindWeight(observations: o, kind: .route, now: now),
                       "an accept still inside its learning window scores nothing yet")
    }

    func testStandingOfferPrefersTheKindThatWorks() {
        var o = Observations()
        // Two declined routes: the kind has a record of being unwanted.
        for target in ["a.com", "b.com"] {
            o.apply(coachEvent(action: "offered", kind: "route", target: target,
                               address: nil, at: start))
            o.apply(coachEvent(action: "never", kind: "route", target: target,
                               address: nil, at: start.addingTimeInterval(60)))
        }
        let now = start.addingTimeInterval(120 * 86_400)
        let route = Recommendation(
            kind: .route, target: "c.com", detail: "d", secondsPerWeek: 60,
            probability: 0.95, evidence: [],
            edit: .addRoute(pattern: "c.com", profileKey: "brave:Work"))
        let bind = Recommendation(
            kind: .bind, target: "slack", detail: "d", secondsPerWeek: 60,
            probability: 0.95, evidence: [],
            edit: .bindTarget(chain: ["s"], target: "Slack"))
        let offer = Coach.standingOffer(observations: o,
                                        recommendations: [route, bind], now: now)
        XCTAssertEqual(offer?.kind, .bind,
                       "equal value, but route has twice said no — history breaks the tie")
    }
}
