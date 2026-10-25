import AppKit

// The DMG window background, drawn — not designed in an editor — so it is
// versioned, reproducible, and in lockstep with the app and the site: the
// homepage's wall in Ceramic's night glaze. Lodestar's other doors stand
// around the window as quiet panes, and one bar in full contrast holds the
// name, the app and where it goes.
//
// Three facts about Finder decide the drawing (measured on macOS 27,
// 2026-10-25). It sets every icon's name in black on a background
// picture, in dark mode too, so names stand only on a light surface: the
// bar is the slab, the day's ground on the night's. It composites a
// transparent picture over white, so the picture cannot follow the Mac's
// look and is opaque. And its path bar, when the person has it on, covers
// the last 30 points of the window, so nothing is drawn there.
//
// Usage: swift scripts/make-dmg-background.swift <output-dir> <minimum-macos>
//   Writes background.png (660×400) and background@2x.png; make-dmg.sh
//   joins them into the retina TIFF Finder wants. Nothing in it changes
//   from release to release: the floor comes from the app's Info.plist.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let floor = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "27"

let width: CGFloat = 660
let height: CGFloat = 400

// Finder geometry (top-left coordinates, mirrored in make-dmg.sh): the app
// at (190, 214), Applications at (470, 214), icons 96 points. Finder
// centres an icon on the position it is given.
let iconY: CGFloat = 214
let appX: CGFloat = 190
let folderX: CGFloat = 470

func hex(_ v: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

// Ceramic's steps (Sources/LodestarCore/Palette.swift): the night outside,
// the day inside the slab.
enum Night {
    static let ground = hex(0x120F0C), pane = hex(0x1D1916), ink = hex(0xF1EBE2), quiet = hex(0xA99F92)
    static let slab = hex(0xF1E8DF), slabSide = hex(0xADA093)
}
enum Day {
    static let ink = hex(0x1E1814), quiet = hex(0x66584E), orange = hex(0xC83500)
}

/// Top-left to AppKit's bottom-left.
func y(_ top: CGFloat) -> CGFloat { height - top }

/// Ceramic's type: the system sans at its sizes (design/02-type.md).
func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: size, weight: weight) }

func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
          x: CGFloat, top: CGFloat, centred: Bool = true) {
    let string = NSAttributedString(string: s, attributes: [.font: font(size, weight), .foregroundColor: color])
    let bounds = string.size()
    string.draw(at: CGPoint(x: centred ? x - bounds.width / 2 : x, y: y(top) - bounds.height))
}

func rounded(_ rect: NSRect, _ radius: CGFloat, fill: NSColor, edge: NSColor? = nil) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    guard let edge else { return }
    edge.setStroke()
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
    path.lineWidth = 1
    path.stroke()
}

/// The mark, small: its faces in International Orange, drawn from Mark.swift
/// (make-dmg.sh compiles this script beside it), so the pane's star is the
/// icon's star.
func drawMark(center: CGPoint, radius: CGFloat) {
    for face in Mark.faces {
        let path = NSBezierPath()
        for (i, p) in face.points.enumerated() {
            let point = CGPoint(x: center.x + p.x * radius, y: center.y - p.y * radius)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        let c = Mark.fill(tone: face.tone, accent: Mark.internationalOrange)
        let color = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        color.setFill(); color.setStroke()
        path.lineWidth = 0.3
        path.fill(); path.stroke()
    }
}

func draw() {
    Night.ground.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // The wall: six of Lodestar's doors, named and quiet, running off the
    // window's sides the way the homepage's wall runs off the page.
    let rows: [(top: CGFloat, bottom: CGFloat)] = [(18, 112), (128, 222), (238, 332)]
    // Each name fits whole on its side of the bar: nothing is cut by the
    // window's edge or tucked under the bar.
    let left = ["Breaths", "The browser", "Select text"]
    let right = ["Meetings", "The coach", "Health"]
    for (i, row) in rows.enumerated() {
        for (x, name) in [(CGFloat(-50), left[i]), (CGFloat(582), right[i])] {
            let pane = NSRect(x: x, y: y(row.bottom), width: 126, height: row.bottom - row.top)
            rounded(pane, 12, fill: Night.pane, edge: Night.ink.withAlphaComponent(0.08))
            text(name, size: 13, weight: .medium, color: Night.quiet.withAlphaComponent(0.8),
                 x: max(pane.minX, 0) + 10, top: row.top + 14, centred: false)
        }
    }

    // The bar is the slab: it stands on its side, and inside it is the day.
    let bar = NSRect(x: 100, y: y(334), width: 460, height: 312)
    rounded(bar, 22, fill: Night.slabSide)
    rounded(NSRect(x: bar.minX, y: bar.minY + 5, width: bar.width, height: bar.height - 5), 22, fill: Night.slab)

    // The name, the mark beside it, and what to do.
    let name = NSAttributedString(string: "Lodestar", attributes: [.font: font(23, .semibold), .foregroundColor: Day.ink])
    let markRadius: CGFloat = 13, gap: CGFloat = 10
    let nameLeft = width / 2 - (markRadius * 2 + gap + name.size().width) / 2
    drawMark(center: CGPoint(x: nameLeft + markRadius, y: y(60)), radius: markRadius)
    name.draw(at: CGPoint(x: nameLeft + markRadius * 2 + gap, y: y(60) - name.size().height / 2 - 1))
    text("Drag Lodestar into Applications to install it", size: 16, color: Day.quiet, x: width / 2, top: 82)

    let rule = NSBezierPath()
    rule.move(to: CGPoint(x: bar.minX, y: y(118)))
    rule.line(to: CGPoint(x: bar.maxX, y: y(118)))
    rule.lineWidth = 1
    Day.ink.withAlphaComponent(0.10).setStroke()
    rule.stroke()

    // Applications is where you put it: a drop target sinks
    // (design/04-material.md), one step below the slab with a firmer edge,
    // holding the folder and its name.
    let well = NSRect(x: folderX - 72, y: y(iconY + 88), width: 144, height: 152)
    rounded(well, 16, fill: hex(0xE2D8CD), edge: Day.ink.withAlphaComponent(0.14))

    // Which way: the system's arrow, in the one orange, where the hand
    // goes next. Nothing here stands up, since nothing here is pressed.
    let symbol = NSImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [Day.orange]))
    if let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?.withSymbolConfiguration(symbol) {
        let size = arrow.size
        let centre = (appX + 48 + well.minX) / 2
        arrow.draw(in: NSRect(x: centre - size.width / 2, y: y(iconY) - size.height / 2,
                              width: size.width, height: size.height))
    }

    text("Apple silicon · macOS \(floor) or later", size: 13, weight: .medium, color: Night.quiet, x: width / 2, top: 344)
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
