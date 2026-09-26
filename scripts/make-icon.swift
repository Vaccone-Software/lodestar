import AppKit

// The Lodestar app icon and the website's marks, drawn from Mark.swift, never
// designed in an editor, so they are versioned, reproducible, and always the
// mark the menu bar draws. Run it through scripts/make-icon.sh, which
// compiles it beside Mark.swift; see that script for the options.
//
// The icon: the star with depth on charcoal that carries a little of the
// accent, on Apple's macOS grid (an 824-point plate, corner 185, on 1024),
// with the plate's faint top sheen and hairline edge, a soft shadow under
// the star, and the faintest wash of the accent behind it.

var accent = Mark.internationalOrange
var name = "international-orange"
var outputDir = ".build/mark"
var all = false
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--accent":
        guard let value = arguments.first, let color = Mark.RGB(hex: value) else {
            FileHandle.standardError.write("--accent takes a hex color such as #FF4F00\n".data(using: .utf8)!)
            exit(64)
        }
        arguments.removeFirst()
        accent = color
        name = value.hasPrefix("#") ? String(value.dropFirst()).lowercased() : value.lowercased()
    case "--preset":
        guard let value = arguments.first, let preset = Mark.presets.first(where: { $0.name == value }) else {
            FileHandle.standardError.write("--preset takes one of: \(Mark.presets.map(\.name).joined(separator: ", "))\n".data(using: .utf8)!)
            exit(64)
        }
        arguments.removeFirst()
        accent = preset.color
        name = preset.name
    case "--out":
        outputDir = arguments.removeFirst()
    case "--all":
        all = true
    default:
        FileHandle.standardError.write("unknown option \(flag)\n".data(using: .utf8)!)
        exit(64)
    }
}

func color(_ c: Mark.RGB, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: alpha)
}

/// The mark's faces into a rect, back to front, in `accent`. Each face is
/// stroked in its own color a hair wide so neighbours meet without a seam.
func drawFaces(center: CGPoint, radius: CGFloat, accent: Mark.RGB, seam: CGFloat) {
    for face in Mark.faces {
        let path = NSBezierPath()
        for (i, p) in face.points.enumerated() {
            let point = CGPoint(x: center.x + p.x * radius, y: center.y - p.y * radius)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
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
}

func drawIcon(canvas: CGFloat, accent: Mark.RGB) -> NSImage {
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        let scale = canvas / 1024
        let plateRect = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        let plate = NSBezierPath(roundedRect: plateRect, xRadius: 185 * scale, yRadius: 185 * scale)
        NSGraphicsContext.current?.saveGraphicsState()
        plate.addClip()

        let ground = Mark.ground(accent: accent)
        NSGradient(colors: [color(ground.top), color(ground.bottom)])!.draw(in: plateRect, angle: -90)

        // The faintest wash of the accent behind the star.
        let wash = NSGradient(colors: [color(accent, alpha: 0.07), color(accent, alpha: 0)])!
        wash.draw(fromCenter: CGPoint(x: 512 * scale, y: 554 * scale), radius: 0,
                  toCenter: CGPoint(x: 512 * scale, y: 554 * scale), radius: 470 * scale, options: [])

        // The star, with a soft shadow under it as one piece.
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 36 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -16 * scale)
        shadow.set()
        NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        drawFaces(center: CGPoint(x: 512 * scale, y: 502 * scale), radius: 294 * scale, accent: accent,
                  seam: max(0.35, 1.2 * scale))
        NSGraphicsContext.current?.cgContext.endTransparencyLayer()
        NSGraphicsContext.current?.restoreGraphicsState()

        // The plate's top sheen.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: plateRect.minX, y: plateRect.maxY - plateRect.height * 0.45,
                             width: plateRect.width, height: plateRect.height * 0.45), angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        // The hairline edge.
        let edge = NSBezierPath(roundedRect: plateRect.insetBy(dx: 1.5 * scale, dy: 1.5 * scale),
                                xRadius: 184 * scale, yRadius: 184 * scale)
        edge.lineWidth = max(0.5, 3 * scale)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        edge.stroke()
        return true
    }
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

/// The website's data: every face with its fill, and the ground, so the
/// site's logo and touch icon are drawn from the same faces.
func siteData(accent: Mark.RGB) -> String {
    let ground = Mark.ground(accent: accent)
    let faces = Mark.faces.map { face in
        let points = face.points.map { String(format: "[%.4f,%.4f]", $0.x, $0.y) }.joined(separator: ",")
        return "{\"points\":[\(points)],\"fill\":\"\(Mark.fill(tone: face.tone, accent: accent).hex)\"}"
    }.joined(separator: ",\n    ")
    return """
    {
      "_": "Generated by scripts/make-icon.sh from Sources/LodestarCore/Mark.swift. Do not edit.",
      "accent": "\(accent.hex)",
      "ground": { "top": "\(ground.top.hex)", "bottom": "\(ground.bottom.hex)" },
      "faces": [
        \(faces)
      ]
    }

    """
}

func render(accent: Mark.RGB, into dir: String) {
    let iconset = "\(dir)/lodestar.iconset"
    try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    let entries: [(pixels: Int, name: String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
        (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]
    for entry in entries {
        writePNG(drawIcon(canvas: CGFloat(entry.pixels), accent: accent), to: "\(iconset)/\(entry.name).png", pixels: entry.pixels)
    }
    writePNG(drawIcon(canvas: 1024, accent: accent), to: "\(dir)/preview.png", pixels: 1024)
    try! Mark.svg(accent: accent, size: 64, ground: true).write(toFile: "\(dir)/icon.svg", atomically: true, encoding: .utf8)
    try! Mark.svg(accent: accent, size: 64).write(toFile: "\(dir)/mark.svg", atomically: true, encoding: .utf8)
    try! siteData(accent: accent).write(toFile: "\(dir)/mark.json", atomically: true, encoding: .utf8)
    print("\(dir): iconset, preview.png, icon.svg, mark.svg, mark.json")
}

if all {
    for preset in Mark.presets { render(accent: preset.color, into: "\(outputDir)/\(preset.name)") }
} else {
    render(accent: accent, into: "\(outputDir)/\(name)")
}
