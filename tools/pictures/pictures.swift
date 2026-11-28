import AppKit

// The pictures of the places and the doors: each a few rounded slabs of
// Lodestar's own things, seen from a little above, in one light.
//
// Every slab is a face and the side that face stands on (design/04-material.md:
// depth is a visible side). Faces are filled in the key's colour, sides a step
// darker and engraved along their depth, each stretch of side as dark as the
// way its edge turns from the mark's light. The one part where the hand goes
// is orange, shaded by Mark.fill the way the mark's own faces are. A part sits
// wholly on a face or clear of it, never across an edge, and no picture holds
// words. Night is drawn, not tinted: with light lines on a dark ground the
// lines carry light, so the side is engraved the other way round.
//
//   ./scripts/make-pictures.sh        writes packaging/places and packaging/doors
//
// Each picture is a 100 x 75 box (the overview's 4:3), y down; the files are
// 768 x 576 with nothing behind the drawing. The night picture is the plain
// name and its day twin is `-sand`, as SettingsController.picture reads them.

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil) }
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 0) -> CGPath {
    let k = min(r, w / 2 - 0.01, h / 2 - 0.01)
    return CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: k, cornerHeight: k, transform: nil)
}
func poly(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p }
func roundedPoly(_ pts: [CGPoint], _ radii: [CGFloat]) -> CGPath {
    let p = CGMutablePath(), n = pts.count
    p.move(to: P((pts[n - 1].x + pts[0].x) / 2, (pts[n - 1].y + pts[0].y) / 2))
    for i in 0..<n { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: radii[i]) }
    p.closeSubpath(); return p
}
func stroke(_ pts: [CGPoint], _ w: CGFloat, cap: CGLineCap = .round) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts)
    return p.copy(strokingWithWidth: w, lineCap: cap, lineJoin: .round, miterLimit: 4)
}
func strokeP(_ w: CGFloat, _ build: (CGMutablePath) -> Void) -> CGPath {
    let p = CGMutablePath(); build(p); return p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4)
}
func pt(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint { P(c.x + r * cos(a * .pi / 180), c.y + r * sin(a * .pi / 180)) }
func arcStroke(_ c: CGPoint, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat, _ w: CGFloat) -> CGPath {
    strokeP(w) { p in p.move(to: pt(c, r, a0)); p.addArc(center: c, radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: a1 < a0) }
}
/// An arrowhead: base centred on `b`, aimed at `deg`. The tip aims, so it stays sharp.
func head(_ b: CGPoint, _ deg: CGFloat, _ len: CGFloat, _ w: CGFloat) -> CGPath {
    let d = P(cos(deg * .pi / 180), sin(deg * .pi / 180)), n = P(-d.y, d.x)
    return roundedPoly([P(b.x + d.x * len, b.y + d.y * len), P(b.x + n.x * w / 2, b.y + n.y * w / 2), P(b.x - n.x * w / 2, b.y - n.y * w / 2)], [0.6, 2, 2])
}
func star(_ c: CGPoint, _ n: Int, _ R: CGFloat, _ r: CGFloat) -> CGPath {
    poly((0..<(n * 2)).map { i in pt(c, i % 2 == 0 ? R : r, -90 + CGFloat(i) * 180 / CGFloat(n)) })
}
func wave(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, _ amp: CGFloat, _ period: CGFloat, _ w: CGFloat) -> CGPath {
    strokeP(w) { p in
        for i in 0...80 {
            let x = x0 + (x1 - x0) * CGFloat(i) / 80, q = P(x, y + sin((x - x0) / period * 2 * .pi) * amp)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
    }
}
/// A leaf from base to tip, fuller on one side.
func leaf(_ b: CGPoint, _ t: CGPoint, _ w: CGFloat) -> CGPath {
    let d = P(t.x - b.x, t.y - b.y), l = hypot(d.x, d.y), n = P(-d.y / l, d.x / l)
    func at(_ f: CGFloat, _ s: CGFloat) -> CGPoint { P(b.x + d.x * f + n.x * s, b.y + d.y * f + n.y * s) }
    let p = CGMutablePath(); p.move(to: b)
    p.addCurve(to: t, control1: at(0.2, w), control2: at(0.7, w))
    p.addCurve(to: b, control1: at(0.75, -w * 0.45), control2: at(0.25, -w * 0.45))
    p.closeSubpath(); return p
}
func turn(_ p: CGPath, _ c: CGPoint, _ deg: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: deg * .pi / 180).translatedBy(x: -c.x, y: -c.y); return p.copy(using: &t)!
}
func scaled(_ p: CGPath, _ s: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> CGPath {
    var t = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: dx, ty: dy); return p.copy(using: &t)!
}
func moved(_ p: CGPath, _ v: CGPoint) -> CGPath { var t = CGAffineTransform(translationX: v.x, y: v.y); return p.copy(using: &t)! }
func grow(_ p: CGPath, _ w: CGFloat) -> CGPath { p.copy(strokingWithWidth: w * 2, lineCap: .round, lineJoin: .round, miterLimit: 1).union(p, using: .winding) }
func union(_ ps: [CGPath]) -> CGPath { ps.dropFirst().reduce(ps[0]) { $0.union($1, using: .winding) } }
func cut(_ a: CGPath, _ bs: [CGPath]) -> CGPath { bs.reduce(a) { $0.subtracting($1, using: .winding) } }
func meet(_ a: CGPath, _ b: CGPath) -> CGPath { a.intersection(b, using: .winding) }
func lines(_ x: CGFloat, _ ys: [CGFloat], _ ws: [CGFloat], _ w: CGFloat = 2) -> CGPath { union(zip(ys, ws).map { y, l in stroke([P(x, y), P(x + l, y)], w) }) }

// MARK: - The burin

/// Parallel lines across `shape` at `angle`, each swelling to `width(p)` and
/// tapering to a point at both ends, kept `inset` clear of the contour; `bow`
/// bends them round the form.
func hatch(_ shape: CGPath, angle: CGFloat, spacing: CGFloat, inset: CGFloat, bow: CGFloat = 0, width: (CGPoint) -> CGFloat) -> CGPath {
    let out = CGMutablePath(), bb = shape.boundingBox.insetBy(dx: -2, dy: -2)
    let keepOut = shape.copy(strokingWithWidth: inset * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
    let d = P(cos(angle * .pi / 180), sin(angle * .pi / 180)), n = P(-d.y, d.x)
    let c = P(bb.midX, bb.midY), R = hypot(bb.width, bb.height) / 2, step: CGFloat = 0.5
    var k = -R
    while k <= R {
        var run: [CGPoint] = []
        func flush() {
            defer { run = [] }
            let L = CGFloat(run.count - 1) * step
            guard L >= 1.2, run.map(width).max() ?? 0 >= 0.12 else { return }
            var left: [CGPoint] = [], right: [CGPoint] = []
            for (i, p) in run.enumerated() {
                let s = CGFloat(i) * step, taper = pow(max(0, min(1, s / 3.2, (L - s) / 3.2)), 0.75), w = width(p) * taper / 2
                left.append(P(p.x + n.x * w, p.y + n.y * w)); right.append(P(p.x - n.x * w, p.y - n.y * w))
            }
            out.addLines(between: left + right.reversed()); out.closeSubpath()
        }
        var s = -R
        while s <= R {
            let b = bow * (1 - min(1, (s / R) * (s / R))) * R
            let p = P(c.x + n.x * (k + b) + d.x * s, c.y + n.y * (k + b) + d.y * s)
            if shape.contains(p, using: .winding) && !keepOut.contains(p, using: .winding) { run.append(p) } else if !run.isEmpty { flush() }
            s += step
        }
        if !run.isEmpty { flush() }
        k += spacing
    }
    return out
}

// MARK: - Slabs

/// The one viewpoint: every slab stands this far down and to the right of its face.
let depth = P(1.8, 5.5)
let depthAngle = atan2(depth.y, depth.x) * 180 / .pi
/// Toward the mark's light, in the picture's plane: up and to the left.
let towardLight = { () -> CGPoint in let l = hypot(0.55, 0.7); return P(-0.55 / l, -0.7 / l) }()

/// Something drawn on a face: a solid mark, or a knock that clears the face
/// to show what is behind it.
struct Detail { let path: CGPath; var accent = false; var knock = false }
func ink(_ p: CGPath) -> Detail { Detail(path: p) }
func lit(_ p: CGPath) -> Detail { Detail(path: p, accent: true) }
func knock(_ p: CGPath) -> Detail { Detail(path: p, knock: true) }

struct Slab { let face: CGPath; var accent = false; var marks: [Detail] = []; var lift: CGFloat = 1 }
/// A part mounted on a face stands only a little proud of it.
func raised(_ face: CGPath, accent: Bool = true, marks: [Detail] = []) -> Slab { Slab(face: face, accent: accent, marks: marks, lift: 0.36) }
/// Marks with no face of their own: a stem, a route.
func loose(_ marks: [Detail]) -> Slab { Slab(face: CGMutablePath(), marks: marks) }

struct Look {
    let night: Bool
    let ink, face, side: CGColor
    let orange: Mark.RGB
}
func rgb(_ c: Mark.RGB) -> CGColor { CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: 1) }
func hex(_ h: UInt32) -> CGColor { rgb(Mark.RGB(hex: h)) }
let day = Look(night: false, ink: hex(0x231B16), face: hex(0xFCF8F4), side: hex(0xE2D4C5), orange: Mark.RGB(hex: 0xE8480C))
let night = Look(night: true, ink: hex(0xF1EBE2), face: hex(0x2E2824), side: hex(0x14110F), orange: Mark.RGB(hex: 0xFA5617))

func sweep(_ face: CGPath, _ d: CGPoint) -> CGPath { union((0...14).map { k in moved(face, P(d.x * CGFloat(k) / 14, d.y * CGFloat(k) / 14)) }) }
/// Which way the face's edge faces at a point just outside it.
func outward(_ shape: CGPath, _ q: CGPoint) -> CGPoint {
    var n = P(0, 0)
    for i in 0..<16 {
        let a = CGFloat(i) / 16 * 2 * .pi, d = P(cos(a), sin(a))
        if !shape.contains(P(q.x + d.x * 2, q.y + d.y * 2), using: .winding) { n.x += d.x; n.y += d.y }
    }
    let l = hypot(n.x, n.y); return l > 0 ? P(n.x / l, n.y / l) : P(0, 1)
}
/// How heavily a point on a slab's side is engraved: walk back along the
/// depth to the face's edge and ask which way that edge faces the light.
func sideWeight(_ face: CGPath, _ p: CGPoint, _ d: CGPoint, night: Bool) -> CGFloat {
    var q = p
    for k in 0...14 {
        let c = P(p.x - d.x * CGFloat(k) / 14, p.y - d.y * CGFloat(k) / 14)
        if face.contains(c, using: .winding) { break }
        q = c
    }
    let n = outward(face, q), away = max(0, -(n.x * towardLight.x + n.y * towardLight.y))
    let t = 0.3 + 0.62 * away
    return night ? 0.8 - t * 0.42 : t
}
/// How much shade a face takes toward its lower right.
func faceShade(_ p: CGPoint, _ bb: CGRect) -> CGFloat {
    max(0, min(1, (p.x - bb.minX) / bb.width * 0.55 + (p.y - bb.minY) / bb.height * 0.55))
}

/// Draws slabs back to front. Every clearance is cut through to nothing, so a
/// picture lies on whatever ground it is shown on: the page, or the slab of
/// a place that is chosen.
func draw(_ slabs: [Slab], look: Look, in ctx: CGContext) {
    for (k, s) in slabs.enumerated() {
        let d = P(depth.x * s.lift, depth.y * s.lift)
        let face = s.face.normalized(using: .winding), empty = face.isEmpty
        let body = empty ? face : sweep(face, d), side = empty ? face : cut(body, [face]), bb = face.boundingBox
        func clear(_ p: CGPath) { ctx.saveGState(); ctx.setBlendMode(.clear); ctx.addPath(p); ctx.fillPath(); ctx.restoreGState() }
        if k > 0 && !empty { clear(grow(body, s.lift < 1 ? 1.2 : 1.7)) }
        var faceFill: CGColor?
        if !empty {
            faceFill = s.accent ? rgb(Mark.fill(tone: 0.12, accent: look.orange)) : look.face
            let sideFill = s.accent ? rgb(Mark.fill(tone: -0.5, accent: look.orange)) : look.side
            ctx.addPath(side); ctx.setFillColor(sideFill); ctx.fillPath()
            ctx.addPath(face); ctx.setFillColor(faceFill!); ctx.fillPath()
            let ribs = hatch(side, angle: depthAngle, spacing: 1.55, inset: 0.3) { p in 0.94 * pow(max(0, sideWeight(face, p, d, night: look.night) - 0.28) / 0.72, 1.1) }
            let shade = hatch(face, angle: -32, spacing: 2.5, inset: 1.4, bow: 0.12) { q in 0.8 * pow(max(0, faceShade(q, bb) - 0.7) / 0.3, 1.4) }
            let edges = union([ribs, shade, body.copy(strokingWithWidth: 1.35, lineCap: .round, lineJoin: .round, miterLimit: 1),
                               face.copy(strokingWithWidth: 1.1, lineCap: .round, lineJoin: .round, miterLimit: 1)])
            ctx.addPath(edges); ctx.setFillColor(s.accent ? rgb(Mark.fill(tone: -0.85, accent: look.orange)) : look.ink); ctx.fillPath()
        }
        // On an orange face an orange mark would vanish, so it takes the mark's darkest orange.
        let markOrange = s.accent ? rgb(Mark.fill(tone: -0.8, accent: look.orange)) : rgb(look.orange)
        for (i, m) in s.marks.enumerated() {
            if i > 0 && !m.knock {
                if let faceFill { ctx.addPath(grow(m.path, 1.36)); ctx.setFillColor(faceFill); ctx.fillPath() } else { clear(grow(m.path, 1.36)) }
            }
            if m.knock {
                if let faceFill { ctx.addPath(m.path); ctx.setFillColor(faceFill); ctx.fillPath() } else { clear(m.path) }
                continue
            }
            ctx.addPath(m.path); ctx.setFillColor(m.accent ? markOrange : look.ink); ctx.fillPath()
        }
    }
}

// MARK: - The pictures

let body: CGFloat = 8.4, part: CGFloat = 3.2
let pictures: [(file: String, folder: String, slabs: [Slab])] = {
    let bars: [CGFloat] = [4, 9, 14, 8, 16, 11, 6, 12, 7, 3]
    var keyGrid: [CGPath] = []
    for r in 0..<2 { for c in 0..<5 {
        keyGrid.append(rect(6 + CGFloat(c) * 7.2, 20 + CGFloat(r) * 7.6, 5.2, 5.2, 1.4).copy(strokingWithWidth: 0.9, lineCap: .round, lineJoin: .round, miterLimit: 1))
    } }
    let leftGrid = union(keyGrid)
    let pointer = roundedPoly([P(40, 10), P(40, 62), P(52, 50), P(62, 70), P(70, 66), P(60, 46), P(76, 46)], [0, part, 1, part, part, 1, part])
    let document = rect(8, 5, 80, 60, body), front = rect(28, 20, 64, 46, body), route = rect(50, 17, 44, 36, body)
    let dots = union([circle(P(35, 34.5), 1.3), circle(P(39, 34.5), 1.3)])
    return [
        // General: Lodestar starts with your Mac. The Mac, and the star on its screen.
        ("place-general", "places", [
            Slab(face: rect(20, 3, 60, 40, 6)),
            raised(star(P(50, 22), 4, 10, 2.8)),
            Slab(face: rect(8, 52, 84, 9, 4.5), marks: [ink(stroke([P(42, 56.5), P(58, 56.5)], 1.6))])]),
        // Write: a page with one word marked.
        ("door-write", "doors", [Slab(face: document, marks: [
            ink(lines(16, [16, 26, 51], [62, 52, 40])), ink(lines(16, [35.5], [16])), ink(lines(37, [35.5], [22])), ink(lines(64, [35.5], [12])),
            lit(wave(36, 61, 42, 1.3, 4, 1.4))])]),
        // Switch: two windows, the front one wearing its hint key.
        ("door-switch", "doors", [
            Slab(face: rect(4, 4, 56, 40, body), marks: [ink(lines(4, [13], [56], 1)), ink(union([circle(P(10, 8.6), 1.5), circle(P(15, 8.6), 1.5), circle(P(20, 8.6), 1.5)]))]),
            Slab(face: front, marks: [ink(lines(28, [30], [64], 1)), ink(lines(35, [40, 48, 56], [26, 20, 24]))]),
            raised(rect(66, 38, 19, 19, 5.5), marks: [knock(grow(star(P(75.5, 47.5), 4, 6.5, 1.9), 1.6)), lit(star(P(75.5, 47.5), 4, 6.5, 1.9))])]),
        // Keep: what you copied, the newest card in front.
        ("door-keep", "doors", [
            Slab(face: rect(26, 3, 64, 38, body), marks: [ink(lines(50, [12], [30]))]),
            Slab(face: rect(8, 21, 64, 42, body), marks: [ink(lines(36, [32, 41, 50], [28, 22, 26]))]),
            raised(rect(15, 31, 15, 15, 4))]),
        // Speak: the pill, listening.
        ("door-speak", "doors", [
            Slab(face: rect(6, 22, 86, 28, 14), marks: [ink(union(bars.enumerated().map { i, h in stroke([P(38 + CGFloat(i) * 4.8, 36 - h / 2), P(38 + CGFloat(i) * 4.8, 36 + h / 2)], 2) }))]),
            raised(circle(P(21, 36), 8))]),
        // Operate: a key, and the pointer it moves.
        ("place-operate", "places", [
            Slab(face: rect(6, 24, 44, 42, 9), marks: [ink(stroke([P(20, 49), P(28, 40), P(36, 49)], 3))]),
            Slab(face: scaled(pointer, 0.7, 59 - 40 * 0.7, 18 - 10 * 0.7), accent: true)]),
        // Routing: a link, sent along to the window it belongs in.
        ("place-web", "places", [
            Slab(face: rect(56, 4, 40, 28, 6.4), marks: [ink(lines(56, [12], [40], 1))]),
            Slab(face: route, marks: [lit(meet(route, rect(50, 17, 44, 9))), ink(lines(57, [33, 40], [26, 18]))]),
            Slab(face: rect(2, 28, 28, 13, 6.5), marks: [ink(circle(P(9.5, 34.5), 2.1)), ink(stroke([P(15.5, 34.5), P(23, 34.5)], 2))]),
            loose([ink(dots), ink(head(P(41.5, 34.5), 0, 5, 7))])]),
        // Input: the keyboard in its two halves, the lode key under the thumb.
        ("place-keys", "places", [
            Slab(face: turn(rect(2, 15, 42, 34, body), P(23, 32), 6),
                 marks: [ink(turn(union([leftGrid, rect(26, 38, 12, 5.2, 1.4).copy(strokingWithWidth: 0.9, lineCap: .round, lineJoin: .round, miterLimit: 1)]), P(23, 32), 6))]),
            Slab(face: turn(rect(54, 15, 42, 34, body), P(75, 32), -6), marks: [ink(turn(moved(leftGrid, P(52, 0)), P(75, 32), -6))]),
            raised(turn(rect(57, 35.5, 18, 8, 3), P(75, 32), -6))]),
        // Wellbeing: a sprout, growing.
        ("place-observations", "places", [
            Slab(face: rect(31, 55, 38, 14, 7)),
            Slab(face: leaf(P(48, 45), P(8, 12), 13), marks: [ink(stroke([P(46, 43), P(18, 20)], 1.2))]),
            Slab(face: leaf(P(52, 39), P(93, 3), -14), accent: true),
            loose([ink(stroke([P(50, 54.5), P(50, 41)], 2.6))])]),
    ]
}()

// MARK: - Writing

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging")
let pixels = (w: 768, h: 576)
for picture in pictures {
    for look in [night, day] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: pixels.w, height: pixels.h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let scale = CGFloat(pixels.w) / 100
        ctx.translateBy(x: 0, y: CGFloat(pixels.h)); ctx.scaleBy(x: scale, y: -scale)
        draw(picture.slabs, look: look, in: ctx)
        let name = picture.file + (look.night ? "" : "-sand")
        let url = out.appendingPathComponent(picture.folder).appendingPathComponent(name + ".png")
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print(url.path)
    }
}
