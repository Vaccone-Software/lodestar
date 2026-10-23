import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The pane (design/04-material.md): one opaque ceramic surface in the look's
/// own step, a rim along its top edge and a hairline round it, both above
/// its content, and one shadow where it floats.
final class PaneTests: XCTestCase {
    override func tearDown() { GalleryLook.reset() }

    private let size = NSSize(width: 160, height: 100)

    /// A pane in a window of `look`, with a marker view over it, as a panel's
    /// root stands.
    private func pane(in look: GalleryLook, fill: CeramicPane.Fill = .pane) -> (NSWindow, NSView, CeramicPane, NSView) {
        look.apply()
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let pane = Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius, fill: fill)
        let content = NSView(frame: NSRect(x: 40, y: 30, width: 20, height: 20))
        content.wantsLayer = true
        root.addSubview(content)
        let window = GalleryHost.window(root, size: size, look: look)
        root.layoutSubtreeIfNeeded()
        return (window, root, pane, content)
    }

    private func srgb(_ color: CGColor?) throws -> NSColor {
        try XCTUnwrap(color.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
    }

    private func near(_ a: NSColor, _ b: RGB, _ message: String, tolerance: CGFloat = 0.012,
                      file: StaticString = #filePath, line: UInt = #line) {
        let a = a.usingColorSpace(.sRGB) ?? a
        XCTAssertEqual(a.redComponent, CGFloat(b.red), accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(a.greenComponent, CGFloat(b.green), accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(a.blueComponent, CGFloat(b.blue), accuracy: tolerance, message, file: file, line: line)
    }

    typealias RGB = Readability.RGB

    /// A pixel of the rendered pane, `x` from the left and `y` down from
    /// the top, in points.
    private func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
    }

    func testAPaneIsOpaqueAndItsFillIsTheLooksStep() throws {
        for look in GalleryLook.all {
            let steps = look == .night ? Palette.night : Palette.clay
            let (window, root, _, _) = pane(in: look)
            let rep = GalleryRender.bitmap(of: root)
            for point in [CGPoint(x: 80, y: 50), CGPoint(x: 20, y: 80), CGPoint(x: 140, y: 20)] {
                let drawn = try pixel(rep, x: point.x, y: point.y)
                XCTAssertEqual(drawn.alphaComponent, 1, accuracy: 0.001, "\(look.name): nothing lets the desktop through")
                near(drawn, steps.pane, "\(look.name): the pane's own step, (\(point.x), \(point.y))")
            }
            // The corners are the only place the window shows: the curve cuts them away.
            XCTAssertLessThan(try pixel(rep, x: 0.5, y: 0.5).alphaComponent, 0.05, "\(look.name): the corner curves away")
            _ = window
        }
    }

    func testTheKeyStepPaneIsTheKeyStepOpaque() throws {
        for look in GalleryLook.all {
            let steps = look == .night ? Palette.night : Palette.clay
            let (window, root, _, _) = pane(in: look, fill: .key)
            let drawn = try pixel(GalleryRender.bitmap(of: root), x: 80, y: 60)
            XCTAssertEqual(drawn.alphaComponent, 1, accuracy: 0.001)
            near(drawn, steps.key, "\(look.name): the one the hand is on is the key step")
            _ = window
        }
    }

    /// The rim: 1.5 points along the top, the clay key step by day and the
    /// ink at 10% by night, clipped to the corners so it thins into the curve.
    func testTheRimIsOnTheTopAndThinsIntoTheCorners() throws {
        for look in GalleryLook.all {
            let steps = look == .night ? Palette.night : Palette.clay
            let (window, root, pane, _) = pane(in: look)
            let edge = try XCTUnwrap(pane.edge)
            let path = try XCTUnwrap(edge.rimPath)
            let box = path.boundingBoxOfPath
            XCTAssertEqual(box.height, Ceramic.Edge.rim, accuracy: 0.01, "1.5 points tall")
            XCTAssertEqual(Ceramic.Edge.rim, 1.5)
            XCTAssertEqual(box.maxY, pane.face.maxY, accuracy: 0.01, "along the top, the light from above")
            XCTAssertFalse(path.contains(CGPoint(x: 0.2, y: pane.face.maxY - 0.2)),
                           "clipped to the corner: the curve has turned away from the light there")
            XCTAssertTrue(path.contains(CGPoint(x: pane.face.midX, y: pane.face.maxY - 0.7)))
            let color = try srgb(edge.rimColor)
            if look == .night {
                near(color, steps.ink, "night: the ink", tolerance: 0.01)
                XCTAssertEqual(color.alphaComponent, 0.10, accuracy: 0.005, "at 10%")
            } else {
                near(color, steps.key, "day: the clay key step")
                XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
            }
            // As drawn: a point 1 below the top is the rim over the pane, 3 below is the pane.
            let rep = GalleryRender.bitmap(of: root)
            near(try pixel(rep, x: 80, y: 3.0), steps.pane, "\(look.name): below the rim the pane")
            let over = look == .night
                ? RGB(red: steps.pane.red + (steps.ink.red - steps.pane.red) * 0.10,
                      green: steps.pane.green + (steps.ink.green - steps.pane.green) * 0.10,
                      blue: steps.pane.blue + (steps.ink.blue - steps.pane.blue) * 0.10)
                : steps.key
            near(try pixel(rep, x: 80, y: 1.0), over, "\(look.name): on the rim", tolerance: 0.02)
            _ = window
        }
    }

    /// The edge: 0.5 point all round, the ink at 10% by day and 8% by
    /// night, and drawn above the pane's content.
    func testTheEdgeIsAHairlineAboveTheContent() throws {
        for look in GalleryLook.all {
            let steps = look == .night ? Palette.night : Palette.clay
            let (window, root, pane, content) = pane(in: look)
            let edge = try XCTUnwrap(pane.edge)
            XCTAssertEqual(edge.edgeWidth, 0.5)
            XCTAssertEqual(Ceramic.Edge.line, 0.5)
            let color = try srgb(edge.edgeColor)
            XCTAssertEqual(color.alphaComponent, steps.hairlineAlpha, accuracy: 0.005, "\(look.name): ink at \(steps.hairlineAlpha)")
            near(color, steps.ink, "\(look.name): the ink", tolerance: 0.01)
            XCTAssertEqual(steps.hairlineAlpha, look == .night ? 0.08 : 0.10)
            XCTAssertNil(edge.hitTest(NSPoint(x: 80, y: 50)), "it takes no pointer")
            XCTAssertGreaterThan(try XCTUnwrap(edge.layer).zPosition, try XCTUnwrap(content.layer).zPosition,
                                 "above the content in the compositor")
            // A picture that fills the pane does not cover it: an opaque
            // view across the top edge, and the hairline still crosses it.
            let picture = NSView(frame: NSRect(x: 60, y: size.height - 12, width: 40, height: 12))
            picture.wantsLayer = true
            picture.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
            root.addSubview(picture)
            let rep = GalleryRender.bitmap(of: root)
            XCTAssertEqual(root.subviews.last, edge, "the edge is brought over what was added after it")
            let crossed = try pixel(rep, x: 80, y: 0.25)
            XCTAssertLessThan(crossed.redComponent, 0.99, "\(look.name): the picture does not cover the hairline over it")
            XCTAssertGreaterThan(crossed.greenComponent, 0.0, "\(look.name): the hairline's ink is laid over the red")
            _ = window
        }
    }

    /// The pane repaints in its own look: the same pane in a day window and
    /// a night window draws two looks, with no colour baked in at creation.
    func testAPaneRepaintsInTheLookItIsIn() throws {
        GalleryLook.day.apply()
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let pane = Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)
        let window = GalleryHost.window(root, size: size, look: .day)
        near(try pixel(GalleryRender.bitmap(of: root), x: 80, y: 50), Palette.clay.pane, "day")
        let edge = try XCTUnwrap(pane.edge)
        let dayEdge = try srgb(edge.edgeColor)
        window.appearance = NSAppearance(named: .darkAqua)
        pane.needsDisplay = true
        near(try pixel(GalleryRender.bitmap(of: root), x: 80, y: 50), Palette.night.pane, "night, on the same view")
        XCTAssertNotEqual(try srgb(edge.edgeColor).alphaComponent, dayEdge.alphaComponent, "the edge followed too")
    }

    /// The shadow: one, following the outline, 24 blur and 8 down; quiet ink
    /// at 14% by day, espresso's ground at 40% by night.
    func testTheShadowIsOneSoftShadowFollowingTheOutline() throws {
        for look in GalleryLook.all {
            look.apply()
            let steps = look == .night ? Palette.night : Palette.clay
            let panel = Ceramic.makePanel(level: .floating)
            panel.appearance = NSAppearance(named: look.appearance)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)
            SoftShadow.host(root, in: panel, cornerRadius: BarTheme.surfaceRadius)
            panel.setFrame(SoftShadow.outset(NSRect(x: 0, y: 0, width: 200, height: 120)), display: false)
            let host = try XCTUnwrap(panel.contentView as? ShadowHostView)
            host.layoutSubtreeIfNeeded()
            host.viewDidChangeEffectiveAppearance()
            let casters = (host.layer?.sublayers ?? []).filter { $0.shadowPath != nil }
            XCTAssertEqual(casters.count, 1, "\(look.name): one shadow, not a soft one and a contact line")
            let shadow = try XCTUnwrap(casters.first)
            XCTAssertEqual(Ceramic.Shadow.blur, 24)
            XCTAssertEqual(shadow.shadowRadius * 2, Ceramic.Shadow.blur, "a layer's radius is half the contract's blur")
            XCTAssertEqual(shadow.shadowOffset.height, -8, "8 down")
            XCTAssertEqual(shadow.shadowOffset.width, 0)
            XCTAssertEqual(Double(shadow.shadowOpacity), look == .night ? 0.40 : 0.14, accuracy: 0.001)
            near(try srgb(shadow.shadowColor), look == .night ? steps.ground : steps.quietInk, "\(look.name): never black")
            XCTAssertEqual(shadow.frame, host.subviews[0].frame, "the pane's own outline")
            XCTAssertEqual(shadow.shadowPath?.boundingBoxOfPath, shadow.bounds)
            XCTAssertEqual(shadow.cornerRadius, BarTheme.surfaceRadius, "rounded as the pane is")
            XCTAssertFalse(panel.hasShadow, "the window server's shadow cannot be shaped; the pane casts its own")
            XCTAssertGreaterThanOrEqual(SoftShadow.margin, Ceramic.Shadow.reach, "the window leaves room for it")
        }
    }

    /// The well: the pane darkened by 0.05 of OKLab lightness by day and 0.04
    /// by night (never below the ground by night), opaque, with an edge at
    /// ink 14% by day and 12% by night.
    func testTheWellIsOneStepBelowThePane() throws {
        for (steps, drop) in [(Palette.clay, 0.05), (Palette.night, 0.04)] {
            let well = steps.well
            XCTAssertEqual(steps.pane.lightness - well.lightness, drop, accuracy: 0.002)
            XCTAssertEqual(well.chroma, steps.pane.chroma, accuracy: 0.006, "the same ceramic a step down")
        }
        XCTAssertGreaterThanOrEqual(Palette.night.well.lightness, Palette.night.ground.lightness - 0.0005,
                                    "by night never below the ground")
        let day = Palette.clay.well, night = Palette.night.well
        XCTAssertEqual(day.red * 255, 0xE6, accuracy: 2)
        XCTAssertEqual(day.green * 255, 0xDE, accuracy: 2)
        XCTAssertEqual(day.blue * 255, 0xD6, accuracy: 2)
        XCTAssertEqual(night.red * 255, 0x14, accuracy: 2)
        XCTAssertEqual(night.green * 255, 0x10, accuracy: 2)
        XCTAssertEqual(night.blue * 255, 0x0D, accuracy: 2)
        XCTAssertEqual(Palette.clay.wellEdgeAlpha, 0.14)
        XCTAssertEqual(Palette.night.wellEdgeAlpha, 0.12)
        for look in GalleryLook.all {
            look.apply()
            let steps = look == .night ? Palette.night : Palette.clay
            var drawn = NSColor.clear, edge = NSColor.clear
            NSAppearance(named: look.appearance)?.performAsCurrentDrawingAppearance {
                drawn = BarTheme.wellFill.usingColorSpace(.sRGB) ?? .clear
                edge = BarTheme.wellEdge.usingColorSpace(.sRGB) ?? .clear
            }
            XCTAssertEqual(drawn.alphaComponent, 1, "\(look.name): a well is opaque")
            near(drawn, steps.well, "\(look.name): the theme's well is the palette's")
            XCTAssertEqual(edge.alphaComponent, steps.wellEdgeAlpha, accuracy: 0.002, "\(look.name): the well's edge")
            near(edge, steps.ink, "\(look.name): the ink", tolerance: 0.01)
            // A placeholder in quiet ink still reads in the well.
            XCTAssertGreaterThanOrEqual(Readability.contrast(steps.quietInk.luminance, steps.well.luminance), 5,
                                        "\(look.name): quiet ink clears 5 : 1 in a well")
        }
    }

    func testTheStripsCardsAreStandingPanesAndOnlyTheActedOnOneIsTheKeyStep() {
        let stage = Stage()
        let a = stage.seedClip("one")
        stage.seedClip("two")
        stage.openStrip()
        let cards = stage.engine.strip.shownFills.filter { $0 != .well }
        XCTAssertEqual(Set(cards), [.pane], "no card is the one acted on; the empty slot is a well")
        for card in stage.engine.strip.shownCards.values {
            XCTAssertNotNil(card.subviews.first { $0 is CeramicPane }, "an opaque pane under its words")
            XCTAssertNil(card.subviews.first { String(describing: type(of: $0)).contains("Glass") })
        }
        stage.chord("k", .maskCommand)
        let fills = stage.engine.strip.shownFills.filter { $0 != .well }
        XCTAssertEqual(fills.filter { $0 == .key }.count, 1, "the card the actions act on")
        XCTAssertEqual(fills.filter { $0 == .pane }.count, fills.count - 1)
        _ = a
        stage.press("escape")
        stage.press("escape")
    }

    func testAnEmptyPinSlotIsAWell() {
        let stage = Stage()
        stage.seedClip("one")
        stage.openStrip()
        XCTAssertTrue(stage.engine.strip.shownFills.contains(.well), "slot one is drawn, waiting")
        let free = stage.engine.strip.shownFreePlaces.values
        XCTAssertFalse(free.isEmpty)
        XCTAssertTrue(free.allSatisfy { ($0 as? CeramicDepth)?.depth == .sinks }, "a place to put something sinks")
        stage.press("escape")
    }
}

