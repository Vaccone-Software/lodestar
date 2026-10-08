import AppKit
import LodestarCore

/// The mark as a note's picture, lit as far as something has come. Lodestar
/// speaking about itself is a room, so its notes may carry the mark; a
/// note about a download carries it filling. The faces take the person's
/// accent in turn, clockwise from the top, as the share of the work done
/// grows, and the rest stand in a quiet stone shaded the same way, so the
/// star is always whole and only its light moves. No bar, no number, no
/// timer: the mark is the progress.
final class LitMark: NSView {
    static let size: CGFloat = 44

    /// The share of faces lit, 0 to 1.
    var lit: Double {
        didSet {
            let clamped = min(1, max(0, lit))
            if clamped != lit { lit = clamped; return }
            if Self.litCount(lit) != Self.litCount(oldValue) { needsDisplay = true }
        }
    }

    init(lit: Double) {
        self.lit = min(1, max(0, lit))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    /// How many faces a share lights. Whole faces only, so a redraw happens
    /// when the picture changes and not on every byte.
    static func litCount(_ share: Double) -> Int {
        Int((min(1, max(0, share)) * Double(Mark.faces.count)).rounded())
    }

    /// The faces in the order they light: clockwise from the top, by where
    /// each face's middle sits. The mark's own y grows downward.
    static let order: [Int] = Mark.faces.indices.sorted { a, b in
        angle(Mark.faces[a]) < angle(Mark.faces[b])
    }

    private static func angle(_ face: Mark.Face) -> Double {
        let n = Double(face.points.count)
        let x = face.points.reduce(0) { $0 + $1.x } / n
        let y = face.points.reduce(0) { $0 + $1.y } / n
        let a = atan2(x, -y)
        return a < 0 ? a + 2 * .pi : a
    }

    /// The faces still to light: a warm stone, darker at night, so the
    /// unlit star reads as the same object waiting rather than a hole.
    static var stone: Mark.RGB {
        Tone.systemDark ? Mark.RGB(hex: 0x6E655E) : Mark.RGB(hex: 0xB9AEA4)
    }

    static var accent: Mark.RGB {
        let accent = BarTheme.accent.usingColorSpace(.sRGB) ?? .orange
        return Mark.RGB(red: Double(accent.redComponent), green: Double(accent.greenComponent),
                        blue: Double(accent.blueComponent))
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = Self.litCount(lit)
        var litFaces = Set<Int>()
        for index in Self.order.prefix(count) { litFaces.insert(index) }
        let accent = Self.accent, stone = Self.stone
        let radius = bounds.width / 2 * 0.96
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        for (index, face) in Mark.faces.enumerated() {
            let fill = Mark.fill(tone: face.tone, accent: litFaces.contains(index) ? accent : stone)
            let color = NSColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1)
            let path = NSBezierPath()
            for (i, point) in face.points.enumerated() {
                let p = NSPoint(x: center.x + point.x * radius, y: center.y - point.y * radius)
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            color.setFill(); color.setStroke()
            path.lineWidth = 0.5
            path.lineJoinStyle = .round
            path.fill(); path.stroke()
        }
    }
}
