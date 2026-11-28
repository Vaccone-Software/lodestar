import CoreGraphics
import Foundation
import Synchronization

/// Lodestar's glyphs: every symbol it draws, in place of a symbol set.
///
/// Each is made of the same things the pictures of the places and doors are
/// (tools/pictures): rounded slabs of Lodestar's own objects, seen a little
/// from above, so a glyph is a picture with all but its idea taken away. A
/// slab is its face and the side it stands on (design/04-material.md: depth
/// is a visible side); the face takes the full light and the side is turned
/// from it. Corners round on the ladder (design/03-geometry.md); only a point
/// that aims (an arrow's head, the pointer's tip, the mark's points) stays
/// sharp. What is drawn on a face is cut through it, so it reads at the sizes
/// text wears, and a part stands wholly on a face or clear of it, never
/// across an edge. Each glyph keeps the outline its convention has (a bin, a
/// folder, a triangle that warns), so it reads before it charms.
///
/// This file holds the shapes alone and depends on CoreGraphics and
/// Foundation, so a script can compile it beside itself and draw the same
/// glyphs the app does; the glaze (the two strengths, the rim, the colours)
/// is GlyphArt's.
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
    public var planes: [Plane] { Self.carved[self] ?? [] }

    /// Whether any part of it wears the accent.
    public var hasAccent: Bool { planes.contains { $0.accent && !$0.cut } }

    /// How far a glyph's planes may reach past its 100-unit square. Whatever
    /// draws a glyph keeps this margin round the square, so nothing is clipped.
    public static let margin: CGFloat = 4

    /// The one light: from above, a little to the left of straight up.
    public static let light = CGPoint(x: -0.25, y: 0.97).normalised

    /// Every glyph carved once: the shapes are fixed, so the work of cutting
    /// them is done the first time any is drawn.
    private static let carved: [Glyph: [Plane]] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, Carving.planes($0.slabs)) })
}

// MARK: - What a glyph is made of

/// A slab: a face, the side it stands on, and what is drawn on the face.
private struct Slab {
    let face: CGPath
    var accent = false
    var marks: [Detail] = []
    /// How far it stands: a part mounted on a face stands a little proud of it.
    var lift: CGFloat = 1
}

/// Something drawn on a slab's face: cut through it, or, where it wears the
/// accent on an ink face, set in it with a clearance round it. On a slab
/// with no face (a stem, a ray) it is drawn as it is.
private struct Detail {
    let path: CGPath
    var accent = false
}

private func slab(_ face: CGPath, accent: Bool = false, _ marks: [Detail] = []) -> Slab { Slab(face: face, accent: accent, marks: marks) }
private func raised(_ face: CGPath, accent: Bool = false, _ marks: [Detail] = []) -> Slab { Slab(face: face, accent: accent, marks: marks, lift: 0.4) }
private func loose(_ marks: [Detail]) -> Slab { Slab(face: CGMutablePath(), marks: marks) }
private func mark(_ path: CGPath, accent: Bool = false) -> Detail { Detail(path: path, accent: accent) }

// MARK: - The drawings (y down in this section, as they were drawn)

private let body: CGFloat = 8.4, part: CGFloat = 3.2

