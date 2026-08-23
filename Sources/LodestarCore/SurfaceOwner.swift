import Foundation

/// Who the shared glass panel currently belongs to.
///
/// One panel serves three different kinds of thing: the chain guide (the
/// pending state a hand is waiting on), a flash (a receipt for something
/// that just happened), and the coach's chip (an offer). They share a
/// window because they occupy the same place on the screen and only one
/// of them can be there — not because they are the same kind of thing.
///
/// The sharing is fine. What was missing was the *record* of it: a writer
/// could take the panel without the previous occupant ever learning, so
/// the coach went on believing a chip stood when it had been ordered off
/// the glass a third of a second after it was drawn — and billed the
/// suggestion for a showing nobody could have read. This type exists so
/// that handing the panel over is a transition that cannot happen
/// silently.
public enum SurfaceOwner: Equatable, Sendable {
    case none
    case guide
    case flash
    case coach
}

/// The handover rule, pure so the one thing that must never be forgotten
/// is the one thing that is tested.
public enum Surface {
    /// Does moving the panel from `previous` to `next` displace the coach?
    ///
    /// Only the coach is notified, because it is the only occupant that
    /// outlives the gesture that drew it. A guide replaced by a guide, or
    /// a flash by a flash, is the same hand still working.
    public static func displacesCoach(from previous: SurfaceOwner,
                                      to next: SurfaceOwner) -> Bool {
        previous == .coach && next != .coach
    }
}
