import CoreGraphics

/// The pointer comes along when Lodestar takes the hand to another display.
/// "Here" is the display under the pointer, so a visit or a throw that left
/// the pointer behind left "here" behind too: the next summon, the launcher
/// and Keep all opened on the screen the hand had just left. Within one
/// display the pointer is the hand's own and never moves.
public enum PointerFollow {
    /// Where the pointer should go, or nil to leave it: the middle of the
    /// part of the window on its display, when that display is not the one
    /// under the pointer. A window on no display (parked, or not placed
    /// yet) is not followed.
    public static func destination(pointer: CGPoint, window: CGRect, displays: [CGRect]) -> CGPoint? {
        var home: (bounds: CGRect, overlap: CGRect)?
        var largest: CGFloat = 0
        for bounds in displays {
            let overlap = bounds.intersection(window)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > largest { (home, largest) = ((bounds, overlap), area) }
        }
        guard let home, !home.bounds.contains(pointer) else { return nil }
        return CGPoint(x: home.overlap.midX, y: home.overlap.midY)
    }
}
