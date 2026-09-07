import XCTest
@testable import LodestarCore

/// The pointer's reaches, measured: the tracker reads homing, travel,
/// settle, press, drag and return off a stream of motion, presses and
/// keys, and the moments fold them without ever keeping a position.
final class PointerTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func testAReachIsTimedFromFirstMotionToThePress() {
        var tracker = PointerTracker()
        tracker.moved(to: CGPoint(x: 0, y: 0), at: at(0))
        tracker.moved(to: CGPoint(x: 30, y: 40), at: at(0.2))
        tracker.moved(to: CGPoint(x: 60, y: 80), at: at(0.4))
        let click = tracker.down(at: CGPoint(x: 60, y: 80), at: at(0.7))
        XCTAssertFalse(click.stationary)
        XCTAssertEqual(click.travel, 0.4, accuracy: 1e-6, "first motion to last motion")
        XCTAssertEqual(click.settle, 0.3, accuracy: 1e-6, "last motion to the press")
        XCTAssertEqual(click.path, 100, accuracy: 1e-6, "two legs of fifty")
        XCTAssertEqual(click.displacement, 100, accuracy: 1e-6, "a straight reach")
        XCTAssertNil(click.homing, "no keystroke preceded the reach")
    }

    func testHomingIsTheKeyToFirstMotionGap() {
        var tracker = PointerTracker()
        tracker.keyed(at: at(0))
        tracker.moved(to: CGPoint(x: 0, y: 0), at: at(0.45))
        tracker.moved(to: CGPoint(x: 10, y: 0), at: at(0.6))
        let click = tracker.down(at: CGPoint(x: 10, y: 0), at: at(0.8))
        XCTAssertEqual(click.homing ?? -1, 0.45, accuracy: 1e-6)

        // A key that lands after the reach began is not a homing.
        tracker.moved(to: CGPoint(x: 0, y: 0), at: at(5))
        tracker.keyed(at: at(5.1))
        tracker.moved(to: CGPoint(x: 10, y: 0), at: at(5.2))
        XCTAssertNil(tracker.down(at: CGPoint(x: 10, y: 0), at: at(5.3)).homing)
    }

    func testARestSplitsReaches() {
        var tracker = PointerTracker()
        tracker.moved(to: CGPoint(x: 0, y: 0), at: at(0))
        tracker.moved(to: CGPoint(x: 100, y: 0), at: at(0.2))
        // Longer than the rest gap: the reach that matters starts here.
        tracker.moved(to: CGPoint(x: 100, y: 0), at: at(2))
        tracker.moved(to: CGPoint(x: 110, y: 0), at: at(2.1))
        let click = tracker.down(at: CGPoint(x: 110, y: 0), at: at(2.2))
        XCTAssertEqual(click.travel, 0.1, accuracy: 1e-6)
        XCTAssertEqual(click.path, 10, accuracy: 1e-6, "the earlier leg belonged to a reach that ended in nothing")
    }

    func testAPressWithoutMotionIsStationary() {
        var tracker = PointerTracker()
        tracker.moved(to: CGPoint(x: 0, y: 0), at: at(0))
        _ = tracker.down(at: CGPoint(x: 0, y: 0), at: at(0.1))
        _ = tracker.up(at: CGPoint(x: 0, y: 0), at: at(0.2))
        let again = tracker.down(at: CGPoint(x: 0, y: 0), at: at(0.3))
        XCTAssertTrue(again.stationary, "a double click's second press closed no reach")

        // Motion long ago is not this press's aim either.
        tracker.moved(to: CGPoint(x: 5, y: 0), at: at(1))
        let late = tracker.down(at: CGPoint(x: 5, y: 0), at: at(1 + PointerTracker.settleCeiling + 1))
        XCTAssertTrue(late.stationary)
    }

    func testPressAndDrag() {
        var tracker = PointerTracker()
        tracker.moved(to: CGPoint(x: 0, y: 0), at: at(0))
        _ = tracker.down(at: CGPoint(x: 0, y: 0), at: at(0.1))
        let tap = tracker.up(at: CGPoint(x: 1, y: 0), at: at(0.19))
        XCTAssertEqual(tap?.press ?? 0, 0.09, accuracy: 1e-6)
        XCTAssertNil(tap?.drag, "a point of wobble is a click, not a drag")

        _ = tracker.down(at: CGPoint(x: 0, y: 0), at: at(1))
        tracker.moved(to: CGPoint(x: 50, y: 0), at: at(1.2))
        tracker.moved(to: CGPoint(x: 100, y: 0), at: at(1.4))
        let drag = tracker.up(at: CGPoint(x: 100, y: 0), at: at(1.5))
        XCTAssertEqual(drag?.drag?.seconds ?? 0, 0.5, accuracy: 1e-6)
        XCTAssertEqual(drag?.drag?.path ?? 0, 100, accuracy: 1e-6)
        XCTAssertNil(tracker.up(at: .zero, at: at(2)), "a release with no press open is nothing")
    }

    func testMotionUnderAPressDoesNotOpenAReach() {
        var tracker = PointerTracker()
        _ = tracker.down(at: CGPoint(x: 0, y: 0), at: at(0))
        tracker.moved(to: CGPoint(x: 100, y: 0), at: at(0.1))
        _ = tracker.up(at: CGPoint(x: 100, y: 0), at: at(0.2))
        XCTAssertTrue(tracker.down(at: CGPoint(x: 100, y: 0), at: at(0.3)).stationary,
                      "the drag's motion belonged to the press")
    }

    func testTheReturnIsTheFirstKeyAfterAPress() {
        var tracker = PointerTracker()
        _ = tracker.down(at: .zero, at: at(0))
        XCTAssertEqual(tracker.keyed(at: at(0.6)) ?? 0, 0.6, accuracy: 1e-6)
        XCTAssertNil(tracker.keyed(at: at(0.8)), "only the first key comes back from the mouse")
        _ = tracker.down(at: .zero, at: at(10))
        XCTAssertNil(tracker.keyed(at: at(10 + PointerTracker.returnCeiling + 1)),
                     "a key that late is a new thought, not a return")
    }
}

