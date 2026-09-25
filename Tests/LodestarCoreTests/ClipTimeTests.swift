import XCTest
@testable import LodestarCore

/// A clip that is only a timestamp is read as the moment it names: how long
/// ago as it is felt, your clock, and the other zones. The value itself is
/// untouched.
final class ClipTimeTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let english = Locale(identifier: "en_US")
    /// 2026-09-25 13:14:17 UTC.
    private let moment = Date(timeIntervalSince1970: 1_790_342_057)

    func testUnixTimeInEveryUnit() {
        XCTAssertEqual(ClipTime.parse("1790342057")?.kind, .unix(.seconds))
        XCTAssertEqual(ClipTime.parse("1790342057")?.date, moment)
        XCTAssertEqual(ClipTime.parse("1790342057.5")?.date, moment.addingTimeInterval(0.5))
        XCTAssertEqual(ClipTime.parse("1790342057000")?.kind, .unix(.milliseconds))
        XCTAssertEqual(ClipTime.parse("1790342057000")?.date, moment)
        XCTAssertEqual(ClipTime.parse("1790342057000000")?.kind, .unix(.microseconds))
        XCTAssertEqual(ClipTime.parse("1790342057000000000")?.kind, .unix(.nanoseconds))
    }

    func testNumbersThatAreNotTimes() {
        XCTAssertNil(ClipTime.parse("2125551234"), "a US phone number: area codes start at 2")
        XCTAssertNil(ClipTime.parse("999999999"), "nine digits")
        XCTAssertNil(ClipTime.parse("12345"))
        XCTAssertNil(ClipTime.parse("1790342057000.5"), "a fraction only on seconds")
        XCTAssertNil(ClipTime.parse("it happened at 1790342057"), "a sentence")
        XCTAssertNil(ClipTime.parse("2026-13-40"), "no such day")
    }

    func testWrittenDates() {
        XCTAssertEqual(ClipTime.parse("2026-09-25T13:14:17Z")?.date, moment)
        XCTAssertEqual(ClipTime.parse("2026-09-25T22:14:17+09:00")?.date, moment)
        XCTAssertEqual(ClipTime.parse("2026-09-25T13:14:17.000Z")?.date, moment)
        XCTAssertEqual(ClipTime.parse("Fri, 25 Sep 2026 13:14:17 +0000")?.date, moment)
        XCTAssertEqual(ClipTime.parse("Fri, 25 Sep 2026 13:14:17 GMT")?.date, moment)
        XCTAssertEqual(ClipTime.parse("2026-09-25T13:14:17Z")?.kind, .written)
        XCTAssertEqual(ClipTime.parse("2026-09-25")?.kind, .day)
    }

    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    func testTheNoteIsTheFeltTimeYourClockAndTheOtherZones() throws {
        let time = try XCTUnwrap(ClipTime.parse("1790342057"))
        let note = time.note(local: newYork, zones: [tokyo], now: moment.addingTimeInterval(4 * 3600), locale: english)
        XCTAssertEqual(note.voice, "4 hours ago")
        XCTAssertEqual(plain(note.local), "9:14 AM", "the voice has named the day, so the clock is enough")
        XCTAssertEqual(note.zones.map(plain), ["1:14 PM UTC", "10:14 PM Tokyo"],
                       "13:14 UTC is 22:14 in Tokyo, still Friday there: no weekday")
    }

    func testAFarMomentKeepsItsDate() throws {
        let time = try XCTUnwrap(ClipTime.parse("1790342057"))
        let note = time.note(local: newYork, now: moment.addingTimeInterval(20 * 86_400), locale: english)
        XCTAssertEqual(note.voice, "2 weeks ago")
        XCTAssertTrue(note.local.contains("Sep 25"), "the voice no longer names the day: \(note.local)")
    }

    func testAnotherDaySaysWhichDay() throws {
        let time = try XCTUnwrap(ClipTime.parse("2026-09-25T23:30:00-04:00"))
        let note = time.note(local: newYork, zones: [tokyo], now: time.date, locale: english)
        XCTAssertTrue(note.zones[1].hasPrefix("Sat"), "Tokyo is already Saturday: \(note.zones[1])")
    }

    func testAZoneThatRepeatsTheValueOrYourClockIsLeftOut() throws {
        let written = try XCTUnwrap(ClipTime.parse("2026-09-25T22:14:17+09:00"))
        XCTAssertEqual(written.writtenOffset, 9 * 3600)
        XCTAssertEqual(written.note(local: newYork, zones: [tokyo], now: moment, locale: english).zones.map(plain),
                       ["1:14 PM UTC"], "the value already says Tokyo's time")
        let utc = try XCTUnwrap(ClipTime.parse("Fri, 25 Sep 2026 13:14:17 GMT"))
        XCTAssertEqual(utc.writtenOffset, 0)
        XCTAssertEqual(utc.note(local: newYork, zones: [tokyo], now: moment, locale: english).zones.map(plain),
                       ["10:14 PM Tokyo"], "the value already says UTC")
        let unix = try XCTUnwrap(ClipTime.parse("1790342057"))
        XCTAssertEqual(unix.note(local: TimeZone(identifier: "UTC")!, now: moment, locale: english).zones, [],
                       "your clock is UTC")
        XCTAssertEqual(unix.note(local: newYork, zones: [TimeZone(identifier: "America/Toronto")!], now: moment,
                                 locale: english).zones.map(plain), ["1:14 PM UTC"], "Toronto reads as New York")
    }

    func testADayIsItsWeekday() throws {
        let day = try XCTUnwrap(ClipTime.parse("2026-09-28"))
        let note = day.note(local: .current, zones: [tokyo], now: moment, locale: english)
        XCTAssertEqual(note.zones, [], "a day has no zones to read into")
        XCTAssertTrue(note.local.hasPrefix("Monday"), note.local)
        XCTAssertEqual(note.voice, "This Monday")
    }

    /// Now is Friday, 9:14 in the morning, in New York.
    func testTheTimeAsItIsFelt() {
        func felt(_ seconds: TimeInterval) -> String {
            ClipTime(date: moment.addingTimeInterval(seconds), kind: .unix(.seconds))
                .felt(now: moment, zone: newYork, locale: english)
        }
        let minute = 60.0, hour = 3600.0, day = 86_400.0
        XCTAssertEqual(felt(-30), "Just now")
        XCTAssertEqual(felt(30), "In a moment")
        XCTAssertEqual(felt(-minute), "A minute ago")
        XCTAssertEqual(felt(-20 * minute), "20 minutes ago")
        XCTAssertEqual(felt(20 * minute), "In 20 minutes")
        XCTAssertEqual(felt(-hour), "An hour ago")
        XCTAssertEqual(felt(5 * hour), "In 5 hours")
        XCTAssertEqual(felt(-day), "Yesterday morning")
        XCTAssertEqual(felt(-(11 * hour + 14 * minute)), "Last night", "Thursday at ten")
        XCTAssertEqual(felt(-3 * day + 6 * hour), "Tuesday afternoon")
        XCTAssertEqual(felt(day + 10 * hour), "Tomorrow evening")
        XCTAssertEqual(felt(-7 * day), "A week ago")
        XCTAssertEqual(felt(7 * day), "A week from today")
        XCTAssertEqual(felt(-10 * day), "10 days ago")
        XCTAssertEqual(felt(-21 * day), "3 weeks ago")
        XCTAssertEqual(felt(-100 * day), "3 months ago")
        XCTAssertEqual(felt(-400 * day), "August 2025")
    }

    func testADayIsFeltInDays() {
        func felt(_ days: Int) -> String {
            let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: moment)!
            return ClipTime(date: date, kind: .day).felt(now: moment, zone: newYork, locale: english)
        }
        XCTAssertEqual(felt(0), "Today")
        XCTAssertEqual(felt(-1), "Yesterday")
        XCTAssertEqual(felt(1), "Tomorrow")
        XCTAssertEqual(felt(-3), "Last Tuesday")
        XCTAssertEqual(felt(3), "This Monday")
        XCTAssertEqual(felt(7), "A week from today")
    }

    func testZonesFromWhatAHandTypes() {
        XCTAssertEqual(ClipTime.zone(named: "Asia/Tokyo")?.identifier, "Asia/Tokyo")
        XCTAssertEqual(ClipTime.zone(named: "tokyo")?.identifier, "Asia/Tokyo")
        XCTAssertEqual(ClipTime.zone(named: "New York")?.identifier, "America/New_York")
        XCTAssertNotNil(ClipTime.zone(named: "PST"))
        XCTAssertNil(ClipTime.zone(named: "Atlantis"))
        XCTAssertEqual(ClipTime.label(tokyo, at: moment), "Tokyo · UTC+9")
        XCTAssertEqual(ClipTime.label(TimeZone(identifier: "Asia/Kolkata")!, at: moment), "Kolkata · UTC+5:30")
        XCTAssertEqual(ClipTime.label(newYork, at: moment), "New York · UTC−4")
    }

    func testUTCIsListedOnce() {
        XCTAssertEqual(ClipTime.label(TimeZone(identifier: "UTC")!), "UTC")
    }
}
