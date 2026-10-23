import Foundation

/// Eye comfort (design/06-eye-comfort.md): Lodestar's own surfaces ease
/// through the day to be gentler on the eyes. Pure, so a test can state any
/// minute of any day at any place: when the sun is up, where bedtime falls,
/// how much of its luminance a surface keeps, and what that does to every
/// colour of both looks. The app keeps the timer and the observers and hands
/// the level to the theme.
///
/// What it does, and never does:
/// - It dims **luminance**, every channel together in linear light, so a
///   colour's hue and saturation are exactly what they were. (The prototype
///   dimmed OKLab lightness by 12 per cent, a 35 per cent cut in luminance:
///   clay went grey and the orange went brown.)
/// - It dims the bright things of the look the Mac is in: the surfaces by
///   day, the ink, the quiet ink and the slab by night. It never changes
///   which look that is.
/// - The orange calms in the evening by day, and dims with the ink at night,
///   and holds 4.5 to 1 as text on its pane either way.
/// - The floors hold at every minute: ink 7 to 1, quiet ink and the orange
///   as text 4.5 to 1, a lit fill 3 to 1.
public enum EyeComfort {
    // MARK: - The schedule

    /// The share of its luminance a bright colour keeps: full by day, then
    /// by the schedule below.
    public static let full = 1.0
    /// One hour after sunset.
    public static let evening = 0.96
    /// Three hours after sunset, and held until bedtime.
    public static let lateEvening = 0.88
    /// From bedtime until the sun is up, the deepest.
    public static let bedtime = 0.80

    /// The ease from sunset to the evening's level, from there to the late
    /// evening's, from bedtime to the deepest, and from sunrise back to full.
    /// Each is long enough that a step every five minutes moves a colour's
    /// luminance by under 1 per cent of what it was.
    public static let firstEase: TimeInterval = 3_600
    public static let secondEase: TimeInterval = 7_200
    public static let bedtimeEase: TimeInterval = 5_400
    public static let morningEase: TimeInterval = 7_200

    /// How often the level is worked out, besides on waking, a clock change
    /// and a time-zone change.
    public static let beat: TimeInterval = 300

    /// Bedtime is four hours after sunset, held between 21:30 and 00:30. No
    /// public, permission-free read of the Sleep Focus's schedule exists
    /// (macOS tells an authorised app only that a Focus is on), so bedtime is
    /// estimated from the sun, and lasts until sunrise.
    public static let bedtimeAfterSunset: TimeInterval = 4 * 3_600
    public static let earliestBedtime: TimeInterval = 21.5 * 3_600
    public static let latestBedtime: TimeInterval = 24.5 * 3_600

