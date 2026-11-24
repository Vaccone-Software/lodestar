import XCTest
@testable import LodestarCore

/// The guide's fade, generalized: a bar's footer waits longer as the bar
/// is used, comes straight back on a stumble, and forfeits its wait with
/// disuse — keyed by the verb the observation layer already counts.
final class SurfaceFadeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func used(_ verb: String, times: Int, at: Date? = nil) -> Observations {
        var o = Observations()
        for i in 0..<times {
            var event = ObservationEvent(t: (at ?? start).addingTimeInterval(Double(i)),
                                         kind: .verb)
            event.verb = verb
            o.apply(event)
        }
        return o
    }

    func testAFreshSurfacePaintsItsLegendAtOnce() {
        XCTAssertEqual(SurfaceFade().delay(surface: "launcher", observations: Observations(),
                                           now: start), 0)
    }

    func testALearnedSurfaceEarnsTheFullWait() {
        let o = used("launcher", times: SurfaceFade.bentUses)
        XCTAssertEqual(SurfaceFade().delay(surface: "launcher", observations: o,
                                           now: start.addingTimeInterval(60)),
                       SurfaceFade.maxSeconds, accuracy: 0.001)
    }

    func testTheWaitGrowsWithUse() {
        let half = used("web", times: SurfaceFade.bentUses / 2)
        XCTAssertEqual(SurfaceFade().delay(surface: "web", observations: half,
                                           now: start.addingTimeInterval(60)),
                       SurfaceFade.maxSeconds / 2, accuracy: 0.001)
    }

    func testAStumbleBringsTheLegendBack() {
        let o = used("launcher", times: SurfaceFade.bentUses)
        var fade = SurfaceFade()
        fade.stumbled(surface: "launcher", at: start.addingTimeInterval(60))
        XCTAssertEqual(fade.delay(surface: "launcher", observations: o,
                                  now: start.addingTimeInterval(120)), 0)
        XCTAssertEqual(fade.delay(surface: "web", observations: o,
                                  now: start.addingTimeInterval(120)), 0,
                       "another surface's legend is its own question")
    }

    func testDisuseForfeitsTheWait() {
        let o = used("menu", times: SurfaceFade.bentUses)
        let fade = SurfaceFade()
        XCTAssertEqual(fade.delay(surface: "menu", observations: o,
                                  now: start.addingTimeInterval(SurfaceFade.decayHorizon * 2.5)),
                       0, "two horizons of quiet and the legend is back before the stumble")
    }
}