final class PointerMomentsTests: XCTestCase {
    func testMomentsFoldAndDerive() {
        var moments = PointerMoments()
        moments.add(PointerTracker.Click(travel: 0.4, settle: 0.2, homing: 0.5, path: 200, displacement: 100))
        moments.add(PointerTracker.Click(travel: 0.6, settle: 0.4, homing: nil, path: 100, displacement: 100))
        moments.add(PointerTracker.Click(stationary: true))
        moments.add(PointerTracker.Release(press: 0.1))
        moments.add(PointerTracker.Release(press: 0.5, drag: .init(seconds: 0.5, path: 80)))
        moments.addReturn(0.7)
        XCTAssertEqual(moments.n, 2)
        XCTAssertEqual(moments.stationary, 1)
        XCTAssertEqual(moments.pointMean ?? 0, 0.8, accuracy: 1e-9, "travel and settle over the timed reaches")
        XCTAssertEqual(moments.homingMean ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(moments.efficiency ?? 0, 200.0 / 300.0, accuracy: 1e-9)
        XCTAssertEqual(moments.pressN, 2)
        XCTAssertEqual(moments.dragN, 1)
        XCTAssertEqual(moments.returnMean ?? 0, 0.7, accuracy: 1e-9)

        var other = PointerMoments()
        other.add(PointerTracker.Click(travel: 1, settle: 1, path: 10, displacement: 10))
        moments.merge(other)
        XCTAssertEqual(moments.n, 3)
        XCTAssertEqual(moments.travelSum, 2.0, accuracy: 1e-9)
        XCTAssertFalse(moments.isEmpty)
        XCTAssertTrue(PointerMoments().isEmpty)
    }

    func testTheEventCarriesMomentsAndRoundTrips() throws {
        var event = ObservationEvent(t: Date(timeIntervalSince1970: 1_700_000_000), kind: .clicks)
        event.app = "brave"
        var moments = PointerMoments()
        moments.add(PointerTracker.Click(travel: 0.4, settle: 0.2, homing: 0.5, path: 200, displacement: 100))
        event.pointer = moments
        event.scrolls = 3
        event.scrollSeconds = 4.5
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let back = try decoder.decode(ObservationEvent.self, from: try encoder.encode(event))
        XCTAssertEqual(back.pointer, moments)
        XCTAssertEqual(back.scrollSeconds, 4.5)
        let text = String(decoding: try encoder.encode(event), as: UTF8.self)
        XCTAssertFalse(text.contains("\"x\""), "no position leaves the tracker")
    }
}

final class ClickPulsePointerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testReachesPressesReturnsAndWheelFoldPerApp() {
        var pulse = ClickPulse()
        let act = PointerTracker.Click(travel: 0.4, settle: 0.2, homing: 0.5, path: 200, displacement: 100)
        _ = pulse.click(app: "Brave", role: "AXLink", trip: true, act: act, at: start)
        _ = pulse.released(app: "Brave", .init(press: 0.1), at: start)
        _ = pulse.returned(app: "Brave", seconds: 0.8, at: start)
        _ = pulse.click(app: "Slack", role: "AXButton", trip: false,
                        act: .init(stationary: true), at: start.addingTimeInterval(1))
        _ = pulse.scroll(app: "Brave", seconds: 2.5, at: start.addingTimeInterval(2))
        _ = pulse.scroll(app: "Notes", seconds: 1.0, at: start.addingTimeInterval(3))
        let events = pulse.flush()
        let brave = events.first { $0.app == "brave" }
        XCTAssertEqual(brave?.clicks, 1)
        XCTAssertEqual(brave?.pointer?.n, 1)
        XCTAssertEqual(brave?.pointer?.pressN, 1)
        XCTAssertEqual(brave?.pointer?.returnN, 1)
        XCTAssertEqual(brave?.scrolls, 1)
        XCTAssertEqual(brave?.scrollSeconds ?? 0, 2.5, accuracy: 1e-9)
        let slack = events.first { $0.app == "slack" }
        XCTAssertEqual(slack?.pointer?.stationary, 1)
        XCTAssertNil(slack?.scrolls, "no wheel in Slack")
        let notes = events.first { $0.app == "notes" }
        XCTAssertEqual(notes?.clicks, 0, "an app can be scrolled and never clicked")
        XCTAssertEqual(notes?.scrolls, 1)
        XCTAssertNil(notes?.pointer)

