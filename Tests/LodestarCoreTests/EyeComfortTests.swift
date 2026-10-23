import XCTest
@testable import LodestarCore

private func tzNamed(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

private func wallDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, in zone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func contrast(_ a: Readability.RGB, _ b: Readability.RGB) -> Double {
    Readability.contrast(a.luminance, b.luminance)
}

/// Where the sun is: by the almanac, to a few minutes, and where the Mac is,
/// from its time zone alone.
final class SunTests: XCTestCase {
    /// Minutes after local midnight.
    private func minutes(_ instant: Date, in zone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return instant.timeIntervalSince(calendar.startOfDay(for: instant)) / 60
    }

    /// Days whose times the NOAA calculator publishes to the minute for the
    /// city's own coordinates; ours is allowed three.
    func testTheSunRisesAndSetsWhereTheAlmanacSaysItDoes() {
        let newYork = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let cases: [(String, Coordinate, (Int, Int, Int), Double, Double)] = [
            ("America/New_York", newYork, (2026, 6, 21), 5 * 60 + 25, 20 * 60 + 31),
            ("America/New_York", newYork, (2026, 12, 21), 7 * 60 + 16, 16 * 60 + 32),
            ("Europe/London", Coordinate(latitude: 51.5074, longitude: -0.1278), (2026, 12, 21), 8 * 60 + 4, 15 * 60 + 53),
            ("Australia/Sydney", Coordinate(latitude: -33.8688, longitude: 151.2093), (2026, 12, 21), 5 * 60 + 41, 20 * 60 + 5),
            ("Asia/Kolkata", Coordinate(latitude: 28.6139, longitude: 77.2090), (2026, 3, 20), 6 * 60 + 25, 18 * 60 + 33),
            ("Asia/Tokyo", Coordinate(latitude: 35.6762, longitude: 139.6503), (2026, 6, 21), 4 * 60 + 25, 19 * 60),
            ("Atlantic/Reykjavik", Coordinate(latitude: 64.1466, longitude: -21.9426), (2026, 12, 21), 11 * 60 + 22, 15 * 60 + 30),
        ]
        for (id, place, day, sunrise, sunset) in cases {
            let tz = tzNamed(id)
            guard case .rises(let up, let down) = Sun.day(containing: wallDate(day.0, day.1, day.2, in: tz), at: place, in: tz) else {
                return XCTFail("\(id) has a sunrise")
            }
            XCTAssertEqual(minutes(up, in: tz), sunrise, accuracy: 3, "\(id) \(day) sunrise")
            XCTAssertEqual(minutes(down, in: tz), sunset, accuracy: 3, "\(id) \(day) sunset")
        }
    }

    func testTheSunDoesNotSetInTheMidnightSunAndDoesNotRiseInThePolarNight() {
        let tromso = Coordinate(latitude: 69.6492, longitude: 18.9553), tz = tzNamed("Europe/Oslo")
        XCTAssertEqual(Sun.day(containing: wallDate(2026, 6, 21, in: tz), at: tromso, in: tz), .polarDay)
        XCTAssertEqual(Sun.day(containing: wallDate(2026, 12, 21, in: tz), at: tromso, in: tz), .polarNight)
    }

    /// Where the sun does not set or rise the day is fixed: up at 07:00,
    /// down at 21:00, and bedtime is the latest it can be.
    func testThePolarFallbackIsSevenAndNine() {
        let oslo = tzNamed("Europe/Oslo"), tromso = Coordinate(latitude: 69.6492, longitude: 18.9553)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = oslo
        for (month, label) in [(6, "the midnight sun"), (12, "the polar night")] {
            let day = wallDate(2026, month, 21, in: oslo)
            let times = EyeComfort.times(onDayOf: day, at: tromso, in: oslo)
            let midnight = calendar.startOfDay(for: day)
            XCTAssertEqual(times.sunrise.timeIntervalSince(midnight) / 3_600, 7, accuracy: 0.001, "\(label): up at seven")
            XCTAssertEqual(times.sunset.timeIntervalSince(midnight) / 3_600, 21, accuracy: 0.001, "\(label): down at nine")
            XCTAssertEqual(times.bedtime.timeIntervalSince(midnight) / 3_600, 24.5, accuracy: 0.001, "\(label): bed at half past twelve")
            let evening = EyeComfort.level(at: wallDate(2026, month, 21, 22, 30, in: oslo), place: tromso, zone: oslo)
            XCTAssertLessThan(evening, 0.96, "\(label): the evening still comes")
            XCTAssertEqual(EyeComfort.level(at: wallDate(2026, month, 21, 12, in: oslo), place: tromso, zone: oslo), 1, "\(label): and the day is full")
        }
    }

    /// A zone wider than its sun: a western place's sunset can be after
    /// midnight by the zone's clock, and it is still that day's.
    func testASunsetAfterMidnightIsStillThatDays() {
        let tz = tzNamed("Asia/Shanghai"), kashgar = Coordinate(latitude: 39.47, longitude: 75.99)
        guard case .rises(let up, let down) = Sun.day(containing: wallDate(2026, 6, 21, in: tz), at: kashgar, in: tz) else {
            return XCTFail("rises")
        }
        XCTAssertGreaterThan(down, up)
        XCTAssertGreaterThan(minutes(down, in: tz), 22 * 60, "late by the zone's clock")
        XCTAssertLessThan(down.timeIntervalSince(up), 17 * 3_600, "and the day is the day's length, not a day more")
    }

    // MARK: - Where the Mac is

    func testACoordinateIsReadFromTheTableAsItIsWritten() {
        let ny = ZoneCoordinates.coordinate(iso6709: "+404251-0740023")!
        XCTAssertEqual(ny.latitude, 40.7142, accuracy: 0.001)
        XCTAssertEqual(ny.longitude, -74.0064, accuracy: 0.001)
        let minutesOnly = ZoneCoordinates.coordinate(iso6709: "-3352+15113")!
        XCTAssertEqual(minutesOnly.latitude, -33.8667, accuracy: 0.001)
        XCTAssertEqual(minutesOnly.longitude, 151.2167, accuracy: 0.001)
        for bad in ["", "4042-07400", "+40-074", "+4042_07400", "+9942+07400", "+4042+18100", "+40x2-07400"] {
            XCTAssertNil(ZoneCoordinates.coordinate(iso6709: bad), bad)
        }
    }

    private let zone1970 = """
        # tzdb timezone descriptions
        #country-\tcoordinates\tTZ\tcomments
        CA,BS\t+4339-07923\tAmerica/Toronto\tEastern - ON, QC (most areas)
        US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)
        DE,DK,NO,SE,SJ\t+5230+01322\tEurope/Berlin\tmost of Germany
        AU\t-3352+15113\tAustralia/Sydney\tNew South Wales (most areas)
        """

    func testATableIsReadByZoneAndAZoneItLacksFallsBackToTheMeridian() {
        let table = ZoneCoordinates.parse(zone1970)
        XCTAssertEqual(table.count, 4, "comments and the header are not zones")
        XCTAssertEqual(table["Europe/Berlin"]?.longitude ?? 0, 13.3667, accuracy: 0.001)

        let known = ZoneCoordinates.estimate(identifier: "America/New_York", tables: [zone1970],
                                             standardOffset: -5 * 3_600, southern: false)
        XCTAssertEqual(known.latitude, 40.7, accuracy: 0.1)

        let second = ZoneCoordinates.estimate(identifier: "Europe/Amsterdam", tables: [zone1970, "NL\t+5222+00454\tEurope/Amsterdam\n"],
                                              standardOffset: 3_600, southern: false)
        XCTAssertEqual(second.latitude, 52.3667, accuracy: 0.01, "the second table answers for a zone the first merged away")

        let north = ZoneCoordinates.estimate(identifier: "Mars/Olympus", tables: [zone1970], standardOffset: 5.5 * 3_600, southern: false)
        XCTAssertEqual(north, Coordinate(latitude: 40, longitude: 82.5))
        let south = ZoneCoordinates.estimate(identifier: "Mars/Olympus", tables: [], standardOffset: -3 * 3_600, southern: true)
        XCTAssertEqual(south, Coordinate(latitude: -35, longitude: -45))
        XCTAssertEqual(ZoneCoordinates.fallback(standardOffset: 14 * 3_600, southern: false).longitude, 180, "clamped to the globe")
    }

    /// The tables the Mac really carries name every zone a Mac can be in; a
    /// zone the first merged away is in the second.
    func testTheMacsOwnTablesPlaceTheZonesItCanBeIn() throws {
        // zone.tab is the one a Mac is sure to carry; zone1970.tab where it has it.
        let tables = ["/usr/share/zoneinfo/zone1970.tab", "/usr/share/zoneinfo/zone.tab"]
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        guard !tables.isEmpty else { throw XCTSkip("this Mac has no zone tables") }
        let newYork = ZoneCoordinates.estimate(identifier: "America/New_York", tables: tables, standardOffset: -5 * 3_600, southern: false)
        XCTAssertEqual(newYork.latitude, 40.7, accuracy: 0.5)
        XCTAssertEqual(newYork.longitude, -74, accuracy: 0.5)
        let sydney = ZoneCoordinates.estimate(identifier: "Australia/Sydney", tables: tables, standardOffset: 10 * 3_600, southern: true)
        XCTAssertEqual(sydney.latitude, -33.9, accuracy: 0.5)
        let amsterdam = ZoneCoordinates.estimate(identifier: "Europe/Amsterdam", tables: tables, standardOffset: 3_600, southern: false)
        XCTAssertEqual(amsterdam.latitude, 52.4, accuracy: 0.5, "a zone zone1970.tab merged away is still placed")
    }
}

/// The schedule: when the evening begins, where bedtime falls and how much of
/// its luminance a bright colour keeps at every minute.
final class EyeComfortScheduleTests: XCTestCase {
    private let tz = tzNamed("America/New_York")
    private let newYork = Coordinate(latitude: 40.7128, longitude: -74.0060)

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date { wallDate(y, m, d, h, min, in: tz) }
    private func level(_ instant: Date) -> Double { EyeComfort.level(at: instant, place: newYork, zone: tz) }

    /// The wall clock's hour, in hours and fractions, counted from the
    /// midnight of `day` when given (so half past midnight after is 24.5).
    private func clock(_ instant: Date, from day: Date? = nil, in zone: TimeZone? = nil) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? tz
        guard let day else {
            let wall = calendar.dateComponents([.hour, .minute], from: instant)
            return Double(wall.hour ?? 0) + Double(wall.minute ?? 0) / 60
        }
        let parts = calendar.dateComponents([.day, .hour, .minute], from: calendar.startOfDay(for: day), to: instant)
        return Double(parts.day ?? 0) * 24 + Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    // MARK: - Bedtime

    /// Sunset and four hours, held between half past nine and half past twelve.
    func testBedtimeIsFourHoursAfterSunsetHeldBetweenHalfPastNineAndHalfPastTwelve() {
        let winter = EyeComfort.times(onDayOf: at(2026, 12, 21), at: newYork, in: tz)
        XCTAssertEqual(clock(winter.sunset), 16.53, accuracy: 0.06)
        XCTAssertEqual(clock(winter.bedtime), 21.5, accuracy: 0.02, "a 4:30 sunset would put bed at 8:30; no earlier than 21:30")

        let autumn = EyeComfort.times(onDayOf: at(2026, 10, 21), at: newYork, in: tz)
        XCTAssertEqual(clock(autumn.bedtime) - clock(autumn.sunset), 4, accuracy: 0.02, "in the middle, four hours")

        let summer = EyeComfort.times(onDayOf: at(2026, 6, 21), at: newYork, in: tz)
        XCTAssertEqual(clock(summer.bedtime, from: summer.sunset), 24.5, accuracy: 0.02, "an 8:30 sunset would put bed at 12:30; no later")
        XCTAssertEqual(summer.bedtime.timeIntervalSince(summer.sunset) / 3_600, 4, accuracy: 0.6, "a few hours after the sun is down")
    }

    // MARK: - The level

    func testTheDayIsFullAndTheEveningEasesDownToTheContractsLevels() {
        let times = EyeComfort.times(onDayOf: at(2026, 10, 21), at: newYork, in: tz)
        XCTAssertEqual(level(at(2026, 10, 21, 12)), 1)
        XCTAssertEqual(level(times.sunset.addingTimeInterval(-60)), 1, "nothing before the sun is down")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(1_800)), 0.98, accuracy: 0.0005, "half-way up the first ease")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(3_600)), 0.96, accuracy: 0.0005, "96% an hour after sunset")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(2 * 3_600)), 0.92, accuracy: 0.0005, "half-way up the second")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(3 * 3_600)), 0.88, accuracy: 0.0005, "88% three hours after")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(3.5 * 3_600)), 0.88, accuracy: 0.0005, "held until bedtime")
    }

    func testBedtimeEasesToTheDeepestAndHoldsUntilTheSunIsUp() {
        let times = EyeComfort.times(onDayOf: at(2026, 12, 21), at: newYork, in: tz)  // bedtime 21:30, the clamp
        let wake = EyeComfort.times(onDayOf: at(2026, 12, 22), at: newYork, in: tz).sunrise
        XCTAssertEqual(level(times.bedtime.addingTimeInterval(-60)), 0.88, accuracy: 0.0005)
        XCTAssertEqual(level(times.bedtime.addingTimeInterval(EyeComfort.bedtimeEase / 2)), 0.84, accuracy: 0.0005)
        XCTAssertEqual(level(times.bedtime.addingTimeInterval(EyeComfort.bedtimeEase)), 0.80, accuracy: 0.0005)
        XCTAssertEqual(level(at(2026, 12, 22, 2, 0)), 0.80, accuracy: 0.0005, "past midnight, still the deepest")
        XCTAssertEqual(level(wake.addingTimeInterval(-60)), 0.80, accuracy: 0.0005)
    }

    func testTheMorningEasesBackToFullOverTwoHours() {
        let wake = EyeComfort.times(onDayOf: at(2026, 10, 22), at: newYork, in: tz).sunrise
        XCTAssertEqual(level(wake), 0.80, accuracy: 0.0005, "the deepest at sunrise")
        XCTAssertEqual(level(wake.addingTimeInterval(3_600)), 0.8 * pow(1.25, 0.5), accuracy: 0.0005, "a constant share of what is there at each step")
        XCTAssertEqual(level(wake.addingTimeInterval(7_200)), 1, accuracy: 0.0005)
        XCTAssertEqual(level(at(2026, 10, 22, 10)), 1)
    }

    /// Where bedtime comes before the evening has finished easing (a sunset
    /// at half past ten), the deeper dim waits for it rather than cutting in.
    func testALateSunsetNeverJumpsToTheDeepest() {
        let stockholm = tzNamed("Europe/Stockholm"), place = Coordinate(latitude: 59.3293, longitude: 18.0686)
        var instant = wallDate(2026, 6, 21, 12, in: stockholm)
        for _ in 0..<(18 * 60) {
            instant = instant.addingTimeInterval(60)
            let now = EyeComfort.level(at: instant, place: place, zone: stockholm)
            let before = EyeComfort.level(at: instant.addingTimeInterval(-300), place: place, zone: stockholm)
            XCTAssertLessThan(abs(now - before) / before, 0.01, "no step of 1% at \(instant)")
        }
    }

    /// The level at every minute of a day, at four places and every season:
    /// never above full nor under the deepest, and no step of five minutes seen.
    func testTheLevelAtEveryMinuteOfADayStaysInTheScheduleAndNeverStepsByOnePercent() {
        let places: [(String, Coordinate)] = [
            ("America/New_York", newYork), ("Europe/London", Coordinate(latitude: 51.5074, longitude: -0.1278)),
            ("Australia/Sydney", Coordinate(latitude: -33.8688, longitude: 151.2093)),
            ("Asia/Kolkata", Coordinate(latitude: 28.6139, longitude: 77.2090)),
            ("Europe/Oslo", Coordinate(latitude: 69.6492, longitude: 18.9553)),
        ]
        for (id, place) in places {
            let tz = tzNamed(id)
            for (month, day) in [(1, 15), (3, 20), (6, 21), (9, 22), (12, 21)] {
                var instant = wallDate(2026, month, day, 0, 0, in: tz)
                for minute in 1...(2 * 24 * 60) {
                    instant = instant.addingTimeInterval(60)
                    let now = EyeComfort.level(at: instant, place: place, zone: tz)
                    let before = EyeComfort.level(at: instant.addingTimeInterval(-EyeComfort.beat), place: place, zone: tz)
                    XCTAssertGreaterThanOrEqual(now, EyeComfort.bedtime - 1e-9, "\(id) \(month)/\(day) +\(minute)m")
                    XCTAssertLessThanOrEqual(now, 1 + 1e-9, "\(id) \(month)/\(day) +\(minute)m")
                    // A step of five minutes, the beat, is under 1% of the
                    // luminance there was.
                    XCTAssertLessThan(abs(now - before) / before, 0.01, "\(id) \(month)/\(day) +\(minute)m")
                }
            }
        }
        // And the day is full: noon, wherever there is a noon.
        for (id, place) in places.dropLast() {
            XCTAssertEqual(EyeComfort.level(at: wallDate(2026, 3, 20, 13, in: tzNamed(id)), place: place, zone: tzNamed(id)), 1, id)
        }
    }

    /// A clock change or a zone change gives a level with no memory of the
    /// old clock: the same instant in another zone is the schedule there.
    func testTheLevelIsAFunctionOfTheInstantThePlaceAndTheZoneAlone() {
        let instant = at(2026, 10, 21, 21, 45)
        let here = EyeComfort.level(at: instant, place: newYork, zone: tz)
        XCTAssertLessThan(here, 0.9, "late evening in New York")
        let tokyo = tzNamed("Asia/Tokyo")
        XCTAssertEqual(EyeComfort.level(at: instant, place: Coordinate(latitude: 35.68, longitude: 139.65), zone: tokyo), 1,
                       "the same instant is mid-morning there")
        XCTAssertEqual(EyeComfort.level(at: instant, place: newYork, zone: tz), here, "and asking again changes nothing")
    }
}

