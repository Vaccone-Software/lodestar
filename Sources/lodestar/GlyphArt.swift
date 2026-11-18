import AppKit
import LodestarCore

/// Lodestar's glyphs, glazed. The shapes are `Glyph`'s (LodestarCore); this
/// applies the glaze in the look of the view that draws them: each plane in
/// the tint at one of two strengths by the way it faces the light, the rim
/// along the top that the material contract gives every surface (the shape
/// less itself moved down, design/04-material.md), and the accent on the
/// parts where the hand goes next. Every colour comes from the theme, and
/// shading leans toward the palette's own lightest and darkest steps, as a
/// lit key's does, so nothing is drawn translucent.
enum GlyphArt {
    /// How far down the rim's shape is moved, in the glyph's 100-unit square:
    /// a point and a little at the sizes text wears.
    static let rimDepth: CGFloat = 8
    /// How much heavier the cut is than the drawing, in the same units: at
    /// the sizes text wears a glyph must weigh what the medium words beside
    /// it weigh, as Woodsmoke's text-size cut does.
    static let weight: CGFloat = 4

    static func draw(_ glyph: Glyph, in rect: NSRect, tint: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let planes = glyph.planes

        func colour(_ plane: Glyph.Plane) -> CGColor {
            let base = plane.accent ? BarTheme.accent : tint
            guard plane.value >= 0.5 else {
                return base.blended(withFraction: 0.32, of: dark ? BarTheme.darkest : BarTheme.lightest)?.cgColor ?? base.cgColor
            }
            // By night the rim is the brightest the ink may be, so the faces
            // beneath it step down a little to let it read.
            return (dark ? base.blended(withFraction: 0.12, of: BarTheme.darkest) : base)?.cgColor ?? base.cgColor
        }
        func rim(_ plane: Glyph.Plane) -> CGColor {
            let base = plane.accent ? BarTheme.accent : tint
            return (dark ? base : base.blended(withFraction: 0.4, of: BarTheme.lightest))?.cgColor ?? base.cgColor
        }
        func fill(_ planes: [Glyph.Plane], dy: CGFloat = 0, erase: Bool = false, honourCuts: Bool = true, _ colour: (Glyph.Plane) -> CGColor) {
            for plane in planes where honourCuts || !plane.cut {
                context.setBlendMode(plane.cut || erase ? .destinationOut : .normal)
                // Erasing reads only the alpha, so any opaque colour of the theme does.
                let ink = plane.cut || erase ? Ceramic.resolved(BarTheme.ink) : colour(plane)
                context.setFillColor(ink)
                context.setStrokeColor(ink)
                context.setLineWidth(weight)
                context.setLineJoin(.round)
                let path = CGMutablePath()
                path.addLines(between: plane.points.map { CGPoint(x: $0.x, y: $0.y + dy) })
                path.closeSubpath()
                context.addPath(path)
                context.drawPath(using: .fillStroke)
            }
            context.setBlendMode(.normal)
        }

        context.saveGState()
        // The square and its margin fill the rect, so a tip is never clipped.
        let span = 100 + Glyph.margin * 2
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / span, y: rect.height / span)
        context.translateBy(x: Glyph.margin, y: Glyph.margin)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        fill(planes, colour)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        fill(planes, rim)
        fill(planes, dy: -rimDepth, erase: true, honourCuts: false) { _ in Ceramic.resolved(BarTheme.ink) }
        context.endTransparencyLayer()
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

extension NSImage {
    /// A glyph at a text size: a square a fifth larger than the size, as a
    /// symbol at that size stands. Drawn each time it is shown, so it takes
    /// the look and the tint of the moment.
    static func glyph(_ glyph: Glyph, size: CGFloat, description: String? = nil,
                      tint: @escaping () -> NSColor = { BarTheme.ink }) -> NSImage {
        let side = (size * 1.2).rounded()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            GlyphArt.draw(glyph, in: rect, tint: tint())
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = description
        return image
    }
}

/// A glyph in a view, tinted the way a symbol was: `contentTintColor` is
/// its ink.
final class GlyphView: NSImageView {
    var glyph: Glyph { didSet { refresh() } }
    let size: CGFloat
    let label: String?

    init(_ glyph: Glyph, size: CGFloat = BarTheme.glyph, description: String? = nil) {
        self.glyph = glyph
        self.size = size
        self.label = description
        super.init(frame: .zero)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlyphView is made in code") }

    override var contentTintColor: NSColor? { didSet { refresh() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func refresh() {
        image = NSImage.glyph(glyph, size: size, description: label) { [weak self] in
            self?.contentTintColor ?? BarTheme.ink
        }
    }
}