/// The system's accessibility settings, honoured: more contrast means
/// captions in the label colour, and a mark's accent never sits on its
/// ground. (There is no transparency setting to honour: nothing is
/// translucent.)
final class AccessibilitySettingsTests: XCTestCase {
    override func tearDown() {
        Accessibility.reset()
        BarTheme.accentColor = { BarTheme.internationalOrange }
    }

    func testIncreaseContrastSetsCaptionsInTheInk() {
        // The grey resolves when drawn, so it is compared as drawn: in the
        // app's appearance, in sRGB.
        func drawn(_ color: NSColor) -> NSColor {
            var out = color
            NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
                out = color.usingColorSpace(.sRGB) ?? color
            }
            return out
        }
        Accessibility.increaseContrast = { true }
        XCTAssertEqual(drawn(BarTheme.secondaryColor), drawn(BarTheme.ink))
        Accessibility.increaseContrast = { false }
        XCTAssertNotEqual(drawn(BarTheme.secondaryColor), drawn(BarTheme.ink))
        XCTAssertEqual(drawn(BarTheme.secondaryColor), BarTheme.palette.quietInk.color.usingColorSpace(.sRGB),
                       "otherwise the look's quiet ink")
    }

    func testAnAccentOnItsGroundFallsBackToTheInk() {
        BarTheme.accentColor = { BarTheme.ground }
        XCTAssertEqual(BarTheme.readableAccent, BarTheme.ink, "no contrast at all")
        BarTheme.accentColor = { BarTheme.internationalOrange }
        XCTAssertEqual(BarTheme.readableAccent, BarTheme.internationalOrange, "each look's orange clears its own ground")
        BarTheme.accentColor = { BarTheme.palette.ink.color }
        XCTAssertNotEqual(BarTheme.readableAccent, BarTheme.ink, "a strong accent is kept as chosen")
    }

    func testTheInsertBarWearsTheReadableAccent() {
        BarTheme.accentColor = { BarTheme.ground }
        let panel = DraftPanel()
        defer { panel.hide() }
        panel.show(DraftView(buffer: Draft.Buffer(text: "x", cursor: 0), mode: .insert, editor: .insert,
                             speech: nil, destination: ("Notes", nil), replacing: false))
        XCTAssertEqual(panel.caretColor?.usingColorSpace(.sRGB), BarTheme.ink.usingColorSpace(.sRGB),
                       "a bar the eye could not find is drawn in the text's colour instead")
    }

    func testAFlashStaysLongEnoughToRead() {
        let stage = Stage()
        stage.hud.flash("press ⌘V to paste, this field blocks synthetic input")
        stage.clock.advance(by: 1.5)
        XCTAssertEqual(stage.hud.owner, .flash, "still up past the old fixed 1.4 seconds")
        stage.clock.advance(by: 1.6)
        XCTAssertNotEqual(stage.hud.owner, .flash, "gone once it has been read")
        stage.hud.flash("⌂ saved")
        stage.clock.advance(by: 1.5)
        XCTAssertNotEqual(stage.hud.owner, .flash, "a short flash still gets the floor")
    }
}

