import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// One glass. Every panel, card, and chip is the launcher's backdrop,
/// and the scrim inside it never keeps a cold first guess.
final class GlassTests: XCTestCase {
    /// The veil these tests read is the frost's, not the opaque one a
    /// runner with Reduce Transparency on would draw.
    override func setUp() { Accessibility.reduceTransparency = { false } }
    override func tearDown() {
        Accessibility.reduceTransparency = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    }

    /// The veil's alpha as the layer holds it, once the view has drawn.
    private func alpha(_ scrim: EqualizerScrim) -> CGFloat? {
        scrim.displayIfNeeded()
        return scrim.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent
    }

    /// A scrim in a window whose appearance is the system's, so the
    /// material's stamp and the system agree and the veil is the base.
    private func scrimInAWindow() -> (NSWindow, EqualizerScrim) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let scrim = EqualizerScrim()
        scrim.wantsLayer = true
        scrim.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        (scrim.darkBase, scrim.lightBase) = (0.31, 0.31)
        window.contentView?.addSubview(scrim)
        return (window, scrim)
    }

    func testTheScrimRereadsWhenTheMaterialStampsItsTone() {
        let (window, scrim) = scrimInAWindow()
        XCTAssertEqual(alpha(scrim) ?? 0, 0.31, accuracy: 0.01, "the first reading")
        // The veil's target changes; a scrim that kept its first guess
        // would still say 0.31 after the stamp.
        (scrim.darkBase, scrim.lightBase) = (0.57, 0.57)
        scrim.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(alpha(scrim) ?? 0, 0.57, accuracy: 0.01, "a changed stamp is a new reading")
        _ = window
    }

    func testTheScrimReadsOnArrivalInAWindow() {
        let (window, scrim) = scrimInAWindow()
        XCTAssertEqual(alpha(scrim) ?? 0, 0.31, accuracy: 0.01, "arriving in a window is a reading")
        _ = window
    }

    func testOneBackdropWithAWeight() {
        let root = NSView()
        let normal = Glass.installBackdrop(in: root, cornerRadius: 18)
        let raised = Glass.installBackdrop(in: NSView(), cornerRadius: 18, weight: .raised)
        let faint = Glass.installBackdrop(in: NSView(), cornerRadius: 18, weight: .faint)
        XCTAssertEqual(Glass.scrim(in: normal)?.darkBase, 0.32)
        XCTAssertEqual(Glass.scrim(in: raised)?.darkBase, 0.50)
        XCTAssertEqual(Glass.scrim(in: faint)?.darkBase, 0.20)
        XCTAssertLessThan(Glass.Weight.faint.bases.dark, Glass.Weight.normal.bases.dark)
        XCTAssertLessThan(Glass.Weight.normal.bases.dark, Glass.Weight.raised.bases.dark)
        XCTAssertEqual(root.subviews.first, normal, "installed under everything else")
    }

    func testAChipIsTheLaunchersGlassWithTheLabelOnTop() {
        let (chip, label) = GlassChip.make("ab")
        let backdrop = chip.subviews.first { Glass.scrim(in: $0) != nil }
        XCTAssertNotNil(backdrop, "the one backdrop recipe")
        XCTAssertEqual(Glass.scrim(in: backdrop!)?.darkBase, Glass.Weight.normal.bases.dark,
                       "the launcher's own veil, not a heavier one")
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
            let backdrop = card.subviews.first { Glass.scrim(in: $0) != nil }
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

    private func veilAlpha(reduce: Bool) -> CGFloat {
        Accessibility.reduceTransparency = { reduce }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let scrim = EqualizerScrim()
        scrim.wantsLayer = true
        scrim.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        window.contentView?.addSubview(scrim)
        scrim.displayIfNeeded()
        return scrim.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
    }

    func testReduceTransparencyMakesTheVeilOpaque() {
        XCTAssertEqual(veilAlpha(reduce: true), EqualizerScrim.opaque, accuracy: 0.01)
        XCTAssertLessThan(veilAlpha(reduce: false), 0.8, "and the frost is back when it is off")
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

    func testTheChipCountsMinutesThenSecondsThenNow() {
        XCTAssertEqual(MeetingController.phrase(.upcoming(minutes: 4)), "in 4 min")
        XCTAssertEqual(MeetingController.phrase(.soon(seconds: 45)), "in 45s")
        XCTAssertEqual(MeetingController.phrase(.now), "now")
        XCTAssertEqual(MeetingController.phrase(.inProgress(minutes: 10)), "10 min in")
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
