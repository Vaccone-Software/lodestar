import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// One ceramic. Every panel, card, and chip is the launcher's pane: opaque,
/// in the palette's own colour, re-read live.
final class CeramicTests: XCTestCase {
    override func setUp() { Accessibility.reset() }
    override func tearDown() { Accessibility.reset() }

    /// The colour a layer holds, in sRGB.
    private func rgb(_ color: CGColor?) -> NSColor? {
        color.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
    }

    /// A pane in a window of the given look, the way a backdrop stands.
    private func paneInAWindow(_ look: NSAppearance.Name = .aqua, weight: Ceramic.Weight = .normal)
        -> (NSWindow, CeramicPane) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look)
        let pane = CeramicPane(radius: BarTheme.surfaceRadius, weight: weight)
        pane.frame = NSRect(x: 0, y: 0, width: 100, height: 60)
        window.contentView?.addSubview(pane)
        window.contentView?.layoutSubtreeIfNeeded()
        pane.updateLayer()
        return (window, pane)
    }

    func testThePaneIsOpaqueCeramicInThePalettesOwnColour() {
        for (look, steps) in [(NSAppearance.Name.aqua, Palette.clay), (.darkAqua, Palette.night)] {
            let (window, pane) = paneInAWindow(look)
            let fill = rgb(pane.layer?.backgroundColor)
            XCTAssertEqual(fill, steps.pane.color.usingColorSpace(.sRGB), "the look's pane: \(look.rawValue)")
            XCTAssertEqual(fill?.alphaComponent, 1, "opaque: nothing of the desktop shows through")
            XCTAssertEqual(pane.layer?.cornerRadius, BarTheme.surfaceRadius)
            XCTAssertEqual(pane.edge.hairlineWidth, 0.5, "a half-point hairline for its edge")
            XCTAssertEqual(rgb(pane.edge.hairlineColor)?.alphaComponent ?? 0, CGFloat(steps.hairlineAlpha), accuracy: 0.001)
            _ = window
        }
    }

    func testThePolishedRimCatchesTheLightAlongTheTop() throws {
        let (day, dayPane) = paneInAWindow(.aqua)
        let (night, nightPane) = paneInAWindow(.darkAqua)
        dayPane.edge.layoutSubtreeIfNeeded()
        XCTAssertEqual(dayPane.edge.rimFrame.height, 1.5)
        XCTAssertEqual(dayPane.edge.rimFrame.maxY, dayPane.edge.bounds.height, "along the top edge")
        XCTAssertEqual(rgb(dayPane.edge.rimColor), NSColor.white.usingColorSpace(.sRGB), "white by day")
        XCTAssertEqual(rgb(nightPane.edge.rimColor)?.alphaComponent ?? 0, 0.10, accuracy: 0.001, "a tenth at night")
        XCTAssertEqual(dayPane.edge.layer?.masksToBounds, true, "clipped to the pane's own corners")
        _ = (day, night)
    }

    func testThePaneFollowsTheLookWhileItStands() {
        let (window, pane) = paneInAWindow(.aqua)
        window.appearance = NSAppearance(named: .darkAqua)
        pane.viewDidChangeEffectiveAppearance()
        pane.updateLayer()
        XCTAssertEqual(rgb(pane.layer?.backgroundColor), Palette.night.pane.color.usingColorSpace(.sRGB),
                       "a standing surface is espresso when the Mac turns dark, not at its next opening")
    }

    func testNothingFrostsBehindAnyInstalledBackdrop() {
        let root = NSView()
        Ceramic.installBackdrop(in: root, cornerRadius: 18)
        var found: [String] = []
        func walk(_ view: NSView) {
            if view is NSVisualEffectView || view is NSGlassEffectView { found.append(String(describing: type(of: view))) }
            view.subviews.forEach(walk)
        }
        walk(root)
        XCTAssertEqual(found, [], "no blur, no frost, no material: on every macOS")
    }

    func testOneBackdropWithAWeight() {
        let root = NSView()
        let normal = Ceramic.installBackdrop(in: root, cornerRadius: 18)
        let raised = Ceramic.installBackdrop(in: NSView(), cornerRadius: 18, weight: .raised)
        let faint = Ceramic.installBackdrop(in: NSView(), cornerRadius: 18, weight: .faint)
        XCTAssertEqual(Ceramic.weight(in: normal), .normal)
        XCTAssertEqual(Ceramic.weight(in: raised), .raised)
        XCTAssertEqual(Ceramic.weight(in: faint), .faint)
        XCTAssertEqual(root.subviews.first, normal, "installed under everything else")
    }

    func testAWeightIsAStepOfThePalette() {
        for (look, steps) in [(NSAppearance.Name.aqua, Palette.clay), (.darkAqua, Palette.night)] {
            for (weight, step) in [(Ceramic.Weight.normal, steps.pane), (.raised, steps.raised), (.faint, steps.ground)] {
                let (window, pane) = paneInAWindow(look, weight: weight)
                XCTAssertEqual(rgb(pane.layer?.backgroundColor), step.color.usingColorSpace(.sRGB), "\(weight) in \(look.rawValue)")
                _ = window
            }
        }
    }

    func testASunkSlotCatchesNoLightOnItsRim() throws {
        let (window, pane) = paneInAWindow(.aqua, weight: .faint)
        XCTAssertNil(pane.edge.rimColor, "a place you put something is not a thing the light falls on")
        _ = window
    }

    /// Content that fills a pane edge to edge (a picture, a tile) covers an
    /// edge drawn under it, so the edge is a view above the content, whenever
    /// the content was added.
    func testThePanesEdgeStandsAboveContentAddedAfterIt() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        let pane = try XCTUnwrap(Ceramic.installBackdrop(in: root, cornerRadius: 18) as? CeramicPane)
        let picture = NSView(frame: root.bounds)
        picture.wantsLayer = true
        root.addSubview(picture)
        XCTAssertTrue(pane.edge.superview === root, "beside the content, not under it")
        XCTAssertGreaterThan(pane.edge.layer?.zPosition ?? 0, picture.layer?.zPosition ?? 0, "and above what came later")
        XCTAssertNil(pane.edge.hitTest(NSPoint(x: 50, y: 30)), "it takes no pointer")
        pane.removeFromSuperview()
        XCTAssertNil(pane.edge.superview, "it goes with its pane")
    }

    func testAPaneStandingInAnObjectLeavesTheEdgeToIt() {
        let card = SoftShadow.object(radius: BarTheme.surfaceRadius, lift: .rest)
        let pane = Ceramic.installBackdrop(in: card, cornerRadius: BarTheme.surfaceRadius) as? CeramicPane
        XCTAssertEqual(pane?.drawsEdge, false, "the hairline is drawn once")
    }

    func testAMarkIsTheOneKeyStandingOnItsSideAndAShadow() throws {
        let mark = KeyMark.key("ab")
        XCTAssertNotNil(mark.layer?.shadowPath, "stands on a short warm shadow")
        let key = try XCTUnwrap(mark.subviews.first as? KeyBody)
        XCTAssertEqual(key.faceColor, Ceramic.resolved(BarTheme.markFill), "the key's face, opaque over the app")
        XCTAssertEqual(key.sideColor, Ceramic.resolved(BarTheme.keySide), "on its side")
        XCTAssertEqual(key.layers.stance, .standing)
        XCTAssertEqual(key.layers.face.frame.minY, KeyLayers.sideHeight(forHeight: KeyMark.height), "three points up at key size")
        let label = key.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertEqual(label?.stringValue, "AB")
        XCTAssertEqual(mark.frame.height, KeyMark.height)
    }

    func testTheStripsCardsAreKeysAndOnlyTheChosenOneIsTheSlab() {
        let stage = Stage()
        let a = stage.seedClip("one")
        stage.seedClip("two")
        stage.openStrip()
        let cards = stage.engine.strip.shownWeights.filter { $0 != .faint }
        XCTAssertEqual(cards.filter { $0 == .slab }.count, 1, "the newest is the one chosen until a key moves it")
        XCTAssertEqual(cards.filter { $0 == .raised }.count, cards.count - 1, "every other card is a key's face")
        XCTAssertFalse(cards.contains(.normal), "no card is a flat pane")
        for card in stage.engine.strip.shownCards.values {
            let backdrop = card.subviews.first { Ceramic.weight(in: $0) != nil }
            XCTAssertNotNil(backdrop)
            XCTAssertTrue(backdrop is CeramicPane, "the strip's cards are the launcher's ceramic")
        }
        stage.chord("k", .maskCommand)
        let weights = stage.engine.strip.shownWeights.filter { $0 != .faint }
        XCTAssertEqual(weights.filter { $0 == .slab }.count, 1, "the card the actions act on, and no other")
        XCTAssertEqual(weights.filter { $0 == .raised }.count, weights.count - 1)
        _ = a
        stage.press("escape")
        stage.press("escape")
    }

    /// A clip stands on a visible side, the chosen one on the slab's, and
    /// the free keepsake is a well that receives: sunk, with no side and no
    /// shadow. The cards' own content (the clip's text) is untouched.
    func testClipsStandOnASideTheChosenOneOnTheSlabsAndTheFreeKeepsakeIsAWell() {
        let stage = Stage()
        stage.seedClip("one")
        stage.seedClip("two")
        stage.openStrip()
        let surfaces = stage.engine.strip.shownCards.values.compactMap { $0 as? ObjectSurface }
        XCTAssertEqual(surfaces.filter { $0.stance == .slab }.count, 1)
        XCTAssertGreaterThan(surfaces.filter { $0.stance == .key }.count, 0)
        for card in surfaces {
            XCTAssertGreaterThan(card.sideHeight, 0, "a visible side")
            XCTAssertNotNil(card.sideColor)
        }
        let slab = surfaces.first { $0.stance == .slab }
        XCTAssertEqual(slab?.appearance?.bestMatch(from: [.darkAqua, .aqua]),
                       Tone.systemDark ? .aqua : .darkAqua, "the chosen card wears the other look")
        XCTAssertFalse(slab?.hasEdge ?? true, "the slab is a ground and wants no outline")
        let well = ObjectSurface(radius: BarTheme.surfaceRadius, lift: .rest)
        well.stance = .well
        well.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(well.sideHeight, 0, "a place that receives has no side")
        XCTAssertTrue(stage.engine.strip.shownStances.contains(.well), "the free keepsake is the well")
        XCTAssertEqual(stage.engine.strip.shownStances.filter { $0 == .well }.count,
                       stage.engine.strip.shownWeights.filter { $0 == .faint }.count, "and only it is sunk")
        stage.press("escape")
    }

    func testAnEmptyPinSlotIsFaint() {
        let stage = Stage()
        stage.seedClip("one")
        stage.openStrip()
        XCTAssertTrue(stage.engine.strip.shownWeights.contains(.faint), "slot one is drawn, waiting")
        stage.press("escape")
    }
}