extension Glyph {
    fileprivate var slabs: [Slab] {
        switch self {
        case .open:
            // The mark's four long points, as the pill wears the mark while an app opens.
            return [slab(star(P(50, 48), 44, 12))]
        case .scroll:
            return [slab(union([stroke([P(50, 26), P(50, 74)], 11), head(P(50, 28), -90, 22, 40), head(P(50, 72), 90, 22, 40)]))]
        case .click:
            // The pointer, and three short rays from its tip: the click.
            let tip = P(58, 18)
            return [slab(scaled(pointer, 1.25, 8, 5.5), accent: true),
                    loose([mark(union([180, 222, 264].map { a in stroke([pt(tip, 12, CGFloat(a)), pt(tip, 22, CGFloat(a))], 8) }))])]
        case .select:
            // Words chosen: the highlight with its line cut through, and the
            // I-beam at its end, the caret, where the hand is.
            return [slab(rect(4, 22, 64, 44, 9), [mark(stroke([P(16, 44), P(56, 44)], 9))]),
                    slab(union([stroke([P(84, 12), P(84, 76)], 9), stroke([P(74, 12), P(94, 12)], 8), stroke([P(74, 76), P(94, 76)], 8)]), accent: true)]
        case .editor:
            // Lines of text with a proofreader's caret under the gap where a
            // word is wanted: the editor's correction, not a tick.
            return [slab(rect(6, 4, 88, 62, body), [mark(thick(20, [22], [60], 9)), mark(thick(20, [45], [18], 9)), mark(thick(54, [45], [26], 9))]),
                    slab(strokeP(11) { p in p.addLines(between: [P(32, 97), P(46, 80), P(60, 97)]) }, accent: true)]
        case .refused:
            return [slab(union([ring(P(50, 48), 44, 12), turn(rect(14, 42, 72, 12, 6), P(50, 48), 45)]))]
        case .needsYou:
            return [slab(roundedPoly([P(50, 6), P(96, 88), P(4, 88)], [10, 8, 8]), accent: true,
                         [mark(union([stroke([P(50, 34), P(50, 57)], 9), circle(P(50, 72), 5.5)]))])]
        case .breath:
            // A breath is a saved layout: its panes, standing.
            return [slab(rect(6, 8, 50, 82, body)), slab(rect(64, 8, 30, 82, body))]
        case .copied:
            return [slab(rect(30, 4, 62, 62, body)), slab(rect(8, 28, 62, 62, body))]
        case .done:
            return [slab(strokeP(17) { p in p.addLines(between: [P(10, 52), P(36, 78), P(90, 18)]) })]
        case .layout:
            return [slab(rect(4, 10, 92, 78, body), [mark(stroke([P(46, 4), P(46, 94)], 7, cap: .butt)), mark(stroke([P(46, 48), P(100, 48)], 7, cap: .butt))])]
        case .menuBarShown:
            return [slab(rect(4, 12, 92, 78, body), [mark(stroke([P(0, 31), P(100, 31)], 7, cap: .butt))])]
        case .pin:
            return [slab(pushpin)]
        case .unpin:
            // The pin as it stands, struck through across its own axis.
            let strike = turn(rect(-2, 44.5, 104, 11, 5.5), P(50, 50), 45)
            return [slab(cut(pushpin, [grow(strike, 5)])), slab(strike)]
        case .rename:
            return [slab(rect(4, 26, 92, 46, 12), [mark(thick(16, [49], [34]))]), raised(rect(62, 32, 8, 34, 4), accent: true)]
        case .edit:
            // A pencil: its body, and the sharpened tip just apart from it.
            return [slab(turn(rect(37, 40, 57, 20, 5), P(50, 50), -45)),
                    slab(turn(roundedPoly([P(36, 40), P(36, 60), P(10, 50)], [2, 2, 0]), P(50, 50), -45))]
        case .expand:
            return [slab(union([stroke([P(58, 42), P(78, 22)], 10), head(P(76, 24), -45, 18, 30)])),
                    slab(union([stroke([P(42, 58), P(22, 78)], 10), head(P(24, 76), 135, 18, 30)]))]
        case .save:
            return [slab(union([stroke([P(50, 4), P(50, 38)], 11), head(P(50, 36), 90, 18, 34)])),
                    slab(strokeP(10) { p in p.addLines(between: [P(8, 62), P(8, 88), P(92, 88), P(92, 62)]) })]
        case .showInFinder:
            // A folder open: its back, and the flap falling forward.
            return [slab(roundedPoly([P(4, 12), P(38, 12), P(48, 22), P(94, 22), P(94, 88), P(4, 88)], [6, 4, 4, 6, body, body])),
                    slab(roundedPoly([P(18, 42), P(98, 42), P(86, 88), P(4, 88)], [5, 5, body, body]))]
        case .moveHere:
            return [slab(strokeP(10) { p in p.addLines(between: [P(58, 12), P(92, 12), P(92, 88), P(58, 88)]) }),
                    slab(union([stroke([P(4, 50), P(46, 50)], 11), head(P(44, 50), 0, 18, 32)]), accent: true)]
        case .delete:
            // The bin with its lid lifted.
            return [slab(roundedPoly([P(16, 34), P(84, 34), P(77, 96), P(23, 96)], [part, part, body, body]),
                         [mark(union([stroke([P(40, 48), P(40, 82)], 7), stroke([P(60, 48), P(60, 82)], 7)]))]),
                    slab(union([rect(6, 14, 88, 11, 5.5), rect(36, 4, 28, 14, 6)]))]
        case .neverSave:
            return [slab(strokeP(10) { p in p.addLines(between: [P(8, 68), P(8, 92), P(92, 92), P(92, 68)]) }),
                    slab(union([ring(P(50, 30), 26, 9), turn(rect(26, 25.5, 48, 9, 4.5), P(50, 30), 45)]))]
        case .web:
            // The globe: a ball with its meridian and equator drawn on it.
            let meridian = CGPath(ellipseIn: CGRect(x: 31, y: 5, width: 38, height: 90), transform: nil)
                .copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 1)
            return [slab(circle(P(50, 50), 45), [mark(union([meridian, stroke([P(4, 50), P(96, 50)], 7, cap: .butt)]))])]
        case .addLink:
            // A link, added: two links of a chain, one through the other, and the plus that adds.
            return [slab(chain), slab(plus(P(86, 14), 11, 9), accent: true)]
        case .route:
            // One way in, two ways on, the one taken in the accent.
            return [slab(union([stroke([P(50, 96), P(50, 62)], 10), stroke([P(50, 64), P(24, 38)], 10), head(P(26, 40), -135, 22, 34)])),
                    slab(union([stroke([P(58, 56), P(76, 38)], 10), head(P(74, 40), -45, 22, 34)]), accent: true)]
        case .remove:
            return [slab(circle(P(50, 48), 42), [mark(stroke([P(28, 48), P(72, 48)], 10))])]
        case .add:
            return [slab(circle(P(50, 48), 42), [mark(plus(P(50, 48), 22, 10))])]
        case .undo:
            // An arc turning back on itself, anticlockwise, its head the way
            // back: the earlier value, put back.
            return [slab(strokeP(13) { p in p.move(to: P(40, 30)); p.addLine(to: P(58, 30)); p.addArc(center: P(58, 56), radius: 26, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false); p.addLine(to: P(26, 82)) }),
                    slab(roundedPoly([P(4, 30), P(38, 8), P(38, 52)], [0, 3, 3]), accent: true)]
        case .profilePinned:
            return [slab(personHead), slab(personBody), raised(circle(P(84, 16), 11), accent: true)]
        case .profileUnpinned:
            return [slab(personHead), slab(personBody)]
        case .chosen:
            return [slab(ring(P(50, 48), 42, 12)), raised(circle(P(50, 48), 18), accent: true)]
        case .notChosen:
            return [slab(ring(P(50, 48), 42, 12))]
        case .appsAndWindows:
            // The lens holds the mark: what is looked for is Lodestar's. In
            // ink, because the field's caret is its one orange.
            return [slab(ring(P(40, 40), 34, 11)), slab(stroke([P(66, 66), P(92, 92)], 14)), slab(star(P(40, 40), 17, 5))]
        case .menus:
            // The menu bar with a menu dropped from it.
            return [slab(rect(4, 4, 92, 16, 8)),
                    slab(rect(14, 28, 58, 68, body), [mark(thick(25, [44, 61, 78], [36, 28, 32]))])]
        case .choose:
            // The arrows a popup wears beside its value: up and down.
            return [slab(roundedPoly([P(30, 43), P(50, 10), P(70, 43)], [3, 3, 3])),
                    slab(roundedPoly([P(30, 57), P(70, 57), P(50, 90)], [3, 3, 3]))]
        }
    }
}

