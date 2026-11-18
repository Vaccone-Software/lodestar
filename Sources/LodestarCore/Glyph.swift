import CoreGraphics
import Foundation

/// Lodestar's glyphs: every symbol it draws, in place of a symbol set.
///
/// Each is cut the way the mark is: flat planes, each taking its value only
/// from the way it faces the one light, which is above (design/04-material.md).
/// What points is drawn as one of the mark's own points, a long triangle
/// whose ridge leans off its axis so its two faces are never the same width;
/// every other stroke has its ends cut on one angle, across the light, the
/// way a broad nib is cut, so no end in the set is round. Each glyph keeps
/// the outline its convention has (a folder, a pin, a triangle that warns),
/// so it reads before it charms. The glaze (the planes' two strengths, the
/// rim along the top, the colours) is the app's to apply: this file holds
/// the shapes alone and depends on CoreGraphics and Foundation, so a script
/// can compile it beside itself and draw the same glyphs the app does.
///
/// A part marked `accent` is where the hand goes next (the click, the caret,
/// a correction, the way something moves, what is chosen) and wears the
/// accent; everything else is ink.
public enum Glyph: String, CaseIterable, Sendable {
    // The lenses, worn on the pill.
    case open, scroll, click, select, editor
    // The flashes: what kind of line it is.
    case refused, needsYou, breath, copied, done, layout, menuBarShown
    // Keep's actions.
    case pin, unpin, rename, edit, expand, save, showInFinder, moveHere, delete, neverSave
    // The bars' fields and cards.
    case web, addLink, route, remove, add, undo, profilePinned, profileUnpinned, chosen, notChosen, appsAndWindows, menus
    // A control: a value chosen from a list.
    case choose

    /// One flat plane: its outline in the glyph's 100-unit square (x to the
    /// right, y up), the value its facing gives it in the light (0 turned
    /// away … 1 facing it), and what it is.
    public struct Plane: Sendable {
        public let points: [CGPoint]
        public let value: CGFloat
        /// Wears the accent rather than the ink.
        public let accent: Bool
        /// Taken out of what is beneath it: the glyph's ground shows through.
        public let cut: Bool
    }

    /// The glyph's planes, in drawing order.
    public var planes: [Plane] {
        pieces.flatMap { piece in
            piece.facets().map { Plane(points: $0.points, value: $0.value, accent: piece.accent, cut: piece.cut) }
        }
    }

    /// Whether any part of it wears the accent.
    public var hasAccent: Bool { pieces.contains { $0.accent && !$0.cut } }

    /// How far a glyph's pieces may reach past its 100-unit square: a cut
    /// end or a point's tip. Whatever draws a glyph keeps this margin round
    /// the square, so nothing is clipped.
    public static let margin: CGFloat = 4

    /// The one light: from above, a little to the left of straight up, so a
    /// vertical stroke still shows two faces.
    public static let light = CGPoint(x: -0.25, y: 0.97).normalised
}

// MARK: - The pieces each glyph is cut from

