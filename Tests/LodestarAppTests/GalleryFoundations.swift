import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The foundations drawn from the code that decides them: every colour of
/// the palette and of the theme with its hex and lightness, the text pairs
/// that matter with their measured contrast, and every font the theme
/// defines. Nothing here is typed in as a value; a change to Palette.swift
/// or BarTheme changes the picture.
enum GalleryFoundations {
    // MARK: - Measuring

    static func hex(_ color: Readability.RGB) -> String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }

    /// OKLab lightness, the measure Palette.swift's steps are spaced by.
    static func lightness(_ color: Readability.RGB) -> Double {
        ColorNames.oklab(red: color.red, green: color.green, blue: color.blue).l
    }

    static func ratio(_ a: Readability.RGB, _ b: Readability.RGB) -> Double {
        Readability.contrast(a.luminance, b.luminance)
    }

    /// A colour as the look draws it: resolved in `appearance`, and laid
    /// over `background` when it is not opaque (ink at 85 per cent, a key's
    /// white at 8), which is the colour the eye gets.
    static func resolved(_ color: NSColor, over background: Readability.RGB,
                         in appearance: NSAppearance) -> Readability.RGB {
        var out = background
        appearance.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            let a = Double(c.alphaComponent)
            out = Readability.RGB(red: Double(c.redComponent) * a + background.red * (1 - a),
                                  green: Double(c.greenComponent) * a + background.green * (1 - a),
                                  blue: Double(c.blueComponent) * a + background.blue * (1 - a))
        }
        return out
    }

    // MARK: - The sheet

    /// A view that paints by a closure and is flipped, so a sheet is laid
    /// down the page from its top.
    final class Sheet: NSView {
        var paint: (NSRect) -> Void = { _ in }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { paint(bounds) }
    }

    /// Lays a sheet down a page, top to bottom; run once to measure and once to draw.
    struct Page {
        let width: CGFloat
        let draws: Bool
        var y: CGFloat = 28
        let margin: CGFloat = 28

        static var ink: NSColor { .labelColor }

        func text(_ string: String, at point: NSPoint, font: NSFont = BarTheme.secondaryFont,
                  color: NSColor = BarTheme.secondaryColor) {
            guard draws else { return }
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
        }

        func fill(_ rect: NSRect, _ color: Readability.RGB, radius: CGFloat = BarTheme.controlRadius,
                  edge: Bool = true) {
            guard draws else { return }
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            color.color.setFill()
            path.fill()
            guard edge else { return }
            BarTheme.hairline.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        mutating func heading(_ title: String, _ detail: String? = nil) {
            text(title, at: NSPoint(x: margin, y: y), font: BarTheme.roomTitleFont, color: Self.ink)
            y += 28
            if let detail {
                text(detail, at: NSPoint(x: margin, y: y))
                y += 22
            }
            y += 6
        }

        /// Swatches in rows of `perRow`: the colour, its name, its hex and
        /// its OKLab lightness.
        mutating func swatches(_ items: [(name: String, color: Readability.RGB, note: String?)], perRow: Int = 5) {
            let cell = (width - margin * 2) / CGFloat(perRow)
            for (index, item) in items.enumerated() {
                let column = CGFloat(index % perRow)
                let origin = NSPoint(x: margin + column * cell, y: y)
                fill(NSRect(x: origin.x, y: origin.y, width: cell - 14, height: 44), item.color)
                text(item.name, at: NSPoint(x: origin.x, y: origin.y + 50), color: Self.ink)
                text("\(GalleryFoundations.hex(item.color))  L \(String(format: "%.3f", GalleryFoundations.lightness(item.color)))",
                     at: NSPoint(x: origin.x, y: origin.y + 68), font: BarTheme.metaMono)
                if let note = item.note { text(note, at: NSPoint(x: origin.x, y: origin.y + 86)) }
                if index % perRow == perRow - 1 || index == items.count - 1 { y += item.note == nil ? 98 : 116 }
            }
            y += 8
        }

        /// One measured pair: the colours as a sample, what they are, the
        /// ratio, and the floor it is held to.
        mutating func pair(_ name: String, foreground: Readability.RGB, background: Readability.RGB, floor: Double) {
            let measured = GalleryFoundations.ratio(foreground, background)
            fill(NSRect(x: margin, y: y, width: 74, height: 26), background)
            text("Aa 12", at: NSPoint(x: margin + 8, y: y + 4), font: BarTheme.bodyFont,
                 color: NSColor(srgbRed: foreground.red, green: foreground.green, blue: foreground.blue, alpha: 1))
            text(name, at: NSPoint(x: margin + 92, y: y + 4), color: Self.ink)
            text(String(format: "%.2f : 1", measured), at: NSPoint(x: width - margin - 250, y: y + 4),
                 font: BarTheme.metaMono, color: Self.ink)
            text(measured >= floor ? "meets \(floor == floor.rounded() ? String(Int(floor)) : String(floor)) : 1"
                                   : "under \(floor == floor.rounded() ? String(Int(floor)) : String(floor)) : 1",
                 at: NSPoint(x: width - margin - 120, y: y + 4))
            y += 32
        }
    }

    /// A window of `look` holding a sheet that paints `body`, sized by a
    /// dry run of it.
    static func sheet(look: GalleryLook, width: CGFloat,
                      _ body: @escaping (inout Page, NSAppearance) -> Void) -> (NSWindow, [AnyObject]) {
        let appearance = NSAppearance(named: look.appearance)!
        var measure = Page(width: width, draws: false)
        body(&measure, appearance)
        let size = NSSize(width: width, height: measure.y + 20)
        let view = Sheet(frame: NSRect(origin: .zero, size: size))
        view.paint = { bounds in
            BarTheme.palette.pane.color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: BarTheme.surfaceRadius, yRadius: BarTheme.surfaceRadius).fill()
            var page = Page(width: width, draws: true)
            body(&page, appearance)
        }
        let window = GalleryHost.window(view, size: size, look: look)
        return (window, [window, view])
    }

    // MARK: - Colour

    static func colour(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        sheet(look: look, width: 1040) { page, appearance in
            let palette = BarTheme.palette
            let pane = palette.pane
            func themed(_ color: NSColor, over background: Readability.RGB = pane) -> Readability.RGB {
                resolved(color, over: background, in: appearance)
            }
            let accent = themed(BarTheme.accent, over: pane)
            let ink = themed(.labelColor)
            let secondary = themed(BarTheme.secondaryColor)
            page.heading("Colour · \(look.name)",
                         "Drawn from Palette.swift and BarTheme in the \(look.name) look. The look's pane is the sheet's own ground.")

            page.heading("Palette steps", "Palette.night, Palette.clay: ground behind everything, pane a surface is made of, raised a chosen thing stands on.")
            func steps(_ name: String, _ s: Palette.Steps) -> [(String, Readability.RGB, String?)] {
                [("\(name) ground", s.ground, nil), ("\(name) pane", s.pane, nil), ("\(name) raised", s.raised, nil)]
            }
            page.swatches(steps("night", Palette.night) + steps("clay", Palette.clay).map { $0 }
                          + [("clay key", Palette.clayKey, "Palette.clayKey"),
                             ("clay key letter", Palette.clayKeyLetter, "Palette.clayKeyLetter")], perRow: 5)
            page.heading("The accent", "International Orange: one value per look.")
            page.swatches([("orange, night", Readability.orangeOnCharcoal, "orangeOnCharcoal"),
                           ("orange, clay", Readability.orangeOnPaper, "orangeOnPaper"),
                           ("in force: accent", accent, "BarTheme.accent"),
                           ("in force: on accent", themed(BarTheme.onAccent, over: accent), "BarTheme.onAccent")],
                          perRow: 5)

            page.heading("In force in \(look.name)", "What the theme resolves in this look, laid over the pane when it is not opaque.")
            let keyFace = themed(BarTheme.keyFill)
            let markFill = themed(BarTheme.markFill)
            page.swatches([
                ("ground (pane)", palette.pane, "BarTheme.ground"),
                ("raised", themed(BarTheme.raised), "BarTheme.raised"),
                ("key face", keyFace, "BarTheme.keyFill"),
                ("key top edge", themed(BarTheme.keyTop, over: keyFace), "BarTheme.keyTop"),
                ("key lip", themed(BarTheme.keyLip, over: pane), "BarTheme.keyLip"),
                ("mark face", markFill, "BarTheme.markFill"),
                ("lit key top", themed(BarTheme.litKeyTop, over: accent), "BarTheme.litKeyTop"),
                ("lit key lip", themed(BarTheme.litKeyLip, over: accent), "BarTheme.litKeyLip"),
                ("well", themed(BarTheme.well), "ink at 5%"),
                ("hairline", themed(BarTheme.hairline), "ink at 12%"),
                ("ink", ink, "labelColor over pane"),
                ("secondary ink", secondary, "BarTheme.secondaryColor"),
                ("glass tint", themed(BarTheme.glassTint, over: pane), "BarTheme.glassTint"),
            ], perRow: 5)

            page.heading("Text pairs", "Measured WCAG contrast, ratio : 1. Reading text is held to 4.5, a mark or a lit fill to 3.")
            for (name, bg) in [("ground", palette.ground), ("pane", palette.pane), ("raised", themed(BarTheme.raised))] {
                page.pair("ink on \(name)", foreground: themed(.labelColor, over: bg), background: bg, floor: 4.5)
            }
            for (name, bg) in [("ground", palette.ground), ("pane", palette.pane), ("raised", themed(BarTheme.raised))] {
                page.pair("secondary on \(name)", foreground: themed(BarTheme.secondaryColor, over: bg), background: bg, floor: 4.5)
            }
            page.pair("accent on pane (as text)", foreground: accent, background: pane, floor: 4.5)
            page.pair("accent on pane (as a mark)", foreground: accent, background: pane, floor: Readability.markFloor)
            page.pair("ink on accent", foreground: themed(.labelColor, over: accent), background: accent, floor: 4.5)
            page.pair("onAccent on accent (a lit key's letter)", foreground: themed(BarTheme.onAccent, over: accent),
                      background: accent, floor: 4.5)
            page.pair("key letter on key face", foreground: themed(BarTheme.keyLetter, over: keyFace), background: keyFace, floor: 4.5)
            page.pair("mark letter on mark face", foreground: themed(BarTheme.markLetter, over: markFill), background: markFill, floor: 4.5)
        }
    }

    // MARK: - Type

    /// A font's weight by name, from the weight trait the font carries.
    static func weightName(_ font: NSFont) -> String {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let value = (traits?[.weight] as? CGFloat) ?? 0
        let named: [(String, NSFont.Weight)] = [
            ("ultralight", .ultraLight), ("thin", .thin), ("light", .light), ("regular", .regular),
            ("medium", .medium), ("semibold", .semibold), ("bold", .bold), ("heavy", .heavy), ("black", .black)]
        return named.min { abs(CGFloat($0.1.rawValue) - value) < abs(CGFloat($1.1.rawValue) - value) }!.0
    }

    /// The face's own kind: the system's sans, its mono, its serif.
    static func faceName(_ font: NSFont) -> String {
        let name = font.fontName.lowercased()
        if name.contains("newyork") { return "serif" }
        if name.contains("monospaceddigit") { return "sans, tabular digits" }
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return "mono" }
        return "sans"
    }

    /// Every font BarTheme defines (and the one KeyMark adds), by the name
    /// the code gives it. A font added to the theme is added here.
    static let fonts: [(name: String, font: NSFont, sample: String)] = {
        let prose = "The quick brown fox jumps over the lazy dog"
        let typed = "swift build -c release 0123"
        let voice = "Notes could be one key away"
        return [
            ("inputFont", BarTheme.inputFont, typed),
            ("stripInputFont", BarTheme.stripInputFont, typed),
            ("typedFont", BarTheme.typedFont, typed),
            ("readingMono", BarTheme.readingMono, typed),
            ("readingMonoAccent", BarTheme.readingMonoAccent, typed),
            ("metaMono", BarTheme.metaMono, typed),
            ("chipFont", BarTheme.chipFont, "esc  tab  ⌘K  space"),
            ("KeyMark.peekFont", KeyMark.peekFont, "37"),
            ("titleFont", BarTheme.titleFont, prose),
            ("roomTitleFont", BarTheme.roomTitleFont, "Send Feedback"),
            ("bodyFont", BarTheme.bodyFont, prose),
            ("rowLabelFont", BarTheme.rowLabelFont, "Safari"),
            ("secondaryFont", BarTheme.secondaryFont, prose),
            ("footerFont", BarTheme.footerFont, "3 found"),
            ("fileNameFont", BarTheme.fileNameFont, "Annual report.pdf"),
            ("voiceFont", BarTheme.voiceFont, voice),
            ("settingsSentenceFont", BarTheme.settingsSentenceFont, "Startup, updates and look"),
            ("coachVoiceFont", BarTheme.coachVoiceFont, voice),
            ("stubTitleFont", BarTheme.stubTitleFont, "Product sync"),
            ("stubCountFont", BarTheme.stubCountFont, "3:59  12"),
            ("stubWordFont", BarTheme.stubWordFont, "Now"),
            ("stubUnitFont", BarTheme.stubUnitFont, "min"),
            ("stubDetailFont", BarTheme.stubDetailFont, "Zoom · 6 people"),
            ("dotFont", BarTheme.dotFont, "● needs you"),
        ]
    }()

    static func type(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        sheet(look: look, width: 1040) { page, _ in
            page.heading("Type · \(look.name)",
                         "Every font BarTheme defines, set in the theme's ink. Name, size in points, weight, face. SF Symbol configurations are not shown.")
            let sizes: [(String, CGFloat)] = [("Scale.meta", BarTheme.Scale.meta), ("Scale.body", BarTheme.Scale.body),
                                              ("Scale.title", BarTheme.Scale.title), ("Scale.input", BarTheme.Scale.input)]
            page.text("The scale: the system's sans at each size", at: NSPoint(x: page.margin, y: page.y), color: Page.ink)
            page.y += 24
            for (name, size) in sizes {
                let font = NSFont.systemFont(ofSize: size)
                page.text("The quick brown fox jumps over the lazy dog", at: NSPoint(x: page.margin, y: page.y),
                          font: font, color: Page.ink)
                page.text("\(name) · \(Int(size)) pt · \(weightName(font)) · sans",
                          at: NSPoint(x: page.width - page.margin - 330, y: page.y + 2), font: BarTheme.metaMono)
                page.y += ceil(font.ascender - font.descender + font.leading) + 10
            }
            page.y += 14
            page.text("The theme's fonts", at: NSPoint(x: page.margin, y: page.y), color: Page.ink)
            page.y += 24
            for item in fonts {
                page.text(item.sample, at: NSPoint(x: page.margin, y: page.y), font: item.font, color: Page.ink)
                page.text("\(item.name) · \(String(format: "%g", Double(item.font.pointSize))) pt · \(weightName(item.font)) · \(faceName(item.font))",
                          at: NSPoint(x: page.width - page.margin - 400, y: page.y + 2), font: BarTheme.metaMono)
                page.y += ceil(item.font.ascender - item.font.descender + item.font.leading) + 10
            }
        }
    }

    static var shots: [GalleryShot] {
        func shot(_ surface: String, _ make: @escaping (GalleryLook) -> (NSWindow, [AnyObject])) -> GalleryShot {
            GalleryShot(surface: "foundation", state: surface, looks: GalleryLook.all) { look in
                let (window, keep) = make(look)
                return (window.contentView!, keep)
            }
        }
        return [shot("colour", colour), shot("type", type)]
    }
}
