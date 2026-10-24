import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/11-slab.md. The chosen thing is a slab of the other look's ground
/// on a four-point side inside its frame, everything in it in the other look,
/// and only the key that acts lit. Every test here is offscreen: the real
/// views drawn into bitmaps and read back, never put on screen.
final class SlabTests: XCTestCase {
    override func tearDown() {
        GalleryLook.reset()
        ActivePolicy.frameOverride = nil
        EyeComfortState.shared.set(enabled: false, level: 1)
    }

    // MARK: - Reading a slab

    typealias RGB = Readability.RGB

    private func rgb(_ color: CGColor?) -> RGB? {
        guard let color, let c = NSColor(cgColor: color)?.usingColorSpace(.sRGB), c.alphaComponent > 0.01 else { return nil }
        return RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

    private func near(_ a: RGB, _ b: RGB, _ tolerance: Double = 0.012) -> Bool {
        abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance && abs(a.blue - b.blue) <= tolerance
    }

    private func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> RGB? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { return nil }
        return RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double { Readability.contrast(a.luminance, b.luminance) }

    private func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    /// Every chosen slab standing in `root`.
    private func slabs(in root: NSView) -> [NSView] {
        var out: [NSView] = []
        walk(root) { view in
            if let surface = view as? SlabSurface, surface.isSlab, !view.isHidden { out.append(view) }
        }
        return out
    }

    /// What a slab holds: itself, or for a step laid behind a row, the row.
    private func content(of slab: NSView) -> NSView { slab is LandingStep ? (slab.superview ?? slab) : slab }

    /// A view is not shown when it or what holds it is hidden.
    private func shown(_ view: NSView, below top: NSView) -> Bool {
        var up: NSView? = view
        while let v = up {
            if v.isHidden { return false }
            if v === top { return true }
            up = v.superview
        }
        return true
    }

    /// The frame of a view in `root`'s coordinates, y counted from the top of the picture.
    private func picture(_ view: NSView, in root: NSView, bounds: NSRect? = nil) -> NSRect {
        let rect = root.convert(bounds ?? view.bounds, from: view)
        return NSRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where a view is drawn: its frame in `root`, moved up by what the rows
    /// above it lift their content by (a row's layers rise by half its side).
    private func rendered(_ view: NSView, in root: NSView) -> NSRect {
        var rect = picture(view, in: root)
        var above = view.superview
        while let ancestor = above, ancestor !== root.superview {
            rect.origin.y -= ancestor.layer?.sublayerTransform.m42 ?? 0
            above = ancestor.superview
        }
        return rect
    }

    private func steps(night: Bool) -> Palette.Steps { EyeComfortState.shared.steps(dark: night) }

    private func stepSet(_ look: Palette.Steps) -> [RGB] {
        [look.ground, look.pane, look.key, look.side, look.ink, look.quietInk, look.orange, look.well, look.letterOnOrange]
    }

    /// Content is not material: a picture, an app's icon, a file's sheet.
    private func isContent(_ view: NSView) -> Bool {
        view is PictureView || view is SheetView || view is NSImageView
    }

    private func isInsideContent(_ view: NSView, below top: NSView) -> Bool {
        var up = view.superview
        while let v = up, v !== top {
            if isContent(v) { return true }
            up = v.superview
        }
        return false
    }

    // MARK: - Every surface with a chosen thing, in both looks and at every hour

    /// What each gallery surface shows chosen: how many slabs. A surface with
    /// nothing chosen shows none, and none shows two.
    private func expectedSlabs(_ shot: GalleryShot) -> Int? {
        let state = shot.state
        switch shot.surface {
        case "launcher": return state.contains("no-match") ? 0 : 1
        case "commands": return 1
        case "ask": return nil
        // Bring's cards are not yet a chosen thing (the slab contract's table
        // does not list them), and an empty keepsake wall has no card.
        case "keep": return ["empty-keepsakes-no-clips", "bring-search"].contains(state) ? 0 : 1
        case "coach": return 1
        case "walk": return state.hasPrefix("welcome-tile-chosen") ? 1 : (state.hasPrefix("welcome") ? 0 : nil)
        case "settings":
            // A search with nothing typed yet has no result to choose.
            return state == "search-empty" ? 0 : (state.hasPrefix("search") || state == "landing-row" ? 1 : nil)
        case "choice", "inputmenu": return 1
        case "foundation": return state.hasPrefix("slab") ? 3 : nil
        default: return nil
        }
    }

    func testEveryChosenThingIsTheSlabAndMeetsTheFloorsInBothLooksAtEveryHour() throws {
        var checkedSurfaces = Set<String>(), words = 0, slabCount = 0, litKeys = 0
        var wrong: [String] = []
        for look in GalleryLook.all {
            look.apply()
            let night = look == .night
            for shot in GalleryShots.all where shot.looks.contains(look) {
                EyeComfortState.shared.set(enabled: shot.level < 1 || shot.receded, level: shot.level)
                defer { EyeComfortState.shared.set(enabled: false, level: 1) }
                guard let (root, keep) = try? shot.built(in: look) else { continue }
                GalleryHost.settle(0.02)
                root.window?.contentView?.layoutSubtreeIfNeeded()
                root.layoutSubtreeIfNeeded()
                let name = shot.name(in: look)
                let found = slabs(in: root)
                if let expected = expectedSlabs(shot) {
                    if found.count != expected { wrong.append("\(name): \(found.count) slabs, expected \(expected)") }
                }
                if shot.surface != "foundation" && found.count > 1 { wrong.append("\(name): one slab per surface, found \(found.count)") }
                guard !found.isEmpty else { _ = keep; continue }
                let rep = GalleryRender.bitmap(of: root)
                let host = steps(night: night), inside = steps(night: !night)
                let hostOnly = stepSet(host).filter { colour in !stepSet(inside).contains { near($0, colour, 0.004) } }
                let innerSet = stepSet(inside)
                for slab in found {
                    slabCount += 1
                    checkedSurfaces.insert(shot.surface)
                    let frame = rendered(slab, in: root)
                    let depth = slab as? CeramicDepth
                    let side = depth?.drawnSide ?? (slab as? ObjectSurface)?.pane?.side ?? 0
                    // The face is the slab step of the look around it; the side is 4 points, inside the frame.
                    do {
                        let x = frame.minX + 3, y = frame.minY + (frame.height - side) / 2
                        if let face = pixel(rep, x: x, y: y) {
                            if !near(face, host.slab) { wrong.append("\(name): the face of \(type(of: slab)) is not the slab step") }
                        } else { wrong.append("\(name): no face under \(type(of: slab))") }
                        XCTAssertEqual(side, (slab as? SlabRow)?.pressed == true ? Ceramic.Side.pressed : Ceramic.Side.row,
                                       "\(name): a slab stands on 4 points, 1 pressed")
                        // Down the middle of the bottom straight, the side shows 4 points, and nothing below the frame.
                        let sx = frame.midX
                        var shownSide = 0.0
                        var yy = frame.maxY - 0.25
                        while yy > frame.minY, let p = pixel(rep, x: sx, y: yy), near(p, host.slabSide, 0.02) {
                            shownSide += 0.5
                            yy -= 0.5
                        }
                        if abs(shownSide - side) > 0.6 && !(slab is ObjectSurface) {
                            wrong.append("\(name): the side shows \(shownSide) points, not \(side)")
                        }
                        if let below = pixel(rep, x: frame.minX + frame.width / 2, y: frame.maxY + 1.5), near(below, host.slabSide, 0.02) {
                            wrong.append("\(name): the side hangs below its frame")
                        }
                    }
                    let held = content(of: slab)
                    // Everything inside is in the other look.
                    walk(held) { view in
                        guard self.shown(view, below: held), !self.isContent(view), !self.isInsideContent(view, below: held) else { return }
                        if view !== held, BarTheme.isNight(view.effectiveAppearance) == night, !(view is PictureView) {
                            if !(slab is LandingStep && view === slab) {
                                wrong.append("\(name): a \(type(of: view)) inside the slab is in the surrounding look")
                            }
                        }
                        if let field = view as? NSTextField, !field.stringValue.isEmpty {
                            if let ink = self.rgb(Ceramic.resolved(field.textColor ?? NSColor.clear, in: field)) {
                                if hostOnly.contains(where: { self.near($0, ink, 0.004) }) {
                                    wrong.append("\(name): \"\(field.stringValue.prefix(20))\" keeps the surrounding look's ink")
                                }
                                let floor: Double? = self.near(ink, inside.ink, 0.004) ? EyeComfort.inkFloor
                                    : (self.near(ink, inside.quietInk, 0.004) ? EyeComfort.quietInkFloor : nil)
                                if let floor, !field.isEditable {
                                    let area = self.rendered(field, in: root)
                                    var best = 1.0
                                    var py = area.minY
                                    while py < area.maxY {
                                        var px = area.minX
                                        while px < area.maxX {
                                            if let p = self.pixel(rep, x: px, y: py) { best = max(best, self.contrast(p, host.slab)) }
                                            px += 0.5
                                        }
                                        py += 0.5
                                    }
                                    words += 1
                                    if best < floor { wrong.append("\(name): \"\(field.stringValue.prefix(20))\" reaches \(String(format: "%.2f", best)), under \(floor)") }
                                }
                            }
                        }
                        // No colour of the look around survives in a layer.
                        func inspect(_ layer: CALayer) {
                            var colours = [layer.backgroundColor, layer.borderColor]
                            if let shape = layer as? CAShapeLayer { colours += [shape.fillColor, shape.strokeColor] }
                            for case let colour? in colours {
                                if let c = self.rgb(colour), hostOnly.contains(where: { self.near($0, c, 0.004) }),
                                   !innerSet.contains(where: { self.near($0, c, 0.004) }) {
                                    wrong.append("\(name): a \(type(of: view)) layer keeps the surrounding look's colour")
                                }
                            }
                        }
                        if let layer = view.layer {
                            inspect(layer)
                            for sub in layer.sublayers ?? [] where !(sub.delegate is NSView) { inspect(sub) }
                        }
                    }
                    // One lit key, and it is the one that acts, or none.
                    var lit: [Key] = []
                    walk(held) { if let key = $0 as? Key, key.lit, self.shown(key, below: held) { lit.append(key) } }
                    litKeys += lit.count
                    if lit.count > 1 { wrong.append("\(name): \(lit.count) lit keys on one slab: \(lit.map(\.legend))") }
                    if let key = lit.first {
                        if !(slab is ObjectSurface) && !["⏎", "lode"].contains(key.legend) {
                            wrong.append("\(name): the lit key is \(key.legend), which does not act")
                        }
                        if let face = self.rgb(key.standing.faceColor), !self.near(face, inside.orange, 0.004) {
                            wrong.append("\(name): the lit key is not the slab look's orange")
                        }
                    }
                }
                _ = keep
            }
        }
        XCTAssertEqual(Array(Set(wrong)).sorted(), [], "the slab, in both looks, at every hour")
        for surface in ["launcher", "ask", "commands", "keep", "coach", "walk", "settings", "choice", "inputmenu", "foundation"] {
            XCTAssertTrue(checkedSurfaces.contains(surface), "\(surface) shows a chosen thing in the gallery")
        }
        XCTAssertGreaterThan(slabCount, 60)
        XCTAssertGreaterThan(words, 150, "words measured on slabs")
        XCTAssertGreaterThan(litKeys, 10)
    }

    // MARK: - Words on the face

    /// The ink rows of a word as drawn: the top and bottom of what differs
    /// from the slab inside the field's frame, found in the bitmap at its own
    /// resolution (half a point) with the edge taken where the ink is half
    /// as strong as at its strongest.
    private func inkSpan(in rect: NSRect, of rep: NSBitmapImageRep, over slab: RGB) -> (top: CGFloat, bottom: CGFloat)? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var rows: [(y: Int, strength: Double)] = []
        for py in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            var strongest = 0.0
            for px in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                let d = max(abs(Double(c.redComponent) - slab.red), abs(Double(c.greenComponent) - slab.green),
                            abs(Double(c.blueComponent) - slab.blue))
                strongest = max(strongest, d)
            }
            rows.append((py, strongest))
        }
        guard let peak = rows.map(\.strength).max(), peak > 0.2 else { return nil }
        let inked = rows.filter { $0.strength >= peak / 2 }
        guard let first = inked.first, let last = inked.last else { return nil }
        return (CGFloat(first.y) / scale, CGFloat(last.y + 1) / scale)
    }

    /// A single line of words stands on the middle of the slab's face: the
    /// middle of its cap-height band, as a key's legend does, is the face's
    /// middle within half a point, measured on the pixels.
    func testASingleLineOfWordsIsCentredOnTheFaceOfItsSlab() throws {
        var wrong: [String] = []
        var measured = 0
        var surfaces = Set<String>()
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) && shot.level == 1 && !shot.receded {
                guard let (root, keep) = try? shot.built(in: look) else { continue }
                GalleryHost.settle(0.02)
                root.window?.contentView?.layoutSubtreeIfNeeded()
                root.layoutSubtreeIfNeeded()
                let slabsHere = slabs(in: root).filter { $0 is SlabRow }
                guard !slabsHere.isEmpty else { _ = keep; continue }
                let rep = GalleryRender.bitmap(of: root)
                let host = steps(night: look == .night)
                for slab in slabsHere {
                    let frame = rendered(slab, in: root)
                    let side = (slab as? CeramicDepth)?.drawnSide ?? 0
                    // The face: the frame less the side beneath it.
                    // A pressed face lies lower by what its side gave up.
                    let reserved = (slab as? SlabRow)?.reservedTop ?? 0
                    let face = NSRect(x: frame.minX, y: frame.minY + reserved + (Slab.side - side), width: frame.width,
                                      height: frame.height - Slab.side - reserved)
                    var fields: [NSTextField] = []
                    walk(content(of: slab)) { view in
                        if let f = view as? NSTextField, !f.stringValue.isEmpty, self.shown(f, below: content(of: slab)),
                           !f.isEditable, !self.isContent(f) {
                            fields.append(f)
                        }
                    }
                    // Words stacked in lines are centred as a block, not each on its own.
                    let areas = fields.map { rendered($0, in: root) }.filter { face.intersects($0) }
                    let stacked = areas.enumerated().contains { one in
                        areas.enumerated().contains { other in
                            other.offset != one.offset && abs(other.element.midY - one.element.midY) > 6
                                && other.element.minX < one.element.maxX && other.element.maxX > one.element.minX
                        }
                    }
                    guard !stacked else { continue }
                    for (index, area) in areas.enumerated() {
                        let field = fields[index]
                        guard area.height < (field.font?.boundingRectForFont.height ?? 40) * 1.6,
                              let font = field.font,
                              let span = inkSpan(in: area, of: rep, over: host.slab) else { continue }
                        // Where the ink's bottom stands below the baseline, from the glyphs themselves.
                        let line = CTLineCreateWithAttributedString(NSAttributedString(string: field.stringValue,
                                                                                       attributes: [.font: font]))
                        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                        let baseline = span.bottom + glyphs.minY
                        let band = baseline - font.capHeight / 2
                        let off = band - face.midY
                        measured += 1
                        surfaces.insert(shot.surface)
                        // The largest words of a row are centred to the half point; a smaller word
                        // beside them stands on the same middle of its box, a point at most off.
                        let largest = fields.map { $0.font?.pointSize ?? 0 }.max() ?? 0
                        if abs(off) > ((font.pointSize >= largest) ? 0.5 : 1.0) {
                            wrong.append("\(shot.name(in: look)): \"\(field.stringValue.prefix(24))\" is \(String(format: "%.2f", off)) points off the face's middle")
                        }
                    }
                }
                _ = keep
            }
        }
        XCTAssertEqual(wrong, [], "single lines of words are centred on the face")
        XCTAssertGreaterThan(measured, 25, "words were measured")
        for surface in ["launcher", "ask", "choice", "inputmenu", "coach", "settings", "keep"] {
            XCTAssertTrue(surfaces.contains(surface), "\(surface)'s words were measured")
        }
    }

    // MARK: - The floors, by the palette

    /// Eye comfort's rule for each look at the one level: the slab's face is
    /// the surrounding look's, what stands on it the other's. Every floor
    /// holds at full, in the evening and at bedtime.
    func testTheFloorsHoldOnTheSlabAtEveryLevel() {
        for level in [1.0, GalleryShots.evening, GalleryShots.bedtime] {
            EyeComfortState.shared.set(enabled: level < 1, level: level)
            for night in [false, true] {
                let host = steps(night: night), inside = steps(night: !night)
                let name = "\(night ? "night" : "day") slab at \(level)"
                XCTAssertGreaterThanOrEqual(contrast(inside.ink, host.slab), EyeComfort.inkFloor, "\(name): ink")
                XCTAssertGreaterThanOrEqual(contrast(inside.quietInk, host.slab), EyeComfort.quietInkFloor, "\(name): quiet ink")
                XCTAssertGreaterThanOrEqual(contrast(inside.orange, host.slab), EyeComfort.litFillFloor, "\(name): the orange fill")
                XCTAssertGreaterThanOrEqual(contrast(inside.letterOnOrange, inside.orange), EyeComfort.orangeTextFloor, "\(name): the letter on the orange")
            }
        }
        EyeComfortState.shared.set(enabled: false, level: 1)
    }

    func testTheSlabIsTheOtherLooksGroundAtFullLevel() {
        XCTAssertEqual(Palette.clay.slab, Palette.rgb(0x2A221D))
        XCTAssertEqual(Palette.clay.slabSide, Palette.rgb(0x120D0A))
        XCTAssertEqual(Palette.night.slab, Palette.rgb(0xF1E8DF))
        XCTAssertEqual(Palette.night.slabSide, Palette.rgb(0xADA093))
        // As the full-level contract measures it.
        XCTAssertEqual(contrast(Palette.night.ink, Palette.clay.slab), 13.18, accuracy: 0.05)
        XCTAssertEqual(contrast(Palette.night.quietInk, Palette.clay.slab), 5.99, accuracy: 0.05)
        XCTAssertEqual(contrast(Palette.clay.ink, Palette.night.slab), 14.51, accuracy: 0.05)
        XCTAssertEqual(contrast(Palette.clay.quietInk, Palette.night.slab), 5.65, accuracy: 0.05)
        XCTAssertEqual(contrast(Palette.night.orange, Palette.clay.slab), 4.76, accuracy: 0.05)
        XCTAssertEqual(contrast(Palette.clay.orange, Palette.night.slab), 4.38, accuracy: 0.05)
    }

    // MARK: - Pressing

    private func chosenRow(look: GalleryLook = .day) -> (SlabRow, NSWindow) {
        look.apply()
        let (row, _) = GallerySlab.row("Mail", note: "Inbox", chosen: true)
        let window = GalleryHost.window(NSView(), size: NSSize(width: 700, height: 80), look: look)
        window.contentView?.addSubview(row)
        row.frame.origin = NSPoint(x: 20, y: 12)
        window.contentView?.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()
        return (row, window)
    }

    func testPressingASlabCollapsesItsSideToAPointAndLowersTheFace() {
        for look in GalleryLook.all {
            let (row, window) = chosenRow(look: look)
            XCTAssertEqual(row.drawnSide, 4, "\(look.name): 4 at rest")
            XCTAssertEqual(row.depth, .standsUp(side: 4))
            let resting = row.face
            row.press(true)
            row.layoutSubtreeIfNeeded()
            XCTAssertEqual(row.drawnSide, 1, "\(look.name): 1 once pressed")
            XCTAssertEqual(row.depth, .standsUp(side: 1))
            XCTAssertEqual(row.face.height, resting.height, "the face keeps its size")
            XCTAssertEqual(resting.minY - row.face.minY, 3, "and goes down by what the side gave up")
            XCTAssertNil(row.layer?.animationKeys(), "at once")
            row.press(false)
            XCTAssertEqual(row.drawnSide, 4)
            XCTAssertEqual(row.face, resting)
            _ = window
        }
    }

    func testAPressedSlabsContentLiesLowerWithTheFace() throws {
        GalleryLook.day.apply()
        let (row, window) = chosenRow()
        func rest() -> CGFloat { row.layer?.sublayerTransform.m42 ?? 0 }
        let before = rest()
        row.press(true)
        XCTAssertEqual(before - rest(), 3, accuracy: 0.001, "what stands on the face moves down with it")
        row.press(false)
        XCTAssertEqual(rest(), before, accuracy: 0.001)
        _ = window
    }

    func testOnlyAChosenRowIsPressed() {
        GalleryLook.day.apply()
        let row = SlabRow(frame: NSRect(x: 0, y: 0, width: 200, height: 48))
        row.setupSlab()
        row.press(true)
        XCTAssertFalse(row.pressed)
        XCTAssertEqual(row.drawnSide, 0, "a row not chosen has no face and no side")
        XCTAssertEqual(row.depth, .flat)
    }

    func testAChosenCardIsPressedToo() throws {
        GalleryLook.day.apply()
        let strip = ClipboardStrip()
        let clip = Clipboard.Clip(id: "a", kind: .text, created: Date(), sourceBundleID: nil, sourceAppName: "Ghostty",
                                  preview: "swift build", bytes: 11, nativeTypes: [], pinnedSlot: nil)
        let card = try XCTUnwrap(strip.makeCard(clip: clip, key: "j", lit: true, size: NSSize(width: 190, height: 150),
                                                reading: nil, thumbnail: nil, chosen: true) as? ObjectSurface)
        let pane = try XCTUnwrap(card.pane)
        let key = try XCTUnwrap(card.subviews.compactMap { $0 as? Key }.first)
        XCTAssertEqual(pane.side, 4)
        let y = key.frame.minY
        card.press(true)
        XCTAssertEqual(pane.side, 1, "the card's side is a point once pressed")
        XCTAssertEqual(key.frame.minY, y - 3, accuracy: 0.001, "and its key goes down with the face")
        card.press(false)
        XCTAssertEqual(pane.side, 4)
        XCTAssertEqual(key.frame.minY, y, accuracy: 0.001)
    }

    // MARK: - Following the choice

    func testThePointerMovesTheSlabInTheInputMenu() throws {
        GalleryLook.night.apply()
        // Built as the gallery builds it: the card is put away as soon as it is made.
        let (_, keep) = try GallerySlab.inputMenu()
        let menu = try XCTUnwrap(keep.compactMap { $0 as? InputMenu }.first)
        menu.slabRows.forEach { $0.choose(false) }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        XCTAssertNil(menu.slabTitle, "nothing is chosen until the pointer is on a row")
        let rows = menu.slabRows
        rows[1].mouseEntered(with: event(.mouseEntered))
        XCTAssertEqual(menu.slabTitle, "MacBook Pro Microphone")
        rows[1].mouseExited(with: event(.mouseExited))
        rows[2].mouseEntered(with: event(.mouseEntered))
        XCTAssertEqual(menu.slabTitle, "CalDigit Thunderbolt 3 Audio", "the slab moves with the pointer")
        XCTAssertEqual(rows.filter(\.chosen).count, 1, "one slab")
        XCTAssertEqual(menu.currentTitle, "System default", "the microphone in use is another fact")
        rows[2].mouseExited(with: event(.mouseExited))
        XCTAssertNil(menu.slabTitle)
    }

    func testKeepsChosenCardFollowsTheSelectionAndOnlyItsPasteKeyLights() throws {
        GalleryLook.day.apply()
        func card(_ shot: String, _ id: String) throws -> (chosen: [String], lit: [String]) {
            let made = try XCTUnwrap(GalleryShots.all.first { $0.surface == "keep" && $0.state == shot })
            let (_, keep) = try made.build(.day)
            let strip = try XCTUnwrap(keep.compactMap { $0 as? ClipboardStrip }.first)
            var chosen: [String] = [], lit: [String] = []
            for (clip, view) in strip.shownCards {
                guard let surface = view as? ObjectSurface else { continue }
                if surface.chosen { chosen.append(clip) }
                for case let key as Key in surface.subviews where key.lit { lit.append(clip) }
            }
            _ = id
            return (chosen.sorted(), lit.sorted())
        }
        let newest = try card("clips-newest-chosen", "r0")
        XCTAssertEqual(newest.chosen, ["r0"], "the newest, until a key moves it")
        XCTAssertEqual(newest.lit, ["r0"], "its paste key lights")
        let third = try card("third-chosen-search", "r2")
        XCTAssertEqual(third.chosen, ["r2"], "a search moves it")
        XCTAssertEqual(third.lit, ["r2"])
        let acting = try card("card-actions", "r0")
        XCTAssertEqual(acting.chosen, ["r0"], "the card the actions act on")
        XCTAssertEqual(acting.lit, [], "with a menu open the keys answer it: nothing lights on the card")
        let sources = try card("source-menu", "r0")
        XCTAssertEqual(sources.chosen, [], "with the list of sources open the choice is in the list")
        XCTAssertEqual(sources.lit, [])
    }

    /// The night sets words a step heavier than the day, so a day slab holds
    /// wider words than the layout was cut for: none is clipped to the old width.
    func testWordsOnADaySlabAreNotCutShortByTheHeavierLook() throws {
        GalleryLook.day.apply()
        for state in ["source-menu", "clips-newest-chosen", "card-actions"] {
            let made = try XCTUnwrap(GalleryShots.all.first { $0.surface == "keep" && $0.state == state })
            let (root, keep) = try made.build(.day)
            root.layoutSubtreeIfNeeded()
            for slab in slabs(in: root) {
                walk(content(of: slab)) { view in
                    guard let field = view as? NSTextField, let style = field.typeStyle, !field.stringValue.isEmpty,
                          field.maximumNumberOfLines <= 1, !(field.cell?.wraps ?? false),
                          field.lineBreakMode == .byTruncatingTail, field.superview === slab || field.superview === slab.superview
                    else { return }
                    let cell = NSTextFieldCell(textCell: "")
                    cell.attributedStringValue = NSAttributedString(
                        string: field.stringValue,
                        attributes: BarTheme.attributes(style.role, tabular: style.tabular, in: field.effectiveAppearance))
                    // A field may be shorter than its words only where the card has no more room.
                    if field.frame.width < ceil(cell.cellSize.width) - 0.5 {
                        XCTAssertGreaterThan(field.frame.maxX + Grid.group, slab.bounds.width - 40,
                                             "\(state): \"\(field.stringValue)\" is cut short with room to spare")
                    }
                }
            }
            _ = keep
        }
    }

    func testChoosingAndLeavingAreInstant() {
        GalleryLook.day.apply()
        let (row, window) = chosenRow()
        row.choose(false)
        XCTAssertEqual(row.drawnSide, 0)
        XCTAssertNil(row.appearance, "back in the look it is in")
        row.choose(true)
        XCTAssertNotNil(row.appearance)
        XCTAssertEqual(row.drawnSide, 4)
        for layer in row.layer?.sublayers ?? [] { XCTAssertNil(layer.animationKeys(), "nothing slides or fades") }
        _ = window
    }

    func testASlabFollowsItsHostWhenTheLookTurns() throws {
        GalleryLook.day.apply()
        let (row, window) = chosenRow()
        XCTAssertEqual(row.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        window.appearance = NSAppearance(named: .darkAqua)
        GalleryHost.settle(0.02)
        XCTAssertEqual(row.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .aqua, "a night window's slab holds the day")
        XCTAssertEqual(rgb(row.faceColor).map { near($0, Palette.night.slab) }, true, "and its face is the night's slab step")
    }

    // MARK: - The drift guard: a chosen state drawn any other way

    private func code(_ files: [URL]) throws -> [(name: String, lines: [String])] {
        try files.map { ($0.lastPathComponent, DesignDriftTests.code(try String(contentsOf: $0, encoding: .utf8))
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)) }
    }

    /// Selections that are not a chosen thing: the text selection of a field,
    /// a lens's wash over another app's words.
    private static let notAChosenThing: Set<String> = [
        "SelectOverlay.swift", "SelectController.swift", "HintTargets.swift", "EditorMarks.swift", "EditorModel.swift",
        "DraftPanel.swift", "DraftController.swift", "DraftModel.swift", "DraftEditor.swift",
    ]

    private func driftOffenders(in sources: [(name: String, lines: [String])]) -> [String] {
        let chosenWord = #"(chosen|selected|selection|isSelected|highlighted|\braised\b|focused)"#
        let patterns: [(String, String)] = [
            ("the key step is not what a chosen thing stands on",
             chosenWord + #"[^\n]*(faceFill|keyFill|\.key\.color|\.raised|BarTheme\.dynamic \{ look in\s*look\.key)"#),
            ("a selection tint", chosenWord + #"[^\n]*(inkAt\(|selectedContentBackgroundColor|selectedMenuItemColor|selectedTextBackgroundColor|alternateSelectedControlColor|accent\.withAlpha|withAlphaComponent)"#),
            ("bold for chosen", #"(chosen|selected|isSelected|highlighted)\s*\?\s*[^:\n]*(bold|semibold|heavy|\.emphasis|Weight)"#),
            ("an inline highlight", #"(chosen|selected|isSelected|highlighted)[^\n]*(\.backgroundColor|\.strokeColor|borderColor|borderWidth)|(\.backgroundColor|\.strokeColor|borderColor|borderWidth)[^\n]*(chosen|selected|isSelected|highlighted)"#),
            ("every key lit by the choice", #"\.lit\s*=\s*(selected|selectedState|chosen|isSelected|highlighted)\b"#),
            ("the old raised row", #"\b(RaisedRow|RaisedLine|setupRaised|applyRaised)\b|BarTheme\.raised\b"#),
        ]
        var found: [String] = []
        for (file, lines) in sources where !Self.notAChosenThing.contains(file) {
            for (number, line) in lines.enumerated() {
                // A line that names the slab is the slab being drawn.
                if line.contains("slabFill") || line.contains("slabSideFill") { continue }
                // A field editor's own text selection is not a chosen thing.
                if line.contains("selectedTextAttributes") { continue }
                for (what, pattern) in patterns where line.range(of: pattern, options: .regularExpression) != nil {
                    found.append("\(file):\(number + 1): \(what): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return found
    }

    func testNoChosenStateIsDrawnAnyOtherWayThanTheSlab() throws {
        let sources = try code(DesignDriftTests.swiftFiles(under: DesignDriftTests.appSources))
        XCTAssertEqual(driftOffenders(in: sources), [],
                       "a chosen thing is the slab: no key-step face, tint, inline highlight, bold, or key lit by being chosen")
    }

    func testTheSlabGuardCatchesWhatItNames() {
        func offends(_ line: String) -> Bool { !driftOffenders(in: [("Surface.swift", [line])]).isEmpty }
        for line in ["row.layer?.backgroundColor = chosen ? BarTheme.faceFill : nil",
                     "let fill = selected ? BarTheme.inkAt(0.12) : .clear",
                     "label.font = isSelected ? bold : regular",
                     "for strokes in keys { strokes.lit = selectedState }",
                     "view.layer?.borderColor = selected ? accent : edge",
                     "final class Row: RaisedRow {}", "let step = BarTheme.raised"] {
            XCTAssertTrue(offends(line), "the guard misses: \(line)")
        }
        for line in ["standing.paint(in: self, face: chosen ? BarTheme.slabFill : BarTheme.faceFill)",
                     "let enter = Key(\"⏎\"); enter.lit = true", "label.textColor = BarTheme.ink"] {
            XCTAssertFalse(offends(line), "the guard flags what the slab does: \(line)")
        }
    }

    func testTheStripsOldKeyStepFillIsGone() {
        XCTAssertEqual(String(describing: CeramicPane.Fill.slab), "slab")
        XCTAssertEqual(String(describing: ClipboardStrip.CardFill.slab), "slab")
    }
}
