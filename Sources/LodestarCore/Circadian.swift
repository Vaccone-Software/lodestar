import Foundation

/// The day's shape, read off the pulses.
///
/// The printout already had a peak hour and a late-night share, which
/// answer "when do you work" and stop there. These are the measures the
/// actigraphy literature settled on for the same raw material — an
/// activity count per hour per day — and they are used here for the same
/// reason a borrowed instrument is ever used: they are comparable, they
/// have known behaviour, and nobody has to defend a threshold somebody
/// invented on a Tuesday.
///
/// Nothing here is a diagnosis and nothing here is judged. A rhythm is
/// described; what a person wants their rhythm to be is theirs.
public enum Circadian {
    /// The hour a day begins for rhythm purposes. Four in the morning,
    /// the sleep literature's own convention: work that runs to 2am
    /// belongs to the day it started on, and a midnight boundary would
    /// split one evening into two days and halve its onset-to-offset
    /// span. A night owl's numbers are wrong without this.
    public static let dayStartHour = 4

    public struct Profile: Equatable {
        /// Days with any activity at all.
        public var days = 0
        /// Mean active minutes per hour-of-day, averaged across days —
        /// the average day, 24 buckets, starting at midnight.
        public var averageDay = [Double](repeating: 0, count: 24)

        /// Interdaily stability: how alike the days are, 0 to 1. High is
        /// a rhythm that repeats; low is a schedule that does not.
        public var interdailyStability: Double?
        /// Intradaily variability: how broken up a day is, roughly 0 to
        /// 2. High is activity that starts and stops; low is activity in
        /// consolidated blocks.
        public var intradailyVariability: Double?
        /// The most active ten hours and the least active five, as mean
        /// active minutes per hour, with the hour each begins.
        public var m10: Double?
        public var m10Hour: Int?
        public var l5: Double?
        public var l5Hour: Int?
        /// Relative amplitude, 0 to 1: how far the active block stands
        /// above the quiet one. Low means the two are blurring together.
        public var relativeAmplitude: Double?

        /// Mean first and last activity of a day, as hours since
        /// midnight (may exceed 24 for work past the day boundary).
        public var onsetHour: Double?
        public var offsetHour: Double?
        /// The activity-weighted centre of the day, same scale.
        public var midpointHour: Double?
        /// Work-day and free-day midpoints, and the distance between
        /// them in hours — the social-jetlag shape, measured on activity
        /// rather than on sleep, which is the proxy this data can honestly
        /// support and not the clinical definition.
        public var workMidpointHour: Double?
        public var freeMidpointHour: Double?
        public var socialJetlagHours: Double? {
            guard let work = workMidpointHour, let free = freeMidpointHour else { return nil }
            return abs(free - work)
        }
    }

    /// One local day, from `dayStartHour` to `dayStartHour` the next.
    struct Day {
        var ordinal: Int
        /// Active minutes by hour of the clock, 24 buckets from midnight.
        var hours = [Double](repeating: 0, count: 24)
        /// Minutes since the day's own start, for onset and offset.
        var firstOffset: Double?
        var lastOffset: Double?
        var weekend = false
        var total: Double { hours.reduce(0, +) }
    }

