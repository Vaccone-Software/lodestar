import AppKit

// The DMG window background, drawn — not designed in an editor — so it is
// versioned, reproducible, and in lockstep with the icon and the site: the
// same near-black ground, the same compass mark, the same sparse northern
// sky with international orange beacons.
//
// The pane is a plotting sheet, not a poster. The two icons are stations on
// a measured course: a hairline span between them, a plain tick where the
// app starts, and the lodestar itself where it lands. Direction is carried
// by that asymmetry — origin unlit, destination a star — so no arrow is
// drawn, and the accent is spent once, on the thing you are steering to.
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

func capsString(_ text: String, size: CGFloat, alpha: CGFloat) -> (NSAttributedString, CGSize) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: brandFont(size: size),
        .kern: size * 0.38,
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    var bounds = string.size()
    bounds.width -= size * 0.38  // trailing kern is not visible width
    return (string, bounds)
}

func drawCaps(_ text: String, center: CGPoint, size: CGFloat, alpha: CGFloat) {
    let (string, bounds) = capsString(text, size: size, alpha: alpha)
    string.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
}

func drawCaps(_ text: String, at left: CGPoint, size: CGFloat, alpha: CGFloat) {
    let (string, bounds) = capsString(text, size: size, alpha: alpha)
    string.draw(at: CGPoint(x: left.x, y: left.y - bounds.height / 2))
}

func drawCaps(_ text: String, rightAlignedAt right: CGPoint, size: CGFloat, alpha: CGFloat) {
    let (string, bounds) = capsString(text, size: size, alpha: alpha)
    string.draw(at: CGPoint(x: right.x - bounds.width, y: right.y - bounds.height / 2))
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

    // Finder sets an icon's label in the system's label colour whatever
    // the picture behind it — black, on this ground, and nothing in the
    // view options says otherwise. Two pale plates under the two labels,
    // sized to the words, so the names read as names.
    let labelFont = NSFont.systemFont(ofSize: 12)
    for (name, x) in [("lodestar.app", CGFloat(165)), ("Applications", CGFloat(495))] {
        let textWidth = (name as NSString).size(withAttributes: [.font: labelFont]).width
        let plate = NSRect(x: x - (textWidth + 18) / 2, y: 163 - 10, width: textWidth + 18, height: 20)
        NSColor(calibratedWhite: 0.94, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
    }

    // The header is set, not drawn. The compass mark belongs to the app
    // icon standing right below it; repeating it here put two white stars
    // in one composition, each weakening the other. Rules flanking the
    // wordmark is the sheet-title convention, and it leaves the icon as the
    // only mark on the pane.
    let headerY = height - 104
    let (wordmark, wordmarkSize) = capsString("LODESTAR", size: 15, alpha: 0.82)
    wordmark.draw(at: CGPoint(x: width / 2 - wordmarkSize.width / 2,
                              y: headerY - wordmarkSize.height / 2))

    let flank = NSBezierPath()
    let flankGap = wordmarkSize.width / 2 + 22
    let flankReach: CGFloat = 96
    flank.move(to: CGPoint(x: width / 2 - flankGap, y: headerY))
    flank.line(to: CGPoint(x: width / 2 - flankGap - flankReach, y: headerY))
    flank.move(to: CGPoint(x: width / 2 + flankGap, y: headerY))
    flank.line(to: CGPoint(x: width / 2 + flankGap + flankReach, y: headerY))
    flank.lineWidth = 1
    NSColor.white.withAlphaComponent(0.15).setStroke()
    flank.stroke()

    // The course: a hairline span across the gap between the two icons, at
    // their centerline, held clear of both by a margin so it reads as
    // measured distance rather than a rule under them.
    let accent = NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.0, alpha: 0.92)
    let origin = CGPoint(x: appSlot.x + 64, y: appSlot.y)
    let destination = CGPoint(x: folderSlot.x - 64, y: folderSlot.y)

    // Dashed, in the chart convention where a broken line is the course not
    // yet run. Solid, it read as a progress bar.
    let span = NSBezierPath()
    span.move(to: origin)
    span.line(to: CGPoint(x: destination.x - 10, y: destination.y))
    span.lineWidth = 1
    span.setLineDash([5, 4], count: 2, phase: 0)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    span.stroke()

    // The origin tick: the plain end of a dimension line. Unlit, because
    // the light is where you are going.
    let tick = NSBezierPath()
    tick.move(to: CGPoint(x: origin.x, y: origin.y - 4.5))
    tick.line(to: CGPoint(x: origin.x, y: origin.y + 4.5))
    tick.lineWidth = 1
    NSColor.white.withAlphaComponent(0.30).setStroke()
    tick.stroke()

    // The destination: the mark itself, small and lit, standing where the
    // arrowhead used to point. You are dragging toward the lodestar.
    accent.setFill()
    starPath(center: destination, cardinal: 7.5).fill()

    drawCaps("DRAG TO INSTALL", center: CGPoint(x: width / 2, y: appSlot.y + 26), size: 8, alpha: 0.38)

    // Registration marks: the corner ticks of a drawing sheet. They give
    // the pane its edges without boxing it in, and they are the reason the
    // lower half reads as deliberate space rather than leftover space.
    let inset: CGFloat = 22
    let arm: CGFloat = 13
    let corners = NSBezierPath()
    for (x, y, dx, dy) in [(inset, inset, 1.0, 1.0),
                           (width - inset, inset, -1.0, 1.0),
                           (inset, height - inset, 1.0, -1.0),
                           (width - inset, height - inset, -1.0, -1.0)] {
        corners.move(to: CGPoint(x: x + arm * CGFloat(dx), y: y))
        corners.line(to: CGPoint(x: x, y: y))
        corners.line(to: CGPoint(x: x, y: y + arm * CGFloat(dy)))
    }
    corners.lineWidth = 1
    NSColor.white.withAlphaComponent(0.13).setStroke()
    corners.stroke()

    // The title block: rule, then the sheet's particulars. Set inside the
    // registration marks, not flush with them — the margin is what makes
    // the corner ticks read as marks rather than a border.
    let margin = inset + 16
    let rule = NSBezierPath()
    rule.move(to: CGPoint(x: margin, y: 52))
    rule.line(to: CGPoint(x: width - margin, y: 52))
    rule.lineWidth = 1
    NSColor.white.withAlphaComponent(0.09).setStroke()
    rule.stroke()
    drawCaps("KEYBOARD NAVIGATION FOR MACOS", at: CGPoint(x: margin, y: 34), size: 7.5, alpha: 0.30)
    let particulars = version.isEmpty ? "MACOS 13 OR LATER" : "V\(version) · MACOS 13 OR LATER"
    drawCaps(particulars, rightAlignedAt: CGPoint(x: width - margin, y: 34), size: 7.5, alpha: 0.30)
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