        let summary = Health.clicks(events: events, days: 28, now: start.addingTimeInterval(3600))
        XCTAssertEqual(summary?.pointer.n, 1)
        XCTAssertEqual(summary?.pointer.stationary, 1)
        XCTAssertEqual(summary?.scrolls, 2)
        XCTAssertEqual(summary?.scrollSeconds ?? 0, 3.5, accuracy: 1e-9)
        XCTAssertEqual(summary?.scrollRanked.first?.app, "brave")
        XCTAssertEqual(summary?.apps["brave"]?.pointer.homingMean ?? 0, 0.5, accuracy: 1e-9)
    }

    func testAWholeBurstTimesTheWheel() {
        var pulse = HealthPulse()
        _ = pulse.scroll(from: start, to: start.addingTimeInterval(2.5))
        _ = pulse.scroll(from: start.addingTimeInterval(10), to: start.addingTimeInterval(10.5))
        let event = pulse.flush(now: start.addingTimeInterval(20))
        XCTAssertEqual(event?.scrolls, 2)
        XCTAssertEqual(event?.scrollSeconds ?? 0, 3.0, accuracy: 1e-9)
        let summary = Health.summary(events: [event!], days: 28, now: start.addingTimeInterval(3600))
        XCTAssertEqual(summary?.scrollSeconds ?? 0, 3.0, accuracy: 1e-9)
    }

