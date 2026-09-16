import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// One glass. Every panel, card, and chip is the launcher's backdrop,
/// tinted toward the system's ground and re-read live.
final class GlassTests: XCTestCase {
    /// The veil these tests read is the frost's, not the opaque one a
    /// runner with Reduce Transparency on would draw.
    override func setUp() { Accessibility.reduceTransparency = { false } }
    override func tearDown() {
        Accessibility.reduceTransparency = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    }

    /// A toned glass in a window, the way a backdrop stands.
    @available(macOS 26.0, *)
    private func glassInAWindow() -> (NSWindow, TonedGlass) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let glass = TonedGlass()
        glass.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        window.contentView?.addSubview(glass)
        return (window, glass)
    }

    func testTheGlassIsTintedTowardTheSystemsGroundOnArrival() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("no glass before 26") }
        let (window, glass) = glassInAWindow()
        let tint = try XCTUnwrap(glass.tintColor?.usingColorSpace(.sRGB), "arriving in a window is a reading")
        XCTAssertEqual(tint.alphaComponent, 0.92, accuracy: 0.01, "the measured number")
        XCTAssertEqual(tint.redComponent, Tone.systemDark ? 0.25 : 0.92, accuracy: 0.02,
                       "the grey that lands on charcoal or paper: the system's tone, never the backdrop's")
        XCTAssertEqual(glass.veilAlpha, 0.70, accuracy: 0.01, "the veil takes the backdrop's vote, and the frost shows through the rest")
        _ = window
    }

    func testTheGlassRetintsWhenTheSettingsChange() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("no glass before 26") }
        let (window, glass) = glassInAWindow()
        glass.weight = .raised
        XCTAssertEqual(glass.tintColor?.alphaComponent ?? 0, 0.96, accuracy: 0.01, "a lit card is heavier")
        Accessibility.reduceTransparency = { true }
        glass.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(glass.veilAlpha, Glass.opaque, accuracy: 0.01, "a flipped setting is a new reading, not the next opening's")
        _ = window
    }

    func testOneBackdropWithAWeight() {
        let root = NSView()
        let normal = Glass.installBackdrop(in: root, cornerRadius: 18)
        let raised = Glass.installBackdrop(in: NSView(), cornerRadius: 18, weight: .raised)
        let faint = Glass.installBackdrop(in: NSView(), cornerRadius: 18, weight: .faint)
        XCTAssertEqual(Glass.weight(in: normal), .normal)
        XCTAssertEqual(Glass.weight(in: raised), .raised)
        XCTAssertEqual(Glass.weight(in: faint), .faint)
        XCTAssertLessThan(Glass.Weight.faint.alpha, Glass.Weight.normal.alpha)
        XCTAssertLessThan(Glass.Weight.normal.alpha, Glass.Weight.raised.alpha)
        XCTAssertLessThan(Glass.Weight.faint.veil, Glass.Weight.normal.veil)
        XCTAssertLessThan(Glass.Weight.normal.veil, Glass.Weight.raised.veil)
        XCTAssertEqual(root.subviews.first, normal, "installed under everything else")
    }

    func testAChipIsTheLaunchersGlassWithTheLabelOnTop() {
        let (chip, label) = GlassChip.make("ab")
        let backdrop = chip.subviews.first { Glass.weight(in: $0) != nil }
        XCTAssertNotNil(backdrop, "the one backdrop recipe")
        XCTAssertEqual(Glass.weight(in: backdrop!), .normal, "the launcher's own tint, not a heavier one")
        XCTAssertTrue(chip.subviews.contains(label), "the label rides above the material, not inside it")
        XCTAssertNil(label.shadow, "no halo: the frost makes it unnecessary")
        XCTAssertNotNil(chip.layer?.shadowColor, "still lifted off the content beneath")
        if #available(macOS 26.0, *) {
            XCTAssertEqual((backdrop as? NSGlassEffectView)?.style, .regular, "never clear")
        }
    }

    func testTheStripsCardsAreTheLaunchersGlassAndOnlyTheLitOneIsRaised() {
        let stage = Stage()
        let a = stage.seedClip("one")
        stage.seedClip("two")
        stage.openStrip()
        let cards = stage.engine.strip.shownWeights.filter { $0 != .faint }
        XCTAssertEqual(Set(cards), [.normal], "no card is lit; the empty slot is faint")
        for card in stage.engine.strip.shownCards.values {
            let backdrop = card.subviews.first { Glass.weight(in: $0) != nil }
            XCTAssertNotNil(backdrop)
            if #available(macOS 26.0, *) {
                XCTAssertEqual((backdrop as? NSGlassEffectView)?.style, .regular)
            }
        }
        stage.chord("s", .maskCommand)
        let weights = stage.engine.strip.shownWeights.filter { $0 != .faint }
        XCTAssertEqual(weights.filter { $0 == .raised }.count, 1, "the card the actions act on")
        XCTAssertEqual(weights.filter { $0 == .normal }.count, weights.count - 1)
        _ = a
        stage.press("escape")
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

