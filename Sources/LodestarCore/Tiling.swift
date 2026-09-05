import CoreGraphics

public enum Orientation: String, Codable, Sendable {
    case horizontal
    case vertical

    public var flipped: Orientation { self == .horizontal ? .vertical : .horizontal }
}

public enum Tiling {
    /// Equal-sized frames for `count` windows inside `bounds`, laid out along
    /// `orientation`. Pixel remainders go to the leading slices so the total
    /// exactly fills the axis.
    public static func frames(count: Int, in bounds: CGRect, orientation: Orientation, gap: CGFloat = 0) -> [CGRect] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [bounds] }
        let axis = orientation == .horizontal ? bounds.width : bounds.height
        let usable = axis - gap * CGFloat(count - 1)
        let base = (usable / CGFloat(count)).rounded(.down)
        var remainder = usable - base * CGFloat(count)
        var frames: [CGRect] = []
        var cursor = orientation == .horizontal ? bounds.minX : bounds.minY
        for _ in 0..<count {
            let extra: CGFloat = remainder >= 1 ? 1 : 0
            remainder -= extra
            let span = base + extra
            let frame = orientation == .horizontal
                ? CGRect(x: cursor, y: bounds.minY, width: span, height: bounds.height)
                : CGRect(x: bounds.minX, y: cursor, width: bounds.width, height: span)
            frames.append(frame)
            cursor += span + gap
        }
        return frames
    }

    /// Index order for `lode`+digit: left-to-right, then top-to-bottom.
    /// A window is placed by its center along the layout's axis, not its
    /// leading edge: a member that could not fill its slice stands
    /// centered in it (`settledOrigin`), and in a vertical stack a narrow
    /// window's left edge sits to the right of a wide one's, which put
    /// the top window second. Centers along the axis differ by a whole
    /// slice, so no fuzz is needed there; the cross axis breaks ties on
    /// whole points, since sub-point AX jitter must not reorder.
    public static func indexOrder(_ entries: [(id: CGWindowID, frame: CGRect)],
                                  orientation: Orientation) -> [CGWindowID] {
        func key(_ frame: CGRect) -> (CGFloat, CGFloat) {
            orientation == .horizontal
                ? (frame.midX.rounded(), frame.midY.rounded())
                : (frame.midY.rounded(), frame.midX.rounded())
        }
        return entries.sorted { key($0.frame) < key($1.frame) }.map(\.id)
    }

    /// Where a window that took less than its slice belongs: centered on
    /// each axis it fell short of, at the slice's edge on each axis it
    /// filled. System Settings has a fixed width and a palette its own
    /// size; asked for the whole display they take what they can, and
    /// the slice's origin pinned them to its top-left corner. An axis the
    /// window overflows is left where it is — centering an oversize
    /// window pushes part of it off screen, and the corrective pass owns
    /// that case along the layout's axis. nil when the window is already
    /// within a point of where it belongs, so a settle never writes for
    /// nothing.
    public static func settledOrigin(of achieved: CGRect, in slice: CGRect,
                                     tolerance: CGFloat = 6) -> CGPoint? {
        func coordinate(span: CGFloat, want: CGFloat, current: CGFloat,
                        edge: CGFloat, middle: CGFloat) -> CGFloat {
            if span < want - tolerance { return (middle - span / 2).rounded() }
            if span > want + tolerance { return current }
            return abs(current - edge) > tolerance ? edge : current
        }
        let x = coordinate(span: achieved.width, want: slice.width, current: achieved.minX,
                           edge: slice.minX, middle: slice.midX)
        let y = coordinate(span: achieved.height, want: slice.height, current: achieved.minY,
                           edge: slice.minY, middle: slice.midY)
        guard abs(x - achieved.minX) > 1 || abs(y - achieved.minY) > 1 else { return nil }
        return CGPoint(x: x, y: y)
    }
}