    func testPointingReadsAsMeasuredOnceTheReachesAre() {
        var typing = ObservationEvent(t: start, kind: .pulse)
        typing.keys = 1000
        typing.backspaces = 0
        typing.clicks = 0
        typing.scrolls = 0
        typing.activeMinutes = 15
        typing.ikN = 500
        typing.ikSum = 100
        typing.ikSumSq = 20
        var clicks = ObservationEvent(t: start, kind: .clicks)
        clicks.app = "brave"
        clicks.clicks = 100
        clicks.trips = 50
        clicks.roles = ["link": 100]
        var moments = PointerMoments()
        for _ in 0..<80 {
            moments.add(PointerTracker.Click(travel: 0.5, settle: 0.2, homing: 0.3, path: 100, displacement: 100))
            moments.add(PointerTracker.Release(press: 0.1))
        }
        for _ in 0..<20 {
            moments.add(PointerTracker.Click(stationary: true))
            moments.add(PointerTracker.Release(press: 0.1))
        }
        clicks.pointer = moments
        let now = start.addingTimeInterval(3600)
        let events = [typing, clicks]
        let overhead = Overhead.compute(events: events, latency: nil,
                                        health: Health.summary(events: events, days: 28, now: now),
                                        clicks: Health.clicks(events: events, days: 28, now: now),
                                        now: now)
        guard let pointing = overhead.channels.first(where: { $0.name == "pointing" }) else {
            return XCTFail("timed reaches are a pointing channel")
        }
        XCTAssertTrue(pointing.measured)
        // 80 reaches at 0.3 + 0.5 + 0.2 plus 100 presses at 0.1: 90s,
        // and not a KLM constant in it.
        XCTAssertEqual(pointing.actualSecondsPerDay, 90, accuracy: 1e-6)
        XCTAssertEqual(pointing.ratio ?? 0, 1.5, accuracy: 1e-6, "against 100 keyed acts at 0.6s")
    }

    func testTheMeasuredFromKeysShareSupersedesTheTripFlag() {
        var pulse = ClickPulse()
        // Two reaches from the keys, two from an already-resting pointer;
        // the trip flag says three by order, the measured share says half.
        _ = pulse.click(app: "brave", role: "AXLink", trip: true,
                        act: .init(travel: 0.4, settle: 0.1, homing: 0.3, path: 10, displacement: 10), at: start)
        _ = pulse.click(app: "brave", role: "AXLink", trip: true,
                        act: .init(travel: 0.4, settle: 0.1, homing: 0.3, path: 10, displacement: 10), at: start)
        _ = pulse.click(app: "brave", role: "AXLink", trip: true,
                        act: .init(travel: 0.4, settle: 0.1, path: 10, displacement: 10), at: start)
        _ = pulse.click(app: "brave", role: "AXLink", trip: false,
                        act: .init(travel: 0.4, settle: 0.1, path: 10, displacement: 10), at: start)
        let events = pulse.flush()
        let summary = Health.clicks(events: events, days: 28, now: start.addingTimeInterval(3600))!
        XCTAssertEqual(summary.fromKeysShare ?? 0, 0.5, accuracy: 1e-9, "two of four reaches began after a key")
        XCTAssertEqual(summary.tripShare ?? 0, 0.75, accuracy: 1e-9, "the cruder flag still reads, for old data")
    }

    func testTheRollupKeepsTheMomentsAndReadsOldArchives() throws {
        var click = ObservationEvent(t: start, kind: .clicks)
        click.app = "brave"
        click.clicks = 2
        click.trips = 1
        click.roles = ["link": 2]
        var moments = PointerMoments()
        moments.add(PointerTracker.Click(travel: 0.4, settle: 0.2, path: 10, displacement: 10))
        click.pointer = moments
        click.scrolls = 1
        click.scrollSeconds = 2
        var pulse = ObservationEvent(t: start, kind: .pulse)
        pulse.keys = 10
        pulse.scrolls = 1
        pulse.scrollSeconds = 2
        pulse.activeMinutes = 1
        let now = start.addingTimeInterval(120 * 86_400)
        let months = Rollup.build(events: [click, click, pulse], now: now)
        let month = months[Rollup.monthKey(start)]
        let record = month?.health.clicksByApp["brave"]
        XCTAssertEqual(record?.pointer?.n, 2)
        XCTAssertEqual(record?.pointer?.travelSum ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(record?.scrolls, 2)
        XCTAssertEqual(record?.scrollSeconds ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(month?.health.scrollSeconds ?? 0, 2, accuracy: 1e-9)

        let old = #"{"clicks": 4, "trips": 1, "roles": {"link": 3}}"#
        let decoded = try JSONDecoder().decode(Rollup.ClickMonth.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.clicks, 4)
        XCTAssertNil(decoded.pointer, "an archive from before the pointer column")
    }
}
