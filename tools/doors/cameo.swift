import AppKit

// Cuts a relief rendered by cameo.py into its two pictures, the cameo of each look:
// the relief in the other look's clay (pale by night, espresso by day), lit as the
// render lit it relative to its ground, on its own shadow, with the letters inlaid
// in ink and the one orange glaze. The ground itself is left clear.
//
//   swift cameo.swift <relief.png> <mask.png> <out-night.png> <out-day.png>

let arguments = CommandLine.arguments
func load(_ path: String) -> NSBitmapImageRep { NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))! }
let relief = load(arguments[1]), mask = load(arguments[2])
let width = relief.pixelsWide, height = relief.pixelsHigh

typealias RGB = (Double, Double, Double)
func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> RGB {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
}
func hex(_ v: Int) -> RGB { (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255) }
func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { (a.0 * t + b.0 * (1 - t), a.1 * t + b.1 * (1 - t), a.2 * t + b.2 * (1 - t)) }

// The lit ground: the brightest of the ground's greys, since shadow and occlusion only take light away.
var counts = [Int](repeating: 0, count: 256)
for y in stride(from: 0, to: height, by: 3) {
    for x in stride(from: 0, to: width, by: 3) where rgb(mask, x, y).0 < 0.01 { counts[Int(rgb(relief, x, y).0 * 255)] += 1 }
}
let total = counts.reduce(0, +)
var seen = 0, groundIndex = 255
for i in (0..<256).reversed() {
    seen += counts[i]
    if Double(seen) > Double(total) * 0.08 { groundIndex = i; break }
}
let ground = (Double(groundIndex) + 0.5) / 255

// Ceramic's values (Sources/LodestarCore/Palette.swift): each look's cameo is the other look's ground.
struct Look { let clay: RGB; let ink: RGB; let marks: RGB; let shadow: RGB; let shadowGain: Double; let orange: RGB }
let night = Look(clay: hex(0xE9DFD4), ink: hex(0x2A221D), marks: hex(0x8C7E72), shadow: (0.02, 0.015, 0.01), shadowGain: 1.6, orange: hex(0xFA5617))
let day = Look(clay: hex(0x3A2F28), ink: hex(0xEDE4DA), marks: hex(0x9A8B7E), shadow: (0.20, 0.13, 0.08), shadowGain: 0.8, orange: hex(0xC83500))
let inkOnGlaze = hex(0x1E1814)

for (look, path) in [(night, arguments[3]), (day, arguments[4])] {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let data = out.bitmapData!
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = rgb(relief, x, y)
            let inside = rgb(mask, x, y).0
            let value = (r + g + b) / 3
            // The render's grain leaves the ground a hair under its lit grey; below 2% is no shadow.
            let shadow = min(1, max(0, (ground - value) / ground - 0.02) * look.shadowGain)
            var color: RGB = (0, 0, 0), alpha = 0.0
            if g > r + 0.15 && g > b + 0.15 {
                // letters on the glaze: dark ink, as a lit key's legend
                color = mix(inkOnGlaze, look.orange, min(1, (g - max(r, b)) / 0.45)); alpha = 1
            } else if r > g + 0.15 && b > g + 0.15 {
                // a page's lines and rules, inlaid in a quieter ink than its words
                color = mix(look.marks, look.clay, min(1, (min(r, b) - g) / 0.4)); alpha = 1
            } else if b > r + 0.12 && b > g + 0.08 {
                // inlaid letters, their edges blended into the clay by how blue the pixel is
                color = mix(look.ink, look.clay, min(1, (b - max(r, g)) / 0.45)); alpha = 1
            } else if max(r, g, b) - min(r, g, b) > 0.18 {
                // the glaze, shaded by its own light
                let k = min(1.25, max(0.7, (r * 0.2126 + g * 0.7152 + b * 0.0722) / 0.30))
                color = (min(1, look.orange.0 * k), min(1, look.orange.1 * k), min(1, look.orange.2 * k)); alpha = 1
            } else if inside > 0.02 {
                // the clay, lit as the relief is lit against its ground; at the outline the shadow shows beneath
                let k = value / ground
                let c = look.clay
                let lit: RGB = k >= 1
                    ? (min(1, c.0 + (1 - c.0) * (k - 1) * 1.6), min(1, c.1 + (1 - c.1) * (k - 1) * 1.6), min(1, c.2 + (1 - c.2) * (k - 1) * 1.6))
                    : (c.0 * k, c.1 * k, c.2 * k)
                alpha = inside + (1 - inside) * shadow
                let a = max(alpha, 0.001)
                color = ((lit.0 * inside + look.shadow.0 * (1 - inside) * shadow) / a,
                         (lit.1 * inside + look.shadow.1 * (1 - inside) * shadow) / a,
                         (lit.2 * inside + look.shadow.2 * (1 - inside) * shadow) / a)
            } else {
                color = look.shadow; alpha = shadow
            }
            let i = y * out.bytesPerRow + x * 4
            data[i] = UInt8(min(255, color.0 * 255 * alpha))
            data[i + 1] = UInt8(min(255, color.1 * 255 * alpha))
            data[i + 2] = UInt8(min(255, color.2 * 255 * alpha))
            data[i + 3] = UInt8(min(255, alpha * 255))
        }
    }
    try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
