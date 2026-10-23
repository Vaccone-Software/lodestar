import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/05-motion.md as a list, read from the code: every animation the
/// app can run, with its time and its curve, and what arrives at once. A
/// still cannot show motion, so the sheet names it; the surfaces' pictures
/// show the end states, which is the point. Nothing here is typed in as a
/// value: a change to `Motion` changes the sheet.
extension GalleryFoundations {
    static func motion(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        sheet(look: look, width: 1040) { page, _ in
            let margin = page.margin
            page.heading("Motion · \(look.name)",
                         "Lodestar answers at once. Motion is kept for a level changing now and a rare change of state.")

            // The curve, drawn from its own control points.
            page.text("The one curve", at: NSPoint(x: margin, y: page.y), role: .body, color: Page.ink)
            page.text(Motion.curveText + " · decelerating · nothing springs, bounces or overshoots",
                      at: NSPoint(x: margin + 190, y: page.y + 2))
            page.y += 30
            let plot = NSRect(x: margin, y: page.y, width: 200, height: 140)
            if page.draws {
                BarTheme.inkAt(0.08).setFill()
                NSBezierPath(rect: plot).fill()
                BarTheme.hairline.setStroke()
                let frame = NSBezierPath(rect: plot)
                frame.lineWidth = 0.5
                frame.stroke()
                let p = Motion.curvePoints.map { CGFloat($0) }
                func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                    NSPoint(x: plot.minX + x * plot.width, y: plot.maxY - y * plot.height)
                }
                let curve = NSBezierPath()
                curve.move(to: point(0, 0))
                curve.curve(to: point(1, 1), controlPoint1: point(p[0], p[1]), controlPoint2: point(p[2], p[3]))
                curve.lineWidth = 2
                BarTheme.ink.setStroke()
                curve.stroke()
            }
            page.text("time", at: NSPoint(x: plot.midX - 10, y: plot.maxY + 6))
            page.text("progress", at: NSPoint(x: plot.maxX + 12, y: plot.minY))
            page.y += 140 + 36

            page.heading("Allowed to move", "Two things, never for longer than \(Motion.milliseconds(Motion.longest)).")
            for motion in Motion.allowed {
                page.text(motion.what, at: NSPoint(x: margin, y: page.y), role: .body, color: Page.ink)
                page.text(Motion.milliseconds(motion.seconds),
                          at: NSPoint(x: margin + 260, y: page.y + 2), role: .meta, color: Page.ink)
                page.text(Motion.curveText, at: NSPoint(x: margin + 340, y: page.y + 2))
                page.y += 24
                func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
                page.text("\(sentence(motion.why)). \(sentence(motion.how)).",
                          at: NSPoint(x: margin + 16, y: page.y))
                page.y += 20
                page.text("Reduce Motion: \(motion.underReduceMotion).", at: NSPoint(x: margin + 16, y: page.y))
                page.y += 30
            }

            page.heading("Instant", "Everything else is in its end state on the next frame. Nothing fades in or out.")
            for line in Motion.instant {
                page.text(line, at: NSPoint(x: margin, y: page.y), color: Page.ink)
                page.y += 22
            }
            page.y += 14
        }
    }
}
