import CoreGraphics

/// The summon's finishing move: a plain summon means "this, maximized,
/// alone", and the sweep makes *alone* true of the screen, not just the
/// layout. Every window Lodestar has placed this session that is still
/// standing visible on the active display parks behind the summon.
///
/// The scope is the whole design. Only session-claimed windows — ones the
/// user summoned, adopted with `lode 0`, or restored through a breath —
/// are ever swept, so the old promise holds untouched: a window Lodestar
/// did not summon is left exactly where its app put it, dialogs and
/// palettes can never be slivered (nothing ever summons a dialog), and
/// every swept window returns by a road the hand already owns. The
/// earlier, retired sweep (a `lode 0` verb that parked *every* non-member)
/// failed exactly where this one cannot: it had to guess what was safe to
/// move. This one only moves what it was once asked to move.
public enum Sweep {
    /// The world as the decision needs it — a lightweight view so the
    /// choice is testable without a window server.
    public struct Candidate: Equatable {
        public let id: CGWindowID
        public let frame: CGRect
        public let isAlive: Bool
        public let isMinimized: Bool

        public init(id: CGWindowID, frame: CGRect, isAlive: Bool, isMinimized: Bool) {
            self.id = id
            self.frame = frame
            self.isAlive = isAlive
            self.isMinimized = isMinimized
        }
    }

    /// Which windows a plain summon should take with it. Claimed by this
    /// session, standing on the active display, and not already spoken
    /// for: members of any display's layout are arrangements (the active
    /// display's own members are parked by the replace itself), parked
    /// windows are already away, minimized ones are already hidden.
    public static func windows(claimed: Set<CGWindowID>, summoned: CGWindowID,
                               members: Set<CGWindowID>, parked: Set<CGWindowID>,
                               display: CGRect,
                               among candidates: [Candidate]) -> [CGWindowID] {
        candidates.filter { window in
            window.id != summoned
                && claimed.contains(window.id)
                && !members.contains(window.id)
                && !parked.contains(window.id)
                && window.isAlive
                && !window.isMinimized
                && window.frame.intersects(display)
        }.map(\.id).sorted()
    }
}