    /// Where the sun does not set or rise the day is a fixed one: up at
    /// seven, down at nine.
    public static let polarSunrise: TimeInterval = 7 * 3_600
    public static let polarSunset: TimeInterval = 21 * 3_600

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
        return Times(sunrise: sunrise, sunset: sunset,
                     bedtime: wall(min(max(after, earliestBedtime), latestBedtime)))
    }

    /// The share of its luminance a bright colour keeps at a moment, at a
    /// place, in a time zone: 1 by day, 0.80 at the deepest. Nothing else is
    /// read: not the clock, not the Mac.
    ///
    /// Each evening makes its own night: it begins at that sunset, eases down
    /// and holds, and after the next sunrise eases back. The level is the
    /// lower of last evening's night and this one's, so it is continuous in
    /// every case, including the days at the edge of a polar night when a
    /// sunrise and the next sunset are minutes apart.
    public static func level(at date: Date, place: Coordinate, zone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func day(_ offset: Int) -> Times {
            let moved = calendar.date(byAdding: .day, value: offset, to: date) ?? date.addingTimeInterval(Double(offset) * 86_400)
            return times(onDayOf: moved, at: place, in: zone)
        }
        let yesterday = day(-1), today = day(0), tomorrow = day(1)
        return min(night(of: yesterday, wakingAt: today.sunrise, at: date),
                   night(of: today, wakingAt: tomorrow.sunrise, at: date))
    }

    /// The level at `date` of the night that begins at `evening`'s sunset and
    /// ends at `wake`: full before it, full again two hours after it.
    static func night(of evening: Times, wakingAt wake: Date, at date: Date) -> Double {
        guard date > evening.sunset else { return full }
        let bedAfter = evening.bedtime.timeIntervalSince(evening.sunset)
        func overnight(_ instant: Date) -> Double {
            level(secondsAfterSunset: instant.timeIntervalSince(evening.sunset), secondsToBedtime: bedAfter)
        }
        guard date >= wake else { return overnight(date) }
        // Sunrise eases back from wherever the night had got to. The deepest
        // level has to climb a quarter of itself in two hours, which a
        // smooth start and finish would do in steps of more than 1% in the
        // middle; so the climb is by a constant share of what is there,
        // eased by only a twentieth at its two ends.
        let from = overnight(wake)
        let along = min(1, max(0, date.timeIntervalSince(wake) / morningEase))
        let shaped = along + 0.05 * (smooth(along) - along)
        return from * pow(full / from, shaped)
    }

    /// The level this long after a sunset whose bedtime is `secondsToBedtime`
    /// later: eased at every corner, so a step every five minutes is never
    /// seen. Where bedtime comes before the evening has finished easing (a
    /// sunset at half past ten), the deeper dim begins when the evening's
    /// ends, never mid-ease.
    public static func level(secondsAfterSunset t: TimeInterval, secondsToBedtime: TimeInterval) -> Double {
        let lateStart = firstEase + secondEase
        let deepStart = max(secondsToBedtime, lateStart)
        if t <= 0 { return full }
        if t < firstEase { return full + (evening - full) * smooth(t / firstEase) }
        if t < lateStart { return evening + (lateEvening - evening) * smooth((t - firstEase) / secondEase) }
        if t < deepStart { return lateEvening }
        if t < deepStart + bedtimeEase {
            return lateEvening + (bedtime - lateEvening) * smooth((t - deepStart) / bedtimeEase)
        }
        return bedtime
    }

    static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    // MARK: - The floors

    /// What a colour holds at every level, in both looks, against every
    /// surface it stands on (design/01-colour.md, rule 3).
    public static let inkFloor = 7.0
    public static let quietInkFloor = 4.5
    public static let orangeTextFloor = 4.5
    public static let litFillFloor = 3.0
    /// The room a floor is solved with, so the measured ratio is never a
    /// rounding under it.
    static let margin = 0.01

    /// How far the orange calms, in chroma at the same hue, at the deepest
    /// level by day; less before it, in step with the dimming.
    public static let deepestChromaCut = 0.10

    // MARK: - What the level does to a look

    /// A look at a level. The level is what a bright colour keeps of its
    /// luminance; 1 returns the look exactly as it is.
    ///
    /// By day (the light look) the surfaces dim: ground, pane, key, side and
    /// well, each scaled in linear light. The inks are dark and stay as they
    /// are, except where a surface that has grown darker would put them under
    /// their floors (the quiet ink at the deepest), when they deepen as far
    /// as that takes. The orange calms and deepens just enough to keep 4.5 to
    /// 1 as text on the dimmed pane and its letter 4.5 to 1 on it.
    ///
    /// By night (the dark look) the ink, the quiet ink and the slab dim, the
    /// ink never under 7 to 1 and the quiet ink never under 4.5 on a surface
    /// it stands on; the orange dims with them and stops at 4.5 to 1 as text
    /// on the pane.
    public static func steps(_ look: Palette.Steps, level raw: Double) -> Palette.Steps {
        let level = min(full, max(bedtime, raw))
        guard level < full else { return look }
        return look.isDark ? darkLook(look, level: level) : lightLook(look, level: level)
    }

    private static func lightLook(_ look: Palette.Steps, level: Double) -> Palette.Steps {
        let ground = look.ground.scaled(luminanceBy: level)
        let pane = look.pane.scaled(luminanceBy: level)
        let key = look.key.scaled(luminanceBy: level)
        let side = look.side.scaled(luminanceBy: level)
        let well = look.well.scaled(luminanceBy: level)
        let surfaces = [pane, key, ground, well]
        let ink = deepened(look.ink, over: surfaces, floor: inkFloor)
        let quiet = deepened(look.quietInk, over: surfaces, floor: quietInkFloor)
        let calm = deepestChromaCut * (full - level) / (full - bedtime)
        let orange = calmed(look.orange, by: calm, text: pane, letter: key)
        return Palette.Steps(
            ground: ground, pane: pane, key: key, side: side, ink: ink, quietInk: quiet,
            slab: look.slab, slabSide: look.slabSide, hairlineAlpha: look.hairlineAlpha, orange: orange,
            wellDrop: look.wellDrop, wellStopsAtGround: look.wellStopsAtGround, wellEdgeAlpha: look.wellEdgeAlpha,
            isDark: false, well: well, letterOnOrange: key)
    }

    private static func darkLook(_ look: Palette.Steps, level: Double) -> Palette.Steps {
        let surfaces = [look.pane, look.key, look.ground, look.well]
        let ink = dimmed(look.ink, to: level, over: surfaces, floor: inkFloor)
        let quiet = dimmed(look.quietInk, to: level, over: surfaces, floor: quietInkFloor)
        let orange = dimmedOrange(look.orange, to: level, text: look.pane)
        return Palette.Steps(
            ground: look.ground, pane: look.pane, key: look.key, side: look.side, ink: ink, quietInk: quiet,
            slab: look.slab.scaled(luminanceBy: level), slabSide: look.slabSide.scaled(luminanceBy: level),
            hairlineAlpha: look.hairlineAlpha, orange: orange, wellDrop: look.wellDrop,
            wellStopsAtGround: look.wellStopsAtGround, wellEdgeAlpha: look.wellEdgeAlpha, isDark: true,
            well: look.well)
    }

    static func contrast(_ a: Readability.RGB, _ b: Readability.RGB) -> Double {
        Readability.contrast(a.luminance, b.luminance)
    }

    private static func holds(_ colour: Readability.RGB, over grounds: [Readability.RGB], floor: Double) -> Bool {
        grounds.allSatisfy { contrast(colour, $0) >= floor + margin }
    }

    /// The largest factor in 0...1 for which `holds` is true: 1 when it is
    /// true there already. `holds` must be monotone, true toward 0 and false
    /// toward 1 (a darker ink holds a floor a lighter one does not).
    private static func largestFactor(where holds: (Double) -> Bool) -> Double {
        if holds(1) { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<48 {
            let mid = (low + high) / 2
            if holds(mid) { low = mid } else { high = mid }
        }
        return low
    }

    /// The smallest factor in 0...1 for which `holds` is true: 1 when it is
    /// false there. `holds` must be monotone, true toward 1 and false toward
    /// 0 (a lighter ink holds a floor a darker one does not).
    private static func smallestFactor(where holds: (Double) -> Bool) -> Double {
        if !holds(1) { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<48 {
            let mid = (low + high) / 2
            if holds(mid) { high = mid } else { low = mid }
        }
        return high
    }

    /// A dark ink over surfaces that have grown darker: the ink as it is, or
    /// deepened in linear light only as far as it takes to hold the floor.
    static func deepened(_ ink: Readability.RGB, over surfaces: [Readability.RGB], floor: Double) -> Readability.RGB {
        let factor = largestFactor { holds(ink.scaled(luminanceBy: $0), over: surfaces, floor: floor) }
        return factor >= 1 ? ink : ink.scaled(luminanceBy: factor)
    }

    /// A light ink dimmed to `level`, but not past the floor against any
    /// surface it stands on.
    static func dimmed(_ ink: Readability.RGB, to level: Double, over surfaces: [Readability.RGB],
                       floor: Double) -> Readability.RGB {
        let lowest = smallestFactor { holds(ink.scaled(luminanceBy: $0), over: surfaces, floor: floor) }
        return ink.scaled(luminanceBy: max(level, lowest))
    }

    /// The orange of the light look in the evening: its chroma cut by `calm`
    /// at the same hue, and its lightness lowered just enough to hold 4.5 to 1
    /// as text on the dimmed pane and for the letter on the lit face to hold
    /// 4.5 to 1 on it.
    static func calmed(_ base: Readability.RGB, by calm: Double, text pane: Readability.RGB,
                       letter: Readability.RGB) -> Readability.RGB {
        let lab = base.oklab
        let lightness = lab.L, chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        let hue = atan2(lab.b, lab.a)
        func shade(at lightness: Double) -> Readability.RGB {
            // The chroma asked for, or the most the gamut allows at this
            // lightness: the colour is never pushed out of sRGB and clamped,
            // which would turn its hue.
            let wanted = chroma * (1 - calm)
            func make(_ c: Double) -> Readability.RGB {
                Readability.RGB(L: lightness, a: c * cos(hue), b: c * sin(hue))
            }
            func inGamut(_ c: Double) -> Bool {
                let l = pow(lightness + 0.3963377774 * c * cos(hue) + 0.2158037573 * c * sin(hue), 3)
                let m = pow(lightness - 0.1055613458 * c * cos(hue) - 0.0638541728 * c * sin(hue), 3)
                let s = pow(lightness - 0.0894841775 * c * cos(hue) - 1.2914855480 * c * sin(hue), 3)
                let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
                let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
                let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
                return [r, g, b].allSatisfy { $0 >= -1e-6 && $0 <= 1 + 1e-6 }
            }
            if inGamut(wanted) { return make(wanted) }
            var low = 0.0, high = wanted
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if inGamut(mid) { low = mid } else { high = mid }
            }
            return make(low)
        }
        func holdsAt(_ lightnessShare: Double) -> Bool {
            let candidate = shade(at: lightness * lightnessShare)
            return contrast(candidate, pane) >= orangeTextFloor + margin
                && contrast(letter, candidate) >= orangeTextFloor + margin
        }
        let share = largestFactor(where: holdsAt)
        return shade(at: lightness * share)
    }

    /// The orange of the dark look dimmed with the ink, and stopping where it
    /// would stop being readable as text on the pane, or where its letter
    /// (the ink Palette chooses) would stop being readable on it.
    static func dimmedOrange(_ orange: Readability.RGB, to level: Double, text pane: Readability.RGB) -> Readability.RGB {
        func holdsAt(_ factor: Double) -> Bool {
            let candidate = orange.scaled(luminanceBy: factor)
            return contrast(candidate, pane) >= orangeTextFloor + margin
                && contrast(Palette.letter(on: candidate), candidate) >= orangeTextFloor + margin
        }
        let lowest = smallestFactor(where: holdsAt)
        return orange.scaled(luminanceBy: max(level, lowest))
    }
}

