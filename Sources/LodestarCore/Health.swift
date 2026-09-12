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
///
/// Three things ride beside the counts, and all three are *shape*, which
/// is what the line above permits and the moments could not give:
///
/// - **Hold time**, press to release. How long a press lasted is not
///   which key it was, and it is the one keyboard measurement with a
///   clinical literature behind it.
/// - **The whole rhythm**, as a histogram. The moments keep the motor
///   band under `interKeyCeiling` and mean what they always did; the
///   histogram keeps every gap the bout contains, and the pauses past
///   the ceiling are kept censored (`ikTailN`, `ikTailSum`) instead of
///   dropped. A rhythm's lapses are a measurement, not noise.
/// - **Bouts.** A bout is continuous work; it ends when the hands stop
///   for longer than `boutGap`, and that break closes the window so no
///   pulse ever straddles one. Each pulse carries its position in its
///   bout, which is the only fact a decrement needs and is stored as a
///   position rather than a verdict — the fitting happens at read time,
///   like everything else.
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
    /// Hands quiet for longer than this ended a bout of work. Ten
    /// minutes: short enough that a coffee break separates two bouts,
    /// long enough that reading a page does not.
    public static let boutGap: TimeInterval = 600
    /// A press longer than this was a key being held, not a keystroke.
    /// Autorepeat is already excluded upstream; this catches the held
    /// key that never repeated.
    public static let holdCeiling: TimeInterval = 1.0

    var windowStart: Date?
    var keys = 0
    var backspaces = 0
    var clicks = 0
    var scrolls = 0
    var scrollSeconds = 0.0
    var minutes: Set<Int> = []
    var ikN = 0
    var ikSum = 0.0
    var ikSumSq = 0.0
    /// Gaps past the motor ceiling and inside the bout, censored rather
    /// than discarded.
    var ikTailN = 0
    var ikTailSum = 0.0
    /// Every gap the bout contained, by shape.
    var ikHist = Histogram()
    /// Press durations: moments and shape.
    var holdN = 0
    var holdSum = 0.0
    var holdSumSq = 0.0
    var holdHist = Histogram()
    var lastKeyAt: Date?
    var lastScrollAt: Date?
    /// Any input at all, for the bout boundary — a bout is the hands
    /// being present, not the keyboard specifically.
    var lastInputAt: Date?
    /// The bout in flight: when it began, and how many windows of it
    /// have already closed.
    var boutStart: Date?
    var boutIndex = 0
    /// The backspace run in flight, and the closed runs by length —
    /// single, two to four, five and more — as run counts and as the
    /// backspaces inside them. A run is a revision of thought; a single
    /// is a typo; the two are different budgets and only the second is
    /// anyone's business to shrink.
    var runLength = 0
    var runCounts = [0, 0, 0]
    var runKeys = [0, 0, 0]

    public init() {}

    /// A keystroke landed. Returns the previous window's pulse when this
    /// key is the first input of a new one.
    ///
    /// An `autorepeat` keydown is the OS repeating a held key at its
    /// repeat rate, not a keystroke the hand made: it marks the minute
    /// active but is counted nowhere else, so a key held down reads as
    /// presence, never as typing at 30ms a key. The gap across a repeat
    /// storm is dropped too — `lastKeyAt` does not advance — and the
    /// next real key would show a gap the ceiling discards.
    public mutating func key(at now: Date, backspace: Bool,
                             autorepeat: Bool = false) -> ObservationEvent? {
        let flushed = rollIfDue(now: now)
        guard !autorepeat else {
            touch(now)
            return flushed
        }
        keys += 1
        if backspace {
            backspaces += 1
            runLength += 1
        } else {
            closeRun()
        }
        if let last = lastKeyAt {
            let gap = now.timeIntervalSince(last)
            // A gap at or past the bout gap cannot reach this line — a
            // break clears `lastKeyAt` on its way through `rollIfDue`.
            // One can still arrive when the hands stayed busy on the
            // mouse for longer than the gap, and that is not a typing
            // pause: it belongs to neither the tail nor the shape.
            if gap > 0, gap < Self.boutGap {
                if gap <= Self.interKeyCeiling {
                    ikN += 1
                    ikSum += gap
                    ikSumSq += gap * gap
                } else {
                    // Past the motor band: a pause, and the thing the
                    // moments were built to exclude. Kept censored — a
                    // count and a sum — rather than dropped, because a
                    // rhythm's lapses are a measurement.
                    ikTailN += 1
                    ikTailSum += gap
                }
                ikHist.add(gap)
            }
        }
        lastKeyAt = now
        touch(now)
        return flushed
    }

    /// A press ended, `seconds` after it began.
    ///
    /// Hold time is the one keyboard measurement with a clinical
    /// literature behind it, and it asks nothing the line forbids: how
    /// long a press lasted is not which key it was. Presses the OS
    /// repeated are excluded upstream — a held key releases whole
    /// seconds after it goes down and would read as one impossibly slow
    /// keystroke — and `holdCeiling` catches the held key that never
    /// repeated. The release still marks the hand present either way.
    public mutating func hold(_ seconds: Double, at now: Date) -> ObservationEvent? {
        let flushed = rollIfDue(now: now)
        if seconds > 0, seconds <= Self.holdCeiling {
            holdN += 1
            holdSum += seconds
            holdSumSq += seconds * seconds
            holdHist.add(seconds)
        }
        touch(now)
        return flushed
    }

    public mutating func click(at now: Date) -> ObservationEvent? {
        let flushed = rollIfDue(now: now)
        clicks += 1
        closeRun()
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
        closeRun()
        touch(now)
        return flushed
    }

    /// A whole burst, already coalesced at the tap: one reach for the
    /// wheel, and how long it ran.
    public mutating func scroll(from start: Date, to end: Date) -> ObservationEvent? {
        let flushed = rollIfDue(now: start)
        scrolls += 1
        scrollSeconds += max(0, end.timeIntervalSince(start))
        lastScrollAt = end
        closeRun()
        touch(start)
        touch(end)
        return flushed
    }

    /// Close the open window unconditionally — shutdown's path, and the
    /// switch being turned off. Either way the bout is over: whatever
    /// comes back later starts a new one.
    public mutating func flush(now: Date = Date()) -> ObservationEvent? {
        let pulse = closedWindow()
        reset(windowStart: nil)
        endBout()
        return pulse
    }

    // MARK: - Internals

    private mutating func touch(_ now: Date) {
        if windowStart == nil { windowStart = now }
        if boutStart == nil { boutStart = now }
        lastInputAt = now
        minutes.insert(Int(now.timeIntervalSince1970 / 60))
    }

    /// The bout in flight is over. The rhythm clock goes with it: two
    /// keystrokes ten minutes apart are not one gap of typing.
    private mutating func endBout() {
        boutStart = nil
        boutIndex = 0
        lastInputAt = nil
        lastKeyAt = nil
        lastScrollAt = nil
    }

    /// The open window as an event, or nothing when nothing happened in
    /// it — a window opened by a bare release, say, with no keystroke
    /// behind it yet.
    private mutating func closedWindow() -> ObservationEvent? {
        guard windowStart != nil, keys + clicks + scrolls > 0 else { return nil }
        closeRun()
        return build()
    }

    /// The run in flight ends: any input that is not a backspace, a
    /// window rolling, or the flush. Bucketed by length on the way out.
    private mutating func closeRun() {
        guard runLength > 0 else { return }
        let bucket = runLength == 1 ? 0 : (runLength <= 4 ? 1 : 2)
        runCounts[bucket] += 1
        runKeys[bucket] += runLength
        runLength = 0
    }

    private mutating func rollIfDue(now: Date) -> ObservationEvent? {
        // The hands stopped for longer than a bout survives. The break
        // closes the window wherever it fell — a pulse that straddled a
        // break would carry two bouts' worth of position and describe
        // neither — and the next input opens a new bout at index zero.
        if let last = lastInputAt, now.timeIntervalSince(last) >= Self.boutGap {
            let pulse = closedWindow()
            reset(windowStart: nil)
            endBout()
            return pulse
        }
        guard let start = windowStart,
              now.timeIntervalSince(start) >= Self.windowSeconds else { return nil }
        let pulse = closedWindow()
        reset(windowStart: now)
        boutIndex += 1
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
        if scrollSeconds > 0 { event.scrollSeconds = scrollSeconds }
        event.activeMinutes = minutes.count
        event.ikN = ikN
        event.ikSum = ikSum
        event.ikSumSq = ikSumSq
        event.bsRuns = runCounts
        event.bsRunKeys = runKeys
        if ikTailN > 0 {
            event.ikTailN = ikTailN
            event.ikTailSum = ikTailSum
        }
        if !ikHist.isEmpty { event.ikHist = ikHist }
        if holdN > 0 {
            event.holdN = holdN
            event.holdSum = holdSum
            event.holdSumSq = holdSumSq
            event.holdHist = holdHist
        }
        // Where the window sat in its bout. Position, not a verdict:
        // whether the hands slowed across a bout is a question for read
        // time, fitted from these, never frozen in here.
        event.boutIndex = boutIndex
        if let start = windowStart, let bout = boutStart {
            event.boutSeconds = max(0, start.timeIntervalSince(bout))
        }
        return event
    }

    private mutating func reset(windowStart start: Date?) {
        windowStart = start
        keys = 0
        backspaces = 0
        clicks = 0
        scrolls = 0
        scrollSeconds = 0.0
        minutes = []
        ikN = 0
        ikSum = 0.0
        ikSumSq = 0.0
        ikTailN = 0
        ikTailSum = 0.0
        ikHist = Histogram()
        holdN = 0
        holdSum = 0.0
        holdSumSq = 0.0
        holdHist = Histogram()
        runLength = 0
        runCounts = [0, 0, 0]
        runKeys = [0, 0, 0]
        // The inter-key clock survives the roll: two keystrokes that
        // straddle a window boundary are still one gap of typing. The
        // bout survives it too — a window closing is a bookkeeping
        // boundary, not the hands stopping — and only `endBout` clears
        // either.
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
        /// Seconds the wheel bursts ran, where the pulse timed them.
        public var scrollSeconds = 0.0
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
        /// Backspace runs by length — single, two to four, five and more —
        /// as run counts and as the backspaces inside them.
        public var backspaceRuns = [0, 0, 0]
        public var backspaceRunKeys = [0, 0, 0]
        /// Press durations: how long keys were held down.
        public var holdN = 0
        public var holdSum = 0.0
        public var holdSumSq = 0.0
        public var holdHistogram = Histogram()
        /// The rhythm's whole shape, tail included, where the moments
        /// carry only the band under the ceiling.
        public var interKeyHistogram = Histogram()
        /// Gaps past the motor ceiling and inside a bout: the pauses.
        public var pauseN = 0
        public var pauseSum = 0.0

        public var correctionRate: Double? {
            keys > 0 ? Double(backspaces) / Double(keys) : nil
        }

        /// Mean hold time in seconds — press to release.
        public var holdMean: Double? { holdN > 0 ? holdSum / Double(holdN) : nil }

        public var holdSD: Double? {
            guard holdN > 1, let mean = holdMean else { return nil }
            let variance = max(0, (holdSumSq - Double(holdN) * mean * mean) / Double(holdN - 1))
            return variance.squareRoot()
        }

        /// Hold time's coefficient of variation. The scale-free form is
        /// the one worth comparing across weeks: a hand that got faster
        /// and a hand that got less even are different events, and the
        /// raw SD confounds them.
        public var holdCV: Double? {
            guard let mean = holdMean, mean > 0, let sd = holdSD else { return nil }
            return sd / mean
        }

        /// The share of measured gaps that were pauses rather than
        /// rhythm — the tail the moments exclude by construction, and
        /// the reason it is now kept.
        public var pauseShare: Double? {
            let total = interKeyGaps + pauseN
            return total > 0 ? Double(pauseN) / Double(total) : nil
        }

        /// Mean length of those pauses, seconds.
        public var pauseMean: Double? { pauseN > 0 ? pauseSum / Double(pauseN) : nil }

        /// Gaps inside the motor band, from the moments.
        public var interKeyGaps = 0

        /// The share of backspaces that were single corrections — the
        /// typo budget, which no product should try to train away.
        public var typoShare: Double? {
            backspaces > 0 ? Double(backspaceRunKeys[0]) / Double(backspaces) : nil
        }

        /// The share of backspaces spent in runs of five or more — the
        /// revision-of-thought budget, the one dictation can claim.
        public var revisionShare: Double? {
            backspaces > 0 ? Double(backspaceRunKeys[2]) / Double(backspaces) : nil
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
            out.scrollSeconds += pulse.scrollSeconds ?? 0
            let active = pulse.activeMinutes ?? 0
            out.activeMinutes += active
            ikN += pulse.ikN ?? 0
            ikSum += pulse.ikSum ?? 0
            ikSumSq += pulse.ikSumSq ?? 0
            if let runs = pulse.bsRuns, runs.count == 3 {
                for i in 0..<3 { out.backspaceRuns[i] += runs[i] }
            }
            if let runKeys = pulse.bsRunKeys, runKeys.count == 3 {
                for i in 0..<3 { out.backspaceRunKeys[i] += runKeys[i] }
            }
            out.holdN += pulse.holdN ?? 0
            out.holdSum += pulse.holdSum ?? 0
            out.holdSumSq += pulse.holdSumSq ?? 0
            if let hist = pulse.holdHist { out.holdHistogram.merge(hist) }
            if let hist = pulse.ikHist { out.interKeyHistogram.merge(hist) }
            out.pauseN += pulse.ikTailN ?? 0
            out.pauseSum += pulse.ikTailSum ?? 0
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
        out.interKeyGaps = ikN
        if ikN > 1 {
            let mean = ikSum / Double(ikN)
            out.interKeyMean = mean
            let variance = max(0, (ikSumSq - Double(ikN) * mean * mean) / Double(ikN - 1))
            out.interKeySD = variance.squareRoot()
        }
        return out
    }
}
