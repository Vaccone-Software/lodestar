import Foundation

/// Lodestar's mark: a star with depth.
///
/// Twelve points raised from a dodecahedron's corners, turned so no point
/// faces the viewer, and drawn as flat planes of one color. It began as
/// Kepler's small stellated dodecahedron and was chosen as it was first
/// drawn: each point's base is five corners picked by the icosahedron's
/// directions in the other orientation, so the bases are not the
/// dodecahedron's faces, the points lean and overlap, and the star is open
/// in places, the ground showing through. That irregular, open star is the
/// mark (chosen 2026-09-25 over the closed solid, which read as an
/// ornament); `triangles()` keeps the construction exactly, so changing the
/// directions changes the mark. Each face takes its value only from
/// the way it faces the light: no gloss, no glow, no translucency, nothing
/// that imitates a material. Two faces that share an edge are always at
/// least `separation` apart in value, so every point reads as its own shape.
///
/// Everything that draws the mark (the app icon, the menu bar, the disk
/// image, the website) draws it from these faces, so they cannot drift. The
/// color is a parameter, never a constant: `scripts/make-icon.sh` renders the
/// icon and the site's assets in any color. This file depends on Foundation
/// alone so those scripts can compile it beside themselves.
public enum Mark {
    /// A point in the mark's square: x to the right, y downward, both
    /// within -1…1, centered on the visible star's bounds.
    public struct Point: Equatable, Sendable {
        public let x: Double, y: Double
    }

    /// One flat face, back to front in `faces`: its corners, and its value
    /// from -1 (deepest shadow) to 1 (full light).
    public struct Face: Equatable, Sendable {
        public let points: [Point]
        public let tone: Double
    }