private var pointer: CGPath { roundedPoly([P(40, 10), P(40, 62), P(52, 50), P(62, 70), P(70, 66), P(60, 46), P(76, 46)], [0, part, 1, part, part, 1, part]) }
/// The globe, open: a ring, one meridian and the equator, so it reads as the web, not a ball.
private func globe(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    let w: CGFloat = 9
    let meridian = CGPath(ellipseIn: CGRect(x: c.x - r * 0.42, y: c.y - r + w / 2, width: r * 0.84, height: r * 2 - w), transform: nil)
        .copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1)
    return union([ring(c, r, w), meridian, stroke([P(c.x - r + 2, c.y), P(c.x + r - 2, c.y)], w, cap: .butt)])
}
/// Two links of a chain, interlocked: each passes over the other at one
/// crossing and under it at the other, cut by a thin gap where it goes under.
private var chain: CGPath {
    let a = chainLink(P(26, 74)), b = chainLink(P(52, 48))
    let upperLeft = poly([P(-20, -20), P(120, -20), P(-20, 120)]), lowerRight = poly([P(120, -20), P(120, 120), P(-20, 120)])
    return union([cut(a, [grow(b, 2.5).intersection(upperLeft, using: .winding)]),
                  cut(b, [grow(a, 2.5).intersection(lowerRight, using: .winding)])])
}
/// One link of a chain, on the diagonal.
private func chainLink(_ c: CGPoint) -> CGPath {
    turn(rect(c.x - 24, c.y - 14, 48, 28, 14), c, -45).copy(strokingWithWidth: 8, lineCap: .round, lineJoin: .round, miterLimit: 1)
}
/// A pushpin, leaning: its cap, its body, the collar, and the point that aims.
private var pushpin: CGPath {
    turn(union([rect(30, 4, 40, 13, 6.5), roundedPoly([P(39, 16), P(61, 16), P(60, 44), P(40, 44)], [2, 2, 2, 2]), rect(22, 42, 56, 12, 6),
                roundedPoly([P(45, 52), P(55, 52), P(50, 98)], [1, 1, 0])]), P(50, 50), 35)
}
private var personHead: CGPath { circle(P(44, 30), 18) }
private var personBody: CGPath { roundedPoly([P(14, 92), P(16, 64), P(34, 54), P(58, 54), P(76, 64), P(78, 92)], [4, 14, 10, 10, 14, 4]) }