/// The system's accessibility settings, honoured: more contrast means
/// captions in the label colour, and a mark's accent never sits on its
/// ground. Reduce Transparency has nothing to ask of a surface that is
/// opaque already.
final class AccessibilitySettingsTests: XCTestCase {
    override func tearDown() {
        Accessibility.reset()
        BarTheme.accentColor = { BarTheme.internationalOrange }
    }

    func testIncreaseContrastSetsCaptionsInTheLabelColour() {
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
        XCTAssertEqual(drawn(BarTheme.secondaryColor), BarTheme.palette.secondary.color.usingColorSpace(.sRGB), "the palette's own quiet ink")
    }

    func testAnAccentOnItsGroundFallsBackToTheLabelColour() {
        BarTheme.accentColor = { BarTheme.ground }
        XCTAssertEqual(BarTheme.readableAccent, BarTheme.ink, "no contrast at all")
        BarTheme.accentColor = { .systemOrange }
        if Tone.systemDark {
            XCTAssertEqual(BarTheme.readableAccent, .systemOrange, "orange clears charcoal")
        } else {
            XCTAssertEqual(BarTheme.readableAccent, BarTheme.ink, "orange does not clear paper")
        }
        BarTheme.accentColor = { Tone.systemDark ? .white : .black }
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

/// The strip's shadows: the window casts none, every plate casts its own.
final class StripShadowTests: XCTestCase {
    func testTheWindowCastsNoShadowAndEveryCardDoes() {
        let stage = Stage()
        stage.seedClip("one")
        stage.openStrip()
        XCTAssertFalse(stage.engine.strip.castsWindowShadow)
        for card in stage.engine.strip.shownCards.values {
            XCTAssertTrue(card is ObjectSurface, "each card casts the drawn shadow of its own")
            let cast = card.layer?.sublayers?.filter { $0.shadowPath != nil } ?? []
            XCTAssertEqual(cast.count, 2, "the soft shadow and the contact line, shaped to the card")
        }
        stage.press("escape")
    }
}

/// The chip's words and Lodestar's own accent, as the app draws them.
final class AccentAndChipWordsTests: XCTestCase {
    func testTheAccentIsInternationalOrangeMeasuredForTheCurrentGround() {
        XCTAssertEqual(BarTheme.accent.usingColorSpace(.sRGB), BarTheme.internationalOrange.usingColorSpace(.sRGB),
                       "no setting: the accent is Lodestar's own orange")
        XCTAssertEqual(BarTheme.readableAccent.usingColorSpace(.sRGB),
                       BarTheme.internationalOrange.usingColorSpace(.sRGB),
                       "the pair clears the floor on its own ground, so no fallback")
    }

    /// One value per look, exactly what Readability measures: the true
    /// colour on espresso and the same hue deeper on clay.
    func testTheOrangeIsOneValuePerLookAsMeasured() {
        for (look, pair) in [(NSAppearance.Name.darkAqua, Readability.orangeOnCharcoal), (.aqua, Readability.orangeOnPaper)] {
            let view = NSView()
            view.appearance = NSAppearance(named: look)
            let resolved = Ceramic.resolved(BarTheme.internationalOrange, in: view)
            let color = NSColor(cgColor: resolved)?.usingColorSpace(.sRGB)
            XCTAssertEqual(color?.redComponent ?? 0, CGFloat(pair.red), accuracy: 0.002, look.rawValue)
            XCTAssertEqual(color?.greenComponent ?? 0, CGFloat(pair.green), accuracy: 0.002)
            XCTAssertEqual(color?.blueComponent ?? 1, CGFloat(pair.blue), accuracy: 0.002)
        }
        XCTAssertEqual(Readability.orangeOnCharcoal, Readability.RGB(red: 1.0, green: 0.31, blue: 0.0), "#FF4F00 at night")
        XCTAssertEqual(Readability.orangeOnPaper.red, 0.769, accuracy: 0.001, "#C43B00 on clay")
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

    /// The meeting is a countdown key (it replaced the ticket stub): its
    /// legend is the time, and it lights only when joining is the thing to do.
    func testTheCountdownKeyCountsDownAndLightsAtTheDoor() {
        XCTAssertTrue(MeetingController.countdown(for: .upcoming(minutes: 3)) == ("3m", false),
                      "minutes away: the count, a quiet key")
        XCTAssertTrue(MeetingController.countdown(for: .upcoming(minutes: 14)) == ("14m", false))
        XCTAssertTrue(MeetingController.countdown(for: .soon(seconds: 42)) == ("42s", true), "at the door: lit")
        XCTAssertTrue(MeetingController.countdown(for: .now) == ("Now", true))
        XCTAssertTrue(MeetingController.countdown(for: .inProgress(minutes: 4)) == ("4m ago", true),
                      "begun: still lit, joining is still the thing to do")
    }

    /// No ticket shapes remain: the chip is a pane, a key and words. The
    /// countdown is a `KeyFace` in the theme's countdown face, lit exactly
    /// when the phase says, and nothing draws a perforation or a torn edge.
    func testTheChipHasNoTicketShapesAndTheCountdownIsTheOneKey() throws {
        let text = try String(contentsOf: DesignDriftTests.appSources.appendingPathComponent("MeetingController.swift"),
                              encoding: .utf8)
        let code = DesignDriftTests.code(text)
        for shape in ["Perforation", "perforation", "maskedCorners", "stubWidth", "stubView"] {
            XCTAssertFalse(code.contains(shape), "a ticket's \(shape) is gone")
        }
        XCTAssertTrue(code.contains("KeyFace(countdown.legend"), "the legend stands on a key")
        XCTAssertTrue(code.contains("countdownKey.lit = countdown.lit"), "lit only when it is time to join")
        XCTAssertTrue(code.contains("countdownKey.quiet = !countdown.lit"), "quiet before that")
        XCTAssertEqual(BarTheme.countdownFont.pointSize, BarTheme.Scale.title, "read on the scale")
        let key = KeyFace("4m", height: BarTheme.countdownHeight, font: BarTheme.countdownFont, minWidth: BarTheme.countdownHeight)
        key.lit = true
        XCTAssertEqual(key.stance, .standing, "lit, it stands on its side")
        key.quiet = true; key.lit = false
        XCTAssertEqual(key.stance, .flat, "quiet, it lies flat with no side")
    }

    func testTheChipSaysWhereAndHowMany() {
        XCTAssertEqual(MeetingController.meta(place: "Zoom", people: 6), "Zoom · 6 people")
        XCTAssertEqual(MeetingController.meta(place: "Work", people: nil), "Work", "no guests listed, no count")
        XCTAssertEqual(MeetingController.meta(place: "Zoom", people: 1), "Zoom", "only you is not a crowd")
    }
}

/// The accent never drifts: the system's colour reaches no surface, so
/// International Orange is every place the accent shows.
final class AccentDriftTests: XCTestCase {
    func testNoSurfaceReadsTheSystemAccentDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lodestar")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20, "the sources were found")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("controlAccentColor"),
                           "\(file.lastPathComponent) draws the system accent directly; use BarTheme.accent")
        }
    }

