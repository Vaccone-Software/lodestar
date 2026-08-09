import AppKit

// The lodestar app icon, drawn — not designed in an editor — so it is
// versioned, reproducible, and always in lockstep with the menu-bar mark.
//
// Influences, deliberately: NASA's standards-manual discipline (one mark,
// hairline technical detail), US Graphics Company restraint (near-mono
// palette, precision), SpaceX darkness, Apple materials (squircle, a
// breath of gradient — never a circus).
//
// Usage: swift scripts/make-icon.swift <output-dir>
//   Writes lodestar.iconset/ PNGs and preview.png; iconutil finishes it.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetDir = "\(outputDir)/lodestar.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

/// The compass star — same geometry as the menu bar mark: 16 vertices,
/// long cardinals, mid diagonals, tight waist.
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

func drawIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    let scale = canvas / 1024
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let small = canvas <= 64

    // Apple's macOS icon canvas: the squircle floats inside the square
    // with transparent margins (Big Sur grid: 824pt plate on 1024).
    let plateSize = canvas * (824.0 / 1024.0)
    let plate = NSBezierPath(
        roundedRect: NSRect(x: (canvas - plateSize) / 2, y: (canvas - plateSize) / 2,
                            width: plateSize, height: plateSize),
        xRadius: canvas * (185.0 / 1024.0), yRadius: canvas * (185.0 / 1024.0)
    )
    plate.addClip()

    // Deep space, barely blue — darkness with a floor light.
    NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.08, alpha: 1),
    ])!.draw(in: plate, angle: -90)

    if !small {
        // The technical layer: one hairline graticule ring with cardinal
        // ticks — an instrument, not a decoration.
        let ringRadius = canvas * 0.335
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                               width: ringRadius * 2, height: ringRadius * 2))
        ring.lineWidth = max(1, 2 * scale)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        ring.stroke()

        let tick = NSBezierPath()
        for i in 0..<16 {
            let angle = CGFloat(i) * .pi / 8 + .pi / 2
            let isCardinal = i % 4 == 0
            let inner = ringRadius - (isCardinal ? 14 : 7) * scale
            let outer = ringRadius + (isCardinal ? 14 : 7) * scale
            tick.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            tick.line(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        tick.lineWidth = max(1, 2 * scale)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        tick.stroke()
    }

    // The star: near-white, one breath of gradient, a faint lift.
    let cardinal = canvas * (small ? 0.34 : 0.26)
    let star = starPath(center: center, cardinal: cardinal)
    if !small {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 0.75, green: 0.83, blue: 1.0, alpha: 0.22)
        shadow.shadowBlurRadius = 13 * scale
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.white.setFill()
        star.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGradient(colors: [
            NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.78, green: 0.83, blue: 0.93, alpha: 1),
        ])!.draw(in: star, angle: -90)
    } else {
        NSColor.white.setFill()
        star.fill()
    }

    return image
}

func writePNG(_ image: NSImage, to path: String, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let entries: [(pixels: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for entry in entries {
    writePNG(drawIcon(canvas: CGFloat(entry.pixels)), to: "\(iconsetDir)/\(entry.name).png", pixels: entry.pixels)
}
writePNG(drawIcon(canvas: 512), to: "\(outputDir)/preview.png", pixels: 512)
print("iconset + preview written to \(outputDir)")
