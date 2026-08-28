import Foundation

/// The hands' pulse: counts and moments over all input, folded into one
/// event per quarter hour. Pure and value-typed so the whole accumulation
/// is testable without a tap.
///
/// What it keeps is bounded by one line that must never move: **never key
/// identities on general typing.** Per-key or per-digraph timing on
/// arbitrary text statistically reconstructs what was typed, so this
/// records global counts, global inter-key moments, and exactly one named
/// key — backspace, the correction key, whose rate is the classic early
/// strain signal. Which keys, which apps, which words: never.
///
/// Scrolls are counted as *bursts*, not wheel events — a trackpad emits
/// hundreds of events per flick, and "reached for the scroll" is the fact
/// the pointer-vs-keyboard ratio wants.
public struct HealthPulse: Equatable {
    /// One pulse per quarter hour of activity. Windows are event-driven —
    /// they open at the first input after a flush — so an idle machine
    /// emits nothing at all.
    public static let windowSeconds: TimeInterval = 900
    /// Gaps longer than this are pauses, not typing rhythm; they would put
    /// thinking time into a motor statistic.
    public static let interKeyCeiling: TimeInterval = 2.0
    /// Wheel events closer together than this are one reach for the wheel.
    public static let scrollBurstGap: TimeInterval = 1.0

    var windowStart: Date?
    var keys = 0
    var backspaces = 0
    var clicks = 0
    var scrolls = 0
    var minutes: Set<Int> = []
    var ikN = 0
    var ikSum = 0.0
    var ikSumSq = 0.0
    var lastKeyAt: Date?
    var lastScrollAt: Date?

    public init() {}

    /// A keystroke landed. Returns the previous window's pulse when this
    /// key is the first input of a new one.
    public mutating func key(at now: Date, backspace: Bool) -> ObservationEvent? {
        let flushed = rollIfDue(now: now)
        keys += 1
        if backspace { backspaces += 1 }
        if let last = lastKeyAt {
            let gap = now.timeIntervalSince(last)
            if gap > 0, gap <= Self.interKeyCeiling {
                ikN += 1
                ikSum += gap
                ikSumSq += gap * gap
            }
        }
        lastKeyAt = now
        touch(now)
        return flushed
    }

    public mutating func click(at now: Date) -> ObservationEvent? {
        let flushed = rollIfDue(now: now)
        clicks += 1
        touch(now)
        return flushed
    }

    /// A wheel event. Coalesced into bursts by `scrollBurstGap`.
    public mutating func scroll(at now: Date) -> ObservationEvent? {
        let flushed = rollIfDue(now: now)
        if lastScrollAt.map({ now.timeIntervalSince($0) > Self.scrollBurstGap }) ?? true {
            scrolls += 1
        }
        lastScrollAt = now
        touch(now)
        return flushed
    }

    /// Close the open window unconditionally — shutdown's path.
    public mutating func flush(now: Date = Date()) -> ObservationEvent? {
        guard windowStart != nil, keys + clicks + scrolls > 0 else {
            reset(windowStart: nil)
            return nil
        }
        let pulse = build()
        reset(windowStart: nil)
        return pulse
    }

    // MARK: - Internals

    private mutating func touch(_ now: Date) {
        if windowStart == nil { windowStart = now }
        minutes.insert(Int(now.timeIntervalSince1970 / 60))
    }

    private mutating func rollIfDue(now: Date) -> ObservationEvent? {
        guard let start = windowStart,
              now.timeIntervalSince(start) >= Self.windowSeconds else { return nil }
        let pulse = build()
        reset(windowStart: now)
        return pulse
    }

    /// Stamped at the window's start, so a pulse lands in the hour and the
    /// month it describes.
    private func build() -> ObservationEvent {
        var event = ObservationEvent(t: windowStart ?? Date(), kind: .pulse)
        event.keys = keys
        event.backspaces = backspaces
        event.clicks = clicks
        event.scrolls = scrolls
        event.activeMinutes = minutes.count
        event.ikN = ikN
        event.ikSum = ikSum
        event.ikSumSq = ikSumSq
        return event
    }

