import AppKit
import LodestarCore

/// The lodestar mark in the menu bar: the star with depth as one
/// silhouette (Mark.faces, every face filled in the template color), so the
/// bar's glyph is the icon's star. While a chain is pending, the star sits
/// knocked out of a filled disc: the quiet ambient "you're in something".
enum StatusIcon {
    static let idle = make(active: false)
    static let active = make(active: true)

    private static func star(center: NSPoint, radius: CGFloat) -> [NSBezierPath] {
        Mark.faces.map { face in
            let path = NSBezierPath()
            for (i, p) in face.points.enumerated() {
                let point = NSPoint(x: center.x + p.x * radius, y: center.y - p.y * radius)
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            // A hairline in the same ink closes the seams between faces.
            path.lineWidth = 0.35
            path.lineJoinStyle = .round
            return path
        }
    }

    private static func make(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            // A template image: only its alpha is read, so the colour is the ink.
            BarTheme.ink.setFill()
            BarTheme.ink.setStroke()
            if active {
                NSBezierPath(ovalIn: NSRect(x: center.x - 8.6, y: center.y - 8.6, width: 17.2, height: 17.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                for face in star(center: center, radius: 6.2) { face.fill(); face.stroke() }
            } else {
                for face in star(center: center, radius: 8.2) { face.fill(); face.stroke() }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