    func testTheAccentIsOrangeWhateverTheMacsAccentIs() {
        XCTAssertEqual(BarTheme.accent.usingColorSpace(.sRGB), BarTheme.internationalOrange.usingColorSpace(.sRGB))
        XCTAssertNotEqual(BarTheme.accent.usingColorSpace(.sRGB), NSColor.controlAccentColor.usingColorSpace(.sRGB),
                          "the Mac's accent never reaches a surface")
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
        let orange = NSColor(srgbRed: Readability.orangeOnCharcoal.red, green: Readability.orangeOnCharcoal.green,
                             blue: Readability.orangeOnCharcoal.blue, alpha: 1)
        BarTheme.accentColor = { orange }
        XCTAssertNotEqual(BarTheme.onAccent, .white, "white on this orange is 3.3 to 1")
        XCTAssertGreaterThanOrEqual(contrast(BarTheme.onAccent, on: orange), 4.5, "reading text on a fill")
    }

    /// On clay the orange is the same hue deepened until it reads as text
    /// on the pane (4.65 to 1), one accent for every use; deep enough that
    /// a lit key's letter is white (5.3 to 1). A deep blue takes white too.
    func testTheClayOrangeReadsAsTextAndTakesWhite() {
        let deep = NSColor(srgbRed: Readability.orangeOnPaper.red, green: Readability.orangeOnPaper.green,
                           blue: Readability.orangeOnPaper.blue, alpha: 1)
        BarTheme.accentColor = { deep }
        XCTAssertGreaterThanOrEqual(contrast(deep, on: Palette.clay.pane.color), 4.5, "the accent reads as text on clay")
        XCTAssertEqual(BarTheme.onAccent, .white)
        XCTAssertGreaterThanOrEqual(contrast(BarTheme.onAccent, on: deep), 4.5)
        BarTheme.accentColor = { NSColor(srgbRed: 0.0, green: 0.3, blue: 0.8, alpha: 1) }
        XCTAssertEqual(BarTheme.onAccent, .white)
    }