// MARK: - Carving: slabs into planes

private enum Carving {
    /// The one viewpoint, as the pictures': every side stands this far down
    /// and to the right of its face.
    static let depth = CGPoint(x: 1.8, y: 6)
    /// The values a face and a side take: one faces the light, one is turned from it.
    static let faceValue: CGFloat = 0.9, sideValue: CGFloat = 0.25
    /// The clearance round a part, so neighbours never touch.
    static let clearance: CGFloat = 3

    static func planes(_ slabs: [Slab]) -> [Glyph.Plane] {
        var out: [(points: [CGPoint], value: CGFloat, accent: Bool, cut: Bool)] = []
        func add(_ path: CGPath, value: CGFloat = faceValue, accent: Bool = false, cut: Bool = false, holes: Bool = true) {
            for (points, hole) in regions(path) where holes || !hole {
                out.append((points, value, accent, cut || hole))
            }
        }
        for (k, s) in slabs.enumerated() {
            let face = s.face.normalized(using: .winding)
            guard !face.isEmpty else {
                for m in s.marks { add(m.path, accent: m.accent) }
                continue
            }
            let d = CGPoint(x: depth.x * s.lift, y: depth.y * s.lift)
            let body = sweep(face, d), side = body.subtracting(face, using: .winding)
            if k > 0 { add(grow(body, clearance), cut: true, holes: false) }
            // The side first, so the face covers it; then the face's holes go through both.
            add(side, value: sideValue, accent: s.accent, holes: false)
            add(face, accent: s.accent)
            for m in s.marks {
                if m.accent && !s.accent {
                    add(grow(m.path, clearance), cut: true, holes: false)
                    add(m.path, accent: true)
                } else {
                    // Cut through the face; where the mark is itself open (a
                    // ring, a meridian), the face inside it stays.
                    for (points, hole) in regions(m.path) {
                        out.append((points, faceValue, s.accent, !hole))
                    }
                }
            }
        }
        // Into the square, y up, fitted inside the margin if a drawing reaches past it.
        let all = out.flatMap(\.points)
        let lo = CGPoint(x: all.map(\.x).min() ?? 0, y: all.map(\.y).min() ?? 0)
        let hi = CGPoint(x: all.map(\.x).max() ?? 100, y: all.map(\.y).max() ?? 100)
        let reach = max(50 - lo.x, hi.x - 50, 50 - lo.y, hi.y - 50)
        let fit = min(1, (50 + Glyph.margin / 2) / reach)
        return out.map { plane in
            Glyph.Plane(points: plane.points.map { CGPoint(x: 50 + ($0.x - 50) * fit, y: 50 - ($0.y - 50) * fit) },
                        value: plane.value, accent: plane.accent, cut: plane.cut)
        }
    }