extension Glyph {
    var pieces: [Piece] {
        switch self {
        case .open:
            // The mark's four long points, as the pill wears the mark while
            // an app is opening (DESIGN.md, the last surfaces).
            return [point(P(50, 50), P(50, 97), 12), point(P(50, 50), P(97, 50), 12, lean: -0.3),
                    point(P(50, 50), P(50, 3), 12), point(P(50, 50), P(3, 50), 12, lean: -0.3)]
        case .scroll:
            return [stroke([P(50, 40), P(50, 60)], 9, start: false, end: false),
                    point(P(50, 56), P(50, 97), 21, lean: 0.35), point(P(50, 44), P(50, 3), 21, lean: -0.35)]
        case .click:
            return [gem([P(40, 84), P(40, 24), P(80, 42)], P(51, 50)), stroke([P(60, 38), P(69, 14)], 11, start: false),
                    stroke([P(30, 84), P(16, 84)], 6, accent: true), stroke([P(33, 93), P(25, 100)], 6, accent: true),
                    stroke([P(30, 74), P(19, 67)], 6, accent: true)]
        case .select:
            return [stroke([P(8, 16), P(28, 82), P(48, 16)], 11), stroke([P(17, 40), P(39, 40)], 8, start: false, end: false)] + Self.ibeam
        case .rename:
            return [stroke([P(8, 50), P(54, 50)], 13)] + Self.ibeam
        case .editor:
            // Lines of text with a proofreader's caret under the gap where a
            // word is wanted: the editor's correction, not a tick.
            return [stroke([P(8, 76), P(92, 76)], 10), stroke([P(8, 54), P(38, 54)], 10), stroke([P(60, 54), P(92, 54)], 10),
                    stroke([P(8, 32), P(70, 32)], 10), point(P(49, 36), P(49, 62), 9, accent: true)]
        case .refused:
            return [stroke([P(16, 16), P(84, 84)], 12), stroke([P(16, 84), P(84, 16)], 12)]
        case .needsYou:
            return [gem([P(50, 96), P(4, 10), P(96, 10)], P(50, 40), P(50, 40), accent: true)] + Self.bang(top: 72)
        case .breath:
            // A breath is a saved layout: its panes, standing.
            return [slab(6, 8, 50, 92), slab(58, 54, 94, 92), slab(58, 8, 94, 46)]
        case .copied:
            return [stroke([P(34, 78), P(34, 94), P(90, 94), P(90, 30), P(74, 30)], 7),
                    gem([P(8, 6), P(66, 6), P(66, 56), P(50, 72), P(8, 72)], P(22, 38), P(50, 38)),
                    stroke([P(48, 74), P(48, 54), P(68, 54)], 4, start: false, end: false, cut: true)]
        case .done:
            return [stroke([P(10, 52), P(38, 22), P(88, 76)], 13)]
        case .layout:
            return [slab(6, 54, 46, 92), slab(54, 54, 94, 92), slab(6, 8, 46, 46), slab(54, 8, 94, 46)]
        case .menuBarShown:
            return [stroke([P(10, 78), P(90, 78)], 10), stroke([P(10, 50), P(90, 50)], 10), stroke([P(10, 22), P(90, 22)], 10)]
        case .pin:
            return Self.pushpin.rotated(35)
        case .unpin:
            // The pin as it stands, struck through across its own axis.
            return Self.pushpin.rotated(35) + [stroke([P(17, 27), P(83, 73)], 16, cut: true), stroke([P(20, 29), P(80, 71)], 7)]
        case .edit:
            return [stroke([P(48, 80), P(10, 80), P(10, 10), P(80, 10), P(80, 48)], 8),
                    stroke([P(48, 42), P(86, 80)], 13, start: false), point(P(49, 43), P(32, 26), 6.5)]
        case .expand:
            return [stroke([P(46, 54), P(30, 70)], 9, end: false), point(P(32, 68), P(6, 94), 13),
                    stroke([P(54, 46), P(70, 30)], 9, end: false), point(P(68, 32), P(94, 6), 13)]
        case .save:
            return [stroke([P(10, 42), P(10, 10), P(90, 10), P(90, 42)], 9), stroke([P(50, 94), P(50, 54)], 9, end: false),
                    point(P(50, 56), P(50, 22), 16)]
        case .showInFinder:
            // A folder open: its back, a seam, and the flap falling forward.
            return [gem([P(6, 10), P(6, 84), P(38, 84), P(46, 74), P(86, 74), P(86, 10)], P(26, 44), P(66, 44)),
                    stroke([P(16, 59), P(98, 59)], 5, cut: true), gem([P(6, 10), P(84, 10), P(96, 57), P(18, 57)], P(28, 33), P(78, 33))]
        case .moveHere:
            return [pane(44, 6, 94, 94, 7), stroke([P(6, 50), P(44, 50)], 9, end: false), point(P(40, 50), P(72, 50), 15, accent: true)]
        case .delete:
            // The bin with its lid lifted.
            let lid = [stroke([P(14, 74), P(86, 74)], 9), stroke([P(38, 76), P(41, 86), P(59, 86), P(62, 76)], 7, start: false, end: false)]
            return lid.rotated(12, about: P(14, 74)) + [
                gem([P(22, 64), P(78, 64), P(70, 4), P(30, 4)], P(50, 52), P(50, 16)),
                stroke([P(39, 52), P(41, 16)], 4, start: false, end: false, cut: true),
                stroke([P(61, 52), P(59, 16)], 4, start: false, end: false, cut: true)]
        case .neverSave:
            return [gem(circle(P(50, 50), 46, n: 8, from: 22.5, to: 382.5).dropLast(), P(46, 56)), stroke([P(26, 50), P(74, 50)], 13, cut: true)]
        case .web:
            return [ring(P(50, 50), 42, 7), ring(P(50, 50), 17, 6, ry: 42), stroke([P(9, 50), P(91, 50)], 6, start: false, end: false)]
        case .addLink:
            return [capsule(4, 54, 50, 15, 8), capsule(36, 86, 50, 15, 8)].rotated(35, about: P(45, 40)) + Self.plusBadge
        case .route:
            return [stroke([P(50, 6), P(50, 46)], 9, end: false), stroke([P(50, 46), P(26, 70)], 9, start: false, end: false),
                    point(P(28, 68), P(8, 94), 12), stroke([P(50, 46), P(74, 70)], 9, start: false, end: false),
                    point(P(72, 68), P(92, 94), 12, accent: true)]
        case .remove:
            return [ring(P(50, 50), 42, 8), stroke([P(28, 50), P(72, 50)], 10)]
        case .add:
            return [ring(P(50, 50), 42, 8), stroke([P(50, 26), P(50, 74)], 10), stroke([P(26, 50), P(74, 50)], 10)]
        case .profilePinned:
            return disc(P(50, 50), 47, accent: true) + person(scale: 0.72, cut: true)
        case .profileUnpinned:
            return (0..<8).map { i in stroke(circle(P(50, 50), 44, n: 4, from: CGFloat(i) * 45 + 8, to: CGFloat(i) * 45 + 36), 6) }
                + person(scale: 0.62)
        case .chosen:
            return [gem([P(50, 98), P(98, 50), P(50, 2), P(2, 50)], P(44, 56), accent: true),
                    stroke([P(28, 50), P(44, 34), P(74, 64)], 10, cut: true)]
        case .notChosen:
            return [stroke(closed([P(50, 94), P(94, 50), P(50, 6), P(6, 50)]), 8, start: false, end: false)]
        case .undo:
            // An arc turning back on itself, anticlockwise, its head one of
            // the mark's points: the earlier value, put back.
            let arc = circle(P(50, 48), 36, n: 24, from: 150, to: 422)
            let end = arc[arc.count - 1], turn = CGFloat(422) * .pi / 180
            return [stroke(arc, 9, end: false), point(end, end + P(-sin(turn), cos(turn)) * 30, 15, accent: true)]
        case .appsAndWindows:
            // The lens holds the mark and its handle is one of the mark's
            // points: what is looked for is Lodestar's. In ink, because the
            // field's caret is its one orange.
            let centre = P(42, 58)
            return [ring(centre, 30, 9), point(P(62, 38), P(97, 3), 11),
                    point(centre, P(42, 73), 5.5), point(centre, P(57, 58), 5.5, lean: -0.3),
                    point(centre, P(42, 43), 5.5), point(centre, P(27, 58), 5.5, lean: -0.3)]
        case .menus:
            return [pane(6, 8, 94, 92, 7), slab(6, 72, 94, 92)]
        case .choose:
            return [point(P(50, 58), P(50, 96), 20), point(P(50, 42), P(50, 4), 20, lean: -0.3)]
        }
    }

