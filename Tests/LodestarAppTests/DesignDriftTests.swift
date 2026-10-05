import AppKit
import XCTest
@testable import lodestar

/// The design language never drifts: a radius, a type size or a symbol
/// configuration reaches a surface only through the theme, the way the
/// accent already does. A literal in a surface fails the build with the
/// file named, so the φ table and the type scale stay the only source.
final class DesignDriftTests: XCTestCase {
    /// The theme's homes: the values live here and nowhere else.
    private static let homes: Set<String> = ["Glass.swift", "ModePill.swift"]

    private func surfaces() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lodestar")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !Self.homes.contains($0.lastPathComponent) }
        XCTAssertGreaterThan(files.count, 20, "the sources were found")
        return files
    }

    private func offenders(_ pattern: String, in files: [URL]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            for match in matches {
                let line = (text as NSString).substring(with: match.range)
                found.append("\(file.lastPathComponent): \(line)")
            }
        }
        return found
    }

    func testNoSurfaceDrawsACornerRadiusOfItsOwn() throws {
        let hits = try offenders(#"cornerRadius\s*[:=]\s*[0-9]"#, in: surfaces())
        XCTAssertEqual(hits, [], "a radius comes from the theme's table, never a literal")
    }

    func testNoSurfaceSetsATypeSizeOfItsOwn() throws {
        let hits = try offenders(#"ofSize:\s*[0-9]"#, in: surfaces())
        XCTAssertEqual(hits, [], "a size comes from the type scale, never a literal")
    }

    func testNoSurfaceConfiguresASymbolOfItsOwn() throws {
        let hits = try offenders(#"SymbolConfiguration\(pointSize:\s*[0-9]|\.init\(pointSize:\s*[0-9]"#, in: surfaces())
        XCTAssertEqual(hits, [], "a symbol wears the theme's configuration, never its own")
    }

    func testNoFieldTakesABarePlaceholder() throws {
        let hits = try offenders(#"placeholderString\s*="#, in: surfaces())
        XCTAssertEqual(hits, [], "a placeholder is set through the theme, in the interface's face")
    }

    func testAPlaceholderIsTheInterfaceAskingNotTheHandAnswering() {
        let placeholder = BarTheme.placeholder("Where to?", like: BarTheme.inputFont)
        let font = placeholder.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertFalse(font.isFixedPitch, "the sans, not the hand's mono")
        XCTAssertEqual(font.pointSize, BarTheme.inputFont.pointSize, "at the field's size")
        let field = NSTextField()
        field.font = BarTheme.inputFont
        field.setPlaceholder("Where to?")
        let set = field.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(set?.isFixedPitch, false)
    }

    func testTheThemeHoldsWhatTheGuardExpects() {
        XCTAssertEqual(BarTheme.typedFont.pointSize, 17)
        XCTAssertGreaterThan(BarTheme.typedFont.pointSize, BarTheme.bodyFont.pointSize)
        XCTAssertEqual(BarTheme.symbol.value(forKey: "pointSize") as? CGFloat, BarTheme.Scale.meta)
    }

    /// One ladder from the pill's height, each rung the one above over φ².
    func testRoundingConvergesOnOneLadder() {
        let phi = BarTheme.phi
        XCTAssertEqual(BarTheme.surfaceRadius, BarTheme.pillHeight / (phi * phi), accuracy: 0.001)
        XCTAssertEqual(BarTheme.controlRadius, BarTheme.surfaceRadius / (phi * phi), accuracy: 0.001)
        XCTAssertEqual(BarTheme.markRadius, BarTheme.controlRadius / (phi * phi), accuracy: 0.001)
        for surface in [BarTheme.glassRadius, BarTheme.rowRadius, ModePill.radius] {
            XCTAssertEqual(surface, BarTheme.surfaceRadius, "every surface rounds at the first rung")
        }
        for control in [BarTheme.chipRadius, BarTheme.glassChipRadius, BarTheme.wellRadius] {
            XCTAssertEqual(control, BarTheme.controlRadius, "every control at the second")
        }
        XCTAssertEqual(BarTheme.highlightRadius, BarTheme.markRadius, "a mark at the third")
    }

    /// Three faces, one per speaker, never borrowed.
    func testThreeFacesOnePerSpeaker() {
        XCTAssertFalse(BarTheme.bodyFont.isFixedPitch, "the interface is the sans")
        XCTAssertFalse(BarTheme.secondaryFont.isFixedPitch)
        XCTAssertTrue(BarTheme.inputFont.isFixedPitch, "what the hand types is mono")
        XCTAssertTrue(BarTheme.typedFont.isFixedPitch, "the pill's echo of the hand is mono")
        XCTAssertTrue(BarTheme.readingMono.isFixedPitch, "the draft is mono")
        XCTAssertTrue(BarTheme.voiceFont.fontName.contains("NewYork") || BarTheme.voiceFont.familyName?.contains("New York") == true,
                      "Lodestar speaks in New York")
        XCTAssertFalse(BarTheme.voiceFont.isFixedPitch)
    }

    /// A messaging timeout set on a system-wide element is the whole
    /// process's. Only `AX.swift` makes one and only launch sets it; a
    /// helper that wants a short leash sets it on the element it asks.
    func testNoHelperResetsTheProcessWideAXTimeout() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files: [URL] = []
        for dir in ["Sources/lodestar", "Sources/LodestarCore"] {
            let url = root.appendingPathComponent(dir)
            let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AX.swift" } ?? []
            files += found
        }
        XCTAssertGreaterThan(files.count, 40, "the sources were found")
        XCTAssertEqual(try offenders(#"AXUIElementCreateSystemWide\(\)"#, in: files), [],
                       "the system-wide element comes from AX.systemWide()")
        XCTAssertEqual(try offenders(#"AXUIElementSetMessagingTimeout\(\s*(AX\.)?system"#, in: files), [],
                       "a timeout on the system-wide element is the process's")
    }

    // MARK: - Objects in one light: the chrome's grammar

    /// Every Swift file in the app, named, with its text.
    private func sources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lodestar")
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The surfaces that still wear the system's shadow, or cast none,
    /// at the time the drawn shadow became the rule. The list only
    /// shrinks: a surface moved onto `SoftShadow` must leave it, and a
    /// new surface may not join it.
    private static let notYetOnTheDrawnShadow: Set<String> = [
        "CheatSheet.swift", "ClipboardStrip.swift", "EditorHover.swift", "HUD.swift",
        "IndexBadges.swift", "LinkChip.swift", "MeetingController.swift", "ModePill.swift",
        "OptionsCard.swift", "SelectOverlay.swift", "WalkController.swift",
    ]

    /// Objects float, and cast their own shadow: a surface made with
    /// `Glass.makePanel` stands on the drawn soft shadow and its fine
    /// edge, the bars' and the draft's, never the system's.
    func testEverySurfaceStandsOnTheDrawnShadow() throws {
        var missing: [String] = [], stale: [String] = []
        for (name, text) in try sources() where name != "Glass.swift" && text.contains("makePanel(") {
            let hosted = text.contains("SoftShadow.host(")
            if Self.notYetOnTheDrawnShadow.contains(name) {
                if hosted { stale.append(name) }
            } else if !hosted {
                missing.append(name)
            }
        }
        XCTAssertEqual(missing, [], "a new surface casts the drawn shadow: SoftShadow.host")
        XCTAssertEqual(stale, [], "moved onto the drawn shadow: take it off the not-yet list")
    }

    /// The drawn shadow is window, not glass: a hosted surface that took
    /// the mouse everywhere would eat clicks in its shadow. It takes the
    /// mouse through a `PointerGate`, or not at all.
    func testAHostedSurfaceNeverTakesTheMouseInItsShadow() throws {
        let offenders = try sources()
            .filter { $0.text.contains("SoftShadow.host(") && $0.text.contains("ignoresMouseEvents = false") }
            .map(\.name)
        XCTAssertEqual(offenders, [], "use PointerGate, which opens only over the glass")
    }

    /// Honest matter: nothing is shaded by a gradient. The one fade is
    /// the edge light's, in the theme, where a lit rim turns down into a
    /// corner; a room may fade its own scroll edge. Chrome never does.
    func testChromeIsNeverShadedByAGradient() throws {
        let homes: Set<String> = ["Glass.swift", "SettingsController.swift"]
        let offenders = try sources()
            .filter { !homes.contains($0.name) }
            .filter { $0.text.contains("CAGradientLayer") || $0.text.contains("NSGradient(") }
            .map(\.name)
        XCTAssertEqual(offenders, [], "flat colour only: the light is a line, never a lamp")
    }

    /// Motion is sudden: a surface changing its own shape (the draft
    /// folding or opening) moves in a tenth of a second, and not at all
    /// under Reduce Motion. Only a new band arriving, the keys, glides.
    func testASurfaceChangesShapeSuddenly() {
        XCTAssertLessThanOrEqual(DraftPanel.foldSeconds, 0.12)
        XCTAssertLessThan(DraftPanel.foldSeconds, KeysMotion.growSeconds)
    }
}