    /// The face swept along the depth: the face and its side together.
    static func sweep(_ face: CGPath, _ d: CGPoint) -> CGPath {
        union((0...10).map { k -> CGPath in
            var t = CGAffineTransform(translationX: d.x * CGFloat(k) / 10, y: d.y * CGFloat(k) / 10)
            return face.copy(using: &t)!
        })
    }

    /// A region's outlines as polygons, each marked a hole when it lies
    /// inside an odd number of the others, outermost first.
    static func regions(_ path: CGPath) -> [(points: [CGPoint], hole: Bool)] {
        let loops = polygons(path.normalized(using: .winding))
        let depths = loops.map { loop in loops.filter { other in other != loop && inside(loop[0], other) }.count }
        return zip(loops, depths).sorted { $0.1 < $1.1 }.map { ($0.0, $0.1 % 2 == 1) }
    }

    /// A path's subpaths as polygons, its curves followed in short steps.
    static func polygons(_ path: CGPath) -> [[CGPoint]] {
        var out: [[CGPoint]] = [], current: [CGPoint] = [], last = CGPoint.zero
        func close() { if current.count > 2 { out.append(current) }; current = [] }
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: close(); current = [p[0]]; last = p[0]
            case .addLineToPoint: current.append(p[0]); last = p[0]
            case .addQuadCurveToPoint:
                for i in 1...6 {
                    let t = CGFloat(i) / 6, u = 1 - t
                    current.append(CGPoint(x: u * u * last.x + 2 * u * t * p[0].x + t * t * p[1].x,
                                           y: u * u * last.y + 2 * u * t * p[0].y + t * t * p[1].y))
                }
                last = p[1]
            case .addCurveToPoint:
                for i in 1...8 {
                    let t = CGFloat(i) / 8, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, e = t * t * t
                    current.append(CGPoint(x: a * last.x + b * p[0].x + c * p[1].x + e * p[2].x,
                                           y: a * last.y + b * p[0].y + c * p[1].y + e * p[2].y))
                }
                last = p[2]
            case .closeSubpath: close()
            @unknown default: break
            }
        }
        close()
        return out
    }

    static func inside(_ p: CGPoint, _ loop: [CGPoint]) -> Bool {
        var result = false, j = loop.count - 1
        for i in loop.indices {
            let a = loop[i], b = loop[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
            j = i
        }
        return result
    }
}

// MARK: - The engraving: the pictures' finish, at any size

/// A glyph drawn the way the pictures are (tools/pictures): each slab's face
/// in the key's colour with an ink edge, the side it stands on below and to
/// the right, and what is drawn on a face in ink on it. Large enough to hold
/// it, the side is engraved along its depth, each stretch as dark as its edge
/// is turned from the light, and the face takes a little hatched shade at its
/// far corner; smaller than that the hatching would be finer than a pixel, so
/// the side is one flat tone instead. Lines never draw thinner than a point,
/// so a glyph at the size text wears keeps its edges. Paths are in the glyph's
/// 100-unit square, y up, as the planes are.
public struct Engraving: Sendable {
    /// What a layer is painted with; the colours are the drawer's.
    public enum Paint: Sendable { case clear, face, side, ink, accentFace, accentSide, accentInk, accent }
    /// One painted shape, kept as its outlines (curves followed in short
    /// steps, holes wound the other way) so an engraving is plain values that
    /// any thread may hold; filled with the non-zero rule.
    public struct Layer: Sendable {
        public let outlines: [[CGPoint]]
        public let paint: Paint
        public var path: CGPath {
            let path = CGMutablePath()
            for outline in outlines { path.addLines(between: outline); path.closeSubpath() }
            return path
        }
    }
    public let layers: [Layer]
    /// Whether the sides carry their engraving, or a flat tone in its place.
    public let hatched: Bool
}