/// The strip's shadows: the window casts none, every card casts its own,
/// one, following its outline.
final class StripShadowTests: XCTestCase {
    func testTheWindowCastsNoShadowAndEveryCardDoes() {
        let stage = Stage()
        stage.seedClip("one")
        stage.openStrip()
        XCTAssertFalse(stage.engine.strip.castsWindowShadow)
        for card in stage.engine.strip.shownCards.values {
            XCTAssertTrue(card is ObjectSurface, "each card casts the drawn shadow of its own")
            let cast = card.layer?.sublayers?.filter { $0.shadowPath != nil } ?? []
            XCTAssertEqual(cast.count, 1, "one shadow, shaped to the card")
            XCTAssertEqual(cast.first?.shadowRadius, Ceramic.Shadow.radius)
            XCTAssertEqual(cast.first?.shadowOffset.height, -Ceramic.Shadow.drop)
        }
        stage.press("escape")
    }
}

/// The chip's words and Lodestar's own accent, as the app draws them.
final class AccentAndChipWordsTests: XCTestCase {
    func testTheOrangeAccentIsMeasuredForTheCurrentGround() {
        XCTAssertEqual(BarTheme.readableAccent.usingColorSpace(.sRGB),
                       BarTheme.internationalOrange.usingColorSpace(.sRGB),
                       "each look's orange clears the floor on its own ground, so no fallback")
        let steps = Tone.systemDark ? Palette.night : Palette.clay
        XCTAssertEqual(BarTheme.internationalOrange.usingColorSpace(.sRGB), steps.orange.color.usingColorSpace(.sRGB),
                       "one value per look: the palette's")
    }

