import Foundation

/// How a stretch of the health record was measured: the facts a reader
/// needs before comparing one stretch with another, for the changes that
/// alter what a number means. The record's own `era` events name the build
/// from 0.35.0 on; before them the stage is inferred from what the pulses
/// carry, and says so (`basis`).
///
/// A build is not such a change by itself: Lodestar ships most days, and a
/// release that changed a measure is named here, with the version that
/// changed it.
public struct HealthMeasurement: Encodable, Equatable, Sendable {
    public enum Basis: String, Codable, Sendable {
        /// Read from the era the record wrote.
        case era
        /// Before eras were written (0.35.0): inferred from the columns the
        /// pulses carry. The hold column began with 0.31.2 and the tap's
        /// lateness column with 0.34.0, so the first pulse to carry each
        /// marks the stage.
        case inferred
    }

    /// What timed a hold.
    public enum HoldClock: String, Codable, Sendable {
        /// No holds were recorded (before 0.31.2).
        case none
        /// The handler's clock on the main run loop, press and release alike
        /// (0.31.2 to 0.33). A stall was common to both ends and cancelled;
        /// the 0.34.0 cutover left no step in the mean (audit, 2026-09-16).
        case callback
        /// The key event's own timestamp (0.34.0 on), quantised by the
        /// keyboard's report interval.
        case eventStamp
    }

    /// What the `keyboards` lists on pulses and windows mean.
    public enum KeyboardList: String, Codable, Sendable {
        case none
        /// The keyboards attached when Lodestar launched, not when the press
        /// happened (0.34.0 to 0.39.1): unreliable for attribution.
        case launchSnapshot
        /// The keyboards attached at the time (0.39.2 on).
        case live
    }

    /// How a raw press's `keyboard` was decided.
    public enum PressKeyboard: String, Codable, Sendable {
        case none
        /// By the lid (0.34.0 to 0.39.1): with the lid open, a Bluetooth
        /// keyboard's presses were charged to the built-in one. A press's
        /// `keyboardType` byte (91 built-in, 40 external) is the reliable
        /// field for these.
        case lid
        /// By the press's own keyboard type, matched to the roster (0.39.2 on).
        case keyboardType
        /// Matched to the keyboard's own report (Input Monitoring granted).
        case exact
    }

    /// The build that wrote it; nil before eras were written.
    @Nullable public var build: String? = nil
    public var basis: Basis
    public var holdClock: HoldClock
    /// Pulses carry a bout position and the pause tail (0.31.2 on).
    public var bouts: Bool
    /// Ninety-second windows and the raw press record exist (0.34.0 on).
    public var windows: Bool
    public var keyboardList: KeyboardList
    public var pressKeyboard: PressKeyboard
    /// Spans the instrument could not see were recorded (0.46.0 on).
    /// Before, an unseen hour and a quiet one look the same, so blind time
    /// is unknown, never zero.
    public var blindSpans: Bool
    /// Each keyboard's report interval was written down (0.46.0 on).
    public var reportIntervals: Bool
    /// Spoken drafts were measured (0.53.0 on).
    public var voice: Bool
    /// The raw pointer record's format (2 from 0.54.0: every movement, not
    /// only reaches); nil before eras.
    @Nullable public var pointerSchema: Int? = nil

    /// The measurement as a period sees it. Two kinds of change differ:
    /// one that changes what a number *means* (the hold clock, what a
    /// keyboard list is) cuts a period in two, so no row sums across it;
    /// one that only starts or stops a measure being recorded (bouts,
    /// windows, blind spans, voice) does not, and the period says what share
    /// of its time was recorded instead. Builds alternate around a release
    /// (the old one runs again for a while), so a recorded measure can come
    /// and go within a day, and cutting at each would leave slivers.
    ///
    /// Not here at all: the build (Lodestar ships most days), and what only
    /// raw rows carry, which raw rows state themselves: how a press's
    /// keyboard was decided (each launch writes it twice, a minute apart, as
    /// Input Monitoring is confirmed), the raw pointer format, and whether
    /// intervals were written down (a device's interval holds on both sides
    /// of the era that stated it).
    public struct Period: Encodable, Equatable, Sendable {
        /// `inferred` when any part of the period was.
        public var basis: Basis
        public var holdClock: HoldClock
        public var keyboardList: KeyboardList
        /// The share of the period's time, 0 to 1, under builds that recorded
        /// each. Zero: the period's section for it is null.
        public var recorded: Recorded

        public struct Recorded: Encodable, Equatable, Sendable {
            public var bouts = 0.0
            public var windows = 0.0
            public var blindSpans = 0.0
            public var voice = 0.0
        }
    }

    /// Whether two moments may be summed into one period.
    func meansTheSame(as other: HealthMeasurement) -> Bool {
        holdClock == other.holdClock && keyboardList == other.keyboardList
    }

    /// Whether a change from `other` is worth a line in a list of stretches:
    /// anything a period reads, apart from how it is known.
    func periodReadsTheSame(as other: HealthMeasurement) -> Bool {
        meansTheSame(as: other) && bouts == other.bouts && windows == other.windows
            && blindSpans == other.blindSpans && voice == other.voice
    }

    /// The releases that changed a measure.
    enum Since {
        static let holds = [0, 31, 2]
        static let eventStamp = [0, 34, 0]
        static let liveRoster = [0, 39, 2]
        static let blindSpans = [0, 46, 0]
        static let voice = [0, 53, 0]
    }