    private static let ibeam: [Piece] = [
        stroke([P(72, 18), P(72, 82)], 8, start: false, end: false, accent: true),
        stroke([P(59, 85), P(85, 85)], 8, accent: true), stroke([P(59, 15), P(85, 15)], 8, accent: true),
    ]
    private static let pushpin: [Piece] = [
        gem([P(32, 96), P(68, 96), P(62, 82), P(38, 82)], P(42, 89), P(58, 89)),
        gem([P(40, 82), P(60, 82), P(64, 54), P(36, 54)], P(50, 76), P(50, 60)),
        gem([P(22, 54), P(78, 54), P(70, 42), P(30, 42)], P(36, 48), P(64, 48)),
        point(P(50, 43), P(50, 1), 7.5),
    ]
    private static let plusBadge: [Piece] = [stroke([P(82, 98), P(82, 70)], 8, accent: true), stroke([P(68, 84), P(96, 84)], 8, accent: true)]
    private static func bang(top: CGFloat) -> [Piece] {
        [stroke([P(50, top), P(50, top - 30)], 10, cut: true),
         gem([P(44, top - 43), P(50, top - 37), P(56, top - 43), P(50, top - 51)], P(50, top - 44), cut: true)]
    }
}

// MARK: - The hand's tools

struct Piece {
    enum Shape {
        /// A band along a line, ridged down its middle; each end cut across
        /// the light unless it meets something (`start`/`end` false: square).
        case stroke([CGPoint], width: CGFloat, start: Bool, end: Bool)
        /// A solid outline whose planes rise to a ridge from `a` to `b`
        /// (equal: an apex), so each side is one plane.
        case gem([CGPoint], a: CGPoint, b: CGPoint)
        /// A solid of two planes creased across the light.
        case flat([CGPoint], normal: CGPoint)
    }
    var shape: Shape
    var accent = false
    var cut = false