extension Glyph {
    /// The smallest square, in points, whose side holds the engraving.
    public static let hatchedFrom: CGFloat = 40

    /// The glyph engraved for a square `side` points across, in one look.
    public func engraving(side: CGFloat, night: Bool) -> Engraving {
        let key = "\(rawValue) \(Int(side.rounded())) \(night)"
        if let made = Self.engravings.withLock({ $0[key] }) { return made }
        let made = Engraver.engrave(slabs, side: side, night: night)
        Self.engravings.withLock { $0[key] = made }
        return made
    }

    /// Every engraving made so far, by glyph, size and look: the shapes are
    /// fixed, so each is cut once.
    private static let engravings = Mutex<[String: Engraving]>([:])
}

private enum Engraver {
    static let depth = CGPoint(x: 1.8, y: 5.5)
    static let towardLight = CGPoint(x: -0.55, y: -0.7).normalised

    static func engrave(_ slabs: [Slab], side: CGFloat, night: Bool) -> Engraving {
        // Units per point: the square and its margin fill the side.
        let k = (100 + Glyph.margin * 2) / max(side, 1)
        let hatched = side >= Glyph.hatchedFrom
        var out: [(path: CGPath, paint: Engraving.Paint)] = []
        func add(_ path: CGPath, _ paint: Engraving.Paint) { if !path.isEmpty { out.append((path, paint)) } }
        var bodies: [CGPath] = []
        for (n, s) in slabs.enumerated() {
            let d = CGPoint(x: depth.x * s.lift, y: depth.y * s.lift)
            let face = s.face.normalized(using: .winding)
            guard !face.isEmpty else {
                for m in s.marks { add(m.path, m.accent ? .accent : .ink) }
                continue
            }
            let body = sweep(face, d), sideShape = body.subtracting(face, using: .winding)
            bodies.append(body)
            if n > 0 { add(grow(body, max(s.lift < 1 ? 1.2 : 1.7, 0.9 * k)), .clear) }
            add(sideShape, s.accent ? .accentSide : .side)
            add(face, s.accent ? .accentFace : .face)
            var lines: [CGPath] = [body.copy(strokingWithWidth: max(1.35, 1.0 * k), lineCap: .round, lineJoin: .round, miterLimit: 1),
                                   face.copy(strokingWithWidth: max(1.1, 0.8 * k), lineCap: .round, lineJoin: .round, miterLimit: 1)]
            if hatched {
                let lift = s.lift
                lines.append(hatch(sideShape, angle: atan2(depth.y, depth.x) * 180 / .pi, spacing: 1.55, inset: 0.3) { p in
                    0.94 * pow(max(0, sideWeight(face, p, d, night: night) - 0.28) / 0.72, 1.1) * (lift < 1 ? 0.8 : 1)
                })
                let bb = face.boundingBox
                lines.append(hatch(face, angle: -32, spacing: 2.5, inset: 1.4, bow: 0.12) { q in
                    let t = max(0, min(1, (q.x - bb.minX) / bb.width * 0.55 + (q.y - bb.minY) / bb.height * 0.55))
                    return 0.8 * pow(max(0, t - 0.7) / 0.3, 1.4)
                })
            }
            add(union(lines), s.accent ? .accentInk : .ink)
            // What is drawn on a face stays on it: clipped to the face, never across its edge.
            for m in s.marks {
                add(m.path.intersection(face, using: .winding), s.accent ? .accentInk : (m.accent ? .accent : .ink))
            }
        }
        // Into the square, y up, fitted inside the margin.
        let reach: CGFloat = {
            let boxes = (bodies.isEmpty ? out.map(\.path) : bodies + out.filter { $0.paint == .ink || $0.paint == .accent }.map(\.path)).map(\.boundingBox)
            guard let first = boxes.first else { return 50 }
            let b = boxes.dropFirst().reduce(first) { $0.union($1) }
            return max(50 - b.minX, b.maxX - 50, 50 - b.minY, b.maxY - 50)
        }()
        let fit = min(1, (50 + Glyph.margin / 2) / reach)
        var t = CGAffineTransform(translationX: 50, y: 50).scaledBy(x: fit, y: -fit).translatedBy(x: -50, y: -50)
        return Engraving(layers: out.map { .init(outlines: Carving.polygons($0.path.copy(using: &t)!), paint: $0.paint) }, hatched: hatched)
    }

