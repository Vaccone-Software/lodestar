import XCTest
@testable import LodestarCore

/// The day begins at four in the morning, local — on the days the clock
/// changes too. Four hours of absolute time back from a moment is not
/// "four in the morning" on a 25- or 23-hour day, and filed an hour of
/// presses under the wrong day at every change.
final class DayBoundaryDSTTests: XCTestCase {
    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func moment(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testTheHourBeforeFourOnTheFallBackDayIsTheDayBefore() {
        // 2026-11-01: 02:00 EDT falls back to 01:00 EST. 03:30 EST is 08:30Z.
        XCTAssertEqual(DayFile.day(of: moment("2026-11-01T08:30:00Z"), calendar: newYork), "2026-10-31")
        // 04:30 EST is the new day.
        XCTAssertEqual(DayFile.day(of: moment("2026-11-01T09:30:00Z"), calendar: newYork), "2026-11-01")
    }

    func testTheHourAfterFourOnTheSpringForwardDayIsThatDay() {
        // 2027-03-14: 02:00 EST springs to 03:00 EDT. 04:30 EDT is 08:30Z.
        XCTAssertEqual(DayFile.day(of: moment("2027-03-14T08:30:00Z"), calendar: newYork), "2027-03-14")
        // 03:30 EDT is still the night before.
        XCTAssertEqual(DayFile.day(of: moment("2027-03-14T07:30:00Z"), calendar: newYork), "2027-03-13")
    }

    func testEveryMomentLiesInsideItsOwnDay() {
        // Across both changes, a moment is never before its day's start.
        let start = moment("2026-10-31T00:00:00Z")
        for step in 0..<(24 * 4 * 3) {
            let date = start.addingTimeInterval(Double(step) * 900)
            let day = DayFile.day(of: date, calendar: newYork)
            let dayStart = DayFile.dayStart(of: day, calendar: newYork)!
            XCTAssertGreaterThanOrEqual(date, dayStart, "\(date) filed under \(day)")
            XCTAssertLessThan(date.timeIntervalSince(dayStart), 25 * 3600, "\(date) filed under \(day)")
        }
    }
}
