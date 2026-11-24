import XCTest
@testable import LodestarCore

/// The guide's training wheels: the map paints immediately for anything
/// unlearned, waits its earned seconds over a bent subtree, and comes
/// straight back the moment the hand stumbles.
final class GuideFadeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// An observations view where `chain` has completed `times`.
    private func learned(_ chain: [String], times: Int) -> Observations {
        var o = Observations()
        complete(&o, chain, times: times)
        return o
    }

    private func complete(_ o: inout Observations, _ chain: [String], times: Int) {
        for i in 0..<times {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i)),
                                         kind: .chain)
            event.chain = chain
            event.gaps = [0.3]
            o.apply(event)
        }
    }

    func testFreshSubtreePaintsImmediately() {
        let fade = GuideFade()
        XCTAssertEqual(fade.delay(prefix: ["b"], leaves: [["b", "g"]],
                                  observations: Observations(), now: start), 0)
    }

    func testBentSubtreeEarnsTheFullWait() {
        let o = learned(["b", "g"], times: Coach.bentCompletions)
        let fade = GuideFade()
        XCTAssertEqual(fade.delay(prefix: ["b"], leaves: [["b", "g"]],
                                  observations: o, now: start),
                       GuideFade.maxSeconds, accuracy: 0.001)
    }

    func testTheWeakestLeafDecides() {
        var o = learned(["b", "g"], times: Coach.bentCompletions)
        complete(&o, ["b", "x"], times: 1)
        let fade = GuideFade()
        let delay = fade.delay(prefix: ["b"], leaves: [["b", "g"], ["b", "x"]],
                               observations: o, now: start)
        XCTAssertEqual(delay, 0,
                       "one address still learning keeps the whole subtree's map immediate")
    }

    func testAStumbleBringsTheMapBack() {
        let o = learned(["b", "g"], times: Coach.bentCompletions)
        var fade = GuideFade()
        fade.stumbled(prefix: ["b"], at: start)
        XCTAssertEqual(fade.delay(prefix: ["b"], leaves: [["b", "g"]],
                                  observations: o, now: start.addingTimeInterval(60)), 0)
        // ...and lets go once the hold expires.
        XCTAssertEqual(fade.delay(prefix: ["b"], leaves: [["b", "g"]],
                                  observations: o,
                                  now: start.addingTimeInterval(GuideFade.stumbleHold + 1)),
                       GuideFade.maxSeconds, accuracy: 0.001)
    }

    func testAnAncestorStumbleCoversTheSubtree() {
        let o = learned(["b", "g", "x"], times: Coach.bentCompletions)
        var fade = GuideFade()
        fade.stumbled(prefix: ["b"], at: start)
        XCTAssertEqual(fade.delay(prefix: ["b", "g"], leaves: [["b", "g", "x"]],
                                  observations: o, now: start.addingTimeInterval(60)), 0)
    }

    func testTinyDelaysCollapseToImmediate() {
        let o = learned(["b", "g"], times: 1)
        let fade = GuideFade()
        XCTAssertEqual(fade.delay(prefix: ["b"], leaves: [["b", "g"]],
                                  observations: o, now: start), 0,
                       "a delay below the floor is theater, not training")
    }

    func testARebindRestartsTheFade() {
        // The epoch bump clears the trigger moments, so a superseded
        // address's new letters get their map back immediately.
        var o = learned(["b", "g"], times: Coach.bentCompletions)
        var epoch = ObservationEvent(t: start.addingTimeInterval(100), kind: .epoch)
        epoch.address = "b g"
        epoch.change = "retargeted"
        epoch.epoch = 1
        o.apply(epoch)
        let fade = GuideFade()
        XCTAssertEqual(fade.delay(prefix: ["b"], leaves: [["b", "g"]],
                                  observations: o, now: start), 0)
    }

    // MARK: - The decay watch

    func testFreshUseKeepsTheEarnedWait() {
        let o = learned(["b", "g"], times: Coach.bentCompletions)
        let fade = GuideFade()
        let delay = fade.delay(prefix: ["b"], leaves: [["b", "g"]], observations: o,
                               now: start.addingTimeInterval(GuideFade.decayHorizon - 86_400))
        XCTAssertEqual(delay, GuideFade.maxSeconds, accuracy: 0.001,
                       "inside the horizon, disuse forfeits nothing")
    }

    func testDisuseForfeitsHalfTheFadeHalfwayDownTheRamp() {
        let o = learned(["b", "g"], times: Coach.bentCompletions)
        let fade = GuideFade()
        let delay = fade.delay(prefix: ["b"], leaves: [["b", "g"]], observations: o,
                               now: start.addingTimeInterval(GuideFade.decayHorizon * 1.5))
        XCTAssertEqual(delay, GuideFade.maxSeconds / 2, accuracy: 0.01,
                       "a ramp, not a cliff: half the extra horizon costs half the wait")
    }

    func testALongQuietBringsTheMapAllTheWayBack() {
        let o = learned(["b", "g"], times: Coach.bentCompletions)
        let fade = GuideFade()
        XCTAssertEqual(fade.delay(prefix: ["b"], leaves: [["b", "g"]], observations: o,
                                  now: start.addingTimeInterval(GuideFade.decayHorizon * 2.5)),
                       0, "two horizons of quiet and the scaffold is back before the stumble")
    }
}
