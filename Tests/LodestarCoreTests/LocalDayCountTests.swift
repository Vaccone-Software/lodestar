import XCTest
@testable import LodestarCore

/// A per-day average divides by days on the hand's clock, from four in
/// the morning, the day the key store files under. Counted in UTC days,
/// an evening at the keys past 8 pm in New York was two days.
final class LocalDayCountTests: XCTestCase {
    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func pulse(_ iso: String) -> ObservationEvent {
        var pulse = ObservationEvent(t: ISO8601DateFormatter().date(from: iso)!, kind: .pulse)
        pulse.keys = 100
        pulse.backspaces = 0
        pulse.clicks = 0
        pulse.scrolls = 0
        pulse.activeMinutes = 5
        return pulse
    }

    func testAnEveningAndTheSmallHoursAfterItAreOneDay() throws {
        // 19:00 EDT, 22:30 EDT, and 02:00 EDT the next morning: one day by
        // the hand's clock, and three UTC dates' worth of two.
        let events = [pulse("2026-09-28T23:00:00Z"), pulse("2026-09-29T02:30:00Z"), pulse("2026-09-29T06:00:00Z")]
        let now = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
        let health = try XCTUnwrap(Health.summary(events: events, days: 28, now: now, calendar: newYork))
        XCTAssertEqual(health.days, 1)
    }

    func testFourInTheMorningStartsTheNextDay() throws {
        let events = [pulse("2026-09-28T23:00:00Z"), pulse("2026-09-29T09:00:00Z")]   // 19:00, then 05:00 EDT
        let now = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
        let health = try XCTUnwrap(Health.summary(events: events, days: 28, now: now, calendar: newYork))
        XCTAssertEqual(health.days, 2)
    }
}