/// Receding: a surface that stays on screen while the work is elsewhere
/// grows quieter. After twenty seconds without attention the pill's and the
/// meeting chip's ink moves toward their pane, to 5.5 to 1, and their quiet
/// ink to 4.5 to 1, so the two keep their order; they come back at once. A
/// colour already quieter than its floor is left as it is: receding never
/// raises a contrast. Hue and saturation are unchanged, as in the schedule.
public enum Receding {
    /// How long a surface is left alone before it recedes.
    public static let idleSeconds: TimeInterval = 20
    public static let inkContrast = 5.5
    public static let quietInkContrast = 4.5
    static let margin = 0.002

    /// The ink and the quiet ink of a look as they stand receded, on its pane.
    public static func inks(of look: Palette.Steps) -> (ink: Readability.RGB, quietInk: Readability.RGB) {
        (receded(look.ink, on: look.pane, to: inkContrast), receded(look.quietInk, on: look.pane, to: quietInkContrast))
    }

    static func receded(_ ink: Readability.RGB, on pane: Readability.RGB, to ratio: Double) -> Readability.RGB {
        let target = ratio + margin
        guard Readability.contrast(ink.luminance, pane.luminance) > target, ink.luminance > 0 else { return ink }
        // The luminance that stands at the target against the pane, on the
        // ink's own side of it, and the ink scaled there in linear light.
        let wanted = ink.luminance > pane.luminance
            ? target * (pane.luminance + 0.05) - 0.05
            : (pane.luminance + 0.05) / target - 0.05
        return ink.scaled(luminanceBy: wanted / ink.luminance)
    }
}