    func testWhicheverReadsBetterWins() {
        for fill in [NSColor.systemPurple, .systemGreen, .systemYellow, .systemBlue, .systemRed] {
            BarTheme.accentColor = { fill }
            let chosen = contrast(BarTheme.onAccent, on: fill)
            let other = contrast(BarTheme.onAccent == .white ? NSColor(white: 0.08, alpha: 1) : .white, on: fill)
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

    /// A switch's knob is a thing you press, so it stands on a side like a
    /// key does, in the same ceramic, and casts no shadow.
    func testTheKnobStandsOnASideLikeAKey() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let toggle = AccentSwitch(frame: .zero)
        window.contentView?.addSubview(toggle)
        window.contentView?.layoutSubtreeIfNeeded()
        let knob = toggle.layer!.sublayers![1]
        XCTAssertEqual(knob.shadowOpacity, 0, "no shadow: the side is what stands")
        let parts = try XCTUnwrap(knob.sublayers)
        XCTAssertEqual(parts.count, 2, "a side and a face")
        XCTAssertEqual(parts[0].frame.minY, -AccentSwitch.knobSideHeight, accuracy: 0.01, "the side hangs below the face")
        func rgb(_ c: CGColor?) -> NSColor? { c.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB) }
        XCTAssertEqual(rgb(parts[1].backgroundColor), BarTheme.palette.keyFace.color.usingColorSpace(.sRGB), "the key's own face")
        XCTAssertEqual(rgb(parts[0].backgroundColor), BarTheme.palette.keySide.color.usingColorSpace(.sRGB), "and side")
        _ = window
    }

    /// A switch that cannot be pressed lies flat like a quiet key, and is
    /// never faded: no side, a hairline round the knob, and the layer opaque.
    func testASwitchThatCannotBePressedLiesFlatAndIsNeverFaded() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let toggle = AccentSwitch(frame: .zero)
        window.contentView?.addSubview(toggle)
        toggle.isEnabled = false
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(toggle.layer?.opacity, 1, "depth carries it, never a fade")
        let parts = try XCTUnwrap(toggle.layer!.sublayers![1].sublayers)
        XCTAssertTrue(parts[0].isHidden, "no side")
        XCTAssertNil(parts[1].backgroundColor, "no fill on the knob")
        XCTAssertEqual(parts[1].borderWidth, 0.5, "a hairline instead")
        toggle.isEnabled = true
        XCTAssertFalse(parts[0].isHidden, "and the side is back when it can be pressed")
        _ = window
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

/// Each look is the other's selection: a chosen row is a slab of the
/// opposite look, and everything in it follows.
final class SlabTests: XCTestCase {
    override func tearDown() { BarTheme.accentColor = { BarTheme.internationalOrange } }

    private func rgb(_ color: CGColor?) -> NSColor? { color.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB) }

