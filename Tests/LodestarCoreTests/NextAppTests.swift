import XCTest
@testable import LodestarCore

/// Which app comes next: the chain, the return, and the blend of the two
/// — scored the shadow way, predict then observe, so the warmer's model
/// is the one that measurably predicts the stream.
final class NextAppTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func focus(_ app: String, at seconds: TimeInterval) -> ObservationEvent {
        var event = ObservationEvent(t: start.addingTimeInterval(seconds), kind: .focus)
        event.app = app
        return event
    }

    private func observed(_ apps: [String]) -> NextApp {
        var model = NextApp()
        for app in apps { model.observe(app) }
        return model
    }

    func testAWindowSwitchIsNotATransition() {
        let model = observed(["slack", "Slack", "brave"])
        XCTAssertEqual(model.history, ["slack", "brave"])
    }

    func testTheChainPredictsTheUsualNext() {
        // From ghostty the hand goes to brave three times for every slack.
        let model = observed(["ghostty", "brave", "ghostty", "brave", "ghostty",
                              "slack", "ghostty", "brave", "ghostty"])
        XCTAssertEqual(model.predict(.markov, k: 2), ["brave", "slack"])
    }

    func testPreviousIsTheBackKey() {
        let model = observed(["slack", "brave"])
        XCTAssertEqual(model.predict(.previous), ["slack"])
        XCTAssertEqual(observed(["brave"]).predict(.previous), [],
                       "nothing before the first app")
    }

    func testTheBlendPutsTheReturnFirstWhenTheChainIsSilent() {
        let model = observed(["slack", "brave", "ghostty"])
        XCTAssertEqual(model.predict(.blend, k: 2), ["brave", "slack"],
                       "no chain row for ghostty yet: recency carries it")
    }

    func testNeverTheCurrentApp() {
        let model = observed(["a", "b", "a", "b", "a"])
        for strategy in NextApp.Strategy.allCases {
            XCTAssertFalse(model.predict(strategy).contains("a"), "\(strategy)")
        }
    }

    func testSecondOrderKnowsTheReturn() {
        // After slack → brave the hand goes back to slack; after ghostty
        // → brave it goes on to zoom. First order sees one brave row.
        var apps: [String] = []
        for _ in 0..<6 { apps += ["slack", "brave", "slack", "ghostty", "brave", "zoom"] }
        var model = observed(apps)
        model.tuning = NextApp.Tuning(weight: 1.0, decay: 0.5, secondOrder: true)
        // History ends ...ghostty, brave, zoom; observe the way back to
        // ghostty then brave, so the deep key is "ghostty|brave".
        model.observe("ghostty")
        model.observe("brave")
        XCTAssertEqual(model.predict(.tuned, k: 1), ["zoom"])
    }

    func testEvaluateScoresBeforeObserving() {
        // A perfectly alternating stream: every strategy that knows the
        // return scores a hit on every switch past the warmup.
        var events: [ObservationEvent] = []
        for i in 0..<200 { events.append(focus(i.isMultiple(of: 2) ? "a" : "b", at: Double(i))) }
        let scores = NextApp.evaluate(events: events, tuning: NextApp.Tuning(), warmup: 20)
        let previous = scores.first { $0.strategy == .previous }
        XCTAssertEqual(previous?.switches, 180)
        XCTAssertEqual(previous?.hits[0] ?? 0, 1.0, accuracy: 0.001)
        let markov = scores.first { $0.strategy == .markov }
        XCTAssertEqual(markov?.hits[0] ?? 0, 1.0, accuracy: 0.001)
    }

    func testTuneReturnsACellOfTheGrid() {
        var events: [ObservationEvent] = []
        let cycle = ["a", "b", "c", "a", "b", "d"]
        for i in 0..<120 { events.append(focus(cycle[i % cycle.count], at: Double(i))) }
        let tuning = NextApp.tune(events: events, warmup: 12)
        XCTAssertTrue(NextApp.weightGrid.contains(tuning.weight))
        XCTAssertTrue(NextApp.decayGrid.contains(tuning.decay))
    }

    func testBestPrefersTheWidestNet() {
        let scores = [
            NextApp.Score(strategy: .previous, switches: 100, hits: [0.6, 0.6, 0.6]),
            NextApp.Score(strategy: .blend, switches: 100, hits: [0.55, 0.8, 0.9]),
        ]
        XCTAssertEqual(NextApp.best(scores), .blend,
                       "the warmer warms three; the top-3 rate is what it lives on")
        XCTAssertEqual(NextApp.best([]), .blend)
    }

    func testTheTableIsBounded() {
        var model = NextApp()
        for i in 0..<(NextApp.appCap * 3) {
            model.observe("app\(i)")
        }
        XCTAssertLessThanOrEqual(model.history.count, NextApp.historyCap)
    }
}
