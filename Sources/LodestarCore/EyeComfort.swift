import Foundation

/// Eye comfort: Lodestar's own surfaces ease through the day to be gentler
/// on the eyes (DESIGN, "Ceramic", "Eye comfort"). The mathematics lives
/// here, pure, so a test can state any hour of any day at any place: when
/// the evening starts and the night ends, how far the surfaces have eased
/// down at a moment, and what every colour of the look becomes there. The
/// app target keeps the timer and the observers and hands the result to the
/// theme.
///
/// What it does, and never does:
/// - **Day**, sunrise until sunset: the palettes as they are.
/// - **After sunset** the surfaces (ground, pane, raised step, a key's side,
///   the slab) ease down in OKLab lightness, 4 per cent over the first hour
///   and 12 per cent by the third, and the accent calms by a quarter of its
///   chroma at the deepest, keeping its hue.
/// - **From bedtime until the sun is up** the night palette, whatever the
///   Mac is showing.
/// - **After sunrise** the dimming lifts over two hours, as gently as it came.
/// - It moves lightness only. It never turns a hue, because colour
///   temperature is Night Shift's, and it never touches what Lodestar shows
///   of yours: a clip, an image, a page is drawn as it is.
/// - The text keeps its contrast through all of it: ink holds seven to one
///   on every surface it stands on, and the quiet ink and the accent hold
///   the floors they hold by day.
public enum EyeComfort {
    // MARK: - The curve

    /// How far the surfaces ease down, at the deepest, as a share of their
    /// OKLab lightness; and how much of the accent's chroma goes with it.
    public static let deepestLightnessCut = 0.12
    public static let deepestChromaCut = 0.25
    /// The first hour takes the surfaces a third of the way.
    public static let firstHourCut = 0.04
    /// Minutes after sunset: where the first ramp ends and the second does.
    public static let firstRampMinutes = 60.0
    public static let secondRampMinutes = 180.0
    /// Minutes after the night ends that the dimming takes to lift: as slowly
    /// as it came, so a re-evaluation every few minutes never steps it by a
    /// visible amount.
    public static let morningMinutes = 120.0

    /// Bedtime is the sunset and four hours, no later than half past twelve
    /// and no earlier than half past nine. There is no public, permission-
    /// free way to read the Sleep Focus's schedule (the Focus APIs share only
    /// that a Focus is on, to an app the person has authorised, and the
    /// schedules live in a database the system keeps from apps), so the
    /// night starts where most evenings do. The night ends with the sun.
    public static let bedtimeAfterSunset: TimeInterval = 4 * 3_600
    public static let earliestBedtime = 21.5 * 3_600
    public static let latestBedtime = 24.5 * 3_600

    /// Where the sun is not to be had (the midnight sun, the polar night)
    /// the day is a fixed one: up at seven, down at nine.
    public static let polarSunrise = 7 * 3_600.0
    public static let polarSunset = 21 * 3_600.0

    /// Where the surfaces stand at a moment.
    public struct Level: Equatable, Sendable {
        /// The share of its lightness a surface has given up, 0 by day and
        /// 0.12 at the deepest.
        public var lightnessCut: Double
        /// The night palette is in force, whatever the Mac shows.
        public var night: Bool

        public init(lightnessCut: Double = 0, night: Bool = false) {
            self.lightnessCut = lightnessCut
            self.night = night
        }

        public static let day = Level()

        /// The share of the accent's chroma given up, in step with the
        /// surfaces.
        public var chromaCut: Double { lightnessCut / EyeComfort.deepestLightnessCut * EyeComfort.deepestChromaCut }
    }

    /// One local day's sun and the bedtime that follows its sunset.
    public struct Times: Equatable, Sendable {
        public var sunrise: Date
        public var sunset: Date
        public var bedtime: Date
    }

