import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/01-colour.md, "Prototype lessons": a text field that sets no
/// colour falls back to the system's label colour, which is pure black or
/// pure white. The drift test reads the sources; this one reads the
/// surfaces: every picture of the gallery is built in each look and every
/// word on it must be in a colour of the palette's family, never a grey.
final class TextInkTests: XCTestCase {
    override func tearDown() { GalleryLook.reset() }

    /// A grey has no colour at all: its three channels agree. Every step of
    /// the palette, ink and quiet ink included, leans warm by at least a
    /// few levels of 255.
    private func isGrey(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return true }
        return max(c.redComponent, c.greenComponent, c.blueComponent)
            - min(c.redComponent, c.greenComponent, c.blueComponent) < 0.004
    }

    /// Where a view's words are drawn in a grey, each with its text.
    private func greyWords(in root: NSView) -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty, !field.isHidden {
                var colours: [NSColor] = []
                let attributed = field.attributedStringValue
                attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                    colours.append((value as? NSColor) ?? field.textColor ?? BarTheme.ink)
                }
                var grey = false
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    grey = colours.contains { isGrey($0) }
                }
                if grey { found.append(field.stringValue) }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    func testNoWordOnAnySurfaceIsInTheSystemsGrey() throws {
        var offenders: [String] = []
        var checked = 0
        for picture in GallerySweep.pictures() {
            let shot = picture.shot, look = picture.look, view = picture.root
            // The colour sheets and the type sheet paint by drawing, not by fields.
            checked += 1
            let words = greyWords(in: view)
            if !words.isEmpty { offenders.append("\(shot.name(in: look)): \(Set(words).sorted().prefix(4))") }
        }
        XCTAssertGreaterThan(checked, 100, "the gallery's surfaces were built")
        GallerySweep.expectNone(offenders, "no word is in the system's grey: set the ink, BarTheme.label, or a textColor from the theme")
    }
}