/// What the level does to the looks: luminance and nothing else, and the
/// floors at every level.
final class EyeComfortLooksTests: XCTestCase {
    private let looks: [(name: String, steps: Palette.Steps, other: Palette.Steps)] = [
        ("clay", Palette.clay, Palette.night), ("espresso", Palette.night, Palette.clay),
    ]
    /// Every level the schedule can reach, a thousandth apart.
    private var levels: [Double] { stride(from: 1.0, through: EyeComfort.bedtime - 1e-9, by: -0.001).map { $0 } }

    private func resolved(_ steps: Palette.Steps, _ level: Double) -> Palette.Steps { EyeComfort.steps(steps, level: level) }

    func testFullIsExactlyTheLookAsItIs() {
        XCTAssertEqual(EyeComfort.steps(Palette.clay, level: 1), Palette.clay)
        XCTAssertEqual(EyeComfort.steps(Palette.night, level: 1), Palette.night)
        XCTAssertEqual(EyeComfort.steps(Palette.clay, level: 1.2), Palette.clay, "never brighter than full")
    }

    /// The contract's own numbers: the pane in the evening and at bedtime,
    /// and what the inks measure on it.
    func testTheContractsNumbersHold() {
        func hex(_ c: Readability.RGB) -> String {
            String(format: "#%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()))
        }
        let evening = resolved(Palette.clay, 0.88), bed = resolved(Palette.clay, 0.80)
        XCTAssertEqual(hex(evening.pane), "#E9E2DB")
        XCTAssertEqual(contrast(evening.ink, evening.pane), 13.7, accuracy: 0.05)
        XCTAssertEqual(contrast(evening.quietInk, evening.pane), 5.3, accuracy: 0.05)
        XCTAssertEqual(hex(bed.pane), "#DFD9D2")
        XCTAssertEqual(contrast(bed.ink, bed.pane), 12.5, accuracy: 0.05)
        // The dark look: the ink dims to 80% of its luminance, about 12 to 1, quiet ink 5.5.
        let night = resolved(Palette.night, 0.80)
        XCTAssertEqual(night.ink.luminance, Palette.night.ink.luminance * 0.8, accuracy: 1e-9)
        XCTAssertEqual(contrast(night.ink, night.pane), 12.0, accuracy: 0.1)
        XCTAssertEqual(contrast(night.quietInk, night.pane), 5.5, accuracy: 0.05)
        // By day the quiet ink reaches its floor near 72% of luminance.
        XCTAssertEqual(contrast(Palette.clay.quietInk, Palette.clay.pane.scaled(luminanceBy: 0.72)), 4.5, accuracy: 0.1)
    }

    /// The dimming is luminance: every channel together in linear light, so
    /// hue and saturation (chroma over lightness) are exactly what they were,
    /// and luminance is exactly the level.
    func testDimmingScalesLuminanceAndLeavesHueAndSaturationExactlyAlone() {
        func check(_ full: Readability.RGB, _ dimmed: Readability.RGB, level: Double, _ what: String) {
            XCTAssertEqual(dimmed.luminance, full.luminance * level, accuracy: 1e-9, "\(what) luminance at \(level)")
            XCTAssertEqual(dimmed.hue, full.hue, accuracy: 1e-6, "\(what) hue at \(level)")
            XCTAssertEqual(dimmed.chroma / dimmed.lightness, full.chroma / full.lightness, accuracy: 1e-9,
                           "\(what) saturation at \(level)")
        }
        for level in [0.99, 0.96, 0.92, 0.88, 0.84, 0.8] {
            let day = resolved(Palette.clay, level), night = resolved(Palette.night, level)
            for (name, full, now) in [("ground", Palette.clay.ground, day.ground), ("pane", Palette.clay.pane, day.pane),
                                      ("key", Palette.clay.key, day.key), ("side", Palette.clay.side, day.side),
                                      ("well", Palette.clay.well, day.well)] {
                check(full, now, level: level, "clay \(name)")
            }
            for (name, full, now) in [("ink", Palette.night.ink, night.ink), ("slab", Palette.night.slab, night.slab),
                                      ("slab side", Palette.night.slabSide, night.slabSide)] {
                check(full, now, level: level, "espresso \(name)")
            }
        }
    }

    /// Which colours dim: the surfaces by day; the ink, the slab by night.
    /// Nothing else moves except what a floor makes it.
    func testByDayTheSurfacesDimAndByNightTheInkAndTheSlab() {
        let day = resolved(Palette.clay, 0.8), night = resolved(Palette.night, 0.8)
        for (full, now) in [(Palette.clay.ground, day.ground), (Palette.clay.pane, day.pane), (Palette.clay.key, day.key),
                            (Palette.clay.side, day.side), (Palette.clay.well, day.well)] {
            XCTAssertLessThan(now.luminance, full.luminance)
        }
        XCTAssertEqual(day.slab, Palette.clay.slab, "the day's slab is dark and stays")
        XCTAssertEqual(day.ink, Palette.clay.ink, "dark ink is not dimmed")
        XCTAssertEqual(night.ground, Palette.night.ground)
        XCTAssertEqual(night.pane, Palette.night.pane)
        XCTAssertEqual(night.key, Palette.night.key)
        XCTAssertEqual(night.side, Palette.night.side)
        XCTAssertEqual(night.well, Palette.night.well)
        XCTAssertLessThan(night.ink.luminance, Palette.night.ink.luminance)
        XCTAssertLessThan(night.quietInk.luminance, Palette.night.quietInk.luminance)
        XCTAssertLessThan(night.slab.luminance, Palette.night.slab.luminance)
        XCTAssertEqual(day.isDark, false)
        XCTAssertEqual(night.isDark, true)
    }

    /// The orange calms by up to 10% of its chroma at the same hue; its
    /// lightness falls only as far as the floor asks. By night it dims with
    /// the ink and keeps its hue and saturation.
    func testTheOrangeCalmsByDayAndDimsWithTheInkByNightAtTheSameHue() {
        for level in levels {
            let day = resolved(Palette.clay, level)
            XCTAssertEqual(day.orange.hue, Palette.clay.orange.hue, accuracy: 0.3, "hue at \(level)")
            let kept = day.orange.chroma / Palette.clay.orange.chroma
            XCTAssertGreaterThanOrEqual(kept, 0.9 - 1e-6, "no more than 10% of the chroma goes, at \(level)")
            XCTAssertLessThanOrEqual(kept, 1 + 1e-6)
            XCTAssertLessThanOrEqual(day.orange.lightness, Palette.clay.orange.lightness + 1e-9, "only ever deeper")

            let night = resolved(Palette.night, level)
            XCTAssertEqual(night.orange.hue, Palette.night.orange.hue, accuracy: 1e-6)
            XCTAssertEqual(night.orange.chroma / night.orange.lightness,
                           Palette.night.orange.chroma / Palette.night.orange.lightness, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(night.orange.luminance, Palette.night.orange.luminance + 1e-12)
        }
        XCTAssertEqual(resolved(Palette.clay, 0.8).orange.chroma / Palette.clay.orange.chroma, 0.9, accuracy: 0.011,
                       "the full 10% at the deepest")
        XCTAssertEqual(resolved(Palette.clay, 0.96).orange.chroma / Palette.clay.orange.chroma, 0.98, accuracy: 0.011)
    }

    /// The floors, at every level in both looks: ink 7 to 1 and quiet ink 4.5
    /// on every surface they stand on, the orange 4.5 as text on the pane, a
    /// lit fill 3 to 1 on its pane and key, the letter on it 4.5, and the
    /// other look's marks on this look's slab.
    func testEveryFloorHoldsAtEveryLevelInBothLooks() {
        for level in levels {
            for (name, full, otherFull) in looks {
                let look = resolved(full, level), other = resolved(otherFull, level)
                let surfaces: [(String, Readability.RGB)] = [("pane", look.pane), ("key", look.key), ("ground", look.ground), ("well", look.well)]
                for (surface, ground) in surfaces {
                    XCTAssertGreaterThanOrEqual(contrast(look.ink, ground), 7, "\(name) ink on \(surface) at \(level)")
                    XCTAssertGreaterThanOrEqual(contrast(look.quietInk, ground), 4.5, "\(name) quiet ink on \(surface) at \(level)")
                }
                XCTAssertGreaterThanOrEqual(contrast(look.orange, look.pane), 4.5, "\(name) orange as text at \(level)")
                XCTAssertGreaterThanOrEqual(contrast(look.orange, look.key), 3, "\(name) a lit fill on a key at \(level)")
                XCTAssertGreaterThanOrEqual(contrast(look.orange, look.well), 3, "\(name) a lit fill on a well at \(level)")
                XCTAssertGreaterThanOrEqual(contrast(look.letterOnOrange, look.orange), 4.5, "\(name) letter on the orange at \(level)")
                XCTAssertGreaterThanOrEqual(contrast(look.ink, look.key), 7, "\(name) key letter at \(level)")
                // The other look's marks on this look's slab.
                XCTAssertGreaterThanOrEqual(contrast(other.ink, look.slab), 7, "\(name): other ink on the slab at \(level)")
                XCTAssertGreaterThanOrEqual(contrast(other.quietInk, look.slab), 4.5, "\(name): other quiet ink on the slab at \(level)")
                XCTAssertGreaterThanOrEqual(contrast(other.orange, look.slab), 3, "\(name): other orange on the slab at \(level)")
            }
        }
    }

    /// The deepest by day: what the contract measures, and that the quiet
    /// ink is only moved where a floor asks.
    func testTheQuietInkOnlyDeepensWhereAFloorAsksIt() {
        XCTAssertEqual(resolved(Palette.clay, 0.88).quietInk, Palette.clay.quietInk, "untouched at 88%")
        XCTAssertEqual(resolved(Palette.clay, 0.96).quietInk, Palette.clay.quietInk)
        let deepest = resolved(Palette.clay, 0.8)
        XCTAssertLessThan(deepest.quietInk.luminance, Palette.clay.quietInk.luminance, "deepened at 80%, where the well would lose it")
        XCTAssertEqual(deepest.quietInk.hue, Palette.clay.quietInk.hue, accuracy: 1e-6)
    }

    // MARK: - Receding

    func testRecedingMovesTheInksToTheirFloorsAndKeepsTheirOrder() {
        for level in levels {
            for (name, full, _) in looks {
                let look = resolved(full, level)
                let receded = Receding.inks(of: look)
                let ink = contrast(receded.ink, look.pane), quiet = contrast(receded.quietInk, look.pane)
                XCTAssertEqual(ink, 5.5, accuracy: 0.01, "\(name) ink at \(level)")
                XCTAssertGreaterThanOrEqual(ink, 5.5)
                XCTAssertGreaterThanOrEqual(quiet, 4.5, "\(name) quiet ink at \(level)")
                XCTAssertLessThanOrEqual(quiet, max(4.5, contrast(look.quietInk, look.pane)) + 0.01)
                XCTAssertGreaterThan(ink, quiet, "\(name): the two keep their order at \(level)")
                XCTAssertEqual(receded.ink.hue, look.ink.hue, accuracy: 1e-6, "receding does not tint")
                XCTAssertEqual(receded.quietInk.hue, look.quietInk.hue, accuracy: 1e-6)
                XCTAssertNotEqual(receded.ink, look.ink)
                // Quieter, never louder: a receded ink is nearer its pane.
                XCTAssertLessThan(ink, contrast(look.ink, look.pane))
            }
        }
    }

    /// An ink already quieter than the floor it would recede to is left
    /// alone: receding never raises a contrast.
    func testRecedingNeverRaisesAContrast() {
        let pane = Palette.night.pane, quiet = Palette.night.quietInk
        let already = quiet.scaled(luminanceBy: 0.5)
        XCTAssertLessThan(contrast(already, pane), 4.5 + 0.002)
        XCTAssertEqual(Receding.receded(already, on: pane, to: 4.5), already)
    }
}
