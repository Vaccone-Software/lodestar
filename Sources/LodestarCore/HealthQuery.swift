import Foundation

/// The health record as rows for analysis (`lodestar health`): periods
/// described with the same read-time views the printout uses, and the
/// record's own events one per row, every row saying how it was measured
/// (`HealthMeasurement`). A period is never summed across a change in
/// measurement; it is cut there, and each piece says so. What was not
/// measured is null, never zero.
///
/// Times are Unix seconds, as the record keeps them; days are health days,
/// from four in the morning (`DayFile`).
public enum HealthQuery {
    /// Bumped when a row's shape changes in a way a reader must know.
    public static let schema = 1

    public enum Grain: String, CaseIterable, Sendable {
        case summary, day, week, month
        case pulse, window, bout, blind, voice, click, era
        /// The raw press record: hand, finger, kind and timing of every
        /// press. Not key identity, but a partial transcript (DESIGN, the
        /// health pulse), so it is only ever read when asked for by name
        /// and by flag.
        case press

        var isPeriod: Bool { [.summary, .day, .week, .month].contains(self) }

        /// The event kind behind a one-event-per-row grain.
        var eventKind: ObservationEvent.Kind? {
            switch self {
            case .pulse: .pulse
            case .window: .window
            case .blind: .blind
            case .voice: .voice
            case .click: .clicks
            case .era: .era
            default: nil
            }
        }
    }

    /// Which health days to read, both ends inclusive; nil is open.
    public struct Days: Equatable, Sendable {
        public var since: String?
        public var until: String?

        public init(since: String? = nil, until: String? = nil) {
            self.since = since
            self.until = until
        }

        /// Whether `text` names a real day, written YYYY-MM-DD: a month 13
        /// is refused, not rolled into the next year.
        public static func isDay(_ text: String, calendar: Calendar) -> Bool {
            guard text.count == 10, let start = DayFile.dayStart(of: text, calendar: calendar) else { return false }
            return DayFile.day(of: start, calendar: calendar) == text
        }

        func bounds(calendar: Calendar) -> (from: Date, to: Date) {
            let from = since.flatMap { DayFile.dayStart(of: $0, calendar: calendar) } ?? .distantPast
            let to = until.flatMap { DayFile.dayStart(of: $0, calendar: calendar) }
                .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? .distantFuture
            return (from, to)
        }

        public func contains(day: String) -> Bool {
            (since.map { day >= $0 } ?? true) && (until.map { day <= $0 } ?? true)
        }
    }

    // MARK: - Rows

    /// The first line of every answer: what was read and how to read it.
    public struct Header: Encodable {
        public let row = "header"
        public let schema = HealthQuery.schema
        public var grain: String
        @Nullable public var since: String? = nil
        @Nullable public var until: String? = nil
        public var timeZone: String
        /// Files that did not open. Nonempty: the rows are not the whole record.
        public var problems: [String]
        /// Each change in anything a period reads, oldest first, with the
        /// build that began it (the `era` grain has every build).
        public var measurements: [Stretch]
        /// Each keyboard's report interval in microseconds, or "unknown":
        /// holds from it are quantised to this grain.
        public var reportIntervals: [String: ReportInterval]

        public struct Stretch: Encodable {
            @Nullable public var start: Double? = nil
            public var measurement: HealthMeasurement
        }
    }

    /// One period: a day, a week, a month, or the whole span, or the part of
    /// one on one side of a change in measurement (`split`).
    public struct Period: Encodable {
        public var row: String
        public var firstDay: String
        public var lastDay: String
        public var start: Date
        public var end: Date
        /// The period was cut by a change in measurement: this row is a part of it.
        public var split: Bool
        public var measurement: HealthMeasurement.Period
        public var builds: [String]
        public var activeDays: Int
        @Nullable public var input: Input? = nil
        @Nullable public var hold: Hold? = nil
        @Nullable public var windows: Windows? = nil
        @Nullable public var bouts: Bouts? = nil
        @Nullable public var rhythm: Rhythm? = nil
        @Nullable public var pointer: Pointer? = nil
        @Nullable public var voice: Voice? = nil
        /// Seconds unseen by kind, in the part of the period whose builds
        /// recorded blind spans (`measurement.recorded.blindSpans`). Null when
        /// none did: an unseen hour then looks like a quiet one, so it is
        /// unknown, never zero.
        @Nullable public var blind: [String: Double]? = nil
        @Nullable public var quality: Quality? = nil
    }