    func testTheMeetingSpeaksMinutesInWordsAndSecondsInDigits() {
        XCTAssertEqual(MeetingController.sentence(title: "Standup", phase: .upcoming(minutes: 4)),
                       "Standup begins in four minutes")
        XCTAssertEqual(MeetingController.sentence(title: "Standup", phase: .upcoming(minutes: 1)),
                       "Standup begins in one minute")
        XCTAssertEqual(MeetingController.sentence(title: "Standup", phase: .soon(seconds: 45)),
                       "Standup begins in 45 seconds")
        XCTAssertEqual(MeetingController.sentence(title: "Standup", phase: .now),
                       "Standup is beginning")
        XCTAssertEqual(MeetingController.sentence(title: "Standup", phase: .inProgress(minutes: 10)),
                       "Standup began ten minutes ago")
        XCTAssertEqual(MeetingController.sentence(title: "Standup", phase: .inProgress(minutes: 25)),
                       "Standup began 25 minutes ago", "past twelve, digits")
    }

    func testTheStubCountsDownAndLightsAtTheDoor() {
        XCTAssertTrue(MeetingController.stub(for: .upcoming(minutes: 3)) == ("3", "min", false),
                      "minutes away: the count, quiet")
        XCTAssertTrue(MeetingController.stub(for: .soon(seconds: 42)) == ("42", "sec", true), "at the door: lit")
        XCTAssertTrue(MeetingController.stub(for: .now) == ("Now", nil, true))
        XCTAssertTrue(MeetingController.stub(for: .inProgress(minutes: 4)) == ("4", "min ago", true),
                      "begun: still lit, joining is still the thing to do")
    }