    /// A row in a window of the given look, with a label and a lit key in it.
    private func row(in look: NSAppearance.Name) -> (NSWindow, RaisedRow, NSTextField, KeyFace) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look)
        let row = RaisedRow(frame: NSRect(x: 10, y: 20, width: 280, height: 48))
        window.contentView?.addSubview(row)
        row.setupRaised()
        let label = NSTextField(labelWithString: "Safari")
        label.textColor = BarTheme.ink
        let key = KeyFace("⏎")
        key.lit = true
        row.addSubview(label)
        row.addSubview(key)
        row.applyRaised(true)
        window.contentView?.layoutSubtreeIfNeeded()
        row.layout()
        return (window, row, label, key)
    }

    func testAChosenRowIsTheOppositeLooksSlabOnAFourPointSide() {
        for (look, steps) in [(NSAppearance.Name.aqua, Palette.clay), (.darkAqua, Palette.night)] {
            let (window, row, _, _) = row(in: look)
            XCTAssertEqual(rgb(row.slabColors.face), steps.slab.color.usingColorSpace(.sRGB), "the slab, \(look.rawValue)")
            XCTAssertEqual(rgb(row.slabColors.side), steps.slabSide.color.usingColorSpace(.sRGB), "and its side")
            let layers = row.layer!.sublayers!
            let side = layers.first { $0.frame.minY == 0 && $0.backgroundColor != nil && $0.frame.height < row.bounds.height }
            XCTAssertNotNil(side, "a four-point side stands at the foot of the row")
            XCTAssertEqual(side?.isHidden, false)
            XCTAssertGreaterThanOrEqual(layers.map { $0.frame.minY }.min() ?? 0, 0, "inside the row's own bounds: nothing hangs below")
            _ = window
        }
    }

    /// The side is inside the row, so a scroll view cannot clip it and the
    /// next row cannot cover it: the face is the row less the side, and the
    /// words are centred on the face, whether the row is chosen or not.
    func testTheSlabsSideIsInsideTheRowAndTheContentIsCentredOnTheFace() {
        let (window, row, _, _) = row(in: .aqua)
        let face = row.faceBounds
        XCTAssertEqual(face.minY, RaisedRow.sideHeight)
        XCTAssertEqual(face.height, row.bounds.height - RaisedRow.sideHeight)
        XCTAssertEqual(face.maxY, row.bounds.maxY, "the face reaches the row's top")
        let layout = RaisedRow(frame: NSRect(x: 0, y: 0, width: 200, height: 48))
        layout.setupRaised()
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        layout.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerYAnchor.constraint(equalTo: layout.faceGuide.centerYAnchor),
            content.heightAnchor.constraint(equalToConstant: 20), content.widthAnchor.constraint(equalToConstant: 20),
        ])
        layout.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.frame.midY, layout.faceBounds.midY, accuracy: 0.5, "centred on the face, not on the row")
        for raised in [false, true] {
            layout.applyRaised(raised)
            layout.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.frame.midY, layout.faceBounds.midY, accuracy: 0.5, "and it stays when chosen: \(raised)")
        }
        _ = window
    }

    /// A Settings popup's rows highlight as the slab too: the highlight is
    /// the other look's ground, and the words on it that look's ink.
    func testAChoiceMenuRowHighlightsAsTheSlab() {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let item = NSMenuItem(title: "Weekly", action: nil, keyEquivalent: "")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let view = ChoiceMenuItemView(item: item, chosen: true, width: 200, popup: popup)
        window.contentView?.addSubview(view)
        view.paint(lit: false)
        XCTAssertEqual(rgb(Ceramic.resolved(BarTheme.ink, in: view)), Palette.clay.ink.color.usingColorSpace(.sRGB))
        view.paint(lit: true)
        let label = view.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertEqual(rgb(label?.textColor?.cgColor), Palette.night.ink.color.usingColorSpace(.sRGB), "the slab's ink, by day")
        XCTAssertTrue(view.lit)
        let dot = view.subviews.first { $0.layer?.cornerRadius == BarTheme.dotRadius }
        let orange = Readability.orangeOnCharcoal
        XCTAssertEqual(rgb(dot?.layer?.backgroundColor)?.redComponent ?? 0, CGFloat(orange.red), accuracy: 0.01,
                       "and its dot is the orange of the slab's own look")
        XCTAssertGreaterThanOrEqual(ChoiceMenuItemView.height, 22 + RaisedRow.sideHeight, "room for the side")
    }

    func testTheRowTakesTheOtherLooksAppearanceAndLetsGoWhenNotChosen() {
        let (window, row, _, _) = row(in: .aqua)
        XCTAssertEqual(row.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua, "an espresso slab by day")
        row.applyRaised(false)
        XCTAssertNil(row.appearance, "an unchosen row is in its own surroundings")
        XCTAssertEqual(row.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .aqua)
        XCTAssertNil(row.slabColors.face)
        let (night, dark, _, _) = self.row(in: .darkAqua)
        XCTAssertEqual(dark.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .aqua, "a clay slab by night")
        _ = (window, night)
    }

    func testTheInkInsideTheSlabIsTheOtherLooksInk() {
        for (look, other) in [(NSAppearance.Name.aqua, Palette.night), (.darkAqua, Palette.clay)] {
            let (window, _, label, key) = row(in: look)
            XCTAssertEqual(rgb(Ceramic.resolved(BarTheme.ink, in: label)), other.ink.color.usingColorSpace(.sRGB),
                           "the labels read as the other look's ink on the slab")
            XCTAssertEqual(rgb(Ceramic.resolved(BarTheme.secondaryColor, in: label)),
                           other.secondary.color.usingColorSpace(.sRGB), "and its quiet ink")
            XCTAssertEqual(key.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
                           other.ink.lightness > 0.5 ? .darkAqua : .aqua, "the key inside is in the slab's look")
            _ = window
        }
    }

    func testALitKeyOnTheSlabIsTheAccentThatStandsOnIt() {
        BarTheme.accentColor = { BarTheme.internationalOrange }
        for (look, orange) in [(NSAppearance.Name.aqua, Readability.orangeOnCharcoal), (.darkAqua, Readability.orangeOnPaper)] {
            let (window, _, _, key) = row(in: look)
            key.refresh()
            let face = rgb(key.faceColor)
            XCTAssertEqual(face?.redComponent ?? 0, CGFloat(orange.red), accuracy: 0.01, "the orange of the slab's own look: \(look.rawValue)")
            XCTAssertEqual(face?.greenComponent ?? 0, CGFloat(orange.green), accuracy: 0.01)
            _ = window
        }
    }

    /// Settings draws the slab as a step behind a row's own words, which are
    /// its siblings: the row takes the other look with the step and gives it
    /// back when the step goes.
    func testAStepBehindARowsWordsCarriesTheRowIntoTheOtherLook() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let around = window.contentView!
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        around.addSubview(row)
        let words = NSTextField(labelWithString: "Clipboard")
        words.textColor = BarTheme.ink
        row.addSubview(words)
        let step = LandingStep(frame: row.bounds)
        step.surroundings = around
        step.carries = row
        row.addSubview(step, positioned: .below, relativeTo: nil)
        step.setupRaised()
        step.applyRaised(true)
        XCTAssertEqual(row.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua, "the words are on an espresso slab")
        XCTAssertEqual(rgb(Ceramic.resolved(BarTheme.ink, in: words)), Palette.night.ink.color.usingColorSpace(.sRGB))
        XCTAssertEqual(rgb(step.slabColors.face), Palette.clay.slab.color.usingColorSpace(.sRGB),
                       "and the step is the day's slab, not the night's, though it lives inside the other look")
        step.applyRaised(false)
        XCTAssertNil(row.appearance, "the row is its own again")
        XCTAssertEqual(rgb(Ceramic.resolved(BarTheme.ink, in: words)), Palette.clay.ink.color.usingColorSpace(.sRGB))
    }

    func testAChosenRowCastsNoShadowForItsSideStandsInstead() {
        let (window, row, _, _) = row(in: .darkAqua)
        XCTAssertEqual(row.layer?.shadowOpacity, 0, "the side survives the night where a shadow does not")
        _ = window
    }
}