    /// From an era the record wrote.
    public init(era: EraInfo) {
        let version = Self.numbers(era.appVersion)
        func since(_ release: [Int]) -> Bool { !Updater.isNewer(release, than: version) }
        build = era.appVersion
        basis = .era
        holdClock = since(Since.eventStamp) ? .eventStamp : since(Since.holds) ? .callback : .none
        bouts = since(Since.holds)
        windows = since(Since.eventStamp)
        keyboardList = since(Since.liveRoster) ? .live : since(Since.eventStamp) ? .launchSnapshot : .none
        pressKeyboard = era.exactKeyboards == true ? .exact
            : since(Since.liveRoster) ? .keyboardType : since(Since.eventStamp) ? .lid : .none
        blindSpans = since(Since.blindSpans)
        reportIntervals = era.reportIntervals != nil
        voice = since(Since.voice)
        pointerSchema = era.pointerSchema
    }

    /// An inferred stage before eras: 0 no holds, 1 the callback clock,
    /// 2 the event stamp.
    init(inferredStage stage: Int) {
        build = nil
        basis = .inferred
        holdClock = stage >= 2 ? .eventStamp : stage == 1 ? .callback : .none
        bouts = stage >= 1
        windows = stage >= 2
        keyboardList = stage >= 2 ? .launchSnapshot : .none
        pressKeyboard = stage >= 2 ? .lid : .none
        blindSpans = false
        reportIntervals = false
        voice = false
        pointerSchema = nil
    }

    static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// The measurement in force at each moment of a record, from its own
    /// eras and, before them, from what its pulses carried.
    public struct Timeline: Equatable, Sendable {
        /// Each stretch from its start, oldest first; the first starts at
        /// the distant past.
        public let stretches: [(start: Date, measurement: HealthMeasurement)]
        /// Each keyboard's report interval, as any era stated it: a fact of
        /// the device, so it holds for the device's presses on either side
        /// of the era that wrote it down.
        public let intervals: [String: ReportInterval]

        public static func == (lhs: Timeline, rhs: Timeline) -> Bool {
            lhs.stretches.map(\.start) == rhs.stretches.map(\.start)
                && lhs.stretches.map(\.measurement) == rhs.stretches.map(\.measurement)
                && lhs.intervals == rhs.intervals
        }

        public init(events: [ObservationEvent]) {
            let sorted = events.sorted { $0.t < $1.t }
            let eras = sorted.filter { $0.kind == .era && $0.era != nil }
            let firstEra = eras.first?.t ?? .distantFuture
            let pulses = sorted.lazy.filter { $0.kind == .pulse && $0.t < firstEra }
            var stretches: [(start: Date, measurement: HealthMeasurement)] = [(.distantPast, HealthMeasurement(inferredStage: 0))]
            if let holds = pulses.first(where: { $0.holdN != nil }) {
                stretches.append((holds.t, HealthMeasurement(inferredStage: 1)))
            }
            if let stamped = pulses.first(where: { $0.jitterN != nil }) {
                stretches.append((stamped.t, HealthMeasurement(inferredStage: 2)))
            }
            var intervals: [String: ReportInterval] = [:]
            for event in eras {
                guard let era = event.era else { continue }
                let measurement = HealthMeasurement(era: era)
                if stretches.last?.measurement != measurement { stretches.append((event.t, measurement)) }
                // A stated number outranks an `unknown` from another era.
                for (id, interval) in era.reportIntervals ?? [:] {
                    if case .microseconds = interval { intervals[id] = interval } else if intervals[id] == nil { intervals[id] = .unknown }
                }
            }
            self.stretches = stretches
            self.intervals = intervals
        }

        public func at(_ t: Date) -> HealthMeasurement {
            var low = 0
            var high = stretches.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if stretches[mid].start <= t { low = mid } else { high = mid - 1 }
            }
            return stretches[low].measurement
        }

        /// The stretches where anything a period reads changed, oldest first,
        /// each with the build that began it (the `era` grain has every build).
        public var periodStretches: [(start: Date, measurement: HealthMeasurement)] {
            var out: [(start: Date, measurement: HealthMeasurement)] = []
            for stretch in stretches where !(out.last?.measurement.periodReadsTheSame(as: stretch.measurement) ?? false) {
                out.append(stretch)
            }
            return out
        }

        /// `[start, end)` cut where the meaning of a period's numbers changes,
        /// each piece with what was recorded across it and every build that
        /// wrote in it.
        public func pieces(from start: Date, to end: Date)
            -> [(start: Date, end: Date, measurement: Period, builds: [String])] {
            let inside = stretches.filter { $0.start > start && $0.start < end }
            let cuts = [(start, at(start))] + inside.map { ($0.start, $0.measurement) }
            var groups: [[(start: Date, end: Date, measurement: HealthMeasurement)]] = []
            for (index, cut) in cuts.enumerated() {
                let stretch = (start: cut.0, end: index + 1 < cuts.count ? cuts[index + 1].0 : end, measurement: cut.1)
                if let last = groups.last?.last, last.measurement.meansTheSame(as: stretch.measurement) {
                    groups[groups.count - 1].append(stretch)
                } else {
                    groups.append([stretch])
                }
            }
            return groups.map { group in
                let first = group[0]
                let length = max(1, group.last!.end.timeIntervalSince(first.start))
                func share(_ recorded: (HealthMeasurement) -> Bool) -> Double {
                    group.filter { recorded($0.measurement) }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / length
                }
                let period = Period(
                    basis: group.contains { $0.measurement.basis == .inferred } ? .inferred : .era,
                    holdClock: first.measurement.holdClock, keyboardList: first.measurement.keyboardList,
                    recorded: Period.Recorded(bouts: share(\.bouts), windows: share(\.windows),
                                              blindSpans: share(\.blindSpans), voice: share(\.voice)))
                var builds: [String] = []
                for stretch in group { if let build = stretch.measurement.build, !builds.contains(build) { builds.append(build) } }
                return (first.start, group.last!.end, period, builds)
            }
        }
    }
}