    public struct Input: Encodable {
        public var keys: Int
        public var backspaces: Int
        @Nullable public var correctionRate: Double? = nil
        /// Backspaces by the run they came in: single, two to four, five or more.
        public var backspaceRunKeys: [Int]
        public var activeMinutes: Int
        public var longestStretchMinutes: Int
        /// Gaps under the two-second motor ceiling.
        @Nullable public var interKeyMeanMs: Double? = nil
        @Nullable public var interKeySDMs: Double? = nil
        @Nullable public var interKeyMedianMs: Double? = nil
        /// Gaps past the ceiling, inside a bout.
        public var pauses: Int
        @Nullable public var pauseMeanSeconds: Double? = nil
        @Nullable public var pauseShare: Double? = nil
        /// Last key to the first backspace of a run.
        @Nullable public var fixMeanMs: Double? = nil
        public var minutesByHour: [Int]
    }

    public struct Hold: Encodable {
        public var n: Int
        @Nullable public var meanMs: Double? = nil
        @Nullable public var sdMs: Double? = nil
        @Nullable public var cv: Double? = nil
        /// Read off the pulse histogram, to its bin (four to an octave).
        @Nullable public var p10Ms: Double? = nil
        @Nullable public var medianMs: Double? = nil
        @Nullable public var p90Ms: Double? = nil
        /// Holds per keystroke counted, in pulses that carry holds at all.
        @Nullable public var coverage: Double? = nil
    }

    public struct Windows: Encodable {
        public var total: Int
        public var valid: Int
        @Nullable public var holdSDMedianMs: Double? = nil
        @Nullable public var holdSDSpreadMs: Double? = nil
        @Nullable public var holdMedianMs: Double? = nil
        @Nullable public var fluctSDMedian: Double? = nil
        @Nullable public var vIQRMedian: Double? = nil
        @Nullable public var vOutMedian: Double? = nil
        @Nullable public var overlapShare: Double? = nil
        /// Left hand minus right, median of the windows'.
        @Nullable public var asymmetryMedianMs: Double? = nil
    }

    public struct Bouts: Encodable {
        public var count: Int
        @Nullable public var meanMinutes: Double? = nil
        @Nullable public var longestMinutes: Double? = nil
        public var correctionDrift: Drift
        public var pauseDrift: Drift
        public var holdDrift: Drift
    }

    /// Change per hour into a bout, fitted within bouts.
    public struct Drift: Encodable {
        @Nullable public var perHour: Double? = nil
        @Nullable public var standardError: Double? = nil
        public var fitted: Int
        /// Clears twice its own error.
        public var distinguishable: Bool

        init(_ drift: Vigilance.Drift) {
            perHour = drift.perHour
            standardError = drift.standardError
            fitted = drift.fitted
            distinguishable = drift.isDistinguishable
        }
    }

    /// The actigraphy measures, on two or more active days.
    public struct Rhythm: Encodable {
        @Nullable public var interdailyStability: Double? = nil
        @Nullable public var intradailyVariability: Double? = nil
        @Nullable public var relativeAmplitude: Double? = nil
        @Nullable public var m10: Double? = nil
        @Nullable public var m10Hour: Int? = nil
        @Nullable public var l5: Double? = nil
        @Nullable public var l5Hour: Int? = nil
        @Nullable public var onsetHour: Double? = nil
        @Nullable public var offsetHour: Double? = nil
        @Nullable public var midpointHour: Double? = nil
        @Nullable public var socialJetlagHours: Double? = nil
    }