    /// The sunrise and sunset of the local day `date` falls in, and the
    /// bedtime after that sunset.
    public static func times(onDayOf date: Date, at place: Coordinate, in zone: TimeZone) -> Times {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = calendar.startOfDay(for: date)
        // Wall-clock times, through the calendar, so a day the clocks change
        // keeps seven, nine and half past twelve where the wall says they are.
        func wall(_ seconds: TimeInterval) -> Date {
            var parts = calendar.dateComponents([.year, .month, .day], from: midnight)
            parts.hour = Int(seconds / 3_600)
            parts.minute = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)
            return calendar.date(from: parts) ?? midnight.addingTimeInterval(seconds)
        }
        func sinceMidnight(_ instant: Date) -> TimeInterval {
            let clock = calendar.dateComponents([.hour, .minute, .second], from: instant)
            let days = calendar.dateComponents([.day], from: midnight, to: calendar.startOfDay(for: instant)).day ?? 0
            return TimeInterval(days * 86_400 + (clock.hour ?? 0) * 3_600 + (clock.minute ?? 0) * 60 + (clock.second ?? 0))
        }
        let sunrise: Date, sunset: Date
        switch Sun.day(containing: date, at: place, in: zone) {
        case .rises(let up, let down): (sunrise, sunset) = (up, down)
        case .polarDay, .polarNight: (sunrise, sunset) = (wall(polarSunrise), wall(polarSunset))
        }
        let after = sinceMidnight(sunset) + bedtimeAfterSunset
        let bedtime = wall(min(max(after, earliestBedtime), latestBedtime))
        return Times(sunrise: sunrise, sunset: sunset, bedtime: bedtime)
    }

    /// The level at a moment, at a place, in a time zone. Nothing else is
    /// read: not the clock, not the Mac.
    public static func level(at date: Date, place: Coordinate, zone: TimeZone) -> Level {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = times(onDayOf: date, at: place, in: zone)
        // The evening in force is the last sunset that has passed, and the
        // night that follows it ends at the next sunrise.
        let evening: Times, wake: Date
        if date >= today.sunset {
            evening = today
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
            wake = times(onDayOf: tomorrow, at: place, in: zone).sunrise
        } else {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-86_400)
            evening = times(onDayOf: yesterday, at: place, in: zone)
            wake = today.sunrise
        }
        if date >= wake {
            let minutes = date.timeIntervalSince(wake) / 60
            return Level(lightnessCut: deepestLightnessCut * (1 - smooth(minutes / morningMinutes)), night: false)
        }
        let minutes = date.timeIntervalSince(evening.sunset) / 60
        return Level(lightnessCut: cut(minutesAfterSunset: minutes), night: date >= evening.bedtime)
    }

    /// How much lightness is given up this long after sunset: nothing until
    /// the sun is down, 4 per cent an hour later, 12 per cent at three
    /// hours, eased at each end so the change has no corner.
    public static func cut(minutesAfterSunset minutes: Double) -> Double {
        if minutes <= 0 { return 0 }
        if minutes < firstRampMinutes { return firstHourCut * smooth(minutes / firstRampMinutes) }
        if minutes < secondRampMinutes {
            let along = (minutes - firstRampMinutes) / (secondRampMinutes - firstRampMinutes)
            return firstHourCut + (deepestLightnessCut - firstHourCut) * smooth(along)
        }
        return deepestLightnessCut
    }

    static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    // MARK: - What the level does to the looks

    /// Everything one look is made of at a level: its steps and the accent
    /// that stands on them.
    public struct Look: Equatable, Sendable {
        public let steps: Palette.Steps
        public let accent: Readability.RGB
    }

    /// The two looks at a level, adjusted together because each carries the
    /// other's selection: the slab is the other look's ground, with the other
    /// look's ink and accent standing on it, so the contrast of one is
    /// measured against the other.
    public struct Looks: Equatable, Sendable {
        public let clay: Look
        public let night: Look
    }

    public static let unadjusted = Looks(
        clay: Look(steps: Palette.clay, accent: Readability.orangeOnPaper),
        night: Look(steps: Palette.night, accent: Readability.orangeOnCharcoal))

    /// What primary text holds against every surface it stands on, at every
    /// point of the curve, and what the quiet ink and the accent hold. The
    /// floors sit a little above the rules they serve so rounding never
    /// touches them.
    public static let inkFloor = 7.2
    public static let secondaryFloor = 4.6
    public static let accentFloor = 4.55
    public static let accentOnSlabFloor = 3.1

    /// The near-black a lit key's letter takes over the night's orange, and
    /// the white it takes over clay's, as the theme chooses by measure.
    static let nightLetter = Readability.RGB(red: 0.08, green: 0.08, blue: 0.08)
    static let clayLetter = Readability.RGB(red: 1, green: 1, blue: 1)

    public static func looks(at level: Level) -> Looks {
        let cut = min(deepestLightnessCut, max(0, level.lightnessCut))
        guard cut > 0 else { return unadjusted }
        let clay = Palette.clay, night = Palette.night

        let clayBase = surfaces(of: clay, cut: cut)
        let nightBase = surfaces(of: night, cut: cut)
        let calm = level.chromaCut
        let clayAccent = calmed(Readability.orangeOnPaper, chromaCut: calm)
        let nightAccent = calmed(Readability.orangeOnCharcoal, chromaCut: calm)

        func look(_ own: Palette.Steps, over surfacesOfOwn: Palette.Steps, other: Palette.Steps,
                  accent: Readability.RGB, baseAccent: Readability.RGB, letter: Readability.RGB,
                  baseRaised: Readability.RGB) -> Look {
            let onSurfaces = [surfacesOfOwn.pane, surfacesOfOwn.raised, surfacesOfOwn.ground]
            let ink = holding(own.ink, constraints: onSurfaces.map { ($0, inkFloor) } + [(other.slab, inkFloor)])
            let secondary = holding(own.secondary, constraints:
                [(surfacesOfOwn.pane, secondaryFloor), (surfacesOfOwn.raised, secondaryFloor), (other.slab, secondaryFloor)])
            let floorForAccent = min(accentFloor, Readability.contrast(baseAccent.luminance, baseRaised.luminance))
            let held = holding(accent, constraints: [
                (surfacesOfOwn.pane, floorForAccent), (surfacesOfOwn.raised, floorForAccent),
                (letter, floorForAccent), (other.slab, accentOnSlabFloor)])
            return Look(steps: Palette.Steps(
                ground: surfacesOfOwn.ground, pane: surfacesOfOwn.pane, raised: surfacesOfOwn.raised,
                keySide: surfacesOfOwn.keySide, ink: ink, secondary: secondary,
                hairlineAlpha: own.hairlineAlpha, slab: surfacesOfOwn.slab, slabSide: surfacesOfOwn.slabSide),
                        accent: held)
        }
        return Looks(
            clay: look(clay, over: clayBase, other: nightBase, accent: clayAccent, baseAccent: Readability.orangeOnPaper,
                       letter: clayLetter, baseRaised: clay.raised),
            night: look(night, over: nightBase, other: clayBase, accent: nightAccent, baseAccent: Readability.orangeOnCharcoal,
                        letter: nightLetter, baseRaised: night.raised))
    }

    /// A palette with only its surfaces eased down: the ink is settled
    /// afterwards, against the surfaces as they now are.
    static func surfaces(of steps: Palette.Steps, cut: Double) -> Palette.Steps {
        Palette.Steps(
            ground: dimmed(steps.ground, cut), pane: dimmed(steps.pane, cut), raised: dimmed(steps.raised, cut),
            keySide: dimmed(steps.keySide, cut), ink: steps.ink, secondary: steps.secondary,
            hairlineAlpha: steps.hairlineAlpha, slab: dimmed(steps.slab, cut), slabSide: dimmed(steps.slabSide, cut))
    }

    /// A colour with a share of its OKLab lightness given up, its hue and
    /// chroma as they were.
    public static func dimmed(_ colour: Readability.RGB, _ cut: Double) -> Readability.RGB {
        var lab = colour.oklab
        lab.lightness *= 1 - cut
        return Readability.RGB(lab)
    }

    /// The accent with a share of its chroma given up: the same hue and the
    /// same lightness, a little less of the colour.
    public static func calmed(_ colour: Readability.RGB, chromaCut: Double) -> Readability.RGB {
        var lab = colour.oklab
        lab.a *= 1 - chromaCut
        lab.b *= 1 - chromaCut
        return Readability.RGB(lab)
    }

    /// The colour, moved in lightness alone, only as far as it takes for it
    /// to hold every floor against its grounds: away from them, never
    /// toward. A colour that already holds them is returned as it is.
    public static func holding(_ colour: Readability.RGB, constraints: [(ground: Readability.RGB, floor: Double)]) -> Readability.RGB {
        func holds(_ candidate: Readability.RGB) -> Bool {
            constraints.allSatisfy { Readability.contrast(candidate.luminance, $0.ground.luminance) >= $0.floor }
        }
        if holds(colour) { return colour }
        let lab = colour.oklab
        let lighter = constraints.map(\.ground.luminance)
        let toward: Double
        if lighter.allSatisfy({ $0 > colour.luminance }) { toward = 0 }
        else if lighter.allSatisfy({ $0 < colour.luminance }) { toward = 1 }
        else { toward = colour.luminance > lighter.reduce(0, +) / Double(lighter.count) ? 1 : 0 }
        func moved(_ t: Double) -> Readability.RGB {
            Readability.RGB(Readability.OKLab(lightness: lab.lightness + (toward - lab.lightness) * t, a: lab.a, b: lab.b))
        }
        guard holds(moved(1)) else { return moved(1) }
        var low = 0.0, high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if holds(moved(mid)) { high = mid } else { low = mid }
        }
        return moved(high)
    }
}

