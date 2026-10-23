import AppKit
import XCTest
@testable import lodestar
import LodestarCore

/// The design language never drifts: a radius, a type size or a symbol
/// configuration reaches a surface only through the theme, the way the
/// accent already does. A literal in a surface fails the build with the
/// file named, so the φ table and the type scale stay the only source.
final class DesignDriftTests: XCTestCase {
    /// The theme's homes: the values live here and nowhere else.
    private static let homes: Set<String> = ["Ceramic.swift", "Material.swift", "ModePill.swift", "Type.swift"]

    /// Every Swift file under a folder, subfolders included: a guard that
    /// read only the top level would exempt any folder added later.
    static func swiftFiles(under dir: URL) -> [URL] {
        let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        XCTAssertGreaterThan(files.count, 20, "the sources under \(dir.lastPathComponent) were found")
        return files
    }

    static var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lodestar")
    }

    /// The code without its comments, so a guard neither fails on prose
    /// that names a pattern nor passes on code it should have read.
    static func code(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        out = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
            .joined(separator: "\n")
        return out
    }

    private func surfaces() throws -> [URL] {
        Self.swiftFiles(under: Self.appSources).filter { !Self.homes.contains($0.lastPathComponent) }
    }

    private func offenders(_ pattern: String, in files: [URL]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for file in files {
            let text = Self.code(try String(contentsOf: file, encoding: .utf8))
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

    /// A colour that follows the appearance is resolved where it is drawn.
    /// `.cgColor` on a dynamic colour resolves it in whatever appearance is
    /// current at the call, which off a draw pass is not the surface's: a
    /// Lodestar started at night went on painting night's colours on
    /// clay. `Ceramic.resolved(_:in:)` and `ToneView` are the two ways.
    func testNoDynamicColourIsFixedOutsideItsAppearance() throws {
        let files = Self.swiftFiles(under: Self.appSources).filter { !$0.lastPathComponent.contains("Preview") }
        let hits = try offenders(
            #"(BarTheme\.ink\b|secondaryColor|readableAccent|accentColor|textColor)[^\n]*\.cgColor"#,
            in: files)
        XCTAssertEqual(hits, [], "resolve it with Ceramic.resolved(_:in:) or draw it in a ToneView")
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

    /// A placeholder is set in its field's own role, so it is the field's size
    /// and weight, quiet, and it follows the look like the typed text.
    func testAPlaceholderIsTheFieldsRoleInTheQuietTone() {
        let placeholder = BarTheme.placeholder("Where to?", role: .field)
        let font = placeholder.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(font.pointSize, BarTheme.Role.field.size, "at the field's size")
        let field = NSTextField()
        field.setRole(.field)
        field.setPlaceholder("Where to?")
        let set = field.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(set?.pointSize, BarTheme.Role.field.size)
        XCTAssertEqual(set, field.font, "the placeholder wears the weight the field does")
    }

    func testTheThemeHoldsWhatTheGuardExpects() {
        XCTAssertEqual(BarTheme.symbol.value(forKey: "pointSize") as? CGFloat, BarTheme.Scale.meta)
    }

    /// What builds a font, and so belongs to the theme alone: the system's
    /// constructors, a descriptor, a preferred text style, a font set on a
    /// view by hand. A surface names a role (`setRole`, `BarTheme.attributes`)
    /// and the theme builds the font, in the look of the view that draws it.
    /// The status dot is a glyph used as a mark, not text, and keeps its own.
    private static let fontPatterns: [(String, String)] = [
        ("a system font", #"systemFont|monospaced\w*SystemFont|boldSystemFont|labelFont\(|messageFont\(|userFixedPitchFont"#),
        ("a font descriptor", #"NSFontDescriptor|\.withDesign|withSymbolicTraits"#),
        ("a text style", #"preferredFont\("#),
        ("a font built by hand", #"NSFont\("#),
        ("a font converted by hand", #"NSFontManager"#),
        ("a font set on a view", #"\.font\s*=(?!\s*BarTheme\.dotFont)"#),
    ]

    /// The type contract's one family and one scale: no surface builds a
    /// font, so none can name a serif, a mono face or a size off the scale.
    func testNoSurfaceBuildsAFont() throws {
        var found: [String] = []
        for file in Self.swiftFiles(under: Self.appSources) where !Self.homes.contains(file.lastPathComponent) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            if isDebugOnly(raw) { continue }
            let text = Self.code(raw)
            for (what, pattern) in Self.fontPatterns {
                let regex = try NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                    found.append("\(file.lastPathComponent): \(what): \((text as NSString).substring(with: match.range))")
                }
            }
        }
        XCTAssertEqual(found, [], "name a role: field.setRole(.meta), BarTheme.attributes(.body)")
    }

    func testTheFontGuardCatchesWhatItNames() throws {
        let samples = ["label.font = NSFont.systemFont(ofSize: 13)", "NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)",
                       "NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)", "x.fontDescriptor.withDesign(.serif)",
                       "NSFont.preferredFont(forTextStyle: .body)", "NSFont(descriptor: d, size: 13)",
                       "NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)", "field.font = face"]
        for sample in samples {
            let hit = try Self.fontPatterns.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertTrue(hit, "the guard misses: \(sample)")
        }
        for sample in ["field.setRole(.meta)", "dotLabel.font = BarTheme.dotFont", "let font: NSFont = role.font"] {
            let hit = try Self.fontPatterns.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertFalse(hit, "the guard flags what the theme does: \(sample)")
        }
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

    // MARK: - One theme call (design/01-colour.md)

    /// A file that is wholly a debug harness: it opens with `#if DEBUG` and
    /// closes with the matching `#endif`, so a release build has none of it.
    /// Previews stage a scene for the eye and may draw it in any colour.
    private func isDebugOnly(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first == "#if DEBUG" && lines.last == "#endif"
    }

    /// Files exempt from the colour rule, each for a reason that is its own:
    /// the app icon's artwork is drawn in its own colours (and compiled
    /// beside Mark.swift by make-icon.sh, which does not link the theme).
    private static let colourExempt: Set<String> = ["AppIconArt.swift"]

    /// What names a colour without going through the theme: a system
    /// colour, a fixed colour, a literal in any form.
    private static let colourPatterns: [(String, String)] = [
        ("a system colour",
         #"(?:\bNSColor|(?<![\w)\]?!]))\.(?:label|secondaryLabel|tertiaryLabel|quaternaryLabel|placeholderText|selectedText|selectedTextBackground|selectedContentBackground|unemphasizedSelectedContentBackground|unemphasizedSelectedText|controlAccent|control|controlText|disabledControlText|controlBackground|windowBackground|windowFrameText|textBackground|text|separator|grid|header|headerText|link|highlight|findHighlight|keyboardFocusIndicator|underPageBackground|selectedMenuItemText|selectedControl|selectedControlText|alternateSelectedControlText|scrubberTexturedBackground|shadow)Color\b"#),
        ("a system tint", #"\.system(?:Red|Orange|Yellow|Green|Mint|Teal|Cyan|Blue|Indigo|Purple|Pink|Brown|Gray|Fill)\b"#),
        ("white or black or a named colour",
         #"(?:\bNSColor|\bCGColor|(?<![\w)\]?!]))\.(?:white|black|red|green|blue|orange|yellow|gray|grey|lightGray|darkGray|brown|purple|cyan|magenta)\b"#),
        ("a grey or a colour spelled in numbers",
         #"NSColor\(\s*(?:white|red|calibrated|deviceWhite|deviceRed|displayP3Red|hue)\w*:|(?:NSColor|CGColor)\(\s*(?:srgbRed|gray)\w*:\s*[0-9.]+"#),
        ("a hex literal", #"0[xX][0-9A-Fa-f]{6}\b"#),
        ("a material", #"NSVisualEffectView|NSGlassEffectView|\.material\s*="#),
    ]

    /// Every colour a surface draws comes from the theme: none names a
    /// system colour, a literal, a pure white or black, or a material. Only
    /// the theme (Ceramic.swift, Material.swift) may build a colour, from the
    /// palette's steps; none may name a material, which is glass or a
    /// visual effect (design/04-material.md: nothing is translucent).
    func testNoSurfaceNamesAColourOrAMaterialOutsideTheTheme() throws {
        var offenders: [String] = []
        for file in Self.swiftFiles(under: Self.appSources) {
            let name = file.lastPathComponent
            let raw = try String(contentsOf: file, encoding: .utf8)
            if Self.colourExempt.contains(name) || isDebugOnly(raw) { continue }
            let text = Self.code(raw)
            for (what, pattern) in Self.colourPatterns {
                let regex = try NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                    offenders.append("\(name): \(what): \((text as NSString).substring(with: match.range))")
                }
            }
        }
        XCTAssertEqual(offenders, [], "take it from BarTheme (ink, secondaryColor, hairline, well, accent, …)")
    }

    /// The same drift test, shown to bite: each pattern catches what it names.
    func testTheColourGuardCatchesWhatItNames() throws {
        let samples = [
            "label.textColor = .labelColor", "x = NSColor.controlAccentColor", "tint: .systemBlue",
            "fill = .white", "stroke = NSColor.black", "NSColor(white: 0.5, alpha: 1)",
            "NSColor(srgbRed: 1, green: 0.3, blue: 0, alpha: 1)", "CGColor(gray: 0, alpha: 1)",
            "let c = 0xFA5617", "effect.material = .popover", "NSVisualEffectView()", "let glass = NSGlassEffectView()",
        ]
        for sample in samples {
            let hit = try Self.colourPatterns.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertTrue(hit, "the guard misses: \(sample)")
        }
        let allowed = [
            "field.textColor = BarTheme.ink", "layer.shadowColor = BarTheme.shadow.cgColor",
            "NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)", "panel.backgroundColor = .clear",
            "layer.borderColor = Ceramic.resolved(BarTheme.hairline, in: self)",
        ]
        for sample in allowed {
            let hit = try Self.colourPatterns.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertFalse(hit, "the guard flags what the theme does: \(sample)")
        }
    }

    // MARK: - Objects in one light: the chrome's grammar

    /// Every Swift file in the app, named, with its text.
    private func sources() throws -> [(name: String, text: String)] {
        try Self.swiftFiles(under: Self.appSources)
            .map { ($0.lastPathComponent, Self.code(try String(contentsOf: $0, encoding: .utf8))) }
    }

    /// The surfaces that still wear the system's shadow. The list only
    /// shrinks: a surface moved onto `SoftShadow` must leave it, and a
    /// new surface may not join it.
    private static let notYetOnTheDrawnShadow: Set<String> = [
        // Marks laid over another app's windows — hint badges, select's
        // letters — are not glass surfaces and cast no surface's shadow.
        "IndexBadges.swift", "SelectOverlay.swift",
    ]

    /// Objects float, and cast their own shadow: a surface made with
    /// `Ceramic.makePanel` stands on the drawn soft shadow and its fine
    /// edge, the bars' and the draft's, never the system's.
    func testEverySurfaceStandsOnTheDrawnShadow() throws {
        var missing: [String] = [], stale: [String] = []
        for (name, text) in try sources() where name != "Ceramic.swift" && text.contains("makePanel(") {
            // One surface per window is hosted; Keep's cards share one
            // window and each casts the same shadow as an object.
            let hosted = text.contains("SoftShadow.host(") || text.contains("SoftShadow.object(")
            if Self.notYetOnTheDrawnShadow.contains(name) {
                if hosted { stale.append(name) }
            } else if !hosted {
                missing.append(name)
            }
        }
        XCTAssertEqual(missing, [], "a new surface casts the drawn shadow: SoftShadow.host")
        XCTAssertEqual(stale, [], "moved onto the drawn shadow: take it off the not-yet list")
    }

    /// No window wears the window server's shadow: it cannot be shaped to
    /// the glass, and a room in it reads as a system window in costume.
    /// `Ceramic.makePanel` sets it only for `SoftShadow.host` to take away.
    func testNoWindowWearsTheSystemShadow() throws {
        let offenders = try sources()
            .filter { $0.name != "Ceramic.swift" && $0.text.contains("hasShadow = true") }
            .map(\.name)
        XCTAssertEqual(offenders, [], "host the surface on SoftShadow instead")
    }

    /// Every window Lodestar makes floats on the drawn shadow, not only
    /// the ones `Ceramic.makePanel` builds: a panel made by hand keeps the
    /// window server's shadow unless it says otherwise, which is how four
    /// rooms kept it. A file that makes a window hosts its surface on
    /// `SoftShadow`, or turns the shadow off and draws its own.
    func testEveryWindowMadeByHandCastsTheDrawnShadow() throws {
        let makesWindow = ["KeyablePanel(", "NSPanel(", "NSWindow(", "CeramicPanel(", "ShowingPanel("]
        var missing: [String] = []
        // The render tool's flat ground and stand-in app window are the
        // scene a surface is photographed over, not surfaces.
        let notSurfaces: Set<String> = ["Ceramic.swift", "StripPreview.swift"]
        for (name, text) in try sources() where !notSurfaces.contains(name) {
            guard makesWindow.contains(where: text.contains) else { continue }
            let drawn = text.contains("SoftShadow.host(") || text.contains("SoftShadow.object(")
                || text.contains("hasShadow = false")
            if !drawn { missing.append(name) }
        }
        XCTAssertEqual(missing, [], "host the surface on SoftShadow")
    }

    /// One curve for everything that moves: `BarTheme.motion`. Three
    /// curves chosen surface by surface made the app move like three
    /// materials.
    func testEverythingMovesOnOneCurve() throws {
        let offenders = try sources()
            .filter { $0.text.contains("CAMediaTimingFunction(") && !($0.name == "Ceramic.swift"
                && $0.text.components(separatedBy: "CAMediaTimingFunction(").count == 2) }
            .map(\.name)
        XCTAssertEqual(offenders, [], "use BarTheme.motion")
    }

    /// Grey matter is a well or a hairline (`BarTheme.well`,
    /// `BarTheme.hairline`), never an opacity chosen where it is drawn.
    /// What remains inline is not matter: a selection's wash over text, a
    /// caret, and the overview's ring, tuned per look.
    func testGreyMatterIsAWellOrAHairline() throws {
        let notMatter: [String: Int] = [
            "DraftPanel.swift": 1,      // the draft's selection
            "ClipboardStrip.swift": 1,  // an offered name standing selected
            "ModePill.swift": 1,        // the band's still caret
            "SettingsController.swift": 1, // the overview's ring
        ]
        var offenders: [String] = []
        for (name, text) in try sources() where name != "Ceramic.swift" {
            let count = text.components(separatedBy: "BarTheme.inkAt(").count - 1
            if count > notMatter[name, default: 0] { offenders.append(name) }
        }
        XCTAssertEqual(offenders, [], "use BarTheme.well or BarTheme.hairline")
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

    /// No Lodestar window shows a control in the system's tint: a system
    /// popup paints its highlight in the Mac's accent, not Lodestar's. The
    /// draft's input menu is drawn (`InputMenu`); Settings keeps the
    /// popup's behaviour but draws its face and every menu row
    /// (`KeyPopUp`, `ChoiceMenuItemView`), the one file allowed to.
    func testNoSurfaceUsesASystemPopup() throws {
        let notYet: Set<String> = ["SettingsController.swift", "Ceramic.swift"]
        var offenders: [String] = [], stale: [String] = []
        for (name, text) in try sources() {
            let uses = text.contains("NSPopUpButton")
            if notYet.contains(name) { if !uses { stale.append(name) } } else if uses { offenders.append(name) }
        }
        XCTAssertEqual(offenders, [], "draw the menu: a system popup wears the system's accent")
        XCTAssertEqual(stale, [], "moved off the system popup: take it off the not-yet list")
    }

    /// Honest matter: nothing is shaded by a gradient. A room may fade its
    /// own scroll edge by a mask; the theme and chrome never do, and the rim
    /// is a clipped strip, not a fade (MaterialTests holds the rest).
    func testChromeIsNeverShadedByAGradient() throws {
        let homes: Set<String> = ["SettingsController.swift"]
        let offenders = try sources()
            .filter { !homes.contains($0.name) }
            .filter { $0.text.contains("CAGradientLayer") || $0.text.contains("NSGradient(") }
            .map(\.name)
        XCTAssertEqual(offenders, [], "flat colour only: the light is a line, never a lamp")
    }

    /// One light, never paint: nothing is coloured as an alarm. What
    /// cannot be undone is told by its words and its place under a rule.
    func testNothingIsPaintedAsAnAlarm() throws {
        let offenders = try sources()
            .filter { $0.text.contains(".systemRed") }
            .map(\.name)
        XCTAssertEqual(offenders, [], "no alarm colour: say it in words, set it apart by place")
    }

    /// Motion is sudden: a surface changing its own shape (the draft
    /// folding or opening) moves in a tenth of a second, and not at all
    /// under Reduce Motion. Only a new band arriving, the keys, glides.
    func testASurfaceChangesShapeSuddenly() {
        XCTAssertLessThanOrEqual(DraftPanel.foldSeconds, 0.12)
        XCTAssertLessThan(DraftPanel.foldSeconds, KeysMotion.growSeconds)
    }

    // MARK: - One key, keys drawn, labels as names

    /// Every view shaped like a key, in what a builder made.
    private func keyShapes(in root: NSView) -> [NSView] {
        var out: [NSView] = []
        func walk(_ view: NSView) {
            if view.layer?.cornerRadius == BarTheme.controlRadius, !(view is KeyFace) { out.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    /// There is one key, the launcher's: a guide, a gesture line and a
    /// card's footer draw `KeyFace`, never a grey chip of their own.
    func testTheGuidesAndLinesDrawTheOneKey() {
        let guide = CheatSheet.columns(HotkeyEngine.draftSections(editor: .normal, card: false))
        XCTAssertEqual(keyShapes(in: guide).count, 0, "a guide's keys are the one key")
        let line = Keycaps.line([.init(["lode", "lode"], "go"), .init(["esc"], "back")])
        XCTAssertEqual(keyShapes(in: line).count, 0)
        XCTAssertTrue(Keycaps.cap("A") is KeyFace)
        let footer = OptionsCard.footerLine("⌫ back up    esc back")
        XCTAssertEqual(keyShapes(in: footer).count, 0)
        var keys = 0
        func count(_ view: NSView) { if view is KeyFace { keys += 1 }; view.subviews.forEach(count) }
        count(footer)
        XCTAssertEqual(keys, 2, "a footer's keys are drawn as keys")
    }

    /// The key's face is drawn in one place. Its font appears only in the
    /// theme and on the two chips that are read rather than pressed (Ask's
    /// profile, the commands bar's source); a harness may use it.
    func testOnlyTheThemeDrawsAKey() throws {
        let allowed: Set<String> = ["Ceramic.swift", "WebBar.swift", "CommandsBar.swift", "SplitPreview.swift"]
        let offenders = try sources()
            .filter { $0.text.contains("BarTheme.chipFont") && !allowed.contains($0.name) }
            .map(\.name)
        XCTAssertEqual(offenders, [], "draw a key with KeyFace (Keycaps.cap), not a chip of your own")
    }

    /// Keys are drawn, never typed into a sentence: "esc back" as letters
    /// is a key the eye has to find inside the words.
    func testKeysAreDrawnNotTyped() throws {
        let hits = try offenders(#"stringValue = "[^"]*(\besc [a-z]|⌫ [a-z]|⇥ [a-z]|⏎ [a-z]|↵|h j k l|lode [A-Z] )"#,
                                 in: surfaces())
        XCTAssertEqual(hits, [], "draw keys with Keycaps.line or a footer line")
    }

    /// Every flash literal in the app's sources, as written.
    private func flashLiterals() throws -> [(file: String, text: String)] {
        let regex = try NSRegularExpression(pattern: #"flash\("((?:[^"\\]|\\.)*)""#)
        var found: [(String, String)] = []
        for file in Self.swiftFiles(under: Self.appSources) {
            let text = Self.code(try String(contentsOf: file, encoding: .utf8))
            for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                found.append((file.lastPathComponent, (text as NSString).substring(with: match.range(at: 1))))
            }
        }
        XCTAssertGreaterThan(found.count, 60, "the flashes were found")
        return found
    }

    /// One voice for every flash (DESIGN, the flash rules): it opens with
    /// one of the marks, then a capital; a key it names is drawn, written
    /// in brackets; no timer and no "see the log" on the glass.
    func testEveryFlashSpeaksOneWay() throws {
        let marks: Set<Character> = ["✕", "⚠", "✓", "⌂", "◎", "⟲", "↺", "⤺", "☰"]
        var unmarked: [String] = [], lowercase: [String] = [], typed: [String] = [], timers: [String] = []
        for (file, literal) in try flashLiterals() {
            guard let first = literal.first else { continue }
            let where_ = "\(file): \(literal)"
            if !marks.contains(first) { unmarked.append(where_); continue }
            let rest = literal.dropFirst().drop { $0 == " " }
            if let letter = rest.first, letter.isLowercase { lowercase.append(where_) }
            // Keys outside brackets are typed into the words.
            let unbracketed = literal.replacingOccurrences(of: #"\[\]\]|\[[^\]]+\]"#, with: "", options: .regularExpression)
            if unbracketed.rangeOfCharacter(from: CharacterSet(charactersIn: "⌘⌃⌥⇧⏎↵⌫⇥")) != nil { typed.append(where_) }
            if literal.range(of: #"\b[0-9]+ ?s\b|see (the )?log"#, options: .regularExpression) != nil { timers.append(where_) }
        }
        XCTAssertEqual(unmarked, [], "open with a mark: ✕ refused, ⚠ needs you, ✓ done, ⌂ Keep, ◎ a breath, ⟲ ↺ ⤺ layout, ☰ the menu bar")
        XCTAssertEqual(lowercase, [], "the fact opens with a capital")
        XCTAssertEqual(typed, [], "write a key as [⌘], and it is drawn")
        XCTAssertEqual(timers, [], "no timer and no log on the glass")
    }

    /// A label is a name, capitalized: a section's title, a link, a
    /// button, and the words beside a key.
    func testLabelsAreNames() throws {
        let hits = try offenders(#"header: "[a-z]|smallLink\("[a-z]|RoomButton\(title: "[a-z]|GuideRow\((key|keys): [^\n]*label: "[a-z]|\brow\("[^"\n]*", "[a-z]|KeyRow\("[^"\n]*", "[a-z]|smallLink\([^\n]*"[a-z]"#,
                                 in: surfaces())
        XCTAssertEqual(hits, [], "capitalize it as a name")
        var words: [String] = []
        func read(_ view: NSView) {
            if let field = view as? NSTextField { words.append(field.stringValue) }
            view.subviews.forEach(read)
        }
        read(Keycaps.line([.init(["esc"], "back up")]))
        XCTAssertTrue(words.contains("Back up"), "a key's words are capitalized wherever they come from: \(words)")
    }

    /// A test never writes the Mac's clipboard: the Lodestar running on
    /// it records every write into the person's clipboard history, so a
    /// suite run once filled it with "It broke" and "Offline". Tests hand
    /// a surface a pasteboard of their own.
    func testNoTestWritesTheRealClipboard() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "DesignDriftTests.swift" }
        let hits = try offenders(#"NSPasteboard\.general\.(setString|clearContents|writeObjects|setData)"#, in: files)
        XCTAssertEqual(hits, [], "use a named pasteboard of the test's own")
    }

    /// Nothing leaves the process but through `SystemEvents`: an event
    /// posted to the system or an app, the general pasteboard, focus taken
    /// or given. Under a test run that one file is inert, so a test that
    /// forgets its stand-in cannot type, click or copy into the person's
    /// work, and the suite cannot take their focus.
    func testEverythingThatLeavesTheProcessGoesThroughSystemEvents() throws {
        let files = Self.swiftFiles(under: Self.appSources).filter { $0.lastPathComponent != "SystemEvents.swift" }
        let hits = try offenders(
            #"\.post\(tap:|\.postToPid\(|NSPasteboard\.general|NSApp\.activate\(|\.activate\(options:|[A-Za-z0-9_)?]\.activate\(\)|CGWarpMouseCursorPosition|NSWorkspace\.shared\.open"#,
            in: files)
        XCTAssertEqual(hits, [], "post, warp, open, paste and activate through SystemEvents")
    }

    /// A process that acts on the Mac starts through SystemEvents.run.
    /// Two only read: `launchctl list` for the login item, and the
    /// updater's checks of a downloaded bundle.
    func testAProcessThatActsOnTheMacStartsThroughSystemEvents() throws {
        let allowed: Set<String> = ["main.swift", "UpdateController.swift", "SystemEvents.swift"]
        let files = Self.swiftFiles(under: Self.appSources).filter { !allowed.contains($0.lastPathComponent) }
        let hits = try offenders(#"(process|task)\.run\(\)"#, in: files)
        XCTAssertEqual(hits, [], "start it with SystemEvents.run")
    }

    /// The person's home is Paths.userHome, which a test run replaces.
    /// Two reads are allowed the real one: a model already downloaded to
    /// the Hugging Face cache, and a path shortened to ~ for display.
    func testThePersonsHomeIsReachedThroughPaths() throws {
        let allowed: Set<String> = ["EditorModel.swift", "RepoNames.swift"]
        let files = Self.swiftFiles(under: Self.appSources).filter { !allowed.contains($0.lastPathComponent) }
        let hits = try offenders(#"homeDirectoryForCurrentUser|NSHomeDirectory\(\)"#, in: files)
        XCTAssertEqual(hits, [], "use Paths.userHome")
    }

    func testATestRunHoldsTheSystemBack() {
        XCTAssertTrue(TestRun.active)
        XCTAssertNotEqual(SystemEvents.pasteboard.name, NSPasteboard.general.name)
        XCTAssertFalse(Paths.data.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path),
                       "a test run keeps its data in a home of its own")
        let before = SystemEvents.heldBack
        SystemEvents.post(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true), tap: .cghidEventTap)
        XCTAssertGreaterThanOrEqual(SystemEvents.heldBack, before + 1)
    }

    /// A room's actions are its keys, and its controls are Lodestar's: no
    /// system bezel, checkbox or switch, which wear the Mac's accent and
    /// its shapes. Buttons are `RoomButton`, fields `RoomField`, switches
    /// `AccentSwitch`, primary actions `Keycaps.line` with a lit key.
    func testNoRoomShowsASystemControl() throws {
        let hits = try offenders(#"bezelStyle\s*=|checkboxWithTitle|radioButtonWithTitle|NSSwitch\("#,
                                 in: surfaces())
        XCTAssertEqual(hits, [], "draw it: RoomButton, RoomField, AccentSwitch, or a key")
    }
}
