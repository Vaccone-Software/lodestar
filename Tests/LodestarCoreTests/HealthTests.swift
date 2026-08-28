import XCTest
@testable import LodestarCore

/// The hands' pulse: counts and moments, and never anything else. The
/// hard line — no key identities on general typing — is structural (the
/// accumulator's API cannot be handed a key), so what these tests hold is
/// the arithmetic: windows roll, gaps obey their ceiling, bursts coalesce,
/// and the read-time summary tells the truth about what was folded.
final class HealthTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The pulse

    func testCountsAndCorrectionFlag() {
        var pulse = HealthPulse()
        XCTAssertNil(pulse.key(at: start, backspace: false))
        XCTAssertNil(pulse.key(at: start.addingTimeInterval(0.2), backspace: true))
        XCTAssertNil(pulse.click(at: start.addingTimeInterval(0.4)))
        let event = pulse.flush(now: start.addingTimeInterval(1))
        XCTAssertEqual(event?.kind, .pulse)
        XCTAssertEqual(event?.keys, 2)
        XCTAssertEqual(event?.backspaces, 1)
        XCTAssertEqual(event?.clicks, 1)
    }

    func testInterKeyGapsObeyTheCeiling() {
        var pulse = HealthPulse()
        _ = pulse.key(at: start, backspace: false)
        _ = pulse.key(at: start.addingTimeInterval(0.5), backspace: false)
        // Three seconds is a pause, not rhythm.
        _ = pulse.key(at: start.addingTimeInterval(3.5), backspace: false)
        let event = pulse.flush(now: start.addingTimeInterval(4))
        XCTAssertEqual(event?.ikN, 1)
        XCTAssertEqual(event?.ikSum ?? 0, 0.5, accuracy: 0.001)
    }

    func testWindowRollsAtItsQuarterHour() {
        var pulse = HealthPulse()
        _ = pulse.key(at: start, backspace: false)
        _ = pulse.key(at: start.addingTimeInterval(10), backspace: false)
        let rolled = pulse.key(at: start.addingTimeInterval(HealthPulse.windowSeconds + 1),
                               backspace: false)
        XCTAssertNotNil(rolled, "the first key of a new window ships the old one")
        XCTAssertEqual(rolled?.keys, 2)
        XCTAssertEqual(rolled?.t, start, "a pulse is stamped at its window's start")
        let second = pulse.flush(now: start.addingTimeInterval(2000))
        XCTAssertEqual(second?.keys, 1, "the rolling key starts the new window")
    }

    func testScrollBurstsCoalesce() {
        var pulse = HealthPulse()
        _ = pulse.scroll(at: start)
        _ = pulse.scroll(at: start.addingTimeInterval(0.1))
        _ = pulse.scroll(at: start.addingTimeInterval(0.3))
        _ = pulse.scroll(at: start.addingTimeInterval(3))
        let event = pulse.flush(now: start.addingTimeInterval(4))
        XCTAssertEqual(event?.scrolls, 2, "a flick is one reach, not hundreds")
    }

    func testActiveMinutesCountDistinctMinutes() {
        var pulse = HealthPulse()
        _ = pulse.key(at: start, backspace: false)
        _ = pulse.key(at: start.addingTimeInterval(5), backspace: false)
        _ = pulse.key(at: start.addingTimeInterval(65), backspace: false)
        let event = pulse.flush(now: start.addingTimeInterval(100))
        XCTAssertEqual(event?.activeMinutes, 2)
    }

    func testEmptyFlushShipsNothing() {
        var pulse = HealthPulse()
        XCTAssertNil(pulse.flush(now: start))
    }

    // MARK: - The read-time summary

    private func pulseEvent(at t: Date, keys: Int = 100, backspaces: Int = 3,
                            clicks: Int = 10, scrolls: Int = 5,
                            active: Int = 12) -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .pulse)
        event.keys = keys
        event.backspaces = backspaces
        event.clicks = clicks
        event.scrolls = scrolls
        event.activeMinutes = active
        event.ikN = 50
        event.ikSum = 10
        event.ikSumSq = 2.5
        return event
    }

    func testSummaryAggregatesAndDerives() {
        let events = [pulseEvent(at: start), pulseEvent(at: start.addingTimeInterval(900))]
        let summary = Health.summary(events: events, days: 28,
                                     now: start.addingTimeInterval(86_400))
        XCTAssertEqual(summary?.keys, 200)
        XCTAssertEqual(summary?.correctionRate ?? 0, 0.03, accuracy: 0.001)
        XCTAssertEqual(summary?.pointerShare ?? 0, 30.0 / 230.0, accuracy: 0.001)
        XCTAssertEqual(summary?.interKeyMean ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(summary?.days, 1)
    }

    func testSummaryStretchesSplitAtTheGap() {
        // Two pulses back to back, a long silence, then one more: the
        // longest stretch is the first pair's minutes, not the day's sum.
        let events = [
            pulseEvent(at: start, active: 12),
            pulseEvent(at: start.addingTimeInterval(900), active: 10),
            pulseEvent(at: start.addingTimeInterval(3 * 3600), active: 8),
        ]
        let summary = Health.summary(events: events, days: 28,
                                     now: start.addingTimeInterval(86_400))
        XCTAssertEqual(summary?.longestStretchMinutes, 22)
    }

    func testSummaryIgnoresWhatIsOutsideTheWindow() {
        let events = [pulseEvent(at: start.addingTimeInterval(-40 * 86_400))]
        XCTAssertNil(Health.summary(events: events, days: 28,
                                    now: start))
    }

    // MARK: - The store's gates

    private func scratch() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-health-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }

    func testHealthGateHoldsEvenWhenTheMasterIsOpen() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ObservationStore(
            file: directory.appendingPathComponent("observations.json"),
            log: EventLog(file: directory.appendingPathComponent("events.jsonl")))
        store.setHealthEnabled(false)
        store.healthPulse(pulseEvent(at: start))
        XCTAssertTrue(store.log.readAll().isEmpty,
                      "observations.health false means no pulse, ever")
        store.setHealthEnabled(true)
        store.healthPulse(pulseEvent(at: start))
        XCTAssertEqual(store.log.readAll().count, 1)
    }

    func testLatencyEventsRecord() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ObservationStore(
            file: directory.appendingPathComponent("observations.json"),
            log: EventLog(file: directory.appendingPathComponent("events.jsonl")))
        store.latency(surface: "scroll-panes", seconds: 1.4, at: start)
        store.latency(surface: "", seconds: 1, at: start)
        store.latency(surface: "retile", seconds: 0, at: start)
        let events = store.log.readAll()
        XCTAssertEqual(events.count, 1, "unnamed surfaces and zero seconds are refused")
        XCTAssertEqual(events.first?.verb, "scroll-panes")
        XCTAssertEqual(events.first?.seconds ?? 0, 1.4, accuracy: 0.001)
    }
}