    public static func profile(events: [ObservationEvent], days: Int,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> Profile? {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let pulses = events.filter { $0.kind == .pulse && $0.t >= cutoff }
            .sorted { $0.t < $1.t }
        guard !pulses.isEmpty else { return nil }

        var table: [Int: Day] = [:]
        for pulse in pulses {
            let minutes = Double(pulse.activeMinutes ?? 0)
            guard minutes > 0 else { continue }
            // A window can straddle an hour, so its minutes are split by
            // how much of the window fell in each — an even spread
            // inside a quarter hour, which is the finest honest claim
            // the pulse can make about itself.
            let span = min(HealthPulse.windowSeconds,
                           max(60, Double(pulse.activeMinutes ?? 1) * 60))
            for (hourDate, share) in hourShares(from: pulse.t, span: span, calendar: calendar) {
                let ordinal = dayOrdinal(hourDate, calendar: calendar)
                var day = table[ordinal] ?? blankDay(ordinal: ordinal, at: hourDate, calendar: calendar)
                let hour = calendar.component(.hour, from: hourDate)
                day.hours[hour] += minutes * share
                table[ordinal] = day
            }
            // Onset and offset, measured from the day the window opened.
            let ordinal = dayOrdinal(pulse.t, calendar: calendar)
            var day = table[ordinal] ?? blankDay(ordinal: ordinal, at: pulse.t, calendar: calendar)
            let offset = minutesSinceDayStart(pulse.t, calendar: calendar)
            day.firstOffset = min(day.firstOffset ?? offset, offset)
            day.lastOffset = max(day.lastOffset ?? offset, offset + minutes)
            table[ordinal] = day
        }

        let sorted = table.values.filter { $0.total > 0 }.sorted { $0.ordinal < $1.ordinal }
        guard !sorted.isEmpty else { return nil }

        var out = Profile()
        out.days = sorted.count
        for hour in 0..<24 {
            out.averageDay[hour] = sorted.map { $0.hours[hour] }.reduce(0, +) / Double(sorted.count)
        }

        // The nonparametric pair, both defined over the flat hourly
        // series across every day in the span.
        let series = sorted.flatMap { $0.hours }
        out.interdailyStability = stability(series: series, averageDay: out.averageDay)
        out.intradailyVariability = variability(series: series)

        if let window = extreme(out.averageDay, width: 10, highest: true) {
            out.m10 = window.mean
            out.m10Hour = window.start
        }
        if let window = extreme(out.averageDay, width: 5, highest: false) {
            out.l5 = window.mean
            out.l5Hour = window.start
        }
        if let m10 = out.m10, let l5 = out.l5, m10 + l5 > 0 {
            out.relativeAmplitude = (m10 - l5) / (m10 + l5)
        }

        let onsets = sorted.compactMap { $0.firstOffset }
        let offsets = sorted.compactMap { $0.lastOffset }
        if !onsets.isEmpty {
            out.onsetHour = Double(dayStartHour) + onsets.reduce(0, +) / Double(onsets.count) / 60
        }
        if !offsets.isEmpty {
            out.offsetHour = Double(dayStartHour) + offsets.reduce(0, +) / Double(offsets.count) / 60
        }
        out.midpointHour = midpoint(of: sorted)
        let work = sorted.filter { !$0.weekend }
        let free = sorted.filter { $0.weekend }
        // One day of either side is an anecdote; two is the least that
        // can average.
        if work.count >= 2 { out.workMidpointHour = midpoint(of: work) }
        if free.count >= 2 { out.freeMidpointHour = midpoint(of: free) }
        return out
    }

    // MARK: - Internals

    /// The activity-weighted centre of a set of days, in hours since
    /// midnight on the day-start scale.
    static func midpoint(of days: [Day]) -> Double? {
        var weight = 0.0
        var sum = 0.0
        for day in days {
            for hour in 0..<24 where day.hours[hour] > 0 {
                // Shifted onto the day-start scale so an evening and the
                // small hours after it sit beside each other rather than
                // twenty-three hours apart.
                var position = Double(hour) - Double(dayStartHour)
                if position < 0 { position += 24 }
                sum += (position + 0.5) * day.hours[hour]
                weight += day.hours[hour]
            }
        }
        guard weight > 0 else { return nil }
        return Double(dayStartHour) + sum / weight
    }

    /// IS: the variance of the average day against the variance of the
    /// whole series. One when every day is identical, near zero when the
    /// 24-hour profile explains nothing.
    static func stability(series: [Double], averageDay: [Double]) -> Double? {
        let n = series.count
        guard n >= 48 else { return nil }
        let mean = series.reduce(0, +) / Double(n)
        let total = series.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        guard total > 0 else { return nil }
        let across = averageDay.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (Double(n) * across) / (24 * total)
    }

    /// IV: mean squared difference between neighbouring hours against
    /// the series variance. Rises as activity fragments.
    static func variability(series: [Double]) -> Double? {
        let n = series.count
        guard n >= 48 else { return nil }
        let mean = series.reduce(0, +) / Double(n)
        let total = series.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        guard total > 0 else { return nil }
        var steps = 0.0
        for i in 1..<n {
            let delta = series[i] - series[i - 1]
            steps += delta * delta
        }
        return (Double(n) * steps) / (Double(n - 1) * total)
    }

    /// The highest or lowest mean over a run of consecutive hours,
    /// wrapping around midnight — a quiet block that straddles it is
    /// still one block.
    static func extreme(_ averageDay: [Double], width: Int,
                        highest: Bool) -> (start: Int, mean: Double)? {
        guard averageDay.count == 24, width > 0, width <= 24 else { return nil }
        var best: (start: Int, mean: Double)?
        for start in 0..<24 {
            var sum = 0.0
            for offset in 0..<width { sum += averageDay[(start + offset) % 24] }
            let mean = sum / Double(width)
            if let current = best {
                if highest ? mean > current.mean : mean < current.mean {
                    best = (start, mean)
                }
            } else {
                best = (start, mean)
            }
        }
        return best
    }

    /// How a window's span divides among the hours it touches: the first
    /// date in each hour it covers, and that hour's share of it.
    static func hourShares(from start: Date, span: Double,
                           calendar: Calendar) -> [(Date, Double)] {
        guard span > 0 else { return [(start, 1)] }
        var out: [(Date, Double)] = []
        var cursor = start
        let end = start.addingTimeInterval(span)
        while cursor < end {
            let nextHour = calendar.date(bySetting: .minute, value: 0,
                                         of: cursor.addingTimeInterval(3600))
                .map { calendar.date(bySetting: .second, value: 0, of: $0) ?? $0 }
                ?? cursor.addingTimeInterval(3600)
            let slice = min(end, nextHour)
            let seconds = slice.timeIntervalSince(cursor)
            if seconds > 0 { out.append((cursor, seconds / span)) }
            guard slice > cursor else { break }
            cursor = slice
        }
        return out.isEmpty ? [(start, 1)] : out
    }

    /// Which day a moment belongs to, with the boundary at
    /// `dayStartHour` rather than midnight.
    static func dayOrdinal(_ date: Date, calendar: Calendar) -> Int {
        let shifted = date.addingTimeInterval(-Double(dayStartHour) * 3600)
        var components = calendar.dateComponents([.year, .month, .day], from: shifted)
        components.timeZone = calendar.timeZone
        let day = calendar.date(from: components) ?? shifted
        return Int(day.timeIntervalSince1970 / 86_400)
    }

    static func minutesSinceDayStart(_ date: Date, calendar: Calendar) -> Double {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        var position = Double(hour * 60 + minute) - Double(dayStartHour * 60)
        if position < 0 { position += 24 * 60 }
        return position
    }

    static func blankDay(ordinal: Int, at date: Date, calendar: Calendar) -> Day {
        var day = Day(ordinal: ordinal)
        // The weekday of the day's own start, not of the moment — 1am on
        // a Saturday belongs to Friday's working day.
        let shifted = date.addingTimeInterval(-Double(dayStartHour) * 3600)
        let weekday = calendar.component(.weekday, from: shifted)
        day.weekend = (weekday == 1 || weekday == 7)
        return day
    }
}
