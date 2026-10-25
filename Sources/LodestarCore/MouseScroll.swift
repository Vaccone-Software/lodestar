import CoreGraphics

/// Which way a mouse scrolls, apart from the trackpad (app.mouse-scrolling).
/// macOS keeps one direction for both, so a hand that wants the trackpad
/// natural and the wheel standard needs something in the event stream to
/// turn the wheel's events over. Lodestar already sits there.
///
/// The setting names the result, not a reversal: Natural and Standard mean
/// the same whichever way the system's own setting points, and System
/// leaves every event alone (and no tap runs at all).
public enum MouseScroll {
    public enum Direction: String, CaseIterable, Sendable {
        case system
        case natural
        case standard
    }

    /// Whether this scroll is the mouse's, from what an event says in public
    /// fields. A touch surface gives its scrolls phases and a wheel never
    /// does (measured on the maker's Mac, 2026-09-28: the trackpad's 823
    /// phased scrolls against the ProtoArc's 177 unphased, both continuous,
    /// so continuity names no device). A scroll another app posted is the
    /// mouse too: a mouse utility such as Logi Options+ swallows the wheel
    /// and posts its own smooth scrolls in its place. Lodestar's own, from
    /// scroll mode, are never touched: their direction is already the one
    /// the key names. A Magic Mouse scrolls with phases and reads as a
    /// trackpad, which this cannot tell apart without a private API.
    public static func isMouse(scrollPhase: Int64, momentumPhase: Int64,
                               postingPID: Int64, ownPID: Int64) -> Bool {
        if postingPID == ownPID { return false }
        if postingPID != 0 { return true }
        return scrollPhase == 0 && momentumPhase == 0
    }

    /// Whether the mouse's events must be turned over to arrive the way the
    /// setting names. The system's direction is applied to a device's
    /// events before any tap sees them, and a mouse utility posts in it too.
    public static func reverses(_ want: Direction, systemNatural: Bool) -> Bool {
        switch want {
        case .system: return false
        case .natural: return !systemNatural
        case .standard: return systemNatural
        }
    }

    /// One event's decision, from its own fields.
    public static func reverses(_ event: CGEvent, want: Direction, systemNatural: Bool, ownPID: Int64) -> Bool {
        guard reverses(want, systemNatural: systemNatural) else { return false }
        return isMouse(scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                       momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                       postingPID: event.getIntegerValueField(.eventSourceUnixProcessID),
                       ownPID: ownPID)
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