    static func sweep(_ face: CGPath, _ d: CGPoint) -> CGPath {
        union((0...10).map { n -> CGPath in
            var t = CGAffineTransform(translationX: d.x * CGFloat(n) / 10, y: d.y * CGFloat(n) / 10)
            return face.copy(using: &t)!
        })
    }

    /// Which way the face's edge faces at a point just outside it.
    static func outward(_ shape: CGPath, _ q: CGPoint) -> CGPoint {
        var n = CGPoint.zero
        for i in 0..<16 {
            let a = CGFloat(i) / 16 * 2 * .pi, d = CGPoint(x: cos(a), y: sin(a))
            if !shape.contains(CGPoint(x: q.x + d.x * 2, y: q.y + d.y * 2), using: .winding) { n.x += d.x; n.y += d.y }
        }
        let l = hypot(n.x, n.y); return l > 0 ? CGPoint(x: n.x / l, y: n.y / l) : CGPoint(x: 0, y: 1)
    }

    /// How heavily a point on a side is engraved: walk back along the depth to
    /// the face's edge, and ask which way that edge faces the light. At night
    /// the lines carry light, so the weight runs the other way.
    static func sideWeight(_ face: CGPath, _ p: CGPoint, _ d: CGPoint, night: Bool) -> CGFloat {
        var q = p
        for n in 0...14 {
            let c = CGPoint(x: p.x - d.x * CGFloat(n) / 14, y: p.y - d.y * CGFloat(n) / 14)
            if face.contains(c, using: .winding) { break }
            q = c
        }
        let n = outward(face, q), away = max(0, -(n.x * towardLight.x + n.y * towardLight.y))
        let t = 0.3 + 0.62 * away
        return night ? 0.8 - t * 0.42 : t
    }

    /// Parallel lines across `shape`, each swelling to `width(p)` and tapering
    /// to a point at both ends, kept `inset` clear of the edge; `bow` bends
    /// them round the form.
    static func hatch(_ shape: CGPath, angle: CGFloat, spacing: CGFloat, inset: CGFloat, bow: CGFloat = 0, width: (CGPoint) -> CGFloat) -> CGPath {
        let out = CGMutablePath(), bb = shape.boundingBox.insetBy(dx: -2, dy: -2)
        let keepOut = shape.copy(strokingWithWidth: inset * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        let d = CGPoint(x: cos(angle * .pi / 180), y: sin(angle * .pi / 180)), n = CGPoint(x: -d.y, y: d.x)
        let c = CGPoint(x: bb.midX, y: bb.midY), R = hypot(bb.width, bb.height) / 2, step: CGFloat = 0.5
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
                    left.append(CGPoint(x: p.x + n.x * w, y: p.y + n.y * w)); right.append(CGPoint(x: p.x - n.x * w, y: p.y - n.y * w))
                }
                out.addLines(between: left + right.reversed()); out.closeSubpath()
            }
            var s = -R
            while s <= R {
                let b = bow * (1 - min(1, (s / R) * (s / R))) * R
                let p = CGPoint(x: c.x + n.x * (k + b) + d.x * s, y: c.y + n.y * (k + b) + d.y * s)
                if shape.contains(p, using: .winding) && !keepOut.contains(p, using: .winding) { run.append(p) } else if !run.isEmpty { flush() }
                s += step
            }
            if !run.isEmpty { flush() }
            k += spacing
        }
        return out
    }
}

