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

        static var ink: NSColor { BarTheme.ink }

        func text(_ string: String, at point: NSPoint, role: BarTheme.Role = .meta,
                  color: NSColor = BarTheme.secondaryColor) {
            guard draws else { return }
            let font = role.font(in: NSAppearance.currentDrawing())
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
            text(title, at: NSPoint(x: margin, y: y), role: .roomTitle, color: Self.ink)
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
                     at: NSPoint(x: origin.x, y: origin.y + 68), role: .meta)
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
            text("Aa 12", at: NSPoint(x: margin + 8, y: y + 4), role: .body,
                 color: NSColor(srgbRed: foreground.red, green: foreground.green, blue: foreground.blue, alpha: 1))
            text(name, at: NSPoint(x: margin + 92, y: y + 4), color: Self.ink)
            text(String(format: "%.2f : 1", measured), at: NSPoint(x: width - margin - 250, y: y + 4),
                 role: .meta, color: Self.ink)
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

    /// design/01-colour.md as a picture: every step of the look with its
    /// hex and lightness, International Orange and the letter on it, what
    /// the theme resolves in this look, and every pair of the measured
    /// contrast table with its ratio and its floor. All of it is read from
    /// Palette.swift and BarTheme, so the sheet is the code.
    static func colour(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        sheet(look: look, width: 1040) { page, appearance in
            let steps = BarTheme.steps(for: appearance)
            let night = steps == Palette.night
            let other = night ? Palette.clay : Palette.night
            let id = night ? "night" : "clay"
            let pane = steps.pane
            func themed(_ color: NSColor, over background: Readability.RGB = pane) -> Readability.RGB {
                resolved(color, over: background, in: appearance)
            }
            page.heading("Colour · \(look.name)",
                         "\(night ? "Espresso" : "Clay") of design/01-colour.md, drawn from Palette.swift and BarTheme in the \(look.name) look. The look's pane is the sheet's own ground.")

            page.heading("Steps", "Palette.\(id): ground, pane, key, side, ink, quiet ink, slab, slab side, and the hairline's share of the ink.")
            page.swatches([
                ("ground", steps.ground, "Palette.\(id).ground"), ("pane", steps.pane, "Palette.\(id).pane"),
                ("key", steps.key, "Palette.\(id).key"), ("side", steps.side, "Palette.\(id).side"),
                ("ink", steps.ink, "Palette.\(id).ink"), ("quiet ink", steps.quietInk, "Palette.\(id).quietInk"),
                ("slab", steps.slab, "Palette.\(id).slab"), ("slab side", steps.slabSide, "Palette.\(id).slabSide"),
                ("hairline", themed(BarTheme.hairline), "ink at \(Int((steps.hairlineAlpha * 100).rounded())) per cent"),
            ], perRow: 5)

            page.heading("International Orange", "One value per look. The letter on it is whichever of clay's key face and clay's ink measures higher.")
            page.swatches([
                ("orange", steps.orange, "Palette.\(id).orange"),
                ("the other look's orange", other.orange, "on this look's slab"),
                ("letter on the orange", steps.letterOnOrange, "Palette.\(id).letterOnOrange"),
            ], perRow: 5)

            page.heading("In force in \(look.name)", "What the theme resolves in this look, laid over the pane when it is not opaque.")
            let keyFace = themed(BarTheme.keyFill)
            let accent = themed(BarTheme.accent)
            page.swatches([
                ("ink", themed(BarTheme.ink), "BarTheme.ink"),
                ("quiet ink", themed(BarTheme.secondaryColor), "BarTheme.secondaryColor"),
                ("hairline", themed(BarTheme.hairline), "BarTheme.hairline"),
                ("well", themed(BarTheme.well), "ink at 5%"),
                ("accent", accent, "BarTheme.accent"),
                ("letter on the accent", themed(BarTheme.onAccent, over: accent), "BarTheme.onAccent"),
                ("chosen row", themed(BarTheme.raised), "BarTheme.raised (the key step)"),
                ("key face", keyFace, "BarTheme.keyFill"),
                ("key side", themed(BarTheme.keyLip, over: pane), "BarTheme.keyLip"),
                ("key letter", themed(BarTheme.keyLetter, over: keyFace), "BarTheme.keyLetter"),
                ("key top edge", themed(BarTheme.keyTop, over: keyFace), "BarTheme.keyTop"),
                ("lit key top edge", themed(BarTheme.litKeyTop, over: accent), "BarTheme.litKeyTop"),
                ("lit key side", themed(BarTheme.litKeyLip, over: accent), "BarTheme.litKeyLip"),
                ("mark face", themed(BarTheme.markFill), "BarTheme.markFill"),
                ("shadow", themed(BarTheme.shadow), "BarTheme.shadow"),
                ("glass tint", themed(BarTheme.glassTint), "BarTheme.glassTint (the glass stays until the material contract)"),
            ], perRow: 5)

            page.heading("Measured contrast", "WCAG contrast, ratio : 1, each against the floor of its role: 7 for text read at length, 4.5 for other text, 3 for a fill that carries meaning.")
            for (name, bg) in [("ground", steps.ground), ("pane", steps.pane), ("key", steps.key)] {
                page.pair("ink on \(name)", foreground: steps.ink, background: bg, floor: 7)
            }
            for (name, bg) in [("ground", steps.ground), ("pane", steps.pane), ("key", steps.key)] {
                page.pair("quiet ink on \(name)", foreground: steps.quietInk, background: bg, floor: 4.5)
            }
            page.pair("orange on pane (as text)", foreground: steps.orange, background: steps.pane, floor: 4.5)
            page.pair("orange on key", foreground: steps.orange, background: steps.key, floor: 4.5)
            page.pair("other look's ink on slab", foreground: other.ink, background: steps.slab, floor: 4.5)
            page.pair("other look's quiet ink on slab", foreground: other.quietInk, background: steps.slab, floor: 4.5)
            page.pair("orange on slab (as a fill)", foreground: other.orange, background: steps.slab, floor: 3)
            page.pair("letter on orange", foreground: steps.letterOnOrange, background: steps.orange, floor: 4.5)
            page.pair("theme: ink on pane", foreground: themed(BarTheme.ink), background: pane, floor: 7)
            page.pair("theme: quiet ink on pane", foreground: themed(BarTheme.secondaryColor), background: pane, floor: 4.5)
            page.pair("theme: letter on the accent", foreground: themed(BarTheme.onAccent, over: accent), background: accent, floor: 4.5)
            page.pair("theme: key letter on key face", foreground: themed(BarTheme.keyLetter, over: keyFace), background: keyFace, floor: 7)
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

    /// The face's own kind: the system's sans, its serif, its mono.
    static func faceName(_ font: NSFont) -> String {
        let name = font.fontName.lowercased()
        if name.contains("newyork") { return "serif" }
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return "mono" }
        if name.contains("monospaceddigit") || isTabular(font) { return "sans, tabular figures" }
        return "sans"
    }

    /// Whether every digit is as wide as every other.
    static func isTabular(_ font: NSFont) -> Bool {
        let widths = "0123456789".map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
        return widths.allSatisfy { abs($0 - widths[0]) < 0.001 }
    }

    /// What each role says, set in it: the sample is what the role is for.
    static let samples: [BarTheme.Role: String] = [
        .field: "Where to?", .voice: "Notes could be one key away", .title: "Switch to a window",
        .roomTitle: "Send feedback", .body: "Safari  Slack  Ghostty", .quietVoice: "Product sync",
        .typed: "swift build", .emphasis: "Now", .figure: "3:59  12", .largeFigure: "37",
        .meta: "Zoom · 6 people · just now", .name: "Annual report.pdf",
        .label: "Start at login", .control: "Under the pointer", .heading: "Sound and display", .key: "esc  tab  ⌘K  space",
        .draft: "and tail the log, then move the card", .draftMarked: "lit letters",
    ]

    static func type(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        sheet(look: look, width: 1040) { page, _ in
            let night = look.appearance == .darkAqua
            page.heading("Type · \(look.name)",
                         "Every role the theme defines, set in the theme's ink: name, size, weight, face. "
                         + (night ? "At night every role is one weight heavier." : "By day: regular, medium, semibold."))
            let appearance = NSAppearance(named: look.appearance)!
            for role in BarTheme.Role.allCases {
                let font = role.font(in: appearance)
                page.text(samples[role] ?? role.rawValue, at: NSPoint(x: page.margin, y: page.y), role: role, color: Page.ink)
                page.text("\(role.rawValue) · \(String(format: "%g", Double(font.pointSize))) pt · \(weightName(font)) · \(faceName(font))",
                          at: NSPoint(x: page.width - page.margin - 330, y: page.y + 2), role: .meta)
                page.y += ceil(font.ascender - font.descender + font.leading) + 10
            }
            page.y += 14
            page.text("Every surface, to judge the voice in use, is in the pictures of the surfaces.",
                      at: NSPoint(x: page.margin, y: page.y))
            page.y += 24
        }
    }

    // MARK: - Geometry

    /// design/03-geometry.md as a picture, drawn from the tokens: the ladder
    /// of radii on the pill's curve, the nesting rule on a pane and a row, the
    /// grid's steps, and the sizes everything is cut to. A change to
    /// Geometry.swift changes the picture.
    static func geometry(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        sheet(look: look, width: 1040) { page, _ in
            func round(_ rect: NSRect, _ radius: CGFloat, fill: NSColor, edge: NSColor = BarTheme.hairline) {
                guard page.draws else { return }
                let corner = BarTheme.radius(radius, height: rect.height)
                let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
                fill.setFill()
                path.fill()
                edge.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            func number(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
            let margin = page.margin
            page.heading("Geometry · \(look.name)",
                         "One curve, one grid and the sizes everything is cut to, drawn from Geometry.swift in the \(look.name) look.")

            page.heading("Radii", "Anchored on the pill's own curve, each rung the one above over φ².")
            let ladder: [(String, CGFloat, NSSize)] = [
                ("surface", BarTheme.surfaceRadius, NSSize(width: 200, height: 96)),
                ("control", BarTheme.controlRadius, NSSize(width: 120, height: 48)),
                ("mark", BarTheme.markRadius, NSSize(width: 120, height: 28)),
            ]
            var x = margin
            for (name, radius, size) in ladder {
                round(NSRect(x: x, y: page.y, width: size.width, height: size.height), radius, fill: BarTheme.well)
                page.text("\(name) · \(number(radius))", at: NSPoint(x: x, y: page.y + size.height + 8), color: Page.ink)
                x += size.width + Grid.section * 2
            }
            // The pill, whose ends the surface radius is; and a hairline, round to half its width.
            round(NSRect(x: x, y: page.y, width: 150, height: BarTheme.pillHeight), BarTheme.surfaceRadius, fill: BarTheme.well)
            page.text("pill · \(Int(BarTheme.pillHeight)) tall, ends \(number(BarTheme.pillHeight / 2))",
                      at: NSPoint(x: x, y: page.y + 96 + 8), color: Page.ink)
            round(NSRect(x: x + 190, y: page.y, width: BarTheme.caretWidth, height: BarTheme.caretHeight),
                  BarTheme.hairlineRadius(width: BarTheme.caretWidth), fill: BarTheme.ink, edge: BarTheme.ink)
            page.text("hairline · half its width", at: NSPoint(x: x + 170, y: page.y + 96 + 8), color: Page.ink)
            page.y += 96 + 40

            page.heading("Nesting", "A thing inside another rounds at the outer radius less its inset, never below its own rung.")
            let pane = NSRect(x: margin, y: page.y, width: 420, height: 168)
            round(pane, BarTheme.surfaceRadius, fill: BarTheme.well)
            let inset = BarTheme.paneInset
            let row = NSRect(x: pane.minX + inset, y: pane.minY + inset, width: pane.width - inset * 2, height: BarTheme.rowHeight)
            round(row, BarTheme.paneRowRadius, fill: BarTheme.raised)
            let field = NSRect(x: pane.minX + inset, y: row.maxY + Grid.close, width: pane.width - inset * 2,
                               height: pane.maxY - inset - row.maxY - Grid.close)
            round(field, BarTheme.nested(outer: BarTheme.surfaceRadius, inset: inset, rung: BarTheme.controlRadius), fill: BarTheme.well)
            // A key inside the row stands at its own rung: the row's radius less the inset falls below it.
            round(NSRect(x: row.maxX - Grid.part - 44, y: row.minY + (row.height - BarTheme.keyHeight) / 2, width: 44, height: BarTheme.keyHeight),
                  BarTheme.controlRadius, fill: BarTheme.keyFill)
            page.text("pane \(number(BarTheme.surfaceRadius)), inset \(Int(inset)): row and field \(number(BarTheme.paneRowRadius)); key keeps \(number(BarTheme.controlRadius))",
                      at: NSPoint(x: pane.maxX + Grid.section, y: pane.minY + 4), color: Page.ink)
            page.text("nested = max(rung, outer − inset)", at: NSPoint(x: pane.maxX + Grid.section, y: pane.minY + 28))
            let short = NSRect(x: pane.maxX + Grid.section, y: pane.minY + 64, width: 150, height: 28)
            round(short, BarTheme.surfaceRadius, fill: BarTheme.raised)
            page.text("shorter than twice its radius: a stadium", at: NSPoint(x: short.minX, y: short.maxY + 8))
            page.y += pane.height + 28

            page.heading("The grid", "Every gap, inset and padding is a step. The half-step is allowed only inside a control.")
            let names: [(String, CGFloat)] = [("hair", Grid.hair), ("tight", Grid.tight), ("close", Grid.close), ("part", Grid.part),
                                              ("group", Grid.group), ("section", Grid.section), ("margin", Grid.margin), ("column", Grid.column),
                                              ("half, inside a control", Grid.half)]
            for (name, step) in names {
                if page.draws {
                    Page.ink.setFill()
                    NSBezierPath(rect: NSRect(x: margin + 190, y: page.y + 3, width: step, height: 12)).fill()
                }
                page.text("\(name)", at: NSPoint(x: margin, y: page.y), color: Page.ink)
                page.text("\(Int(step))", at: NSPoint(x: margin + 150, y: page.y))
                page.y += 22
            }
            page.y += 14

            page.heading("Sizes", "The things everything is cut to.")
            let sizes: [(String, CGFloat)] = [
                ("bar width", BarTheme.panelWidth), ("bar's field", BarTheme.inputHeight), ("row", BarTheme.rowHeight),
                ("pill", BarTheme.pillHeight), ("key", BarTheme.keyHeight), ("app icon in a row", BarTheme.appIconSize),
                ("symbol in a row", BarTheme.symbolSize), ("pointer target, at least", BarTheme.minTarget),
                ("sentence measure", BarTheme.measure)]
            for (name, size) in sizes {
                page.text("\(name)", at: NSPoint(x: margin, y: page.y), color: Page.ink)
                page.text("\(Int(size))", at: NSPoint(x: margin + 150, y: page.y))
                if page.draws {
                    BarTheme.inkAt(0.35).setFill()
                    NSBezierPath(rect: NSRect(x: margin + 190, y: page.y + 5, width: min(size, 640) / 2, height: 6)).fill()
                }
                page.y += 22
            }
            page.y += 14
        }
    }

    static var shots: [GalleryShot] {
        func shot(_ surface: String, _ make: @escaping (GalleryLook) -> (NSWindow, [AnyObject])) -> GalleryShot {
            GalleryShot(surface: "foundation", state: surface, looks: GalleryLook.all) { look in
                let (window, keep) = make(look)
                return (window.contentView!, keep)
            }
        }
        return [shot("colour", colour), shot("type", type), shot("geometry", geometry)]
    }
}