/// The launcher: keys lead, the chosen row is the slab, and the field is a
/// well the typing sinks into.
final class LauncherLookTests: XCTestCase {
    private func row(chosen: Bool) -> (NSWindow, SearcherRowView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let row = SearcherRowView(rowHeight: BarTheme.rowHeight)
        row.configure(identity: "mail", icon: { NSImage(size: NSSize(width: 32, height: 32)) }, title: "Mail",
                      chips: ["E P"], showDot: true)
        row.setSelected(chosen)
        window.contentView?.addSubview(row)
        row.frame = NSRect(x: 10, y: 10, width: 600, height: BarTheme.rowHeight)
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, row)
    }

    func testTheKeysLeadTheRow() {
        let (window, row) = row(chosen: true)
        let drawn = row.drawnForTesting
        XCTAssertEqual(drawn.keys.count, 1)
        let key = drawn.keys[0]
        XCTAssertLessThan(row.convert(key.bounds, from: key).maxX, drawn.icon.frame.minX, "the address stands left of the icon")
        XCTAssertLessThan(drawn.icon.frame.maxX, drawn.name.frame.minX, "and the name after it")
        XCTAssertLessThan(drawn.name.frame.maxX, drawn.enter.frame.minX, "⏎ ends the row")
        XCTAssertTrue(key.lit, "the chosen row's keys are lit")
        _ = window
    }

    func testTheNamesStandInOneColumnWhetherOrNotARowHasAnAddress() {
        let (w1, withKeys) = row(chosen: false)
        let bare = SearcherRowView(rowHeight: BarTheme.rowHeight)
        bare.configure(identity: "terminal", icon: { nil }, title: "Terminal", chips: [], showDot: false)
        w1.contentView?.addSubview(bare)
        bare.frame = NSRect(x: 10, y: 60, width: 600, height: BarTheme.rowHeight)
        w1.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(bare.drawnForTesting.icon.frame.minX, withKeys.drawnForTesting.icon.frame.minX, accuracy: 0.5,
                       "the key column holds its width, so the icons line up down the list")
    }

    func testAnUnchosenRowIsFlatAndTheChosenOneIsTheSlab() {
        let (w1, flat) = row(chosen: false)
        XCTAssertNil(flat.slabColors.face, "flat until chosen")
        XCTAssertFalse(flat.drawnForTesting.keys[0].lit)
        XCTAssertTrue(flat.drawnForTesting.enter.isHidden)
        let (w2, chosen) = row(chosen: true)
        XCTAssertNotNil(chosen.slabColors.face, "the slab when chosen")
        XCTAssertFalse(chosen.drawnForTesting.enter.isHidden)
        _ = (w1, w2)
    }

    func testABarsFieldSinksIntoAWell() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 100))
        let well = BarTheme.installFieldWell(in: root, bandHeight: BarTheme.inputHeight)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(well.frame.height, BarTheme.inputHeight - BarTheme.fieldWellMargin * 2)
        XCTAssertEqual(well.frame.minX, BarTheme.rowInset, "ten points in, as the rows are")
        XCTAssertEqual(well.layer?.cornerRadius, BarTheme.rowRadius, "concentric with the pane")
        well.updateLayer()
        var fill: CGColor?
        well.effectiveAppearance.performAsCurrentDrawingAppearance { fill = BarTheme.well.cgColor }
        XCTAssertEqual(well.layer?.backgroundColor, fill, "the receptacle's own fill")
    }

    func testEveryBarSinksItsFieldIntoTheWell() throws {
        for name in ["SearcherPanel.swift", "WebBar.swift", "CommandsBar.swift"] {
            let text = try String(contentsOf: DesignDriftTests.appSources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("BarTheme.installFieldWell("), "\(name): the field is a receptacle")
        }
    }
}

/// A room's button is a key: it stands on a side, and pressed it collapses
/// at once; the answer is the lit key.
final class RoomButtonTests: XCTestCase {
    private func button(_ title: String, primary: Bool = false, look: NSAppearance.Name = .aqua)
        -> (NSWindow, RoomButton) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look)
        let button = RoomButton(frame: NSRect(x: 10, y: 10, width: 90, height: RoomButton.height))
        button.title = title
        button.primary = primary
        window.contentView?.addSubview(button)
        return (window, button)
    }

    func testAButtonStandsOnASideAndCollapsesWhenPressed() {
        let (window, key) = button("Save")
        defer { _ = window }
        XCTAssertEqual(key.stance, .standing)
        let standing = key.visibleSide
        XCTAssertEqual(standing, KeyLayers.sideHeight(forHeight: RoomButton.height), "the side a key of its height stands on")
        XCTAssertNotNil(key.sideColor, "a visible side")
        key.holdForTesting(true)
        XCTAssertEqual(key.stance, .pressed)
        XCTAssertEqual(key.visibleSide, standing / 3, accuracy: 0.001, "pressed, it collapses onto a third of its side")
        key.holdForTesting(false)
        XCTAssertEqual(key.visibleSide, standing, "and comes back up when let go")
    }

    func testAButtonThatCannotBePressedLiesFlatLikeAQuietKey() {
        let (window, key) = button("Continue")
        defer { _ = window }
        key.isEnabled = false
        XCTAssertEqual(key.stance, .flat)
        XCTAssertEqual(key.visibleSide, 0)
        XCTAssertNil(key.sideColor, "no side")
        XCTAssertNil(key.faceColor, "and no fill: a hairline and the quiet ink")
    }

    func testThePrimaryButtonIsTheLitKeyWithTheInkThatReadsOnIt() {
        for look in [NSAppearance.Name.aqua, .darkAqua] {
            let (w1, normal) = button("Cancel", look: look), (w2, lit) = button("Send", primary: true, look: look)
            defer { _ = (w1, w2) }
            let orange = look == .aqua ? Readability.orangeOnPaper : Readability.orangeOnCharcoal
            let face = lit.faceColor?.usingColorSpace(.sRGB)
            XCTAssertEqual(face?.redComponent ?? 0, CGFloat(orange.red), accuracy: 0.01, "the orange: \(look.rawValue)")
            XCTAssertNotEqual(normal.faceColor, lit.faceColor)
            var word: NSColor?
            lit.effectiveAppearance.performAsCurrentDrawingAppearance {
                word = (lit.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
            }
            var ink: NSColor?
            lit.effectiveAppearance.performAsCurrentDrawingAppearance { ink = BarTheme.onAccent.usingColorSpace(.sRGB) }
            XCTAssertEqual(word, ink, "ink chosen by contrast against the lit face")
        }
    }
}

