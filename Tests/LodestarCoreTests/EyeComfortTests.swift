import XCTest
@testable import LodestarCore

/// Eye comfort, as mathematics: where the sun is, when the night is, how far
/// the surfaces have eased down, and what that does to the text. Each test
/// injects the place, the zone and the instant, so the answers are the same
/// on any Mac at any hour.
final class SunTests: XCTestCase {
    private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Minutes after local midnight.
    private func minutes(_ instant: Date, in zone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return instant.timeIntervalSince(calendar.startOfDay(for: instant)) / 60
    }

    /// Days whose times are published by the NOAA calculator, to the minute,
    /// for the place's own city; ours is allowed three.
    func testTheSunRisesAndSetsWhereTheAlmanacSaysItDoes() {
        let cases: [(String, Coordinate, (Int, Int, Int), Double, Double)] = [
            ("America/New_York", Coordinate(latitude: 40.7128, longitude: -74.0060), (2026, 6, 21), 5 * 60 + 25, 20 * 60 + 31),
            ("America/New_York", Coordinate(latitude: 40.7128, longitude: -74.0060), (2026, 12, 21), 7 * 60 + 16, 16 * 60 + 32),
            ("Europe/London", Coordinate(latitude: 51.5074, longitude: -0.1278), (2026, 12, 21), 8 * 60 + 4, 15 * 60 + 53),
            ("Australia/Sydney", Coordinate(latitude: -33.8688, longitude: 151.2093), (2026, 12, 21), 5 * 60 + 41, 20 * 60 + 5),
            ("Asia/Kolkata", Coordinate(latitude: 28.6139, longitude: 77.2090), (2026, 3, 20), 6 * 60 + 25, 18 * 60 + 33),
        ]
        for (id, place, day, sunrise, sunset) in cases {
            let tz = zone(id)
            guard case .rises(let up, let down) = Sun.day(containing: date(day.0, day.1, day.2, in: tz), at: place, in: tz) else {
                return XCTFail("\(id) has a sunrise")
            }
            XCTAssertEqual(minutes(up, in: tz), sunrise, accuracy: 3, "\(id) \(day) sunrise")
            XCTAssertEqual(minutes(down, in: tz), sunset, accuracy: 3, "\(id) \(day) sunset")
        }
    }

    func testTheSunDoesNotSetInTheMidnightSunAndDoesNotRiseInThePolarNight() {
        let tromso = Coordinate(latitude: 69.6492, longitude: 18.9553), tz = zone("Europe/Oslo")
        XCTAssertEqual(Sun.day(containing: date(2026, 6, 21, in: tz), at: tromso, in: tz), .polarDay)
        XCTAssertEqual(Sun.day(containing: date(2026, 12, 21, in: tz), at: tromso, in: tz), .polarNight)
    }

