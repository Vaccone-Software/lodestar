import CoreGraphics

/// Which scrolls turn the other way (`mice.reversed-wheels`). macOS keeps
/// one natural-scrolling setting for the trackpad and the mouse, so a hand
/// that wants the trackpad natural and a wheel the other way needs something
/// in the event stream to turn that wheel's scrolls over. Lodestar sits
/// there already.
///
/// **Nothing is guessed.** A scroll is turned only when something vouches
/// for who made it, and the person has ticked that source on the Reversed
/// wheels page. A source is either a mouse, vouched for by the HID report
/// its wheel sent (a mouse's wheel is Generic Desktop usage 0x38, and the
/// report carries the same timestamp as the scroll it became, measured
/// 159 of 159 on the maker's Mac: the scroll's stamp minus the report's was
/// +0.4 ms at the median, -0.7 ms at the least and +10.4 ms at the most),
/// or an app that posts scrolls in the mouse's place, which a mouse utility
/// such as Logi Options+ does after swallowing the wheel, vouched for by
/// the pid it posts from, which cannot be forged. A trackpad phases its
/// scrolls and a wheel never does, so a phased scroll is never a mouse's.
///
/// This is a reversal and not a direction: whichever way the Mac is set, the
/// wheel's scrolls arrive the other way round, so the Mac's own setting is
/// never read.
public enum MouseScroll {
    /// How long before a scroll its wheel report may have been stamped.
    public static let reportReach: UInt64 = 50_000_000
    /// How long after it: the report is delivered to a different thread
    /// than the scroll, and the two stamps are made by different parts of
    /// the system.
    public static let reportLead: UInt64 = 5_000_000

    /// Whether a HID value is a wheel turning up or down. A sideways pan
    /// (Consumer AC Pan, 0x0C 0x238) is not: only the vertical axis is ever
    /// turned, so a pan's report vouches for nothing.
    public static func isVerticalWheel(page: UInt32, usage: UInt32) -> Bool {
        page == 0x01 && usage == 0x38
    }

    /// The wheel reports heard lately, newest overwriting oldest in place:
    /// the tap's callback reads this under a lock and must never wait on an
    /// allocation, so it is a fixed ring.
    public struct Reports {
        public static let capacity = 64
        private var stamps = [UInt64](repeating: 0, count: capacity)
        private var devices = [String](repeating: "", count: capacity)
        private var next = 0

        public init() {}

        /// A wheel of `device` (its roster id) turned at `stamp`, in
        /// nanoseconds of uptime.
        public mutating func add(device: String, stamp: UInt64) {
            stamps[next] = stamp
            devices[next] = device
            next = (next + 1) % Self.capacity
        }

        /// The device whose report falls in the window around a scroll's
        /// stamp, `reportReach` before it to `reportLead` after, and whether
        /// a second device's does too. Two values and no collection, since
        /// this runs for every scroll on the Mac.
        func heard(near stamp: UInt64) -> (device: String?, several: Bool) {
            var first: String?
            for index in 0..<Self.capacity where !devices[index].isEmpty {
                let at = stamps[index]
                guard at + MouseScroll.reportReach >= stamp, at <= stamp + MouseScroll.reportLead else { continue }
                if let first, first != devices[index] { return (first, true) }
                first = devices[index]
            }
            return (first, false)
        }
    }

    /// Whose a scroll is, as far as anything vouches for it.
    public enum Attribution: Equatable {
        /// A touch surface's: it carries a scroll or momentum phase.
        case touch
        /// Lodestar's own, from scroll mode: already the direction its key
        /// names, and never touched.
        case own
        /// The one device whose wheel reported in the window.
        case device(String)
        /// Wheels of two devices reported in the window, so neither can be
        /// told from the other.
        case ambiguous
        /// Posted by another process, which is the source.
        case posted(pid: Int64)
        /// Nothing vouches for it.
        case unknown
    }