/// A Settings choice is a key: you press it and a menu opens, so it stands
/// on a side and collapses at once when pressed; its menu's rows are the
/// slab as the highlight moves, set by the menu's delegate and never read
/// back in the middle of a draw.
final class KeyPopUpTests: XCTestCase {
    private func popup(look: NSAppearance.Name = .aqua) -> (NSWindow, KeyPopUp) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look)
        let popup = KeyPopUp()
        popup.addItems(withTitles: ["Daily", "Weekly", "Monthly"])
        popup.frame = NSRect(x: 10, y: 10, width: popup.intrinsicContentSize.width, height: KeyPopUp.height)
        window.contentView?.addSubview(popup)
        return (window, popup)
    }

    func testAChoiceStandsOnASideAndCollapsesWhenPressed() {
        let (window, key) = popup()
        defer { _ = window }
        XCTAssertEqual(key.stance, .standing)
        let standing = key.visibleSide
        XCTAssertEqual(standing, KeyLayers.sideHeight(forHeight: KeyPopUp.height))
        XCTAssertNotNil(key.sideColor)
        XCTAssertEqual(rgbOf(key.faceColor), rgbOf(NSColor(cgColor: Ceramic.resolved(BarTheme.keyFace, in: key))),
                       "the key's own face, and no well")
        key.holdForTesting(true)
        XCTAssertEqual(key.stance, .pressed)
        XCTAssertEqual(key.visibleSide, standing / 3, accuracy: 0.001)
        key.holdForTesting(false)
        XCTAssertEqual(key.visibleSide, standing)
    }

    func testAChoiceThatCannotBePressedLiesFlat() {
        let (window, key) = popup()
        defer { _ = window }
        key.isEnabled = false
        XCTAssertEqual(key.stance, .flat)
        XCTAssertNil(key.sideColor)
        XCTAssertNil(key.faceColor)
    }

    func testTheMenuRowUnderTheHighlightIsTheSlabAndTheOthersAreNot() {
        let (window, key) = popup()
        defer { _ = window }
        key.menu?.delegate = key
        key.menuNeedsUpdate(key.menu!)
        let rows = key.menu!.items.compactMap { $0.view as? ChoiceMenuItemView }
        XCTAssertEqual(rows.count, 3)
        key.menu(key.menu!, willHighlight: key.menu!.items[1])
        XCTAssertEqual(rows.map(\.lit), [false, true, false], "the highlight is set as it moves")
        key.menu(key.menu!, willHighlight: key.menu!.items[2])
        XCTAssertEqual(rows.map(\.lit), [false, false, true], "and only one row at a time")
        key.menuDidClose(key.menu!)
        XCTAssertEqual(rows.map(\.lit), [false, false, false], "a closed menu highlights nothing")
    }

    private func rgbOf(_ color: NSColor?) -> NSColor? { color?.usingColorSpace(.sRGB) }
}

/// The one key: resting a quiet cap, lit a piece of the mark.
final class KeyFaceTests: XCTestCase {
    func testALitKeyIsTheAccentWithItsReadableInk() {
        let saved = BarTheme.accentColor
        BarTheme.accentColor = { BarTheme.internationalOrange }
        defer { BarTheme.accentColor = saved }
        let key = KeyFace("E")
        XCTAssertNotEqual(key.faceColor, Ceramic.resolved(BarTheme.accent, in: key), "resting is not lit")
        key.lit = true
        XCTAssertEqual(key.faceColor, Ceramic.resolved(BarTheme.accent, in: key))
        XCTAssertEqual(key.label.textColor, BarTheme.onAccent)
        XCTAssertEqual(key.visibleSide, 3, "it stands on its side")
        XCTAssertNotEqual(key.sideColor, key.faceColor, "a lit key's side is a darker shade of the accent")
    }