/// Receding (DESIGN, "Eye comfort"): a surface that stays on screen while
/// the work is elsewhere lowers its ink toward its pane, to a contrast that
/// is still legible and no lower, and returns the instant it is touched.
public enum Receding {
    /// A pill or a chip left alone this long recedes.
    public static let idleSeconds: TimeInterval = 20
    /// The contrast a receded ink keeps against the surface it stands on:
    /// the floor for text (4.5 to 1) with a margin so a rounding never
    /// crosses it, a little more for the ink than for the quiet ink so the
    /// two still differ.
    public static let inkFloor = 4.8
    public static let secondaryFloor = 4.55

    /// The ink moved toward the ground, in OKLab, as far as it can go and
    /// still hold the floor against every ground it stands on. An ink that
    /// is already at or under the floor is returned as it is: receding
    /// never raises a contrast and never takes one under the floor.
    public static func ink(_ ink: Readability.RGB, over grounds: [Readability.RGB], floor: Double) -> Readability.RGB {
        func holds(_ colour: Readability.RGB) -> Bool {
            grounds.allSatisfy { Readability.contrast(colour.luminance, $0.luminance) >= floor }
        }
        guard holds(ink), let towards = grounds.first?.oklab else { return ink }
        let from = ink.oklab
        func mixed(_ t: Double) -> Readability.RGB {
            Readability.RGB(Readability.OKLab(
                lightness: from.lightness + (towards.lightness - from.lightness) * t,
                a: from.a + (towards.a - from.a) * t, b: from.b + (towards.b - from.b) * t))
        }
        var low = 0.0, high = 1.0
        if holds(mixed(1)) { return mixed(1) }
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if holds(mixed(mid)) { low = mid } else { high = mid }
        }
        return mixed(low)
    }

    /// A look's two inks as they stand when receded, on its pane and on a
    /// key's face.
    public static func inks(of steps: Palette.Steps) -> (ink: Readability.RGB, secondary: Readability.RGB) {
        let grounds = [steps.pane, steps.raised]
        return (ink(steps.ink, over: grounds, floor: inkFloor),
                ink(steps.secondary, over: grounds, floor: secondaryFloor))
    }
}
