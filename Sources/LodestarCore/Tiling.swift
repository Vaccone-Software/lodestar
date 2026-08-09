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

    /// Index order for `hyper`+digit: left-to-right, then top-to-bottom.
    public static func indexOrder(_ entries: [(id: CGWindowID, frame: CGRect)]) -> [CGWindowID] {
        entries.sorted {
            if abs($0.frame.minX - $1.frame.minX) > 1 { return $0.frame.minX < $1.frame.minX }
            return $0.frame.minY < $1.frame.minY
        }.map(\.id)
    }
}