    func testTheChipSaysWhereAndHowMany() {
        XCTAssertEqual(MeetingController.meta(place: "Zoom", people: 6), "Zoom · 6 people")
        XCTAssertEqual(MeetingController.meta(place: "Work", people: nil), "Work", "no guests listed, no count")
        XCTAssertEqual(MeetingController.meta(place: "Zoom", people: 1), "Zoom", "only you is not a crowd")
    }
}

/// The accent never drifts: there is no setting, so the accent is
/// International Orange, and the Mac's own colour reaches no surface.
final class AccentDriftTests: XCTestCase {
    func testNoSurfaceReadsTheSystemAccentDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lodestar")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Ceramic.swift" }
        XCTAssertGreaterThan(files.count, 20, "the sources were found")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("controlAccentColor"),
                           "\(file.lastPathComponent) draws the system accent directly; use BarTheme.accent")
        }
    }

    func testTheSharedAccentIsInternationalOrange() {
        XCTAssertEqual(BarTheme.accent.usingColorSpace(.sRGB), BarTheme.internationalOrange.usingColorSpace(.sRGB))
    }
}

/// Text over the accent fill is chosen by measure, so a selected row
/// reads on any accent a person picks.
final class OnAccentTests: XCTestCase {
    override func tearDown() { BarTheme.accentColor = { BarTheme.internationalOrange } }

    private func contrast(_ text: NSColor, on fill: NSColor) -> Double {
        let t = text.usingColorSpace(.sRGB)!, f = fill.usingColorSpace(.sRGB)!
        return Readability.contrast(
            Readability.luminance(red: t.redComponent, green: t.greenComponent, blue: t.blueComponent),
            Readability.luminance(red: f.redComponent, green: f.greenComponent, blue: f.blueComponent))
    }

    func testInternationalOrangeOnCharcoalTakesInkNotWhite() {
        let orange = Palette.night.orange.color
        BarTheme.accentColor = { orange }
        XCTAssertEqual(BarTheme.onAccent, Palette.clay.ink.color, "white on this orange is 3.3 to 1; the ink is 5.36")
        XCTAssertGreaterThanOrEqual(contrast(BarTheme.onAccent, on: orange), 4.5, "reading text on a fill")
    }