    func facets() -> [(points: [CGPoint], value: CGFloat)] {
        switch shape {
        case let .stroke(line, w, start, end): return Self.stroke(line, w, start: start, end: end)
        case let .gem(poly, a, b): return Self.gem(poly, a, b)
        case let .flat(poly, n): return [(poly, n.lit)]
        }
    }

    func map(_ f: (CGPoint) -> CGPoint) -> Piece {
        var out = self
        switch shape {
        case let .stroke(line, w, s, e): out.shape = .stroke(line.map(f), width: w, start: s, end: e)
        case let .gem(poly, a, b): out.shape = .gem(poly.map(f), a: f(a), b: f(b))
        case let .flat(poly, n): out.shape = .flat(poly.map(f), normal: n)
        }
        return out
    }

    private static func gem(_ poly: [CGPoint], _ a: CGPoint, _ b: CGPoint) -> [(points: [CGPoint], value: CGFloat)] {
        var area: CGFloat = 0
        for i in poly.indices { let p = poly[i], q = poly[(i + 1) % poly.count]; area += p.x * q.y - q.x * p.y }
        let ab = b - a, len2 = max(ab.dot(ab), 1e-6)
        func onRidge(_ p: CGPoint) -> CGPoint { a + ab * min(max((p - a).dot(ab) / len2, 0), 1) }
        return poly.indices.map { i in
            let p = poly[i], q = poly[(i + 1) % poly.count], d = q - p
            let outward = area > 0 ? CGPoint(x: d.y, y: -d.x) : CGPoint(x: -d.y, y: d.x)
            return ([p, q, onRidge(q), onRidge(p)], outward.lit)
        }
    }

    private static func stroke(_ line: [CGPoint], _ w: CGFloat, start: Bool, end: Bool) -> [(points: [CGPoint], value: CGFloat)] {
        let n = line.count
        let normals = (0..<(n - 1)).map { k in (line[k + 1] - line[k]).normalised.left }
        var left: [CGPoint] = [], right: [CGPoint] = [], mid = line
        for k in 0..<n {
            let a = normals[max(k - 1, 0)], b = normals[min(k, n - 2)]
            let m = (a + b).normalised, miter = min(1 / max(m.dot(b), 0.5), 2)
            left.append(line[k] + m * (w / 2 * miter))
            right.append(line[k] - m * (w / 2 * miter))
        }
        // An end is cut across the light: every terminal in the set leans one way.
        func cut(_ k: Int, _ dir: CGPoint) {
            let across = Glyph.light.right, edge = line[k] + dir * (w * 0.32)
            let denom = dir.cross(across)
            // A stroke running along the cut ends square instead.
            guard abs(denom) > 0.3 else {
                let past = dir * (w * 0.32)
                left[k] = left[k] + past; right[k] = right[k] + past; mid[k] = edge
                return
            }
            func onCut(_ s: CGPoint) -> CGPoint { s + dir * min(max((edge - s).cross(across) / denom, -w * 0.2), w * 1.1) }
            left[k] = onCut(left[k]); right[k] = onCut(right[k]); mid[k] = onCut(line[k])
        }
        if start { cut(0, (line[0] - line[1]).normalised) }
        if end { cut(n - 1, (line[n - 1] - line[n - 2]).normalised) }
        return (0..<(n - 1)).flatMap { k in
            [([mid[k], mid[k + 1], left[k + 1], left[k]], normals[k].lit),
             ([mid[k], mid[k + 1], right[k + 1], right[k]], (normals[k] * -1).lit)]
        }
    }
}

