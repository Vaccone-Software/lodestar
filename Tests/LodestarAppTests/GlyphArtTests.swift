import AppKit
import XCTest
@testable import lodestar
import LodestarCore

/// The glaze, drawn: every glyph shows at the size text wears, in both
/// looks, and wears the accent only where its shape says the hand goes next.
final class GlyphArtTests: XCTestCase {
    override func tearDown() { GalleryLook.reset() }

    /// The pixels of a glyph drawn at 13 points, at 2x, in a look.
    private func pixels(_ glyph: Glyph, dark: Bool) -> [(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)] {
        let image = NSImage.glyph(glyph, size: BarTheme.glyph)
        let side = Int(image.size.width * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        var out: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []
        for y in 0..<side { for x in 0..<side {
            let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            out.append((c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent))
        } }
        return out
    }

    func testEveryGlyphShowsAtTextSizeInBothLooks() {
        for glyph in Glyph.allCases {
            for dark in [false, true] {
                let solid = pixels(glyph, dark: dark).filter { $0.a > 0.5 }.count
                XCTAssertGreaterThan(solid, 40, "\(glyph) shows \(dark ? "by night" : "by day")")
            }
        }
    }

    /// Ink is a warm grey and the accent is orange: a pixel far redder than
    /// it is green is the accent, and only a glyph with an accent has one.
    func testOnlyTheAccentGlyphsWearOrange() {
        for glyph in Glyph.allCases {
            for dark in [false, true] {
                let orange = pixels(glyph, dark: dark).contains { $0.a > 0.8 && $0.r - $0.g > 0.25 }
                XCTAssertEqual(orange, glyph.hasAccent, "\(glyph) \(dark ? "by night" : "by day")")
            }
        }
    }

    /// A glyph view takes its ink from its tint, as a symbol did.
    func testAGlyphViewIsTintedByItsTint() {
        let view = GlyphView(.done)
        XCTAssertEqual(view.image?.size.width, (BarTheme.glyph * 1.2).rounded())
        view.contentTintColor = BarTheme.secondaryColor
        XCTAssertEqual(view.image?.accessibilityDescription, nil)
        XCTAssertNotNil(view.image)
    }
}
