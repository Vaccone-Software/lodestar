import CoreGraphics
import Foundation

/// The scripts behind every press Lodestar makes with the pointer: the
/// verified copy's drag, the click door's fallback click, its right-click.
/// Pure — a list of steps the shell posts in order — so the one rule they
/// share is testable: **the pointer walks before it presses.** Some apps
/// take a press without a position; Ghostty's is whatever the last move
/// or drag left it, so a bare press landed wherever the pointer had last
/// rested and the drag selected from there. A move first tells every app
/// where the press is about to be, and apps that read the position off
/// the press itself see one extra move and nothing else.
public enum SyntheticPointer {
    public struct Step: Equatable {
        public let type: CGEventType
        public let point: CGPoint

        public init(_ type: CGEventType, _ point: CGPoint) {
            self.type = type
            self.point = point
        }
    }

    /// A click at a point: walked to, pressed, released.
    public static func click(at point: CGPoint, right: Bool = false) -> [Step] {
        [Step(.mouseMoved, point),
         Step(right ? .rightMouseDown : .leftMouseDown, point),
         Step(right ? .rightMouseUp : .leftMouseUp, point)]
    }

    /// A drag from inside the first glyph to inside the last: walked to
    /// the start, pressed there, dragged through the middle to the end,
    /// released. The walk home afterward is the caller's, a beat later.
    public static func drag(from start: CGPoint, to end: CGPoint) -> [Step] {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        return [Step(.mouseMoved, start),
                Step(.leftMouseDown, start),
                Step(.leftMouseDragged, mid),
                Step(.leftMouseDragged, end),
                Step(.leftMouseUp, end)]
    }

    /// The pointer returned to where the hand left it — a move, not a
    /// warp, so the app under it hears the same thing the press told it.
    public static func home(_ origin: CGPoint) -> [Step] {
        [Step(.mouseMoved, origin)]
    }
}