private func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func stroke(_ line: [CGPoint], _ w: CGFloat, start: Bool = true, end: Bool = true, accent: Bool = false, cut: Bool = false) -> Piece {
    Piece(shape: .stroke(line, width: w, start: start, end: end), accent: accent, cut: cut)
}
private func gem<C: Collection>(_ poly: C, _ a: CGPoint, _ b: CGPoint? = nil, accent: Bool = false, cut: Bool = false) -> Piece where C.Element == CGPoint {
    Piece(shape: .gem(Array(poly), a: a, b: b ?? a), accent: accent, cut: cut)
}
/// One point of the mark: a long triangle whose ridge leans off its axis.
private func point(_ base: CGPoint, _ tip: CGPoint, _ halfWidth: CGFloat, lean: CGFloat = 0.3, accent: Bool = false) -> Piece {
    let d = (tip - base).normalised, n = d.left
    return gem([base + n * halfWidth, tip, base - n * halfWidth], base + n * (halfWidth * lean) + d * 2, tip, accent: accent)
}
private func circle(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat? = nil, n: Int = 28, from a0: CGFloat = 0, to a1: CGFloat = 360) -> [CGPoint] {
    (0...n).map { k in
        let a = (a0 + (a1 - a0) * CGFloat(k) / CGFloat(n)) * .pi / 180
        return P(c.x + cos(a) * rx, c.y + sin(a) * (ry ?? rx))
    }
}
/// A closed line: it runs past its start, so the seam has a neighbour each side.
private func closed(_ pts: [CGPoint]) -> [CGPoint] { pts + [pts[0], pts[1]] }
private func ring(_ c: CGPoint, _ r: CGFloat, _ w: CGFloat, ry: CGFloat? = nil) -> Piece {
    stroke(closed(Array(circle(c, r, ry).dropLast())), w, start: false, end: false)
}
/// A disc of two planes creased across the light: the upper lit, the lower turned away.
private func disc(_ c: CGPoint, _ r: CGFloat, accent: Bool = false) -> [Piece] {
    [Piece(shape: .flat(circle(c, r, n: 20, from: -8, to: 172), normal: P(-0.1, 1)), accent: accent),
     Piece(shape: .flat(circle(c, r, n: 20, from: 172, to: 352), normal: P(0.15, -1)), accent: accent)]
}
private func slab(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Piece {
    let w = x1 - x0, h = y1 - y0, poly = [P(x0, y0), P(x1, y0), P(x1, y1), P(x0, y1)]
    return w >= h ? gem(poly, P(x0 + h / 2, y0 + h / 2), P(x1 - h / 2, y0 + h / 2))
        : gem(poly, P(x0 + w / 2, y0 + w / 2), P(x0 + w / 2, y1 - w / 2))
}
/// A pane's outline, its corners cut rather than rounded.
private func pane(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ w: CGFloat, corner c: CGFloat = 7) -> Piece {
    stroke(closed([P(x0 + c, y0), P(x1 - c, y0), P(x1, y0 + c), P(x1, y1 - c), P(x1 - c, y1), P(x0 + c, y1), P(x0, y1 - c), P(x0, y0 + c)]),
           w, start: false, end: false)
}
private func capsule(_ x0: CGFloat, _ x1: CGFloat, _ yc: CGFloat, _ r: CGFloat, _ w: CGFloat) -> Piece {
    stroke(closed(circle(P(x1 - r, yc), r, n: 10, from: -90, to: 90) + circle(P(x0 + r, yc), r, n: 10, from: 90, to: 270)),
           w, start: false, end: false)
}
private func person(scale s: CGFloat, cut: Bool = false) -> [Piece] {
    [gem(circle(P(50, 50 + 18 * s), 15 * s, n: 10, from: 15, to: 375).dropLast(), P(48, 50 + 21 * s), cut: cut),
     gem(circle(P(50, 50 - 34 * s), 32 * s, 30 * s, n: 10, from: 0, to: 180), P(48, 50 - 20 * s), cut: cut)]
}

private extension Array where Element == Piece {
    func rotated(_ degrees: CGFloat, about c: CGPoint = CGPoint(x: 50, y: 50)) -> [Piece] {
        let a = degrees * .pi / 180
        return map { $0.map { p in let d = p - c; return CGPoint(x: c.x + d.x * cos(a) - d.y * sin(a), y: c.y + d.x * sin(a) + d.y * cos(a)) } }
    }
}

// MARK: - Points as vectors

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    func dot(_ b: CGPoint) -> CGFloat { x * b.x + y * b.y }
    func cross(_ b: CGPoint) -> CGFloat { x * b.y - y * b.x }
    /// Turned a quarter to the left, and to the right.
    var left: CGPoint { CGPoint(x: -y, y: x) }
    var right: CGPoint { CGPoint(x: y, y: -x) }
}

extension CGPoint {
    var normalised: CGPoint { let l = max(hypot(x, y), 1e-6); return CGPoint(x: x / l, y: y / l) }
    /// The value a plane facing this way takes in the light: 0 … 1.
    var lit: CGFloat { 0.5 + 0.5 * (normalised.x * Glyph.light.x + normalised.y * Glyph.light.y) }
}