/// The system's accessibility settings, honoured: no transparency means
/// an opaque veil, more contrast means captions in the label colour,
/// and a mark's accent never sits on its ground.
final class AccessibilitySettingsTests: XCTestCase {
    override func tearDown() {
        Accessibility.reduceTransparency = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
        Accessibility.increaseContrast = { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
        BarTheme.accentColor = { .controlAccentColor }
    }

    private func veilAlpha(reduce: Bool) throws -> CGFloat {
        guard #available(macOS 26.0, *) else { throw XCTSkip("no glass before 26") }
        Accessibility.reduceTransparency = { reduce }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let glass = TonedGlass()
        glass.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        window.contentView?.addSubview(glass)
        _ = window
        return glass.veilAlpha
    }

    func testReduceTransparencyMakesTheVeilOpaque() throws {
        XCTAssertEqual(try veilAlpha(reduce: true), Glass.opaque, accuracy: 0.01)
        XCTAssertLessThan(try veilAlpha(reduce: false), Glass.opaque, "and the frost is back when it is off")
    }

    func testIncreaseContrastSetsCaptionsInTheLabelColour() {
        Accessibility.increaseContrast = { true }
        XCTAssertEqual(BarTheme.secondaryColor, .labelColor)
        Accessibility.increaseContrast = { false }
        XCTAssertNotEqual(BarTheme.secondaryColor, .labelColor)
        if Tone.systemDark { XCTAssertEqual(BarTheme.secondaryColor, .secondaryLabelColor) }
    }

    func testAnAccentOnItsGroundFallsBackToTheLabelColour() {
        BarTheme.accentColor = { BarTheme.ground }
        XCTAssertEqual(BarTheme.readableAccent, .labelColor, "no contrast at all")
        BarTheme.accentColor = { .systemOrange }
        if Tone.systemDark {
            XCTAssertEqual(BarTheme.readableAccent, .systemOrange, "orange clears charcoal")
        } else {
            XCTAssertEqual(BarTheme.readableAccent, .labelColor, "orange does not clear paper")
        }
        BarTheme.accentColor = { Tone.systemDark ? .white : .black }
        XCTAssertNotEqual(BarTheme.readableAccent, .labelColor, "a strong accent is kept as chosen")
    }

    func testTheInsertBarWearsTheReadableAccent() {
        BarTheme.accentColor = { BarTheme.ground }
        let panel = DraftPanel()
        defer { panel.hide() }
        panel.show(DraftView(buffer: Draft.Buffer(text: "x", cursor: 0), mode: .insert, editor: .insert,
                             speech: nil, destination: ("Notes", nil), replacing: false))
        XCTAssertEqual(panel.caretColor?.usingColorSpace(.sRGB), NSColor.labelColor.usingColorSpace(.sRGB),
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
            XCTAssertNotNil(card.layer?.shadowPath, "shaped to the card, not to what the glass draws")
            XCTAssertEqual(card.layer?.shadowOpacity, 1)
        }
        stage.press("escape")
    }
}

/// The chip's words and Lodestar's own accent, as the app draws them.
final class AccentAndChipWordsTests: XCTestCase {
    func testTheOrangeAccentIsMeasuredForTheCurrentGround() {
        BarTheme.accentColor = { BarTheme.accent(for: .orange) }
        defer { BarTheme.accentColor = { .controlAccentColor } }
        XCTAssertEqual(BarTheme.readableAccent.usingColorSpace(.sRGB),
                       BarTheme.accent(for: .orange).usingColorSpace(.sRGB),
                       "the pair clears the floor on its own ground, so no fallback")
        XCTAssertEqual(BarTheme.accent(for: .system), .controlAccentColor)
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
}

/// The accent never drifts: the system's colour reaches a surface only
/// through the theme, so the setting governs every place it shows.
final class AccentDriftTests: XCTestCase {
    func testNoSurfaceReadsTheSystemAccentDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lodestar")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Glass.swift" }
        XCTAssertGreaterThan(files.count, 20, "the sources were found")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("controlAccentColor"),
                           "\(file.lastPathComponent) draws the system accent directly; use BarTheme.accent")
        }
    }

    func testTheSharedAccentFollowsTheChoice() {
        BarTheme.accentColor = { BarTheme.accent(for: .orange) }
        defer { BarTheme.accentColor = { .controlAccentColor } }
        XCTAssertEqual(BarTheme.accent.usingColorSpace(.sRGB), BarTheme.accent(for: .orange).usingColorSpace(.sRGB))
        BarTheme.accentColor = { .controlAccentColor }
        XCTAssertEqual(BarTheme.accent, .controlAccentColor)
    }
}

/// Text over the accent fill is chosen by measure, so a selected row
/// reads on any accent a person picks.
final class OnAccentTests: XCTestCase {
    override func tearDown() { BarTheme.accentColor = { .controlAccentColor } }

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

    func testTheDeeperOrangeAndADeepBlueTakeWhite() {
        let deep = NSColor(srgbRed: Readability.orangeOnPaper.red, green: Readability.orangeOnPaper.green,
                           blue: Readability.orangeOnPaper.blue, alpha: 1)
        BarTheme.accentColor = { deep }
        XCTAssertEqual(BarTheme.onAccent, .white)
        XCTAssertGreaterThanOrEqual(contrast(.white, on: deep), 4.5)
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
        BarTheme.accentColor = { .controlAccentColor }
        Accessibility.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
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
        let orange = BarTheme.accent(for: .orange)
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

    func testTheSwatchIsTheColourItNamesWithRoomAfterIt() {
        let swatch = BarTheme.swatch(.systemGreen, diameter: 12)
        XCTAssertEqual(swatch.size, NSSize(width: 19, height: 12), "the dot, then clear room before the title")
        let bits = NSBitmapImageRep(data: swatch.tiffRepresentation!)!
        XCTAssertEqual(bits.colorAt(x: 16, y: 6)?.alphaComponent ?? 1, 0, accuracy: 0.01, "the room is clear")
        let rep = NSBitmapImageRep(data: swatch.tiffRepresentation!)!
        let center = rep.colorAt(x: 6, y: 6)?.usingColorSpace(.sRGB)
        let green = NSColor.systemGreen.usingColorSpace(.sRGB)!
        XCTAssertEqual(center?.greenComponent ?? 0, green.greenComponent, accuracy: 0.05)
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
        defer { Accessibility.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
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