    public struct RGB: Equatable, Sendable {
        public let red: Double, green: Double, blue: Double
        public init(red: Double, green: Double, blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }
        /// 0xRRGGBB.
        public init(hex: UInt32) {
            self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255)
        }
        /// "#FF4F00" or "FF4F00".
        public init?(hex text: String) {
            let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            self.init(hex: value)
        }
        public var hex: String {
            let byte = { (v: Double) in String(format: "%02X", Int((min(1, max(0, v)) * 255).rounded())) }
            return "#" + byte(red) + byte(green) + byte(blue)
        }
        /// Part of the way toward another color.
        public func mixed(with other: RGB, _ amount: Double) -> RGB {
            RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount)
        }
        public static let white = RGB(red: 1, green: 1, blue: 1)
        public static let black = RGB(red: 0, green: 0, blue: 0)
    }

    /// The color the mark ships in.
    public static let internationalOrange = RGB(hex: 0xFF4F00)

    /// The colors the mark can be rendered in by name: Lodestar's own, and
    /// the Mac's accent colors. A color the Mac adds later is rendered by
    /// hex; this list is a convenience, not a limit.
    public static let presets: [(name: String, color: RGB)] = [
        ("international-orange", internationalOrange),
        ("blue", RGB(hex: 0x007AFF)), ("purple", RGB(hex: 0xA550A7)), ("pink", RGB(hex: 0xF74F9E)),
        ("red", RGB(hex: 0xFF5257)), ("orange", RGB(hex: 0xF7821B)), ("yellow", RGB(hex: 0xFFC600)),
        ("green", RGB(hex: 0x62BA46)), ("graphite", RGB(hex: 0x8C8C8C)),
    ]

    // MARK: - The definition

    /// How far each point stands from the center, against the core's corners.
    public static let spike = 3.05
    /// The turn, in degrees about x, then y, then z.
    public static let turn = (x: 24.0, y: -18.0, z: 8.0)
    /// Where the light comes from: the top left, and toward the viewer.
    static let light = normalized([-0.55, -0.7, 0.9])
    /// The least difference in value between two faces that share an edge.
    public static let separation = 0.16

    // MARK: - Colors

    /// A face's color: the accent lifted toward white in light and lowered
    /// toward black in shadow.
    public static func fill(tone: Double, accent: RGB) -> RGB {
        let t = min(1, max(-1, tone))
        return t >= 0 ? accent.mixed(with: .white, t * 0.4) : accent.mixed(with: .black, -t * 0.44)
    }

    /// The icon's ground: charcoal carrying a little of the accent, top to
    /// bottom, so the icon reads as one piece in any color.
    public static func ground(accent: RGB) -> (top: RGB, bottom: RGB) {
        (RGB(hex: 0x2D2E33).mixed(with: accent, 0.14), RGB(hex: 0x121215).mixed(with: accent, 0.12))
    }

    // MARK: - The faces

    public static let faces: [Face] = build()

    private static func normalized(_ v: [Double]) -> [Double] {
        let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
        return v.map { $0 / l }
    }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
    private static func minus(_ a: [Double], _ b: [Double]) -> [Double] { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
    private static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }

    /// The twelve points: each point's base is the five corners nearest one
    /// of the icosahedron's directions (not the dodecahedron's faces; see the
    /// type's note), ordered around their center, each edge joined to a
    /// point raised over them.
    /// Each triangle with the center of its own point, which it faces away
    /// from. (Facing away from the star's center is not enough: on a solid
    /// this spiky one face lies almost across that test, and rounding
    /// decided which way it turned.)
    private static func triangles() -> [(corners: [[Double]], inside: [Double])] {
        let phi = (1 + 5.0.squareRoot()) / 2, ip = 1 / phi
        var corners: [[Double]] = []
        for x in [-1.0, 1] { for y in [-1.0, 1] { for z in [-1.0, 1] { corners.append([x, y, z]) } } }
        for a in [-1.0, 1] {
            for b in [-1.0, 1] {
                corners.append([0, a * ip, b * phi]); corners.append([a * ip, b * phi, 0]); corners.append([a * phi, 0, b * ip])
            }
        }
        var directions: [[Double]] = []
        for a in [-1.0, 1] {
            for b in [-1.0, 1] { directions.append([0, a, b * phi]); directions.append([a, b * phi, 0]); directions.append([a * phi, 0, b]) }
        }
        var tris: [(corners: [[Double]], inside: [Double])] = []
        for direction in directions {
            let n = normalized(direction)
            var face = corners.sorted { dot($0, n) > dot($1, n) }.prefix(5).map { $0 }
            let c = face.reduce([0.0, 0, 0]) { s, v in [s[0] + v[0] / 5, s[1] + v[1] / 5, s[2] + v[2] / 5] }
            let u = normalized(minus(face[0], c)), w = cross(n, u)
            let angle = { (v: [Double]) in atan2(dot(minus(v, c), w), dot(minus(v, c), u)) }
            face.sort { angle($0) < angle($1) }
            let apex = n.map { $0 * spike }
            // A point inside this spike: a quarter of the way from its base to its tip.
            let inside = (0..<3).map { c[$0] * 0.75 + apex[$0] * 0.25 }
            for i in 0..<5 { tris.append(([face[i], face[(i + 1) % 5], apex], inside)) }
        }
        return tris
    }

    private static func rotate(_ p: [Double]) -> [Double] {
        var (x, y, z) = (p[0], p[1], p[2])
        let a = turn.x * .pi / 180, b = turn.y * .pi / 180, g = turn.z * .pi / 180
        (y, z) = (y * cos(a) - z * sin(a), y * sin(a) + z * cos(a))
        (x, z) = (x * cos(b) + z * sin(b), -x * sin(b) + z * cos(b))
        (x, y) = (x * cos(g) - y * sin(g), x * sin(g) + y * cos(g))
        return [x, y, z]
    }

    private final class Working {
        let corners: [String], p: [[Double]], depth: Double, lambert: Double
        var tone: Double = 0
        init(corners: [String], p: [[Double]], depth: Double, lambert: Double) {
            self.corners = corners; self.p = p; self.depth = depth; self.lambert = lambert
        }
    }

    private static func build() -> [Face] {
        let key = { (v: [Double]) in v.map { String(format: "%.3f", $0) }.joined(separator: ",") }
        var shown: [Working] = []
        for tri in triangles() {
            let p = tri.corners.map(rotate)
            var n = normalized(cross(minus(p[1], p[0]), minus(p[2], p[0])))
            let centroid = (0..<3).map { i in (p[0][i] + p[1][i] + p[2][i]) / 3 }
            if dot(n, minus(centroid, rotate(tri.inside))) < 0 { n = n.map { -$0 } }
            // Only the faces turned toward the viewer are seen.
            guard n[2] > 0 else { continue }
            shown.append(Working(corners: tri.corners.map(key), p: p, depth: centroid[2], lambert: dot(n, light)))
        }

        // Spread the visible faces over the whole range, keeping their order,
        // so no two sit clipped together at one end.
        let lo = shown.map(\.lambert).min() ?? 0, hi = shown.map(\.lambert).max() ?? 1
        for face in shown { face.tone = -0.88 + (face.lambert - lo) / max(hi - lo, 1e-9) * 1.72 }

        // Then part every two neighbours that landed on nearly one value:
        // the brighter up, the darker down, a face at an end of the range
        // leaving the whole step to the other. Edges are walked in the order
        // they were found, so the result is the same on every run.
        var order: [String] = []
        var sharing: [String: [Working]] = [:]
        for face in shown {
            for k in 0..<3 {
                let a = face.corners[k], b = face.corners[(k + 1) % 3]
                let edge = a < b ? a + "|" + b : b + "|" + a
                if sharing[edge] == nil { order.append(edge) }
                sharing[edge, default: []].append(face)
            }
        }
        for _ in 0..<40 {
            for edge in order {
                guard let pair = sharing[edge], pair.count == 2 else { continue }
                let (a, b) = (pair[0], pair[1])
                let gap = abs(a.tone - b.tone)
                guard gap < separation else { continue }
                let up = a.lambert >= b.lambert ? a : b, down = up === a ? b : a
                let need = separation - gap
                var rise = min(need / 2, 1 - up.tone)
                let fall = min(need - rise, down.tone + 1)
                rise = min(need - fall, 1 - up.tone)
                up.tone += rise
                down.tone -= fall
            }
        }

        // Into the mark's square: centered on the visible bounds, the larger
        // half-extent at 1.
        let xs = shown.flatMap { $0.p.map { $0[0] } }, ys = shown.flatMap { $0.p.map { $0[1] } }
        let (x0, x1, y0, y1) = (xs.min() ?? -1, xs.max() ?? 1, ys.min() ?? -1, ys.max() ?? 1)
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, reach = max(x1 - x0, y1 - y0) / 2
        return shown.enumerated()
            .sorted { $0.element.depth == $1.element.depth ? $0.offset < $1.offset : $0.element.depth < $1.element.depth }
            .map { _, face in
                Face(points: face.p.map { Point(x: ($0[0] - cx) / reach, y: ($0[1] - cy) / reach) }, tone: face.tone)
            }
    }

    // MARK: - SVG

    /// The mark as SVG: its faces in `accent`, filling `size` with a margin,
    /// optionally on the icon's rounded ground. Used for the website's
    /// favicon and logo, and anywhere a vector is wanted.
    public static func svg(accent: RGB = internationalOrange, size: Double = 64, ground withGround: Bool = false) -> String {
        let f = { (v: Double) in String(format: "%.2f", v) }
        let center = size / 2, radius = size * (withGround ? 0.31 : 0.48)
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(f(size)) \(f(size))\">"
        if withGround {
            let g = ground(accent: accent)
            out += "<defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(g.top.hex)\"/>"
                + "<stop offset=\"1\" stop-color=\"\(g.bottom.hex)\"/></linearGradient></defs>"
                + "<rect width=\"\(f(size))\" height=\"\(f(size))\" rx=\"\(f(size * 0.225))\" fill=\"url(#g)\"/>"
        }
        for face in faces {
            let color = fill(tone: face.tone, accent: accent).hex
            let d = face.points.map { "\(f(center + $0.x * radius)),\(f(center + $0.y * radius))" }.joined(separator: " ")
            out += "<polygon points=\"\(d)\" fill=\"\(color)\" stroke=\"\(color)\" stroke-width=\"\(f(size / 1024))\" stroke-linejoin=\"round\"/>"
        }
        return out + "</svg>"
    }
}
