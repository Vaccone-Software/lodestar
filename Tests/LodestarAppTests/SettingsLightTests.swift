import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Settings says chosen one way and names apps as people know them. Each
/// place is drawn without the window being shown.
final class SettingsLightTests: XCTestCase {
    private func settings(excluding apps: Set<String> = []) -> SettingsController {
        let settings = SettingsController()
        var config = Config()
        config.clipboardExcludedApps = apps
        settings.config = config
        settings.appDisplayName = { $0 == "com.apple.TextEdit" ? "TextEdit" : nil }
        settings.appIcon = { $0 == "com.apple.TextEdit" ? NSImage(size: NSSize(width: 16, height: 16)) : nil }
        return settings
    }

    private var keep: Int { SettingsModel.placeIndex("Keep")! }

    /// An app is its icon and its name, never its identifier.
    func testAnExcludedAppIsShownByItsNameNotItsIdentifier() {
        let settings = settings(excluding: ["com.apple.TextEdit"])
        settings.renderForTesting(place: keep)
        let texts = settings.shownTextsForTesting
        XCTAssertTrue(texts.contains("TextEdit"), "the name, as the Dock shows it")
        XCTAssertFalse(texts.contains("com.apple.TextEdit"), "the identifier is not drawn")
    }

    /// The verbs that stand on every line (Remove, Reset, Add) are glyphs on
    /// square keys, so a page reads as its entries; each still says its
    /// word on hover and to VoiceOver, and no key spells it out.
    func testTheRepeatedVerbsAreGlyphsThatStillSayTheirNames() {
        let settings = settings(excluding: ["com.apple.TextEdit"])
        settings.config.scrollSpeed = 1200
        var keys: [RoomButton] = []
        for place in 0..<10 {
            settings.renderForTesting(place: place)
            keys += settings.viewsForTesting(of: RoomButton.self)
        }
        for (glyph, name) in [(Glyph.remove, "Remove"), (.undo, "Reset"), (.add, "Add")] {
            let wearing = keys.filter { $0.glyph == glyph }
            XCTAssertFalse(wearing.isEmpty, "\(name) is drawn as its glyph")
            for key in wearing {
                XCTAssertEqual(key.toolTip, name, "named on hover")
                XCTAssertEqual(key.accessibilityLabel(), name, "named to VoiceOver")
                XCTAssertEqual(key.intrinsicContentSize.width, key.intrinsicContentSize.height, "a square key")
            }
        }
        XCTAssertTrue(keys.filter { ["Remove", "Reset", "Add", "Undo"].contains($0.title) }.isEmpty,
                      "no key spells out a verb its glyph says")
    }

    /// History's way back is the same arc as Reset's: both put an earlier
    /// value back.
    func testHistoryUndoWearsTheArcBack() {
        let item = SettingsModel.HistoryItem(id: "1", title: "Scroll speed", detail: "1800 → 1200", today: true)
        let action = SettingsModel.historySection([item]).rows.first?.action
        XCTAssertEqual(action?.label, "Undo")
        XCTAssertEqual(action?.glyph, .undo)
    }

    /// An app no longer on this Mac has no name to show; its identifier is
    /// all there is to recognise it by.
    func testAnAppThatIsGoneFallsBackToItsIdentifier() {
        let settings = settings(excluding: ["com.example.gone"])
        settings.renderForTesting(place: keep)
        XCTAssertTrue(settings.shownTextsForTesting.contains("com.example.gone"))
    }

    /// The picked result is the slab, the launcher's chosen row, and ⏎ on it
    /// the one lit key; no other result is, and none is outlined.
    func testThePickedSearchResultIsTheSlabWithOnlyEnterLit() throws {
        let settings = settings()
        settings.renderForTesting(place: nil)
        settings.searchForTesting("clipboard")
        let rows = settings.searchRowsForTesting.filter { !($0 is NSTextField) }
        XCTAssertGreaterThan(rows.count, 1, "the query finds several rows")
        // A result is a row of the row contract, and the picked one is its slab.
        let risen = rows.map { ($0 as? SlabRow)?.chosen }
        XCTAssertEqual(risen.first, true, "the picked result is the slab")
        XCTAssertEqual(risen.dropFirst().filter { $0 == true }.count, 0, "and only it")
        func keys(in view: NSView) -> [Key] { ((view as? Key).map { [$0] } ?? []) + view.subviews.flatMap(keys) }
        let picked = try XCTUnwrap(rows.first)
        let caps = keys(in: picked)
        XCTAssertFalse(caps.isEmpty)
        XCTAssertEqual(caps.filter(\.lit).map(\.legend), ["⏎"], "the key that lands there lights, the address rests")
        XCTAssertTrue(rows.dropFirst().allSatisfy { keys(in: $0).allSatisfy { !$0.lit } },
                      "no other result lights a key")
        XCTAssertTrue(rows.allSatisfy { ($0.layer?.borderWidth ?? 0) == 0 }, "nothing outlined in the accent")
    }

    /// No wash: nothing in Settings is painted with the accent behind it.
    func testNoRowIsWashedInTheAccent() {
        let settings = settings(excluding: ["com.apple.TextEdit"])
        for place in [nil, keep] {
            settings.renderForTesting(place: place)
            let accent = BarTheme.accent.usingColorSpace(.sRGB)
            let washed = settings.viewsForTesting(of: NSView.self).filter { view in
                guard let fill = view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB),
                      let accent, fill.alphaComponent > 0, fill.alphaComponent < 1 else { return false }
                return abs(fill.redComponent - accent.redComponent) < 0.02
                    && abs(fill.greenComponent - accent.greenComponent) < 0.02
                    && abs(fill.blueComponent - accent.blueComponent) < 0.02
            }
            XCTAssertTrue(washed.isEmpty, "a translucent accent fill is a wash")
        }
    }
}