    /// On clay the orange is deep enough to read as text on the pane (4.65
    /// to 1), one accent for every use, and a lit key's letter is clay's
    /// key face (5.01 to 1), not white. A deep blue takes the key face too.
    func testTheClayOrangeReadsAsTextAndTakesTheKeyFace() {
        let deep = Palette.clay.orange.color
        BarTheme.accentColor = { deep }
        XCTAssertGreaterThanOrEqual(contrast(deep, on: Palette.clay.pane.color), 4.5, "the accent reads as text on clay")
        XCTAssertEqual(BarTheme.onAccent, Palette.clay.key.color)
        XCTAssertGreaterThanOrEqual(contrast(BarTheme.onAccent, on: deep), 4.5)
        BarTheme.accentColor = { NSColor(srgbRed: 0.0, green: 0.3, blue: 0.8, alpha: 1) }
        XCTAssertEqual(BarTheme.onAccent, Palette.clay.key.color)
    }

    func testWhicheverReadsBetterWins() {
        let candidates = [Palette.clay.key.color, Palette.clay.ink.color]
        for fill in [NSColor.systemPurple, .systemGreen, .systemYellow, .systemBlue, .systemRed] {
            BarTheme.accentColor = { fill }
            XCTAssertTrue(candidates.contains(BarTheme.onAccent), "only clay's key face or clay's ink, never white or black")
            let chosen = contrast(BarTheme.onAccent, on: fill)
            let other = contrast(BarTheme.onAccent == candidates[0] ? candidates[1] : candidates[0], on: fill)
            XCTAssertGreaterThanOrEqual(chosen, other, "\(fill)")
        }
    }
}

/// The settings' switches are Lodestar's own, drawn in the accent.
final class AccentSwitchTests: XCTestCase {
    override func tearDown() {
        BarTheme.accentColor = { BarTheme.internationalOrange }
        Accessibility.reset()
    }

    /// A switch on screen, the way the settings window holds one: layers
    /// animate only inside a hosted tree.
    private func hosted() -> (NSWindow, AccentSwitch) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let toggle = AccentSwitch(frame: .zero)
        window.contentView?.addSubview(toggle)
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, toggle)
    }

    func testAFlipSlidesTheKnobUnlessMotionIsReduced() {
        Accessibility.reduceMotion = { false }
        let (window, toggle) = hosted()
        _ = toggle.accessibilityPerformPress()
        let knob = toggle.layer!.sublayers![1]
        XCTAssertNotNil(knob.animation(forKey: "slide"), "the knob crosses the track")
        XCTAssertNotNil(toggle.layer!.sublayers![0].animation(forKey: "tint"), "and the track's colour crosses with it")
        Accessibility.reduceMotion = { true }
        let (window2, still) = hosted()
        _ = still.accessibilityPerformPress()
        let stillKnob = still.layer!.sublayers![1]
        XCTAssertNil(stillKnob.animation(forKey: "slide"), "it simply arrives")
        _ = (window, window2)
    }

    private func trackColor(_ toggle: AccentSwitch) -> NSColor? {
        toggle.layoutSubtreeIfNeeded()
        return (toggle.layer?.sublayers?.first?.backgroundColor).flatMap(NSColor.init(cgColor:))
    }

    func testOnWearsTheAccentAndOffDoesNot() {
        let orange = BarTheme.internationalOrange
        BarTheme.accentColor = { orange }
        let toggle = AccentSwitch(frame: .zero)
        toggle.state = .on
        XCTAssertEqual(trackColor(toggle)?.usingColorSpace(.sRGB), orange.usingColorSpace(.sRGB))
        toggle.state = .off
        XCTAssertNotEqual(trackColor(toggle)?.usingColorSpace(.sRGB), orange.usingColorSpace(.sRGB))
    }

    func testAPressFlipsItAndFiresTheAction() {
        final class Sink: NSObject {
            var fired = 0
            @objc func pressed(_ sender: Any?) { fired += 1 }
        }
        let sink = Sink()
        let toggle = AccentSwitch(frame: .zero)
        toggle.target = sink
        toggle.action = #selector(Sink.pressed(_:))
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(sink.fired, 1)
        toggle.isEnabled = false
        _ = toggle.accessibilityPerformPress()
        XCTAssertEqual(toggle.state, .on, "a dimmed switch does not move")
        XCTAssertEqual(sink.fired, 1)
    }

    func testItSpeaksAsACheckBox() {
        let toggle = AccentSwitch(frame: .zero)
        XCTAssertEqual(toggle.accessibilityRole(), .checkBox)
        toggle.state = .on
        XCTAssertEqual(toggle.accessibilityValue() as? Int, 1)
    }
}

/// A switch survives the pane's rebuild, so its slide is seen.
final class SettingsSwitchSurvivalTests: XCTestCase {
    func testTheSameSwitchStandsAcrossRenders() {
        let controller = SettingsController.preview(0)
        controller.rerender()
        let first = controller.switchView(for: "app.auto-update")
        XCTAssertNotNil(first)
        controller.rerender()
        let second = controller.switchView(for: "app.auto-update")
        XCTAssertTrue(first === second, "rebuilt controls would arrive at rest before the eye saw them move")
        XCTAssertNotNil(second?.superview, "and it is on the pane")
    }