    /// The ⏎ on a bar's row is built once and only hidden and shown, so a
    /// key that is lit later takes the accent then, in its own look.
    func testALitKeyWearsTheAccentOfItsOwnLook() {
        let key = KeyFace("⏎")
        XCTAssertNotEqual(key.faceColor, Ceramic.resolved(BarTheme.accent, in: key), "resting is not lit")
        key.lit = true
        XCTAssertEqual(key.faceColor, Ceramic.resolved(BarTheme.accent, in: key))
        XCTAssertEqual(key.label.textColor, BarTheme.onAccent)
        key.effectiveAppearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(key.sideColor, Ceramic.resolved(BarTheme.litKeySide, in: key))
        }
        key.lit = false
        XCTAssertNotEqual(key.faceColor, Ceramic.resolved(BarTheme.accent, in: key))
    }

    private func rgb(_ color: CGColor?) -> NSColor? { color.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB) }

    /// A key in a window of the given look, the way one stands.
    private func key(_ look: NSAppearance.Name, lit: Bool = false, quiet: Bool = false) -> (NSWindow, KeyFace) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look)
        let key = KeyFace("E")
        key.lit = lit
        key.quiet = quiet
        window.contentView?.addSubview(key)
        window.contentView?.layoutSubtreeIfNeeded()
        key.refresh()
        return (window, key)
    }

    /// A resting key stands on a visible side, three points at key size, in
    /// the look's own colours; its face is the raised step.
    func testARestingKeyStandsOnItsSideInTheLooksOwnColours() {
        for (look, steps) in [(NSAppearance.Name.aqua, Palette.clay), (.darkAqua, Palette.night)] {
            let (window, key) = key(look)
            XCTAssertEqual(key.stance, .standing)
            XCTAssertEqual(key.visibleSide, 3)
            XCTAssertEqual(rgb(key.faceColor), steps.keyFace.color.usingColorSpace(.sRGB), "the face, \(look.rawValue)")
            XCTAssertEqual(rgb(key.sideColor), steps.keySide.color.usingColorSpace(.sRGB), "the side, \(look.rawValue)")
            let faces = key.layer?.sublayers?.filter { $0.backgroundColor != nil } ?? []
            XCTAssertEqual(faces.count, 2, "a side and a face")
            let face = faces.last!, side = faces.first!
            XCTAssertEqual(face.frame.minY - side.frame.minY, 3, accuracy: 0.01, "the face stands three points above the foot")
            XCTAssertEqual(face.frame.height, BarTheme.chipHeight - 3, accuracy: 0.01)
            XCTAssertNotNil(key.rimColor, "the polished top edge is kept")
            _ = window
        }
    }

    /// Pressed, the side collapses to a third and the face goes down onto
    /// it, at once.
    func testAPressedKeyCollapsesItsSideAndTheFaceFollowsAtOnce() {
        let (window, key) = key(.aqua)
        let face = key.layer!.sublayers!.first { $0.backgroundColor != nil && $0.frame.minY > 0 }!
        let before = face.frame.minY
        key.fill(.pressed)
        XCTAssertEqual(key.stance, .pressed)
        XCTAssertEqual(key.visibleSide, 1, accuracy: 0.01, "about a point of side")
        XCTAssertEqual(face.frame.minY, 1, accuracy: 0.01, "the face moved down by what the side gave up")
        XCTAssertEqual(before - face.frame.minY, 2, accuracy: 0.01)
        XCTAssertNil(face.animation(forKey: "position"), "instantly: nothing animates")
        XCTAssertNil(face.animation(forKey: "bounds"))
        key.fill(.resting)
        XCTAssertEqual(face.frame.minY, 3, accuracy: 0.01, "and back up on release")
        _ = window
    }

    /// Quiet is flat: no side, no well, the letter in the quiet ink, a
    /// hairline outline and nothing else.
    func testAQuietKeyIsFlatWithAHairlineAndTheQuietInk() {
        let (window, key) = key(.aqua, quiet: true)
        XCTAssertEqual(key.stance, .flat)
        XCTAssertEqual(key.visibleSide, 0)
        XCTAssertNil(key.faceColor, "no well")
        XCTAssertNil(key.sideColor, "no side")
        XCTAssertNil(key.rimColor, "no light falls on what is not raised")
        let face = key.layer!.sublayers!.first { $0.borderWidth > 0 }
        XCTAssertEqual(face?.borderWidth, 0.5, "a hairline outline")
        XCTAssertEqual(face?.frame.height, BarTheme.chipHeight, "flat: the whole key is its face")
        XCTAssertEqual(key.label.textColor, BarTheme.secondaryColor)
        _ = window
    }

    /// A lit key stands on the accent's darker shade and keeps the lit top
    /// edge as its rim.
    func testALitKeyStandsOnADarkerShadeOfTheAccent() {
        let (window, key) = key(.aqua, lit: true)
        guard let face = rgb(key.faceColor), let side = rgb(key.sideColor) else { return XCTFail("no colours") }
        XCTAssertLessThan(side.brightnessComponent, face.brightnessComponent, "darker")
        XCTAssertEqual(side.hueComponent, face.hueComponent, accuracy: 0.03, "the same hue")
        XCTAssertEqual(key.visibleSide, 3)
        XCTAssertNotNil(key.rimColor)
        _ = window
    }

    func testTheSideScalesWithTheKeyAndHoldsItsLimits() {
        XCTAssertEqual(KeyLayers.sideHeight(forHeight: BarTheme.chipHeight), 3)
        XCTAssertEqual(KeyLayers.sideHeight(forHeight: 6), 1.5, "a small mark never under a point and a half")
        XCTAssertEqual(KeyLayers.sideHeight(forHeight: 11), 1.5)
        XCTAssertEqual(KeyLayers.sideHeight(forHeight: 33), 4.5, accuracy: 0.01, "in proportion")
        XCTAssertEqual(KeyLayers.sideHeight(forHeight: KeyMark.peekHeight), 5, "and the biggest stays a thing you press")
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
        XCTAssertLessThan(light.redComponent, 0.5, "dark ink on clay")
        XCTAssertGreaterThan(dark.redComponent, 0.5, "light ink on espresso")
    }

    /// Every surface with the drawn shadow is gated by construction: the
    /// shadow's margin passes the pointer through, the pane takes it.
    func testAHostedSurfaceTakesThePointerOnlyOverItsPane() {
        let panel = Ceramic.makePanel(level: .floating)
        let gate = SoftShadow.host(NSView(), in: panel, cornerRadius: BarTheme.surfaceRadius)
        let pane = NSRect(x: 300, y: 300, width: 400, height: 120)
        panel.setFrame(SoftShadow.outset(pane), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        gate.update(pointer: NSPoint(x: pane.midX, y: pane.midY))
        XCTAssertTrue(gate.open)
        gate.update(pointer: NSPoint(x: pane.midX, y: pane.minY - 30))
        XCTAssertFalse(gate.open, "a click in the shadow belongs to the app beneath")
    }

    func testTheGroundIsTheNightOrClay() {
        let steps = Tone.systemDark ? Palette.night : Palette.clay
        XCTAssertEqual(BarTheme.ground, steps.pane.color)
        XCTAssertEqual(BarTheme.raised, steps.raised.color)
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