    public struct Pointer: Encodable {
        public var clicks: Int
        public var clicksPosted: Int
        public var scrolls: Int
        public var scrollSeconds: Double
        @Nullable public var scrollPreciseShare: Double? = nil
        @Nullable public var scrollMomentumShare: Double? = nil
        @Nullable public var fromKeysShare: Double? = nil
        @Nullable public var pointSeconds: Double? = nil
        @Nullable public var travelSeconds: Double? = nil
        @Nullable public var settleSeconds: Double? = nil
        @Nullable public var homingSeconds: Double? = nil
        @Nullable public var pressSeconds: Double? = nil
        @Nullable public var returnSeconds: Double? = nil
        @Nullable public var pathPoints: Double? = nil
        @Nullable public var straightness: Double? = nil
        public var drags: Int
        @Nullable public var dragSeconds: Double? = nil
    }

    /// Medians across the period's spoken drafts.
    public struct Voice: Encodable {
        public var drafts: Int
        @Nullable public var f0Hz: Double? = nil
        @Nullable public var jitter: Double? = nil
        @Nullable public var shimmer: Double? = nil
        @Nullable public var hnrDb: Double? = nil
        @Nullable public var wordsPerSecond: Double? = nil
    }

    public struct Quality: Encodable {
        /// How late the tap ran behind the event stamps.
        @Nullable public var tapLateMs: Double? = nil
        public var tapResets: Int
        /// The keyboards the pulses name, with each one's report interval.
        public var keyboards: [String: ReportInterval]
    }

    /// One of the record's events as it was stored.
    public struct Event: Encodable {
        public var row: String
        public var day: String
        public var measurement: HealthMeasurement
        public var event: ObservationEvent
    }

    /// One bout of continuous work.
    public struct BoutRow: Encodable {
        public let row = "bout"
        public var day: String
        public var start: Date
        public var minutes: Double
        public var pulses: Int
        public var keys: Int
        @Nullable public var correctionRate: Double? = nil
        @Nullable public var holdMeanMs: Double? = nil
        /// The record began inside it, or a measurement change cut it.
        public var joined: Bool
        public var measurement: HealthMeasurement.Period
    }

    /// One raw press. No key identity: the hand, the finger and the class.
    public struct Press: Encodable {
        public let row = "press"
        public var day: String
        public var down: Date
        /// Null: no release was seen (stranded past five seconds, or the tap reset).
        @Nullable public var holdMs: Double? = nil
        public var hand: String
        public var finger: String
        public var kind: String
        public var typing: Bool
        public var shift: Bool
        public var chord: Bool
        public var gesture: Bool
        public var lens: Bool
        public var repeated: Bool
        public var armed: Bool
        public var modifiers: [String]
        public var struck: Int
        /// 91 the built-in keyboard, 40 an external one: the reliable field
        /// where `keyboard` was decided by the lid.
        public var keyboardType: Int
        /// The roster id the press was charged to; null when nobody could say.
        @Nullable public var keyboard: String? = nil
        public var lid: Bool
        public var measurement: HealthMeasurement

        init(_ press: KeyPress, keyboard: String?, day: String, measurement: HealthMeasurement) {
            self.day = day
            down = press.down
            holdMs = press.hold.map { $0 * 1000 }
            hand = "\(press.hand)"
            finger = "\(press.finger)"
            kind = "\(press.kind)"
            typing = press.isTyping
            shift = press.shift
            chord = press.chord
            gesture = press.gesture
            lens = press.lens
            repeated = press.repeated
            armed = press.armed
            let names: [(Keys.Modifiers, String)] = [(.command, "command"), (.shift, "shift"), (.option, "option"),
                                                     (.control, "control"), (.fn, "fn")]
            modifiers = names.filter { press.modifiers.contains($0.0) }.map(\.1)
            struck = press.struck
            keyboardType = press.keyboardType
            self.keyboard = keyboard
            lid = press.lid
            self.measurement = measurement
        }
    }