    /// The slide a press started is still running after the write's
    /// render re-hosts the switch — which is the whole point of keeping it.
    func testASlideOutlivesTheRenderAWriteCauses() {
        Accessibility.reduceMotion = { false }
        defer { Accessibility.reset() }
        let controller = SettingsController.preview(0)
        controller.rerender()
        let toggle = controller.switchView(for: "app.auto-update")!
        let before = toggle.state
        toggle.set(before == .on ? .off : .on, animated: true)
        controller.rerender()
        let kept = controller.switchView(for: "app.auto-update")!
        XCTAssertTrue(kept === toggle)
        XCTAssertNotNil(kept.layer?.sublayers?[1].animation(forKey: "slide"), "the slide is still attached")
        XCTAssertNotNil(kept.superview)
    }
}

/// The one key: resting a quiet cap, lit a piece of the mark.
final class KeyFaceTests: XCTestCase {
    func testALitKeyIsTheAccentWithItsReadableInk() {
        let saved = BarTheme.accentColor
        BarTheme.accentColor = { BarTheme.internationalOrange }
        defer { BarTheme.accentColor = saved }
        let key = KeyFace("E")
        key.frame = NSRect(x: 0, y: 0, width: 40, height: BarTheme.keyHeight)
        key.layout()
        let standing: Standing? = key.standing
        XCTAssertNotEqual(standing?.faceColor, BarTheme.accent.cgColor, "resting is not lit")
        key.lit = true
        XCTAssertEqual(standing?.faceColor, BarTheme.accent.cgColor)
        XCTAssertEqual(key.label.textColor, BarTheme.onAccent)
        XCTAssertEqual(key.drawnSide, Ceramic.Side.control, accuracy: 0.01, "the side stands beneath the face")
        XCTAssertNotNil(standing?.sideColor, "in a darker shade of the accent")
        XCTAssertNotEqual(standing?.sideColor, standing?.faceColor)
    }

    /// A caption's grey is resolved when drawn: the same colour object
    /// reads dark on paper and light on charcoal, so a title built in one
    /// appearance is right after the Mac switches to the other.
    func testTheSecondaryGreyFollowsTheAppearance() {
        func resolved(_ name: NSAppearance.Name) -> NSColor {
            var out = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                out = BarTheme.secondaryColor.usingColorSpace(.sRGB)!
            }
            return out
        }
        let light = resolved(.aqua), dark = resolved(.darkAqua)
        XCTAssertEqual(light, Palette.clay.quietInk.color.usingColorSpace(.sRGB), "clay's quiet ink on clay")
        XCTAssertEqual(dark, Palette.night.quietInk.color.usingColorSpace(.sRGB), "espresso's on espresso")
    }

    /// Every surface with the drawn shadow is gated by construction: the
    /// shadow's margin passes the pointer through, the glass takes it.
    func testAHostedSurfaceTakesThePointerOnlyOverItsGlass() {
        let panel = Ceramic.makePanel(level: .floating)
        let gate = SoftShadow.host(NSView(), in: panel, cornerRadius: BarTheme.surfaceRadius)
        let glass = NSRect(x: 300, y: 300, width: 400, height: 120)
        panel.setFrame(SoftShadow.outset(glass), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        gate.update(pointer: NSPoint(x: glass.midX, y: glass.midY))
        XCTAssertTrue(gate.open)
        gate.update(pointer: NSPoint(x: glass.midX, y: glass.minY - 30))
        XCTAssertFalse(gate.open, "a click in the shadow belongs to the app beneath")
    }

    func testTheGroundIsTheNightOrClay() {
        let steps = Tone.systemDark ? Palette.night : Palette.clay
        XCTAssertEqual(BarTheme.ground, steps.pane.color)
        XCTAssertEqual(BarTheme.raised, steps.key.color)
    }
}

/// The app's icon: the mark in the accent on the plate of the appearance
/// in force, flat.
final class AppIconArtTests: XCTestCase {
    private func pixels(_ image: NSImage) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Slip at night, clay by day, sampled on the plate clear of the mark.
    func testThePlateIsThePaletteInForce() throws {
        let orange = NSColor(srgbRed: 1, green: 0.31, blue: 0, alpha: 1)
        let night = try XCTUnwrap(pixels(AppIconArt.current(dark: true, accent: orange)).colorAt(x: 40, y: 128)?
            .usingColorSpace(.sRGB))
        let clay = try XCTUnwrap(pixels(AppIconArt.current(dark: false, accent: orange)).colorAt(x: 40, y: 128)?
            .usingColorSpace(.sRGB))
        XCTAssertEqual(night.redComponent, 0x22 / 255, accuracy: 0.02, "Slip's pane")
        XCTAssertEqual(night.blueComponent, 0x19 / 255, accuracy: 0.02)
        XCTAssertEqual(clay.redComponent, 0xF8 / 255, accuracy: 0.02, "clay's pane")
        XCTAssertEqual(clay.blueComponent, 0xE7 / 255, accuracy: 0.02)
    }