    /// The scroll's source, in order: a touch surface's phases and
    /// Lodestar's own pid rule it out; a scroll another process posted is
    /// that process's; only a scroll no one posted (a device's own, whose
    /// posting pid is zero) is looked up among the wheel reports, and the
    /// one device whose wheel reported in the window is its source. The
    /// poster comes first because its pid cannot be forged and covers every
    /// scroll a mouse utility makes after swallowing the wheel, smooth
    /// continuation included, while a report only sits near some of them:
    /// asked the other way round, one mouse's scrolls would split between
    /// the mouse's switch and the utility's.
    public static func attribution(scrollPhase: Int64, momentumPhase: Int64, postingPID: Int64,
                                   ownPID: Int64, stamp: UInt64, reports: Reports) -> Attribution {
        if scrollPhase != 0 || momentumPhase != 0 { return .touch }
        if postingPID == ownPID { return .own }
        if postingPID != 0 { return .posted(pid: postingPID) }
        let heard = reports.heard(near: stamp)
        if heard.several { return .ambiguous }
        if let device = heard.device { return .device(device) }
        return .unknown
    }

    /// Whether the person ticked the source: the devices by roster id, the
    /// apps by the pids they are running as now.
    public static func turns(_ attribution: Attribution, devices: Set<String>, pids: Set<Int64>) -> Bool {
        switch attribution {
        case .device(let id): return devices.contains(id)
        case .posted(let pid): return pids.contains(pid)
        case .touch, .own, .ambiguous, .unknown: return false
        }
    }

    /// Turns the vertical scroll over, in every field an app might read.
    /// The line delta goes first: setting it makes the system recompute the
    /// point and fixed-point deltas from it, which would lose a smooth
    /// scroll's fractions, so those are set after, from what they were
    /// (Scroll Reverser found the order the hard way). The horizontal axis
    /// is left as it is, as Scroll Reverser leaves it: a mouse's sideways
    /// scroll is a tilt or a thumb wheel, and nobody asked for it turned.
    public static func reverseVertical(_ event: CGEvent) {
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point)
    }
}

/// The ids a ticked source goes by in the config: a mouse by the roster's
/// `vendor:product:hash`, an app that posts a mouse's scrolls by
/// `app:<bundle id>`.
public enum WheelSource {
    private static let appPrefix = "app:"

    public static func app(bundleID: String) -> String { appPrefix + bundleID }

    /// The bundle id an app source names; nil for a mouse's.
    public static func bundleID(of id: String) -> String? {
        id.hasPrefix(appPrefix) ? String(id.dropFirst(appPrefix.count)) : nil
    }

    /// Whether the id is one of the two shapes: an app's with a bundle id
    /// after the prefix, or a roster id (two numbers and an eight-digit
    /// hash).
    public static func isValid(_ id: String) -> Bool {
        if let bundle = bundleID(of: id) { return !bundle.isEmpty }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].count == 8 else { return false }
        return parts[0...1].allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
            && parts[2].allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

/// What the wheel machinery runs, from what is asked and what is allowed.
/// The listener and the tap are separate because the page that finds the
/// mice needs the one and the tap that turns them needs both.
public struct WheelPlan: Equatable {
    public enum Tap: Equatable {
        case off
        /// Listen only: hears which apps post scrolls, turns nothing.
        case listen
        /// The active tap: turns the scrolls of the sources ticked.
        case turn
    }

    /// The HID manager that hears wheel reports is open.
    public let listens: Bool
    public let tap: Tap

    public init(listens: Bool, tap: Tap) {
        self.listens = listens
        self.tap = tap
    }

    /// Off is off: with nothing ticked and no page to find mice for, nothing
    /// runs, and the active tap runs only for a ticked source. Input
    /// Monitoring gates all of it, since neither the reports nor the scrolls
    /// are heard without it, and the active tap needs Accessibility too.
    public init(ticked: Bool, discovering: Bool, inputMonitoring: Bool, accessibility: Bool) {
        guard inputMonitoring, ticked || discovering else {
            listens = false
            tap = .off
            return
        }
        listens = true
        tap = ticked && accessibility ? .turn : (discovering ? .listen : .off)
    }
}