    // MARK: - Building

    public static func header(grain: Grain, days: Days, timeline: HealthMeasurement.Timeline,
                              problems: [String], calendar: Calendar) -> Header {
        Header(grain: grain.rawValue, since: days.since, until: days.until,
               timeZone: calendar.timeZone.identifier, problems: problems,
               measurements: timeline.periodStretches.map {
                   Header.Stretch(start: $0.start == .distantPast ? nil : $0.start.timeIntervalSince1970,
                                  measurement: $0.measurement)
               },
               reportIntervals: timeline.intervals)
    }

    /// One row per event of the grain's kind, in time order.
    public static func events(_ grain: Grain, events: [ObservationEvent], timeline: HealthMeasurement.Timeline,
                              days: Days, calendar: Calendar) -> [Event] {
        guard let kind = grain.eventKind else { return [] }
        return events.compactMap { event in
            guard event.kind == kind else { return nil }
            let day = DayFile.day(of: event.t, calendar: calendar)
            guard days.contains(day: day) else { return nil }
            return Event(row: grain.rawValue, day: day, measurement: timeline.at(event.t), event: event)
        }
    }

    /// The bouts, cut where the measurement changed.
    public static func bouts(events: [ObservationEvent], timeline: HealthMeasurement.Timeline,
                             days: Days, calendar: Calendar) -> [BoutRow] {
        let (from, to) = days.bounds(calendar: calendar)
        let inside = events.filter { $0.kind == .pulse && $0.t >= from && $0.t < to }
        guard let first = inside.first?.t, let last = inside.last?.t else { return [] }
        return timeline.pieces(from: first, to: last.addingTimeInterval(1)).flatMap { piece in
            Vigilance.bouts(events: inside.filter { $0.t >= piece.start && $0.t < piece.end }).map { bout in
                BoutRow(day: DayFile.day(of: bout.start, calendar: calendar), start: bout.start,
                        minutes: bout.minutes, pulses: bout.pulses, keys: bout.keys,
                        correctionRate: bout.keys > 0 ? Double(bout.backspaces) / Double(bout.keys) : nil,
                        holdMeanMs: bout.holdN > 0 ? bout.holdSum / Double(bout.holdN) * 1000 : nil,
                        joined: bout.joined, measurement: piece.measurement)
            }
        }
    }

    public static func presses(_ rows: [(press: KeyPress, keyboard: String?)], day: String,
                               timeline: HealthMeasurement.Timeline) -> [Press] {
        rows.map { Press($0.press, keyboard: $0.keyboard, day: day, measurement: timeline.at($0.press.down)) }
    }

    /// The periods of a grain that hold any of the record, each cut where
    /// the measurement changed.
    public static func periods(_ grain: Grain, events: [ObservationEvent], timeline: HealthMeasurement.Timeline,
                               days: Days, calendar: Calendar) -> [Period] {
        let blind = events.filter { $0.kind == .blind }
        let dayEvents = Dictionary(grouping: events) { DayFile.day(of: $0.t, calendar: calendar) }
            .filter { days.contains(day: $0.key) }
        let present = dayEvents.keys.sorted()
        guard let firstPresent = present.first, let lastPresent = present.last else { return [] }
        var groups: [(first: String, last: String)] = []
        switch grain {
        case .summary:
            groups = [(firstPresent, lastPresent)]
        case .day:
            groups = present.map { ($0, $0) }
        case .week, .month:
            var seen: Set<String> = []
            for day in present {
                guard let span = enclosing(grain, day: day, calendar: calendar), seen.insert(span.first).inserted
                else { continue }
                groups.append((days.since.map { max($0, span.first) } ?? span.first,
                               days.until.map { min($0, span.last) } ?? span.last))
            }
        default:
            return []
        }
        return groups.flatMap { group -> [Period] in
            guard let start = DayFile.dayStart(of: group.first, calendar: calendar),
                  let lastStart = DayFile.dayStart(of: group.last, calendar: calendar),
                  let end = calendar.date(byAdding: .day, value: 1, to: lastStart) else { return [] }
            let inside = events.filter { $0.t >= start && $0.t < end }
            let pieces = timeline.pieces(from: start, to: end)
            return pieces.compactMap { piece in
                let slice = inside.filter { $0.t >= piece.start && $0.t < piece.end }
                // An era alone is the instrument starting, not a period of the record.
                guard slice.contains(where: { $0.kind != .era }) else { return nil }
                return period(grain.rawValue, slice: slice, blind: blind, piece: piece,
                              split: pieces.count > 1, timeline: timeline, calendar: calendar)
            }
        }
    }

