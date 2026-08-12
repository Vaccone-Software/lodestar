import AppKit

// The DMG window background, drawn — not designed in an editor — so it is
// versioned, reproducible, and in lockstep with the icon and the site: the
// same near-black ground, the same compass mark, the same sparse northern
// sky with international orange beacons. The one instruction a first
// launch needs is a dotted transfer arc from the app to Applications.
//
// Usage: swift scripts/make-dmg-background.swift <output-dir> <version>
//   Writes background.png (660×400) and background@2x.png; make-dmg.sh
//   joins them into the retina TIFF Finder wants.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let version = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

let width: CGFloat = 660
let height: CGFloat = 400

// Finder geometry (top-left coordinates, mirrored in make-dmg.sh): the app
// at (165, 200), Applications at (495, 200), icons 96px.
let appSlot = CGPoint(x: 165, y: height - 200)
let folderSlot = CGPoint(x: 495, y: height - 200)

/// The compass star — same geometry as the icon and the menu bar mark.
func starPath(center: CGPoint, cardinal: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for i in 0..<16 {
        let angle = CGFloat(i) * .pi / 8 + .pi / 2
        let radius: CGFloat
        if i % 2 == 1 {
            radius = cardinal * (2.3 / 8.2)
        } else if i % 4 == 0 {
            radius = cardinal
        } else {
            radius = cardinal * (4.4 / 8.2)
        }
        let point = CGPoint(x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius)
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

/// Deterministic stars: the same sky every render, every release.
struct Seeded {
    var state: UInt64 = 0x10DE57A2
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt64(1) << 31)
    }
}

func brandFont(size: CGFloat) -> NSFont {
    for name in ["MapleMono-NF-Medium", "Maple Mono NF", "Menlo"] {
        if let font = NSFont(name: name, size: size) { return font }
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
}

func drawCaps(_ text: String, center: CGPoint, size: CGFloat, alpha: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: brandFont(size: size),
        .kern: size * 0.38,
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    var bounds = string.size()
    bounds.width -= size * 0.38  // trailing kern is not visible width
    string.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
}

func draw() {
    // Near-black ground with a breath of the icon's deep-space blue at the
    // top — darkness with a floor light, never a poster gradient.
    NSGradient(colors: [
        NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.10, alpha: 1),
        NSColor(calibratedRed: 0.039, green: 0.039, blue: 0.043, alpha: 1),
    ])!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // The sky: sparse, still, mostly dim, a few international orange
    // beacons — the site's starfield at rest.
    var random = Seeded()
    for _ in 0..<110 {
        let x = random.next() * width
        let y = random.next() * height
        let size = 0.5 + random.next() * 0.9
        let brightness = 0.14 + pow(random.next(), 2.2) * 0.55
        let beacon = random.next() < 0.045
        let color = beacon
            ? NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.0, alpha: brightness + 0.15)
            : NSColor.white.withAlphaComponent(brightness)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - size / 2, y: y - size / 2,
                                    width: size, height: size)).fill()
    }

    // The mark, top center: hairline graticule ring, cardinal ticks, star.
    let markCenter = CGPoint(x: width / 2, y: height - 78)
    let ringRadius: CGFloat = 30
    let ring = NSBezierPath(ovalIn: NSRect(x: markCenter.x - ringRadius, y: markCenter.y - ringRadius,
                                           width: ringRadius * 2, height: ringRadius * 2))
    ring.lineWidth = 1
    NSColor.white.withAlphaComponent(0.16).setStroke()
    ring.stroke()

    let ticks = NSBezierPath()
    for i in 0..<16 {
        let angle = CGFloat(i) * .pi / 8 + .pi / 2
        let isCardinal = i % 4 == 0
        let inner = ringRadius - (isCardinal ? 3.5 : 1.8)
        let outer = ringRadius + (isCardinal ? 3.5 : 1.8)
        ticks.move(to: CGPoint(x: markCenter.x + cos(angle) * inner, y: markCenter.y + sin(angle) * inner))
        ticks.line(to: CGPoint(x: markCenter.x + cos(angle) * outer, y: markCenter.y + sin(angle) * outer))
    }
    ticks.lineWidth = 1
    NSColor.white.withAlphaComponent(0.28).setStroke()
    ticks.stroke()

    NSColor(calibratedRed: 0.95, green: 0.953, blue: 0.96, alpha: 1).setFill()
    starPath(center: markCenter, cardinal: ringRadius * (34.0 / 44.0)).fill()

    // The transfer arc: one dotted trajectory from the app to its orbit in
    // Applications, in the accent — the single instruction on the pane.
    let accent = NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.0, alpha: 0.9)
    let start = CGPoint(x: appSlot.x + 72, y: appSlot.y + 14)
    let end = CGPoint(x: folderSlot.x - 72, y: folderSlot.y + 14)
    let arc = NSBezierPath()
    arc.move(to: start)
    arc.curve(to: end,
              controlPoint1: CGPoint(x: width / 2 - 60, y: appSlot.y + 62),
              controlPoint2: CGPoint(x: width / 2 + 60, y: appSlot.y + 62))
    arc.lineWidth = 1.6
    arc.lineCapStyle = .round
    arc.setLineDash([0.1, 6.5], count: 2, phase: 0)
    accent.setStroke()
    arc.stroke()

    // Arrowhead: an open chevron whose arms straddle the arc's end
    // tangent, so the trajectory reads as arriving, not decorated.
    let tangent = CGPoint(x: end.x - (width / 2 + 60), y: end.y - (appSlot.y + 62))
    let heading = atan2(tangent.y, tangent.x)
    let chevron = NSBezierPath()
    for spread in [CGFloat(0.5), -0.5] {
        let angle = heading + .pi + spread
        let arm = CGPoint(x: end.x + cos(angle) * 7.5, y: end.y + sin(angle) * 7.5)
        if spread > 0 { chevron.move(to: arm) } else { chevron.line(to: arm) }
        if spread > 0 { chevron.line(to: end) }
    }
    chevron.lineWidth = 1.6
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    accent.setStroke()
    chevron.stroke()

    drawCaps("DRAG TO INSTALL", center: CGPoint(x: width / 2, y: height - 132), size: 9.5, alpha: 0.5)

    // The technical footer: one hairline, the release, the floor.
    let rule = NSBezierPath()
    rule.move(to: CGPoint(x: 40, y: 38))
    rule.line(to: CGPoint(x: width - 40, y: 38))
    rule.lineWidth = 1
    NSColor.white.withAlphaComponent(0.10).setStroke()
    rule.stroke()
    let footer = version.isEmpty ? "MACOS 13 OR LATER" : "V\(version) · MACOS 13 OR LATER"
    drawCaps(footer, center: CGPoint(x: width / 2, y: 22), size: 8, alpha: 0.32)
}

func write(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    // Points, not pixels — the context maps point-space drawing onto the
    // pixel grid, and the PNG carries the DPI Finder pairs reps by.
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

write(scale: 1, to: "\(outputDir)/background.png")
write(scale: 2, to: "\(outputDir)/background@2x.png")
print("background written to \(outputDir)")