// MARK: - Shapes

private func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
private func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil) }
private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 0) -> CGPath {
    let k = min(r, w / 2 - 0.01, h / 2 - 0.01)
    return CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: k, cornerHeight: k, transform: nil)
}
private func poly(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p }
/// A polygon whose corners round by `radii`; 0 keeps a corner that aims sharp.
private func roundedPoly(_ pts: [CGPoint], _ radii: [CGFloat]) -> CGPath {
    let p = CGMutablePath(), n = pts.count
    p.move(to: P((pts[n - 1].x + pts[0].x) / 2, (pts[n - 1].y + pts[0].y) / 2))
    for i in 0..<n { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: radii[i]) }
    p.closeSubpath(); return p
}
private func stroke(_ pts: [CGPoint], _ w: CGFloat, cap: CGLineCap = .round) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts)
    return p.copy(strokingWithWidth: w, lineCap: cap, lineJoin: .round, miterLimit: 4)
}
private func strokeP(_ w: CGFloat, _ build: (CGMutablePath) -> Void) -> CGPath {
    let p = CGMutablePath(); build(p); return p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4)
}
private func pt(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint { P(c.x + r * cos(a * .pi / 180), c.y + r * sin(a * .pi / 180)) }
/// An arrowhead: base centred on `b`, aimed at `deg`.
private func head(_ b: CGPoint, _ deg: CGFloat, _ len: CGFloat, _ w: CGFloat) -> CGPath {
    let d = P(cos(deg * .pi / 180), sin(deg * .pi / 180)), n = P(-d.y, d.x)
    return roundedPoly([P(b.x + d.x * len, b.y + d.y * len), P(b.x + n.x * w / 2, b.y + n.y * w / 2), P(b.x - n.x * w / 2, b.y - n.y * w / 2)], [0.6, 2, 2])
}
/// The mark's four long points.
private func star(_ c: CGPoint, _ R: CGFloat, _ r: CGFloat) -> CGPath {
    poly((0..<8).map { i in pt(c, i % 2 == 0 ? R : r, -90 + CGFloat(i) * 45) })
}
private func ring(_ c: CGPoint, _ r: CGFloat, _ w: CGFloat) -> CGPath { circle(c, r).subtracting(circle(c, r - w), using: .winding) }
private func plus(_ c: CGPoint, _ s: CGFloat, _ w: CGFloat) -> CGPath { union([rect(c.x - s, c.y - w / 2, s * 2, w, w / 2), rect(c.x - w / 2, c.y - s, w, s * 2, w / 2)]) }
/// Lines of text: one stroke per line, `x` from the left, as long as each width.
private func thick(_ x: CGFloat, _ ys: [CGFloat], _ ws: [CGFloat], _ w: CGFloat = 7) -> CGPath { union(zip(ys, ws).map { y, l in stroke([P(x, y), P(x + l, y)], w) }) }
private func turn(_ p: CGPath, _ c: CGPoint, _ deg: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: deg * .pi / 180).translatedBy(x: -c.x, y: -c.y); return p.copy(using: &t)!
}
private func scaled(_ p: CGPath, _ s: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> CGPath {
    var t = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: dx, ty: dy); return p.copy(using: &t)!
}
private func grow(_ p: CGPath, _ w: CGFloat) -> CGPath { p.copy(strokingWithWidth: w * 2, lineCap: .round, lineJoin: .round, miterLimit: 1).union(p, using: .winding) }
private func union(_ ps: [CGPath]) -> CGPath { ps.dropFirst().reduce(ps[0]) { $0.union($1, using: .winding) } }
private func cut(_ a: CGPath, _ bs: [CGPath]) -> CGPath { bs.reduce(a) { $0.subtracting($1, using: .winding) } }

extension CGPoint {
    var normalised: CGPoint { let l = max(hypot(x, y), 1e-6); return CGPoint(x: x / l, y: y / l) }
}