    /// A zone wider than its sun: a western place's sunset can be after
    /// midnight by the zone's clock, and it is still that day's.
    func testASunsetAfterMidnightIsStillThatDays() {
        let tz = zone("Asia/Shanghai"), kashgar = Coordinate(latitude: 39.47, longitude: 75.99)
        guard case .rises(let up, let down) = Sun.day(containing: date(2026, 6, 21, in: tz), at: kashgar, in: tz) else {
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
}

final class EyeComfortCurveTests: XCTestCase {
    private let tz = TimeZone(identifier: "America/New_York")!
    private let newYork = Coordinate(latitude: 40.7128, longitude: -74.0060)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func level(_ instant: Date) -> EyeComfort.Level {
        EyeComfort.level(at: instant, place: newYork, zone: tz)
    }

    /// The wall clock's hour, in hours and fractions.
    private func clock(_ instant: Date, from day: Date? = nil) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        guard let day else {
            let wall = calendar.dateComponents([.hour, .minute], from: instant)
            return Double(wall.hour ?? 0) + Double(wall.minute ?? 0) / 60
        }
        let parts = calendar.dateComponents([.day, .hour, .minute], from: calendar.startOfDay(for: day), to: instant)
        return Double(parts.day ?? 0) * 24 + Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    // MARK: - Bedtime

    /// Sunset and four hours, held between half past nine and half past twelve.
    func testBedtimeIsFourHoursAfterSunsetBetweenHalfPastNineAndHalfPastTwelve() {
        let winter = EyeComfort.times(onDayOf: date(2026, 12, 21), at: newYork, in: tz)
        XCTAssertEqual(clock(winter.sunset), 16.53, accuracy: 0.06)
        XCTAssertEqual(clock(winter.bedtime), 21.5, accuracy: 0.02, "a 4:30 sunset would put bed at 8:30; no earlier than 9:30")

        let autumn = EyeComfort.times(onDayOf: date(2026, 10, 21), at: newYork, in: tz)
        XCTAssertEqual(clock(autumn.bedtime) - clock(autumn.sunset), 4, accuracy: 0.02, "in the middle, four hours")

        let summer = EyeComfort.times(onDayOf: date(2026, 6, 21), at: newYork, in: tz)
        XCTAssertEqual(clock(summer.bedtime, from: summer.sunset), 24.5, accuracy: 0.02, "an 8:30 sunset would put bed at 12:30; no later")
        XCTAssertGreaterThan(summer.bedtime, summer.sunset)
        XCTAssertEqual(summer.bedtime.timeIntervalSince(summer.sunset) / 3_600, 4, accuracy: 0.6, "a few hours after the sun is down")
    }

    func testThePolarDayAndNightGetAFixedOne() {
        let oslo = TimeZone(identifier: "Europe/Oslo")!, tromso = Coordinate(latitude: 69.6492, longitude: 18.9553)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = oslo
        for (month, label) in [(6, "the midnight sun"), (12, "the polar night")] {
            let day = calendar.date(from: DateComponents(year: 2026, month: month, day: 21, hour: 12))!
            let times = EyeComfort.times(onDayOf: day, at: tromso, in: oslo)
            let midnight = calendar.startOfDay(for: day)
            XCTAssertEqual(times.sunrise.timeIntervalSince(midnight) / 3_600, 7, accuracy: 0.001, "\(label): up at seven")
            XCTAssertEqual(times.sunset.timeIntervalSince(midnight) / 3_600, 21, accuracy: 0.001, "\(label): down at nine")
            XCTAssertEqual(times.bedtime.timeIntervalSince(midnight) / 3_600, 24.5, accuracy: 0.001, "\(label): bed at half past twelve")
            let evening = EyeComfort.level(at: calendar.date(from: DateComponents(year: 2026, month: month, day: 21, hour: 22))!,
                                           place: tromso, zone: oslo)
            XCTAssertGreaterThan(evening.lightnessCut, 0, "\(label): the evening still comes")
        }
    }

    // MARK: - The curve

    func testTheDayIsFullAndTheEveningEasesDown() {
        let times = EyeComfort.times(onDayOf: date(2026, 10, 21), at: newYork, in: tz)
        XCTAssertEqual(level(date(2026, 10, 21, 12)), .day)
        XCTAssertEqual(level(times.sunset.addingTimeInterval(-60)), .day, "nothing before the sun is down")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(30 * 60)).lightnessCut, 0.02, accuracy: 0.0005, "half-way up the first ramp")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(3_600)).lightnessCut, 0.04, accuracy: 0.0005, "four per cent in an hour")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(2 * 3_600)).lightnessCut, 0.08, accuracy: 0.0005, "half-way up the second")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(3 * 3_600)).lightnessCut, 0.12, accuracy: 0.0005, "twelve per cent by the third hour")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(3 * 3_600)).chromaCut, 0.25, accuracy: 0.001, "and the accent a quarter calmer")
    }

    func testTheNightIsFromBedtimeUntilTheSunIsUp() {
        let times = EyeComfort.times(onDayOf: date(2026, 10, 21), at: newYork, in: tz)
        let wake = EyeComfort.times(onDayOf: date(2026, 10, 22), at: newYork, in: tz).sunrise
        XCTAssertFalse(level(times.bedtime.addingTimeInterval(-60)).night)
        XCTAssertTrue(level(times.bedtime).night)
        XCTAssertTrue(level(date(2026, 10, 22, 0, 10)).night, "past midnight, still the night")
        XCTAssertTrue(level(wake.addingTimeInterval(-60)).night)
        XCTAssertFalse(level(wake).night, "the sun is up")
        XCTAssertFalse(level(date(2026, 10, 22, 12)).night)
        XCTAssertEqual(level(date(2026, 10, 21, 12)).night, false)
    }

    func testTheMorningLiftsTheDimmingOverTwoHoursAndThenItIsFullAgain() {
        let wake = EyeComfort.times(onDayOf: date(2026, 10, 22), at: newYork, in: tz).sunrise
        XCTAssertEqual(level(wake.addingTimeInterval(-60)).lightnessCut, 0.12, accuracy: 0.0005, "dimmed all night")
        XCTAssertEqual(level(wake).lightnessCut, 0.12, accuracy: 0.0005)
        XCTAssertEqual(level(wake.addingTimeInterval(60 * 60)).lightnessCut, 0.06, accuracy: 0.0005)
        XCTAssertEqual(level(wake.addingTimeInterval(120 * 60)), .day)
        XCTAssertEqual(level(date(2026, 10, 22, 10)), .day)
    }

    /// No visible steps: across two days sampled every five minutes, the
    /// level never changes by more than under one per cent of lightness. The
    /// night palette taking over at bedtime is the one change of look, and it
    /// is not in the number: it goes darker and is applied at once.
    func testTheLevelMovesInStepsTooSmallToSee() {
        var previous = level(date(2026, 10, 21, 0))
        var step = date(2026, 10, 21, 0)
        var largest = 0.0, climbed = false
        while step < date(2026, 10, 23, 0) {
            step = step.addingTimeInterval(5 * 60)
            let now = level(step)
            largest = max(largest, abs(now.lightnessCut - previous.lightnessCut))
            // Monotone through each evening: it only ever goes down until the morning.
            if clock(step) > 12 && clock(step) < 24 { XCTAssertGreaterThanOrEqual(now.lightnessCut, previous.lightnessCut - 1e-12) }
            if now.lightnessCut > previous.lightnessCut { climbed = true }
            previous = now
        }
        XCTAssertTrue(climbed)
        XCTAssertLessThan(largest, 0.008, "\(largest)")
    }

    /// The clock moving across a daylight-saving change does not tear the
    /// curve: the evening after the fall-back day still starts at the sunset.
    func testTheDayTheClocksChangeIsStillAContinuousDay() {
        let fall = date(2026, 11, 1, 12)
        let times = EyeComfort.times(onDayOf: fall, at: newYork, in: tz)
        XCTAssertEqual(clock(times.sunset), 16.9, accuracy: 0.1, "4:50 pm by the wall after the clocks go back")
        XCTAssertEqual(clock(times.bedtime), 21.5, accuracy: 0.02, "and bed is still half past nine by the wall")
        XCTAssertEqual(level(times.sunset.addingTimeInterval(3_600)).lightnessCut, 0.04, accuracy: 0.0005)
    }

    // MARK: - What the level does to the looks

    private func hueGap(_ a: Readability.RGB, _ b: Readability.RGB) -> Double {
        let gap = abs(a.oklab.hue - b.oklab.hue)
        return min(gap, 360 - gap)
    }

    private func contrast(_ a: Readability.RGB, _ b: Readability.RGB) -> Double {
        Readability.contrast(a.luminance, b.luminance)
    }

    private let cuts = stride(from: 0.0, through: EyeComfort.deepestLightnessCut, by: 0.002).map { $0 }

    private func level(cut: Double) -> EyeComfort.Level { EyeComfort.Level(lightnessCut: cut) }

    func testAtFullTheLooksAreExactlyThePalettes() {
        let looks = EyeComfort.looks(at: .day)
        XCTAssertEqual(looks.clay.steps, Palette.clay)
        XCTAssertEqual(looks.night.steps, Palette.night)
        XCTAssertEqual(looks.clay.accent, Readability.orangeOnPaper)
        XCTAssertEqual(looks.night.accent, Readability.orangeOnCharcoal)
        XCTAssertEqual(EyeComfort.looks(at: EyeComfort.Level(lightnessCut: 0, night: true)), looks, "the night flag is the theme's to read, not the palette's")
    }

    /// Text holds seven to one on every surface it stands on, at every point
    /// of the curve: the primary ink on the pane, a key's face and the ground,
    /// and on the other look's slab where it is the selection's ink.
    func testPrimaryTextHoldsSevenToOneAtEveryPointOfTheCurve() {
        for cut in cuts {
            let looks = EyeComfort.looks(at: level(cut: cut))
            for (name, look, other) in [("clay", looks.clay, looks.night), ("night", looks.night, looks.clay)] {
                let s = look.steps
                for (surface, ground) in [("pane", s.pane), ("raised", s.raised), ("ground", s.ground), ("the other look's slab", other.steps.slab)] {
                    XCTAssertGreaterThanOrEqual(contrast(s.ink, ground), 7, "\(name) ink on \(surface) at \(cut)")
                }
            }
        }
    }

    func testNightInkStaysNearTwelveToOneThroughTheCurve() {
        for cut in cuts {
            let night = EyeComfort.looks(at: level(cut: cut)).night.steps
            XCTAssertGreaterThanOrEqual(contrast(night.ink, night.pane), 12, "at \(cut)")
        }
    }

    func testQuietTextAndTheAccentHoldTheirFloorsThroughTheCurve() {
        for cut in cuts {
            let looks = EyeComfort.looks(at: level(cut: cut))
            for (name, look, other) in [("clay", looks.clay, looks.night), ("night", looks.night, looks.clay)] {
                let s = look.steps
                for ground in [s.pane, s.raised, other.steps.slab] {
                    XCTAssertGreaterThanOrEqual(contrast(s.secondary, ground), 4.5, "\(name) quiet ink at \(cut)")
                }
                XCTAssertGreaterThanOrEqual(contrast(look.accent, s.pane), 4.5, "\(name) accent as text on its pane at \(cut)")
                XCTAssertGreaterThanOrEqual(contrast(look.accent, s.raised), 4.5, "\(name) accent on a key's face at \(cut)")
                XCTAssertGreaterThanOrEqual(contrast(look.accent, other.steps.slab), Readability.markFloor,
                                            "\(name) accent as a mark on the other look's slab at \(cut)")
                let letter = max(contrast(Readability.RGB(red: 1, green: 1, blue: 1), look.accent),
                                 contrast(Readability.RGB(red: 0.08, green: 0.08, blue: 0.08), look.accent))
                XCTAssertGreaterThanOrEqual(letter, 4.5, "\(name) lit key's letter at \(cut)")
            }
        }
    }

    /// Never a tint: every colour of both looks keeps its hue to a few
    /// degrees through the curve.
    func testNoHueEverMoves() {
        for cut in cuts {
            let looks = EyeComfort.looks(at: level(cut: cut))
            let pairs: [(String, Readability.RGB, Readability.RGB)] =
                zip(Palette.clay.all, looks.clay.steps.all).map { ("clay", $0, $1) }
                + zip(Palette.night.all, looks.night.steps.all).map { ("night", $0, $1) }
                + [("clay accent", Readability.orangeOnPaper, looks.clay.accent),
                   ("night accent", Readability.orangeOnCharcoal, looks.night.accent)]
            for (name, base, now) in pairs where base.oklab.chroma > 0.01 {
                XCTAssertLessThan(hueGap(base, now), 3, "\(name) \(base) at \(cut): \(base.oklab.hue) to \(now.oklab.hue)")
            }
        }
    }

    /// The surfaces ease by the share asked for and are never brighter than
    /// they were; the accent loses a quarter of its chroma at the deepest.
    func testTheSurfacesEaseByTheShareAskedForAndTheAccentCalms() {
        let deepest = EyeComfort.looks(at: level(cut: 0.12))
        for (base, now) in zip(Palette.clay.all.prefix(4), deepest.clay.steps.all.prefix(4)) {
            XCTAssertEqual(now.lightness, base.lightness * 0.88, accuracy: 0.004, "\(base)")
        }
        for (base, now) in zip(Palette.night.all.prefix(4), deepest.night.steps.all.prefix(4)) {
            XCTAssertEqual(now.lightness, base.lightness * 0.88, accuracy: 0.004, "\(base)")
        }
        let paneTrail = cuts.map { EyeComfort.looks(at: level(cut: $0)).clay.steps.pane.lightness }
        XCTAssertEqual(paneTrail, paneTrail.sorted(by: >), "the pane only gets darker")
        XCTAssertEqual(deepest.clay.accent.oklab.chroma / Readability.orangeOnPaper.oklab.chroma, 0.75, accuracy: 0.03)
        XCTAssertEqual(deepest.night.accent.oklab.chroma / Readability.orangeOnCharcoal.oklab.chroma, 0.75, accuracy: 0.03)
        let first = EyeComfort.looks(at: level(cut: 0.04))
        XCTAssertEqual(first.clay.steps.pane.lightness, Palette.clay.pane.lightness * 0.96, accuracy: 0.003, "four per cent after the first hour")
    }

    func testNothingIsPureWhiteOrPureBlackAndAKeyStillStandsOffItsPane() {
        let white = Readability.RGB(red: 1, green: 1, blue: 1), black = Readability.RGB(red: 0, green: 0, blue: 0)
        for cut in cuts {
            let looks = EyeComfort.looks(at: level(cut: cut))
            for look in [looks.clay, looks.night] {
                for colour in look.steps.all + [look.accent] {
                    XCTAssertNotEqual(colour, white)
                    XCTAssertNotEqual(colour, black)
                }
                XCTAssertGreaterThan(look.steps.raised.lightness - look.steps.pane.lightness, 0.02, "a raised step is visible at \(cut)")
                XCTAssertGreaterThan(look.steps.pane.lightness - look.steps.ground.lightness, 0.02)
                XCTAssertGreaterThan(abs(look.steps.slabSide.lightness - look.steps.slab.lightness), 0.05, "a slab has a side")
            }
        }
    }

    // MARK: - Receding

    /// A receded ink is never below 4.5 to 1 against the pane or a key's
    /// face, never higher than the ink it recedes from, and is lower than it
    /// when there is room.
    func testRecedingNeverGoesBelowTheFloorAndNeverRaisesContrast() {
        for cut in cuts {
            let looks = EyeComfort.looks(at: level(cut: cut))
            for look in [looks.clay, looks.night] {
                let s = look.steps
                let receded = Receding.inks(of: s)
                for ground in [s.pane, s.raised] {
                    XCTAssertGreaterThanOrEqual(contrast(receded.ink, ground), 4.5, "ink at \(cut)")
                    XCTAssertGreaterThanOrEqual(contrast(receded.secondary, ground), 4.5, "quiet ink at \(cut)")
                    XCTAssertLessThanOrEqual(contrast(receded.ink, ground), contrast(s.ink, ground) + 1e-9)
                    XCTAssertLessThanOrEqual(contrast(receded.secondary, ground), contrast(s.secondary, ground) + 1e-9)
                }
                let held = min(contrast(receded.ink, s.pane), contrast(receded.ink, s.raised))
                XCTAssertLessThan(held, 5, "the ink has receded to the neighbourhood of the floor")
                XCTAssertLessThan(held, contrast(s.ink, s.pane) - 4, "and a long way from where it stood")
                XCTAssertGreaterThan(contrast(receded.ink, s.pane), contrast(receded.secondary, s.pane), "the ink still leads the quiet ink")
                XCTAssertLessThan(hueGap(s.ink, receded.ink), 12, "toward the pane, in the same warm family")
            }
        }
    }

    func testAnInkAlreadyAtTheFloorStaysWhereItIs() {
        let pane = Palette.clay.pane
        let quiet = EyeComfort.holding(Palette.clay.secondary, constraints: [(pane, 4.5)])
        XCTAssertEqual(Receding.ink(quiet, over: [pane], floor: 100), quiet, "an ink under the floor is not made worse")
    }

    func testTheIdleWindowIsTwentySeconds() {
        XCTAssertEqual(Receding.idleSeconds, 20)
    }
}
