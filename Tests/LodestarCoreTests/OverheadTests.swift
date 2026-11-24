import XCTest
@testable import LodestarCore

/// The product's own score: actual input cost against its computed floor,
/// per channel. Measured channels come from the instrument's own timings;
/// the others are counts priced by KLM constants at the hand's measured
/// inter-key gap — and every line says which it is.
final class OverheadTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A quarter hour of typing: mean inter-key gap 0.2s.
    private func pulse(keys: Int, backspaces: Int) -> ObservationEvent {
        var event = ObservationEvent(t: start, kind: .pulse)
        event.keys = keys
        event.backspaces = backspaces
        event.clicks = 0
        event.scrolls = 0
        event.activeMinutes = 15
        event.ikN = 500
        event.ikSum = 100
        event.ikSumSq = 20
        return event
    }

    private func latencyAtThirdOfASecond() -> LatencyModel? {
        var samples: [LatencyModel.Sample] = []
        for i in 0..<40 {
            samples.append(.init(address: "g", chain: ["g"], pos: 0,
                                 log: log(0.3) + (i.isMultiple(of: 2) ? 0.02 : -0.02)))
        }
        return LatencyModel.fit(samples: samples)
    }

    func testNavigationRatioFromMeasuredGaps() {
        var events: [ObservationEvent] = []
        for i in 0..<10 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 60),
                                         kind: .chain)
            event.chain = ["b", "x"]
            event.gaps = [0.6, 0.6]
            events.append(event)
        }
        let overhead = Overhead.compute(events: events, latency: latencyAtThirdOfASecond(),
                                        health: nil, clicks: nil,
                                        now: start.addingTimeInterval(86_400))
        guard let nav = overhead.channels.first(where: { $0.name == "navigation" }) else {
            return XCTFail("ten timed chains are a navigation channel")
        }
        XCTAssertTrue(nav.measured)
        XCTAssertEqual(nav.actualSecondsPerDay, 12.0, accuracy: 0.01,
                       "the gaps as they were measured")
        XCTAssertEqual(nav.ratio ?? 0, 4.0, accuracy: 0.5,
                       "each act against one bare-key gesture at this hand's price")
    }

    func testTypingRatioIsTheCorrectionTax() {
        let event = pulse(keys: 1000, backspaces: 100)
        let health = Health.summary(events: [event], days: 28,
                                    now: start.addingTimeInterval(3600))
        let overhead = Overhead.compute(events: [event], latency: nil,
                                        health: health, clicks: nil,
                                        now: start.addingTimeInterval(3600))
        guard let typing = overhead.channels.first(where: { $0.name == "typing" }) else {
            return XCTFail("a pulse with keys is a typing channel")
        }
        XCTAssertFalse(typing.measured)
        XCTAssertEqual(typing.ratio ?? 0, 1000.0 / 800.0, accuracy: 0.001,
                       "each correction erases a typed key and spends another; "
                           + "the ratio is the tax and owes nothing to the gap")
    }

    func testPointingPricedAgainstTheKeyedFloor() {
        var clicksEvent = ObservationEvent(t: start, kind: .clicks)
        clicksEvent.app = "brave"
        clicksEvent.clicks = 100
        clicksEvent.trips = 50
        clicksEvent.roles = ["button": 60, "link": 40]
        let events = [pulse(keys: 1000, backspaces: 0), clicksEvent]
        let now = start.addingTimeInterval(3600)
        let overhead = Overhead.compute(events: events, latency: nil,
                                        health: Health.summary(events: events, days: 28, now: now),
                                        clicks: Health.clicks(events: events, days: 28, now: now),
                                        now: now)
        guard let pointing = overhead.channels.first(where: { $0.name == "pointing" }) else {
            return XCTFail("counted clicks are a pointing channel")
        }
        XCTAssertFalse(pointing.measured)
        // Half the clicks pay homing + point + press (1.7s), half point +
        // press (1.3s): 150s against a floor of 100 keyed acts at 0.6s.
        XCTAssertEqual(pointing.ratio ?? 0, 2.5, accuracy: 0.001)
    }

    func testSelectRatioFromMeasuredSessions() {
        var events: [ObservationEvent] = [pulse(keys: 1000, backspaces: 0)]
        for i in 0..<5 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 60),
                                         kind: .select)
            event.app = "brave"
            event.action = "completed"
            event.seconds = 3.0
            events.append(event)
        }
        let now = start.addingTimeInterval(3600)
        let overhead = Overhead.compute(events: events, latency: nil,
                                        health: Health.summary(events: events, days: 28, now: now),
                                        clicks: nil, now: now)
        guard let select = overhead.channels.first(where: { $0.name == "select" }) else {
            return XCTFail("timed sessions are a select channel")
        }
        XCTAssertTrue(select.measured)
        // Five sessions of three seconds against five keyed acts at 0.6s.
        XCTAssertEqual(select.ratio ?? 0, 5.0, accuracy: 0.001)
    }

    func testBacklogRanksThePoolByCost() {
        var braveClicks = ObservationEvent(t: start, kind: .clicks)
        braveClicks.app = "brave"
        braveClicks.clicks = 100
        braveClicks.trips = 50
        braveClicks.roles = ["button": 60, "link": 30, "other": 10]
        var slackClicks = ObservationEvent(t: start.addingTimeInterval(60), kind: .clicks)
        slackClicks.app = "slack"
        slackClicks.clicks = 20
        slackClicks.trips = 10
        slackClicks.roles = ["textfield": 20]
        let now = start.addingTimeInterval(3600)
        guard let clicks = Health.clicks(events: [braveClicks, slackClicks],
                                         days: 28, now: now) else {
            return XCTFail("two click pulses are a pool")
        }
        let pool = Overhead.pointingBacklog(clicks: clicks)
        XCTAssertEqual(pool.first?.app, "brave")
        XCTAssertEqual(pool.first?.role, "button", "the pool ranks by where the seconds are")
        XCTAssertFalse(pool.contains { $0.role == ClickPulse.other },
                       "the folded remainder names nothing and is not a category")
        // 120 clicks, half of them trips: 1.5s a click; sixty buttons.
        XCTAssertEqual(pool.first?.secondsPerDay ?? 0, 90.0, accuracy: 0.001)
    }
}