    private mutating func reset(windowStart start: Date?) {
        windowStart = start
        keys = 0
        backspaces = 0
        clicks = 0
        scrolls = 0
        minutes = []
        ikN = 0
        ikSum = 0.0
        ikSumSq = 0.0
        // The inter-key clock survives the roll: two keystrokes that
        // straddle a window boundary are still one gap of typing.
    }
}

/// Read-time views over the pulses — the printout's health section and,
/// later, the retrospective's. Aggregation lives here, at read time, per
/// the observation layer's one architectural law.
public enum Health {
    public struct Summary: Equatable {
        public var days = 0
        public var keys = 0
        public var backspaces = 0
        public var clicks = 0
        public var scrolls = 0
        public var activeMinutes = 0
        /// Mean inter-key gap in seconds, when enough rhythm was seen.
        public var interKeyMean: Double?
        public var interKeySD: Double?
        /// Active minutes by local hour of day, 24 buckets.
        public var hourMinutes = [Int](repeating: 0, count: 24)
        /// Active minutes by weekday (1 = Sunday, per Calendar), 7 buckets.
        public var weekdayMinutes = [Int](repeating: 0, count: 7)
        /// Longest continuous active stretch, minutes.
        public var longestStretchMinutes = 0

        public var correctionRate: Double? {
            keys > 0 ? Double(backspaces) / Double(keys) : nil
        }

        /// Clicks and scroll-bursts against keystrokes: the share of input
        /// acts that reached for the pointer.
        public var pointerShare: Double? {
            let total = keys + clicks + scrolls
            guard total > 0 else { return nil }
            return Double(clicks + scrolls) / Double(total)
        }
    }

    /// A gap between active pulses longer than this ends a stretch.
    public static let stretchGap: TimeInterval = 20 * 60

    public static func summary(events: [ObservationEvent], days: Int,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> Summary? {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let pulses = events.filter { $0.kind == .pulse && $0.t >= cutoff }
        guard !pulses.isEmpty else { return nil }
        var out = Summary()
        var dayOrdinals: Set<Int> = []
        var ikN = 0
        var ikSum = 0.0
        var ikSumSq = 0.0
        var stretchEnd: Date?
        var stretchMinutes = 0
        for pulse in pulses.sorted(by: { $0.t < $1.t }) {
            out.keys += pulse.keys ?? 0
            out.backspaces += pulse.backspaces ?? 0
            out.clicks += pulse.clicks ?? 0
            out.scrolls += pulse.scrolls ?? 0
            let active = pulse.activeMinutes ?? 0
            out.activeMinutes += active
            ikN += pulse.ikN ?? 0
            ikSum += pulse.ikSum ?? 0
            ikSumSq += pulse.ikSumSq ?? 0
            dayOrdinals.insert(Int(pulse.t.timeIntervalSince1970 / 86_400))
            let hour = calendar.component(.hour, from: pulse.t)
            out.hourMinutes[min(23, max(0, hour))] += active
            let weekday = calendar.component(.weekday, from: pulse.t) - 1
            out.weekdayMinutes[min(6, max(0, weekday))] += active
            // Stretches: consecutive pulses within the gap extend a run.
            if let end = stretchEnd, pulse.t.timeIntervalSince(end) <= stretchGap {
                stretchMinutes += active
            } else {
                out.longestStretchMinutes = max(out.longestStretchMinutes, stretchMinutes)
                stretchMinutes = active
            }
            stretchEnd = pulse.t.addingTimeInterval(HealthPulse.windowSeconds)
        }
        out.longestStretchMinutes = max(out.longestStretchMinutes, stretchMinutes)
        out.days = dayOrdinals.count
        if ikN > 1 {
            let mean = ikSum / Double(ikN)
            out.interKeyMean = mean
            let variance = max(0, (ikSumSq - Double(ikN) * mean * mean) / Double(ikN - 1))
            out.interKeySD = variance.squareRoot()
        }
        return out
    }
}
