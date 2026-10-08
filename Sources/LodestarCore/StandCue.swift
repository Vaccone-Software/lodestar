import Foundation

/// When to ask for a walk, and when not to.
///
/// What the evidence supports is short walks often: two minutes of light
/// walking every twenty to thirty minutes blunts the glucose and insulin
/// rise that unbroken sitting brings, and walking does this where standing
/// barely does (Dunstan 2012, Henson 2020, Buffey 2022). The length of the
/// unbroken stretch matters on its own (Diaz 2017). So a stretch is input
/// with no gap of two minutes or more, the break the trials found enough,
/// and thirty minutes into one, the top of the tested range, is when the
/// walk is due.
///
/// Due is not now. A cue that lands mid-sentence is dismissed and
/// resented; one at a natural stopping point is taken. So the walk waits
/// for the next stopping point the hand makes: leaving an app it worked
/// in for a while, or sending a draft. Measured on the maker's three weeks,
/// one came within two minutes of the mark in half of long stretches and
/// within ten in nineteen of twenty. If none comes for fifteen minutes,
/// the first pause in typing will do. A pause while reading is never one:
/// a cue there interrupts the reading.
///
/// Two cues at most in a stretch: one at thirty minutes and one at sixty
/// if the first was not taken, and then silence until a break. Repeating a
/// dismissed cue is how a coach becomes a nag.
public struct StandCue: Sendable {
    public enum Boundary: String, Sendable {
        /// Left an app worked in for a while.
        case appSwitch
        /// A draft sent or closed.
        case draft
        /// No stopping point came, and typing paused.
        case pause
    }

    /// A cue to show: the stretch so far, and how much of the hour the
    /// mark should light.
    public struct Cue: Equatable, Sendable {
        public let minutes: Int
        public let share: Double
        public let via: Boundary
        public let index: Int
    }

    public struct Settings: Equatable, Sendable {
        /// Minutes of unbroken work before a walk is due.
        public var after: TimeInterval = 30 * 60
        /// A gap this long is a break, and starts the stretch over.
        public var breakGap: TimeInterval = 120
        /// Time in an app before leaving it counts as a stopping point.
        public var dwell: TimeInterval = 120
        /// Due this long with no stopping point: a typing pause will do.
        public var fallback: TimeInterval = 15 * 60
        /// The typing pause that will do then.
        public var pause: TimeInterval = 15
        /// Cues in one stretch, at most.
        public var maximum = 2
        public init() {}
    }

    public let settings: Settings
    public private(set) var stretchStart: Date?
    public private(set) var lastInput: Date?
    public private(set) var given = 0
    /// The last cue's time, to learn whether a break followed it.
    public private(set) var lastCueAt: Date?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Human input: a key, a click, a scroll, a word into the draft.
    /// Returns true when a break has just ended and a new stretch begins.
    @discardableResult
    public mutating func input(at time: Date) -> Bool {
        defer { lastInput = time }
        guard let last = lastInput, stretchStart != nil else {
            stretchStart = time
            return false
        }
        if time.timeIntervalSince(last) >= settings.breakGap {
            stretchStart = time
            given = 0
            return true
        }
        return false
    }

    /// How long the stretch has run, at `now`.
    public func elapsed(at now: Date) -> TimeInterval {
        guard let start = stretchStart, let last = lastInput,
              now.timeIntervalSince(last) < settings.breakGap else { return 0 }
        return now.timeIntervalSince(start)
    }

    /// When the next cue falls due, or nil when the stretch has had its two.
    public func dueAt() -> Date? {
        guard given < settings.maximum, let start = stretchStart else { return nil }
        return start.addingTimeInterval(settings.after * Double(given + 1))
    }

    /// A stopping point at `now`: the cue it earns, if one is due.
    public mutating func boundary(_ kind: Boundary, at now: Date) -> Cue? {
        guard let due = dueAt(), now >= due, elapsed(at: now) > 0 else { return nil }
        return give(via: kind, at: now)
    }

    /// Checked now and then: due long enough with no stopping point, and
    /// the hand has paused typing.
    public mutating func check(at now: Date) -> Cue? {
        guard let due = dueAt(), elapsed(at: now) > 0,
              now.timeIntervalSince(due) >= settings.fallback,
              let last = lastInput, now.timeIntervalSince(last) >= settings.pause else { return nil }
        return give(via: .pause, at: now)
    }

    private mutating func give(via kind: Boundary, at now: Date) -> Cue {
        given += 1
        lastCueAt = now
        let minutes = Int((settings.after * Double(given) / 60).rounded())
        return Cue(minutes: minutes, share: min(1, Double(given) / Double(settings.maximum)),
                   via: kind, index: given)
    }

    /// The words, in Lodestar's voice: the fact, then the instruction.
    public static func sentence(minutes: Int) -> String {
        "\(spelled(minutes).prefix(1).uppercased())\(spelled(minutes).dropFirst()) minutes without a break"
    }

    public static let instruction = "Walk for two minutes"

    static func spelled(_ minutes: Int) -> String {
        let names = [15: "fifteen", 20: "twenty", 25: "twenty five", 30: "thirty", 40: "forty", 45: "forty five",
                     50: "fifty", 60: "sixty", 80: "eighty", 90: "ninety", 100: "one hundred", 120: "one hundred twenty"]
        return names[minutes] ?? String(minutes)
    }
}
