import AppKit

// measure <png> <dark|light> [--crop out.png]
// Finds the surface against the stage's flat ground, then reports the
// panel's own ground (the modal colour of its interior) and the darkest
// or lightest ink on it, as a WCAG ratio.
// measure <png> <dark|light appearance> [--ground dark|light] [--crop out.png]
// The appearance decides which end of the histogram is ink; the ground
// (default: the appearance's own) decides the stage colour to find the
// surface against.
var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: measure <png> <dark|light> [--ground dark|light] [--crop out.png]"); exit(1) }
let path = args.removeFirst(), light = args.removeFirst() == "light"
var groundLight = light
var cropOut: String? = nil
while !args.isEmpty {
    let flag = args.removeFirst()
    if flag == "--ground", !args.isEmpty { groundLight = args.removeFirst() == "light" }
    else if flag == "--crop", !args.isEmpty { cropOut = args.removeFirst() }
}

guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { print("cannot read \(path)"); exit(1) }
let w = cg.width, h = cg.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

let stage = groundLight ? (246, 246, 247) : (10, 10, 11)
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 80..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    if abs(Int(buf[i]) - stage.0) > 8 || abs(Int(buf[i+1]) - stage.1) > 8 || abs(Int(buf[i+2]) - stage.2) > 8 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}}
guard maxX >= 0 else { print("\(path): nothing on the stage"); exit(2) }

func lin(_ c: Int) -> Double { let s = Double(c) / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
func lum(_ r: Int, _ g: Int, _ b: Int) -> Double { 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }

// Interior only: inset 15% a side drops the shadow and the rim.
let bw = maxX - minX + 1, bh = maxY - minY + 1
let ix0 = minX + bw * 15 / 100, ix1 = maxX - bw * 15 / 100
let iy0 = minY + bh * 15 / 100, iy1 = maxY - bh * 15 / 100
var count = [Int](repeating: 0, count: 256)
var sumR = [Double](repeating: 0, count: 256), sumG = sumR, sumB = sumR, sumL = sumR
var total = 0
for y in iy0...iy1 { for x in ix0...ix1 {
    let i = (y * w + x) * 4
    let r = Int(buf[i]), g = Int(buf[i+1]), b = Int(buf[i+2])
    let gray = min(255, Int(0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)))
    count[gray] += 1; sumR[gray] += Double(r); sumG[gray] += Double(g); sumB[gray] += Double(b)
    sumL[gray] += lum(r, g, b); total += 1
}}
let mode = (0..<256).max { count[$0] < count[$1] }!
let n = Double(count[mode])
let groundL = sumL[mode] / n
let gR = Int(sumR[mode] / n), gG = Int(sumG[mode] / n), gB = Int(sumB[mode] / n)
// Ink: the far 0.5% of the interior, at the end away from the ground.
let want = max(1, total / 200)
var acc = 0, inkL = groundL
let order: [Int] = light ? Array(0..<256) : Array((0..<256).reversed())
for k in order { acc += count[k]; if acc >= want { inkL = sumL[k] / Double(max(1, count[k])); break } }
let ratio = (max(groundL, inkL) + 0.05) / (min(groundL, inkL) + 0.05)
let share = 100.0 * n / Double(total)
print(String(format: "%@  bbox=%dx%d@%d,%d  ground=rgb(%d,%d,%d) L=%.4f (%.0f%% of interior)  ink L=%.4f  ratio=%.2f",
             (path as NSString).lastPathComponent, bw, bh, minX, minY, gR, gG, gB, groundL, share, inkL, ratio))

if let cropOut {
    let m = 24
    let rect = CGRect(x: max(0, minX - m), y: max(0, minY - m),
                      width: min(w, maxX + m) - max(0, minX - m), height: min(h, maxY + m) - max(0, minY - m))
    if let c = cg.cropping(to: rect) {
        let rep = NSBitmapImageRep(cgImage: c)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: cropOut))
    }
}
