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
    /// Columns are judged on whole points — sub-point AX jitter must not
    /// reorder, and quantizing keeps the comparison transitive where a
    /// pairwise ±1 fuzz was not (three frames a point apart could answer
    /// a≈b, b≈c, a<c, and sort's output is unspecified on such an order).
    public static func indexOrder(_ entries: [(id: CGWindowID, frame: CGRect)]) -> [CGWindowID] {
        entries.sorted {
            ($0.frame.minX.rounded(), $0.frame.minY) < ($1.frame.minX.rounded(), $1.frame.minY)
        }.map(\.id)
    }
}
