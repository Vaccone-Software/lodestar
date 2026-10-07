import AppKit
#if canImport(LodestarCore)
import LodestarCore
#endif

/// The app's icon, in the language the rest of Lodestar speaks: the mark
/// in the accent, floating on its own soft, warm shadow over a flat plate
/// of the palette in force, Slip at night and clay by day, with a hairline
/// edge. No gradient, no sheen, no wash: objects in one light.
///
/// One drawing for every icon: the running app's (which follows the
/// appearance and the accent), and the files `make-icon.sh` writes for the
/// bundle and the site, compiled beside `Mark.swift`.
enum AppIconArt {
    enum Ground { case night, clay }

    /// Each palette's plate: its pane, its hairline edge, and the colour
    /// and weight of the shadow the mark casts on it.
    static func plate(_ ground: Ground) -> (fill: Mark.RGB, edge: (Mark.RGB, Double), shadow: (Mark.RGB, Double)) {
        switch ground {
        case .night:
            return (Mark.RGB(hex: 0x221D19),
                    (Mark.RGB(red: 1, green: 0.93, blue: 0.86), 0.11),
                    (Mark.RGB(red: 0.055, green: 0.027, blue: 0.008), 0.62))
        case .clay:
            return (Mark.RGB(hex: 0xF8EFE7),
                    (Mark.RGB(red: 0.27, green: 0.17, blue: 0.1), 0.13),
                    (Mark.RGB(red: 0.35, green: 0.23, blue: 0.13), 0.32))
        }
    }

    static func color(_ c: Mark.RGB, _ alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: alpha)
    }

    /// The icon on macOS's grid: the plate inset on the 1024 canvas, the
    /// mark a little above its middle.
    static func image(canvas: CGFloat, ground: Ground, accent: Mark.RGB) -> NSImage {
        NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            let scale = canvas / 1024
            let plate = plate(ground)
            let rect = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * scale, yRadius: 185 * scale)
            color(plate.fill).setFill()
            shape.fill()
            drawStar(center: CGPoint(x: 512 * scale, y: 502 * scale), radius: 294 * scale,
                     accent: accent, shadow: plate.shadow, scale: scale)
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75 * scale, dy: 0.75 * scale),
                                    xRadius: 184 * scale, yRadius: 184 * scale)
            edge.lineWidth = max(0.5, 1.5 * scale)
            color(plate.edge.0, plate.edge.1).setStroke()
            edge.stroke()
            return true
        }
    }

    /// The mark alone, full bleed on a 1024 canvas with nothing behind it:
    /// the one layer of the bundle's icon, which macOS sets on the plate
    /// of whichever appearance is in force. Its shadow is its own.
    static func star(canvas: CGFloat, accent: Mark.RGB) -> NSImage {
        NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            let scale = canvas / 1024
            drawStar(center: CGPoint(x: 512 * scale, y: 500 * scale), radius: 362 * scale,
                     accent: accent, shadow: (Mark.RGB(red: 0.2, green: 0.12, blue: 0.06), 0.42), scale: scale)
            return true
        }
    }

    /// The faces, lit as the mark is everywhere, cast as one piece onto
    /// what is beneath with one long soft shadow.
    static func drawStar(center: CGPoint, radius: CGFloat, accent: Mark.RGB,
                         shadow: (Mark.RGB, Double), scale: CGFloat) {
        NSGraphicsContext.current?.saveGraphicsState()
        let cast = NSShadow()
        cast.shadowColor = color(shadow.0, shadow.1)
        cast.shadowBlurRadius = 40 * scale
        cast.shadowOffset = NSSize(width: 0, height: -18 * scale)
        cast.set()
        NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        let seam = max(0.35, 1.2 * scale)
        for face in Mark.faces {
            let path = NSBezierPath()
            for (i, point) in face.points.enumerated() {
                let p = CGPoint(x: center.x + point.x * radius, y: center.y - point.y * radius)
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            let fill = color(Mark.fill(tone: face.tone, accent: accent))
            fill.setFill()
            path.fill()
            fill.setStroke()
            path.lineWidth = seam
            path.lineJoinStyle = .round
            path.stroke()
        }
        NSGraphicsContext.current?.cgContext.endTransparencyLayer()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// The running app's icon for the appearance and accent in force:
    /// the person's accent, or International Orange when that is chosen.
    static func current(dark: Bool, accent: NSColor) -> NSImage {
        let rgb = accent.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0.31, blue: 0, alpha: 1)
        return image(canvas: 1024, ground: dark ? .night : .clay,
                     accent: Mark.RGB(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                                      blue: Double(rgb.blueComponent)))
    }
}
