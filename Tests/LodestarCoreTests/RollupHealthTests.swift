import XCTest
@testable import LodestarCore

/// The v2 archive: the health pulse, the focus structure, the latency
/// stats, and the weekly sub-rollups — everything the retrospective will
/// one day need and the ring will long since have dropped. Plus the two
/// compatibility laws: v1 files decode with the new columns empty, and
/// nothing here disturbs add-only.
final class RollupHealthTests: XCTestCase {
    /// Mid-July 2026 UTC; `now` in September keeps July closed.
    private let july = Date(timeIntervalSince1970: 1_784_000_000)
    private var now: Date { july.addingTimeInterval(60 * 86_400) }

    private func pulse(at t: Date, keys: Int = 100, backspaces: Int = 2,
                       clicks: Int = 8, scrolls: Int = 4, active: Int = 10)
        -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .pulse)
        event.keys = keys
        event.backspaces = backspaces
        event.clicks = clicks
        event.scrolls = scrolls
        event.activeMinutes = active
        event.ikN = 20
        event.ikSum = 4
        event.ikSumSq = 1
        return event
    }

    private func focus(_ app: String, at t: Date) -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .focus)
        event.app = app
        return event
    }

    func testPulsesFoldIntoMonthAndWeek() {
        let events = [pulse(at: july), pulse(at: july.addingTimeInterval(900))]
        let months = Rollup.build(events: events, now: now)
        let month = months[Rollup.monthKey(july)]
        XCTAssertEqual(month?.health.keys, 200)
        XCTAssertEqual(month?.health.backspaces, 4)
        XCTAssertEqual(month?.health.clicks, 16)
        XCTAssertEqual(month?.health.scrolls, 8)
        XCTAssertEqual(month?.health.activeMinutes, 20)
        XCTAssertEqual(month?.health.interKey.n, 40)
        XCTAssertEqual(month?.health.activeHours.reduce(0, +), 20)
        XCTAssertEqual(month?.health.weekdays.reduce(0, +), 20)
        let week = "\(Observations.week(july))"
        XCTAssertEqual(month?.weeks[week]?.keys, 200)
        XCTAssertEqual(month?.weeks[week]?.activeMinutes, 20)
        XCTAssertEqual(month?.weeks[week]?.interKey.n, 40)
    }

    func testFocusStructureFolds() {
        // a → b (40s) → a (5s: a checking loop) → c (30s).
        let events = [
            focus("a", at: july),
            focus("b", at: july.addingTimeInterval(40)),
            focus("a", at: july.addingTimeInterval(45)),
            focus("c", at: july.addingTimeInterval(75)),
        ]
        let months = Rollup.build(events: events, now: now)
        let month = months[Rollup.monthKey(july)]
        XCTAssertEqual(month?.transitions["a"]?["b"], 1)
        XCTAssertEqual(month?.transitions["b"]?["a"], 1)
        XCTAssertEqual(month?.transitions["a"]?["c"], 1)
        XCTAssertEqual(month?.checkingLoops, 1, "b was five seconds — a check, not a visit")
        XCTAssertEqual(month?.dwell.n, 3)
        XCTAssertEqual(month?.hours.reduce(0, +), 4, "every focus event marks its hour")
        let week = "\(Observations.week(july))"
        XCTAssertEqual(month?.weeks[week]?.switches, 3)
        XCTAssertEqual(month?.weeks[week]?.checkingLoops, 1)
    }

    func testStretchesAndBreaksAcrossPulses() {
        // Two adjacent pulses, a 90-minute silence, then one more: one
        // completed 20-minute stretch, one 90-minute break, and the
        // trailing stretch recorded at the fold's end.
        let events = [
            pulse(at: july, active: 12),
            pulse(at: july.addingTimeInterval(900), active: 8),
            pulse(at: july.addingTimeInterval(900 + 90 * 60), active: 5),
        ]
        let months = Rollup.build(events: events, now: now)
        let health = months[Rollup.monthKey(july)]?.health
        XCTAssertEqual(health?.stretchMinutes.n, 2)
        XCTAssertEqual(health?.stretchMinutes.sum ?? 0, 25, accuracy: 0.01)
        XCTAssertEqual(health?.breakMinutes.n, 1)
        // The break is measured from the previous window's end.
        XCTAssertEqual(health?.breakMinutes.sum ?? 0, 75, accuracy: 0.1)
    }

    func testOpenMonthStaysUnwritten() {
        let events = [pulse(at: now), focus("a", at: now),
                      focus("b", at: now.addingTimeInterval(10))]
        XCTAssertTrue(Rollup.build(events: events, now: now).isEmpty,
                      "the open month is still being written")
    }

    func testLatencyAndIgnoredFold() {
        var warm = ObservationEvent(t: july, kind: .latency)
        warm.verb = "scroll-panes"
        warm.seconds = 2.0
        var ignored = ObservationEvent(t: july, kind: .coach)
        ignored.action = "ignored"
        ignored.rec = "bind"
        ignored.app = "slack"
        let months = Rollup.build(events: [warm, ignored], now: now)
        let month = months[Rollup.monthKey(july)]
        XCTAssertEqual(month?.latency["scroll-panes"]?.n, 1)
        XCTAssertEqual(month?.coach["bind:slack"]?.ignored, 1)
    }

    func testV1ArchiveDecodesWithEmptyColumns() throws {
        let v1 = """
        {"version": 1, "months": {"2026-06": {
            "events": 3, "days": 1,
            "firstEvent": "2026-06-10T12:00:00Z", "lastEvent": "2026-06-10T13:00:00Z",
            "apps": {}, "addresses": {}, "verbs": {"graph": 3},
            "launcherAbandons": 0,
            "web": {"opens": 0, "hostProfiles": {}, "sources": {}, "rows": {}},
            "meetings": {"actions": {}, "joinedLead": {"n": 0, "sum": 0, "sumSquares": 0}},
            "coach": {"bind:slack": {"offered": 2, "accepted": 1, "never": 0}},
            "epochs": {}, "selectActions": {}, "selectSources": {}, "selectRows": {}
        }}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Rollup.self, from: Data(v1.utf8))
        let month = archive.months["2026-06"]
        XCTAssertEqual(month?.verbs["graph"], 3)
        XCTAssertEqual(month?.coach["bind:slack"]?.ignored, 0,
                       "a column that predates the file reads as zero")
        XCTAssertEqual(month?.health, Rollup.HealthMonth())
        XCTAssertTrue(month?.weeks.isEmpty ?? false)
    }

    func testTransitionCapHoldsInTheArchive() {
        var events: [ObservationEvent] = []
        var t = july
        for i in 0..<40 {
            events.append(focus("app\(i)", at: t))
            t.addTimeInterval(30)
        }
        let months = Rollup.build(events: events, now: now)
        let month = months[Rollup.monthKey(july)]!
        let apps = Set(month.transitions.keys)
            .union(month.transitions.values.flatMap(\.keys))
        XCTAssertLessThanOrEqual(apps.count, Rollup.transitionAppCap)
    }
}
