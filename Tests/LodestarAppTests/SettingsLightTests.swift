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

    /// An app no longer on this Mac has no name to show; its identifier is
    /// all there is to recognise it by.
    func testAnAppThatIsGoneFallsBackToItsIdentifier() {
        let settings = settings(excluding: ["com.example.gone"])
        settings.renderForTesting(place: keep)
        XCTAssertTrue(settings.shownTextsForTesting.contains("com.example.gone"))
    }

    /// The picked result rises onto the step the launcher's row stands on,
    /// its keys lit; no other result does, and none is outlined.
    func testThePickedSearchResultRisesWithItsKeysLit() throws {
        let settings = settings()
        settings.renderForTesting(place: nil)
        settings.searchForTesting("clipboard")
        let rows = settings.searchRowsForTesting.filter { !($0 is NSTextField) }
        XCTAssertGreaterThan(rows.count, 1, "the query finds several rows")
        let risen = rows.map { row in row.subviews.contains { $0 is LandingStep } }
        XCTAssertEqual(risen.first, true, "the picked result rises")
        XCTAssertEqual(risen.dropFirst().filter { $0 }.count, 0, "and only it")
        let picked = try XCTUnwrap(rows.first)
        let caps = picked.subviews.compactMap { $0 as? KeyFace }
        XCTAssertFalse(caps.isEmpty)
        XCTAssertTrue(caps.allSatisfy(\.lit), "its keys light where the hand goes next")
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