    /// The mark wears whatever accent it is given.
    func testTheMarkWearsTheAccent() {
        func count(_ rep: NSBitmapImageRep, _ wanted: (NSColor) -> Bool) -> Int {
            var n = 0
            for x in stride(from: 0, to: 256, by: 2) {
                for y in stride(from: 0, to: 256, by: 2) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), wanted(c) { n += 1 }
                }
            }
            return n
        }
        let orange = pixels(AppIconArt.current(dark: true, accent: NSColor(srgbRed: 1, green: 0.31, blue: 0, alpha: 1)))
        let blue = pixels(AppIconArt.current(dark: true, accent: NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)))
        XCTAssertGreaterThan(count(orange) { $0.redComponent > $0.blueComponent + 0.4 }, 500)
        XCTAssertGreaterThan(count(blue) { $0.blueComponent > $0.redComponent + 0.4 }, 500)
        XCTAssertLessThan(count(blue) { $0.redComponent > $0.blueComponent + 0.4 }, 20, "no orange left in a blue icon")
    }
}

/// Light and dark are whichever the Mac shows now, not whichever it showed
/// when Lodestar started.
final class ToneFollowsAppearanceTests: XCTestCase {
    func testAToneViewRepaintsWhenTheLookChanges() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let view = ToneView(fill: .labelColor)
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        let light = try XCTUnwrap(view.layer?.backgroundColor).components ?? []
        window.appearance = NSAppearance(named: .darkAqua)
        let dark = try XCTUnwrap(view.layer?.backgroundColor).components ?? []
        XCTAssertNotEqual(light, dark, "the label colour is ink by day and paper by night")
        XCTAssertLessThan(light.first ?? 1, 0.5, "dark ink on the light look")
        XCTAssertGreaterThan(dark.first ?? 0, 0.5, "light ink on the dark look")
    }

    /// The bug that hid the draft's cursor: a colour with an alpha applied
    /// is fixed when it is made, so a surface that stored one kept the look
    /// it was made in. Made again at each paint, it follows.
    func testAColourWithAnAlphaFollowsTheLookToo() throws {
        let app = NSApplication.shared
        let before = app.appearance
        defer { app.appearance = before }
        app.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view = ToneView(fill: NSColor.labelColor.withAlphaComponent(0.5))
        window.contentView = view
        let night = try XCTUnwrap(view.layer?.backgroundColor).components ?? []
        app.appearance = NSAppearance(named: .aqua)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let day = try XCTUnwrap(view.layer?.backgroundColor).components ?? []
        XCTAssertGreaterThan(night.first ?? 0, 0.5, "paper ink by night")
        XCTAssertLessThan(day.first ?? 1, 0.5, "dark ink by day, though made at night")
    }

    func testResolvedTakesTheViewsAppearanceNotTheCurrentOne() {
        let view = NSView()
        view.appearance = NSAppearance(named: .aqua)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let ink = Ceramic.resolved(.labelColor, in: view).components ?? []
            XCTAssertLessThan(ink.first ?? 1, 0.5, "the view is light, whatever is current")
        }
    }
}

/// The clay pictures wear the look in force: pale by night, Slip by day.
final class TonedPictureTests: XCTestCase {
    private func solid(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        }
    }

    private func brightness(of image: NSImage, in appearance: NSAppearance.Name) -> CGFloat {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 4, height: 4))
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep.colorAt(x: 2, y: 2)?.brightnessComponent ?? -1
    }

    func testThePictureFollowsTheLook() {
        let picture = TonedPicture.make(night: solid(.white), day: solid(.black))
        XCTAssertGreaterThan(brightness(of: picture, in: .darkAqua), 0.9, "pale by night")
        XCTAssertLessThan(brightness(of: picture, in: .aqua), 0.1, "Slip by day")
    }

    func testEveryPictureHasItsSandTwin() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packaging")
        for folder in ["places", "doors"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? []
            // The pictures themselves: place-name.png, door-name.png.
            let pale = names.filter { $0.range(of: #"^(place|door)-[a-z]+\.png$"#, options: .regularExpression) != nil }
            XCTAssertFalse(pale.isEmpty)
            for name in pale {
                XCTAssertTrue(names.contains(name.replacingOccurrences(of: ".png", with: "-sand.png")),
                              "\(name) has no sand twin for the light look")
            }
        }
    }
}
