import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// One glass. Every panel, card, and chip is the launcher's backdrop,
/// and the scrim inside it never keeps a cold first guess.
final class GlassTests: XCTestCase {
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