    /// The health days of the week (Monday first) or month a day falls in.
    static func enclosing(_ grain: Grain, day: String, calendar: Calendar) -> (first: String, last: String)? {
        guard let date = DayFile.dayStart(of: day, calendar: calendar) else { return nil }
        func name(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        switch grain {
        case .week:
            let back = (calendar.component(.weekday, from: date) + 5) % 7
            guard let monday = calendar.date(byAdding: .day, value: -back, to: date),
                  let sunday = calendar.date(byAdding: .day, value: 6, to: monday) else { return nil }
            return (name(monday), name(sunday))
        case .month:
            guard let range = calendar.range(of: .day, in: .month, for: date) else { return nil }
            let prefix = String(day.prefix(8))
            return (prefix + "01", prefix + String(format: "%02d", range.count))
        default:
            return (day, day)
        }
    }

    private static func period(_ row: String, slice: [ObservationEvent], blind: [ObservationEvent],
                               piece: (start: Date, end: Date, measurement: HealthMeasurement.Period, builds: [String]),
                               split: Bool, timeline: HealthMeasurement.Timeline, calendar: Calendar) -> Period {
        // The read-time views take a window ending now; the slice is already
        // the window, so the span only has to reach past its start.
        let now = piece.end
        let span = Int(piece.end.timeIntervalSince(piece.start) / 86_400) + 2
        let measurement = piece.measurement
        let health = Health.summary(events: slice, days: span, now: now, calendar: calendar)
        var out = Period(row: row, firstDay: DayFile.day(of: piece.start, calendar: calendar),
                         lastDay: DayFile.day(of: piece.end.addingTimeInterval(-1), calendar: calendar),
                         start: piece.start, end: piece.end, split: split, measurement: measurement,
                         builds: piece.builds, activeDays: health?.days ?? 0)
        if let h = health {
            out.input = Input(keys: h.keys, backspaces: h.backspaces, correctionRate: h.correctionRate,
                              backspaceRunKeys: h.backspaceRunKeys, activeMinutes: h.activeMinutes,
                              longestStretchMinutes: h.longestStretchMinutes,
                              interKeyMeanMs: ms(h.interKeyMean), interKeySDMs: ms(h.interKeySD),
                              interKeyMedianMs: ms(h.interKeyHistogram.median),
                              pauses: h.pauseN, pauseMeanSeconds: h.pauseMean, pauseShare: h.pauseShare,
                              fixMeanMs: ms(h.fixMean), minutesByHour: h.hourMinutes)
            if measurement.holdClock != .none {
                out.hold = Hold(n: h.holdN, meanMs: ms(h.holdMean), sdMs: ms(h.holdSD), cv: h.holdCV,
                                p10Ms: ms(h.holdHistogram.quantile(0.1)), medianMs: ms(h.holdHistogram.median),
                                p90Ms: ms(h.holdHistogram.quantile(0.9)), coverage: h.coverage)
            }
            out.quality = Quality(tapLateMs: ms(h.jitterMean), tapResets: h.tapResets,
                                  keyboards: Dictionary(uniqueKeysWithValues: h.keyboards.map {
                                      ($0, timeline.intervals[$0] ?? .unknown)
                                  }))
            out.pointer = Pointer(clicks: h.clicks, clicksPosted: h.clicksPosted, scrolls: h.scrolls,
                                  scrollSeconds: h.scrollSeconds, scrollPreciseShare: h.scrollPreciseShare,
                                  scrollMomentumShare: h.scrollMomentumShare, fromKeysShare: nil, drags: 0)
        }
        if measurement.recorded.windows > 0, let w = WindowSummary.report(events: slice, days: span, now: now) {
            out.windows = Windows(total: w.windows, valid: w.valid, holdSDMedianMs: ms(w.holdSDMedian),
                                  holdSDSpreadMs: ms(w.holdSDSpread), holdMedianMs: ms(w.holdMedian),
                                  fluctSDMedian: w.fluctSDMedian, vIQRMedian: w.vIQRMedian, vOutMedian: w.vOutMedian,
                                  overlapShare: w.overlapShare, asymmetryMedianMs: ms(w.asymmetryMedian))
        }
        if measurement.recorded.bouts > 0, let v = Vigilance.report(events: slice, days: span, now: now), v.bouts > 0 {
            out.bouts = Bouts(count: v.bouts, meanMinutes: v.meanBoutMinutes, longestMinutes: v.longestBoutMinutes,
                              correctionDrift: Drift(v.correctionRate), pauseDrift: Drift(v.pauseShare),
                              holdDrift: Drift(v.holdTime))
        }
        if let c = Circadian.profile(events: slice, days: span, now: now, calendar: calendar), c.days >= 2 {
            out.rhythm = Rhythm(interdailyStability: c.interdailyStability,
                                intradailyVariability: c.intradailyVariability,
                                relativeAmplitude: c.relativeAmplitude, m10: c.m10, m10Hour: c.m10Hour,
                                l5: c.l5, l5Hour: c.l5Hour, onsetHour: c.onsetHour, offsetHour: c.offsetHour,
                                midpointHour: c.midpointHour, socialJetlagHours: c.socialJetlagHours)
        }
        if let clicks = Health.clicks(events: slice, days: span, now: now, calendar: calendar) {
            let p = clicks.pointer
            var pointer = out.pointer ?? Pointer(clicks: 0, clicksPosted: 0, scrolls: 0, scrollSeconds: 0, drags: 0)
            pointer.fromKeysShare = clicks.fromKeysShare
            pointer.pointSeconds = p.pointMean
            pointer.travelSeconds = p.travelMean
            pointer.settleSeconds = p.settleMean
            pointer.homingSeconds = p.homingMean
            pointer.pressSeconds = p.pressMean
            pointer.returnSeconds = p.returnMean
            pointer.pathPoints = p.pathMean
            pointer.straightness = p.efficiency
            pointer.drags = p.dragN
            pointer.dragSeconds = p.dragMean
            out.pointer = pointer
        }
        if measurement.recorded.voice > 0 {
            let v = VoiceStats.summary(events: slice, days: span, now: now)
            out.voice = Voice(drafts: v?.drafts ?? 0, f0Hz: v?.f0, jitter: v?.jitter, shimmer: v?.shimmer,
                              hnrDb: v?.hnr, wordsPerSecond: v?.rate)
        }
        if measurement.recorded.blindSpans > 0 {
            out.blind = Dictionary(uniqueKeysWithValues: BlindSummary.rows(events: blind, from: piece.start, to: piece.end)
                .map { ($0.kind, $0.seconds) })
        }
        return out
    }

    private static func ms(_ seconds: Double?) -> Double? { seconds.map { $0 * 1000 } }
}

/// An optional written as `null` when it is nil, rather than left out: a row
/// keeps every column, and an absent measure reads as absent.
@propertyWrapper
public struct Nullable<Value: Encodable>: Encodable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}

extension Nullable: Equatable where Value: Equatable {}
extension Nullable: Sendable where Value: Sendable {}
