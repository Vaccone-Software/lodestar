import AppKit
import LodestarCore

/// Lodestar's glyphs, engraved as the pictures are. The shapes and their
/// engraving are `Glyph`'s (LodestarCore); this paints them in the look of
/// the view that draws them: each face in the key's colour with its edge in
/// the tint, the side it stands on in the key's side (engraved when the glyph
/// is large enough to hold it, a flat tone standing for the engraving when it
/// is not), and orange on the parts where the hand goes next. Every colour
/// comes from the theme, and nothing is drawn translucent.
enum GlyphArt {
    static func draw(_ glyph: Glyph, in rect: NSRect, tint: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let appearance = NSAppearance.currentDrawing()
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let steps = BarTheme.steps(for: appearance)
        let engraving = glyph.engraving(side: rect.width, night: dark)
        let accent = BarTheme.accent
        // Too small for its engraving, a side takes the tone its lines would have given it.
        let side = engraving.hatched ? steps.side.color : steps.side.color.blended(withFraction: dark ? 0.22 : 0.3, of: tint) ?? steps.side.color
        func colour(_ paint: Engraving.Paint) -> CGColor {
            switch paint {
            case .clear, .ink: return tint.cgColor
            case .face: return steps.key.color.cgColor
            case .side: return side.cgColor
            case .accentFace, .accent: return accent.cgColor
            case .accentSide: return (accent.blended(withFraction: 0.3, of: BarTheme.darkest) ?? accent).cgColor
            case .accentInk: return (accent.blended(withFraction: 0.45, of: BarTheme.darkest) ?? accent).cgColor
            }
        }
        context.saveGState()
        // The square and its margin fill the rect, so nothing is clipped.
        let span = 100 + Glyph.margin * 2
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / span, y: rect.height / span)
        context.translateBy(x: Glyph.margin, y: Glyph.margin)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for layer in engraving.layers {
            // A clearance takes what is behind out, so parts stand apart on any ground.
            context.setBlendMode(layer.paint == .clear ? .destinationOut : .normal)
            context.setFillColor(colour(layer.paint))
            context.addPath(layer.path)
            context.fillPath()
        }
        context.setBlendMode(.normal)
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
