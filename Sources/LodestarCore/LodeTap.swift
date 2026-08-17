import Foundation

/// Double-tap of the lode chord itself: assent addressed to the
/// instrument, not typed into whatever window has focus.
///
/// This is the coach's accept gesture, and it was chosen for what it
/// cannot collide with. A bare modifier never reaches an app as text, so
/// tapping lode twice costs nothing wherever the cursor is; the gesture
/// has no prior meaning (peek needs the hold, chains need a letter), so no
/// existing grammar changes underneath anyone; and when no offer is
/// standing it is simply a no-op, which is the difference between a fixed
/// gesture and a mode.
///
/// Fed the *classified* lode state per flagsChanged, so the hyper shim's
/// chord form is absorbed upstream; repeated same-state calls are ignored,
/// so flag bounce cannot fabricate taps. A tap is a press shorter than
/// `maxHold` with no keystroke inside it — a hold is the peek, a keystroke
/// makes it a chain, and either poisons the gesture.
public struct LodeTapDetector: Equatable {
    /// Longer than this is the peek, not a tap.
    public static let maxHold: TimeInterval = 0.35
    /// Two taps land inside this window or they are two separate thoughts.
    public static let window: TimeInterval = 0.5

    private var downAt: TimeInterval?
    private var poisoned = false
    private var lastTapAt: TimeInterval?

    public init() {}

    /// Any real keypress voids whatever was in flight.
    public mutating func keyDown() {
        poisoned = true
        lastTapAt = nil
    }

    /// Feed the classified lode state on every flagsChanged. Returns true
    /// exactly when the second tap completes.
    public mutating func lodeChanged(held: Bool, at now: TimeInterval) -> Bool {
        if held {
            if downAt == nil {
                downAt = now
                poisoned = false
            }
            return false
        }
        guard let pressed = downAt else { return false }
        downAt = nil
        guard !poisoned, now - pressed < Self.maxHold else {
            lastTapAt = nil
            return false
        }
        if let last = lastTapAt, now - last < Self.window {
            lastTapAt = nil
            return true
        }
        lastTapAt = now
        return false
    }
}
