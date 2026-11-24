import XCTest
@testable import LodestarCore

/// The day's shape. These measures are borrowed from actigraphy rather
/// than invented here, which is the point of them — so the tests pin
/// them against cases whose answers the definitions fix in advance, not
/// against whatever the code happened to return first.
final class CircadianTests: XCTestCase {
    /// A fixed calendar, so a test run in one timezone and a test run in
    /// another are the same test.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    /// Midnight UTC on a known Monday.
    private let monday = Date(timeIntervalSince1970: 1_756_684_800)

    private func pulse(day: Int, hour: Int, minutes: Int = 15) -> ObservationEvent {
        var event = ObservationEvent(
            t: monday.addingTimeInterval(Double(day) * 86_400 + Double(hour) * 3600),
            kind: .pulse)
        event.activeMinutes = minutes
        event.keys = minutes * 100
        return event
    }

    /// Identical days are perfectly stable, by the definition: the
    /// average day explains all of the variance there is.
    func testIdenticalDaysAreStable() throws {
        var events: [ObservationEvent] = []
        for day in 0..<14 {
            for hour in [9, 10, 11, 14, 15, 16] { events.append(pulse(day: day, hour: hour)) }
        }
        let profile = try XCTUnwrap(Circadian.profile(
            events: events, days: 30,
            now: monday.addingTimeInterval(14 * 86_400), calendar: calendar))
        XCTAssertEqual(profile.days, 14)
        XCTAssertEqual(try XCTUnwrap(profile.interdailyStability), 1.0, accuracy: 0.001,
                       "every day the same is stability one")
    }

    /// A schedule that lands somewhere different every day has the same
    /// hours in it and almost none of the structure.
    func testScatteredDaysAreNot() throws {
        var stable: [ObservationEvent] = []
        var scattered: [ObservationEvent] = []
        for day in 0..<14 {
            for hour in [9, 10, 11] { stable.append(pulse(day: day, hour: hour)) }
            let shift = (day * 7) % 24
            for offset in 0..<3 { scattered.append(pulse(day: day, hour: (shift + offset) % 24)) }
        }
        let a = try XCTUnwrap(Circadian.profile(events: stable, days: 30,
                                                now: monday.addingTimeInterval(14 * 86_400),
                                                calendar: calendar).flatMap { $0.interdailyStability })
        let b = try XCTUnwrap(Circadian.profile(events: scattered, days: 30,
                                                now: monday.addingTimeInterval(14 * 86_400),
                                                calendar: calendar).flatMap { $0.interdailyStability })
        XCTAssertGreaterThan(a, b + 0.3, "the same hours every day beats the same hours scattered")
    }

    /// Activity that starts and stops is more broken up than the same
    /// amount of it in one block.
    func testFragmentationSeparatesBlocksFromFlicker() throws {
        var solid: [ObservationEvent] = []
        var broken: [ObservationEvent] = []
        for day in 0..<10 {
            for hour in 9..<17 { solid.append(pulse(day: day, hour: hour)) }
            for hour in stride(from: 8, to: 24, by: 2) { broken.append(pulse(day: day, hour: hour)) }
        }
        let end = monday.addingTimeInterval(10 * 86_400)
        let a = try XCTUnwrap(Circadian.profile(events: solid, days: 30, now: end,
                                                calendar: calendar)?.intradailyVariability)
        let b = try XCTUnwrap(Circadian.profile(events: broken, days: 30, now: end,
                                                calendar: calendar)?.intradailyVariability)
        XCTAssertLessThan(a, b, "eight hours straight is less broken up than eight hours every other hour")
    }

    func testMostAndLeastActiveWindows() throws {
        var events: [ObservationEvent] = []
        for day in 0..<10 {
            for hour in 10..<20 { events.append(pulse(day: day, hour: hour)) }
        }
        let profile = try XCTUnwrap(Circadian.profile(
            events: events, days: 30, now: monday.addingTimeInterval(10 * 86_400),
            calendar: calendar))
        XCTAssertEqual(profile.m10Hour, 10, "the ten busiest hours begin where the work does")
        XCTAssertEqual(try XCTUnwrap(profile.l5), 0, accuracy: 0.001,
                       "and the quietest five are empty")
        XCTAssertEqual(try XCTUnwrap(profile.relativeAmplitude), 1.0, accuracy: 0.001)
    }

    /// The day begins at four in the morning, not at midnight. Work that
    /// runs to 1am belongs to the evening it started in; a midnight
    /// boundary would cut that evening in half and call it two days.
    func testTheDayBeginsAtFourNotMidnight() throws {
        var events: [ObservationEvent] = []
        for day in 0..<6 {
            for hour in [20, 21, 22, 23] { events.append(pulse(day: day, hour: hour)) }
            // And on past midnight, which is still the same working day.
            for hour in [0, 1] { events.append(pulse(day: day + 1, hour: hour)) }
        }
        let profile = try XCTUnwrap(Circadian.profile(
            events: events, days: 30, now: monday.addingTimeInterval(8 * 86_400),
            calendar: calendar))
        XCTAssertEqual(profile.days, 6,
                       "six evenings, each with its own small hours attached — not twelve half-days")
        let onset = try XCTUnwrap(profile.onsetHour)
        XCTAssertEqual(onset, 20, accuracy: 1.5, "the evening starts at eight")
        let offset = try XCTUnwrap(profile.offsetHour)
        XCTAssertGreaterThan(offset, 24, "and ends after midnight, said as hour twenty-five")
    }

    /// The weekend drifting later is the shape social jetlag names. It
    /// is measured on activity here, not on sleep, which is the proxy
    /// this data can honestly support and not the clinical definition.
    func testWeekendDriftShowsAsAShift() throws {
        var events: [ObservationEvent] = []
        for day in 0..<21 {
            let date = monday.addingTimeInterval(Double(day) * 86_400)
            let weekday = calendar.component(.weekday, from: date)
            let weekend = (weekday == 1 || weekday == 7)
            for hour in (weekend ? [16, 17, 18, 19] : [9, 10, 11, 12]) {
                events.append(pulse(day: day, hour: hour))
            }
        }
        let profile = try XCTUnwrap(Circadian.profile(
            events: events, days: 30, now: monday.addingTimeInterval(21 * 86_400),
            calendar: calendar))
        let work = try XCTUnwrap(profile.workMidpointHour)
        let free = try XCTUnwrap(profile.freeMidpointHour)
        XCTAssertEqual(work, 11, accuracy: 0.6)
        XCTAssertEqual(free, 18, accuracy: 0.6)
        XCTAssertEqual(try XCTUnwrap(profile.socialJetlagHours), 7, accuracy: 1)
    }

    func testThinDataDeclinesToAnswer() throws {
        let profile = Circadian.profile(events: [pulse(day: 0, hour: 10)], days: 30,
                                        now: monday.addingTimeInterval(86_400),
                                        calendar: calendar)
        XCTAssertNil(profile?.interdailyStability, "one day cannot say how alike the days are")
        XCTAssertNil(Circadian.profile(events: [], days: 30, now: monday, calendar: calendar))
    }
}
