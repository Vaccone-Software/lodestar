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
    private static let homes: Set<String> = ["Ceramic.swift", "Key.swift", "Material.swift", "ModePill.swift", "Type.swift"]

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
    private static let fontPatterns: [(String, String)] = [
        ("a system font", #"systemFont|monospaced\w*SystemFont|boldSystemFont|labelFont\(|messageFont\(|userFixedPitchFont"#),
        ("a font descriptor", #"NSFontDescriptor|\.withDesign|withSymbolicTraits"#),
        ("a text style", #"preferredFont\("#),
        ("a font built by hand", #"NSFont\("#),
        ("a font converted by hand", #"NSFontManager"#),
        ("a font set on a view", #"\.font\s*=(?!=)"#),
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
        for sample in ["field.setRole(.meta)", "let font: NSFont = role.font"] {
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
            "field.textColor = BarTheme.ink", "layer.shadowColor = BarTheme.shadowInk.cgColor",
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

    /// One curve for everything that moves: `Motion.curve`. Three
    /// curves chosen surface by surface made the app move like three
    /// materials.
    func testEverythingMovesOnOneCurve() throws {
        let offenders = try sources()
            .filter { $0.text.contains("CAMediaTimingFunction(") && !($0.name == "Motion.swift"
                && $0.text.components(separatedBy: "CAMediaTimingFunction(").count == 2) }
            .map(\.name)
        XCTAssertEqual(offenders, [], "use Motion.curve")
    }

    /// Grey matter is a well or a hairline (`BarTheme.well`,
    /// `BarTheme.hairline`), never an opacity chosen where it is drawn.
    /// What remains inline is not matter: a selection's wash over text, a
    /// caret, and the overview's ring, tuned per look.
    func testGreyMatterIsAWellOrAHairline() throws {
        let notMatter: [String: Int] = [
            "DraftPanel.swift": 1,      // the draft's selection
            "ModePill.swift": 1,        // the band's still caret
            "SettingsController.swift": 1, // the overview's ring
        ]
        var offenders: [String] = []
        for (name, text) in try sources() where name != "Ceramic.swift" && name != "Key.swift" {
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

    // MARK: - One key, keys drawn, labels as names

    /// Every view shaped like a key, in what a builder made.
    private func keyShapes(in root: NSView) -> [NSView] {
        var out: [NSView] = []
        func walk(_ view: NSView) {
            if view.layer?.cornerRadius == BarTheme.controlRadius, !(view is Key) { out.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    /// There is one key, the launcher's: a guide, a gesture line and a
    /// card's footer draw `Key`, never a grey chip of their own.
    func testTheGuidesAndLinesDrawTheOneKey() {
        let guide = CheatSheet.columns(HotkeyEngine.draftSections(style: .vim, editor: .normal, card: false))
        XCTAssertEqual(keyShapes(in: guide).count, 0, "a guide's keys are the one key")
        let line = Keycaps.line([.init(["lode", "lode"], "go"), .init(["esc"], "back")])
        XCTAssertEqual(keyShapes(in: line).count, 0)
        XCTAssertTrue(Keycaps.cap("A") is Key)
        let footer = OptionsCard.footerLine("⌫ back up    esc back")
        XCTAssertEqual(keyShapes(in: footer).count, 0)
        var keys = 0
        func count(_ view: NSView) { if view is Key { keys += 1 }; view.subviews.forEach(count) }
        count(footer)
        XCTAssertEqual(keys, 2, "a footer's keys are drawn as keys")
    }

    /// The key is drawn in one place (design/10-key.md, rule 1): a face on a
    /// side whose legend is set by `KeyLegend` (and `KeyWords`, in Row.swift, sets
    /// the words beside it on that legend's baseline). No other file stands a face
    /// on a control's side, places a legend by CoreText, or sets the key
    /// role. The three that read a word rather than ask for a press (a
    /// popup's drawn bezel, Ask's profile chip and the commands bar's source
    /// chip, the meeting's unit) are named, and the list only shrinks.
    func testNoSurfaceDrawsAKeyOfItsOwn() throws {
        let homes: Set<String> = ["Key.swift", "Ceramic.swift", "Material.swift", "Row.swift"]
        let popup: Set<String> = ["SettingsController.swift"]
        let readsAWord: Set<String> = ["WebBar.swift", "CommandsBar.swift", "MeetingController.swift"]
        var offenders: [String] = []
        for (name, text) in try sources() where !homes.contains(name) {
            func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
            if has(#"Standing\(rest:\s*Ceramic\.Side\.(control|large)"#), !popup.contains(name) {
                offenders.append("\(name): stands a face on a key's side")
            }
            if has(#"CTLineDraw|CTLineCreate|KeyLegend\."#) { offenders.append("\(name): places a legend itself") }
            if has(#"setRole\(\s*\.key\b|attributes\(\s*\.key\b|in:\s*\.key\b|role:\s*\.key\b"#), !readsAWord.contains(name) {
                offenders.append("\(name): sets the key role")
            }
        }
        XCTAssertEqual(offenders, [], "draw a key with Key (Keycaps.cap, Keycaps.strokes), not a view of your own")
    }

    /// A double tap is one key and ×2, never two identical keys in a row.
    func testNoSourceWritesADoubleTapAsTwoKeys() throws {
        let hits = try offenders(#""lode",\s*"lode""#, in: Self.swiftFiles(under: Self.appSources))
        XCTAssertEqual(hits, [], "one key and ×2: double: true")
    }

    /// A bare keystroke is shown as typed (design/10-key.md, rule 3): lowercase.
    /// Capitals appear on a key only where Shift is part of it, and a letter
    /// after a modifier in a chord, as macOS writes it. So `uppercased()` in
    /// the sources is for sentence-casing a word, or one of the listed uses
    /// below, each of which is data, a chord, or what VoiceOver says. A new
    /// `uppercased()` that shows a keystroke fails here.
    func testNoBareKeystrokeIsUppercasedForDisplay() throws {
        let allowed: [(file: String, snippet: String, why: String)] = [
            ("MeetingController.swift", "unit.uppercased()", "a countdown's unit (MIN), not a key"),
            ("SelectOverlay.swift", "label.uppercased()", "a hint is picked with Shift, so it wears capitals"),
            ("ClipboardStrip.swift", "\"⌥\") + label.uppercased()", "a chord: ⌥ then the letter as a capital"),
            ("ClipboardStrip.swift", "chord = label.uppercased()", "a chord: the letter after a modifier is a capital"),
            ("ClipboardStrip.swift", "\\(label.uppercased()), match", "what VoiceOver says"),
            ("ClipboardStrip.swift", "\\(label.uppercased()), clip", "what VoiceOver says"),
            ("ClipColor.swift", "s == s.uppercased()", "reading a colour, not drawing a key"),
            ("Vim.swift", "ch.uppercased()", "vim's case toggle on the text"),
            ("Vim.swift", "text.uppercased()", "vim's gU on the text"),
            ("Vim.swift", "Character($0.uppercased())", "vim's case toggle on the text"),
            ("Keys.swift", "key.uppercased()", "what a key types with shift: data the engine matches on"),
            ("CodeNames.swift", "$0.uppercased()", "UPPER_SNAKE for a name in code"),
            ("ClipTime.swift", "s.uppercased()", "reading a time"),
            ("ClipTime.swift", "typed.uppercased()", "reading a time zone"),
            ("MenuItems.swift", "char.uppercased()", "a menu shortcut's chord: modifiers, then a capital"),
            ("IntentChecker.swift", "w.uppercased()", "reading words"),
            ("EditorSession.swift", "word.uppercased()", "reading words"),
            ("EditorRegion.swift", "$0.uppercased()", "reading a region code"),
            ("EditorDiff.swift", "words[0].uppercased()", "reading words"),
        ]
        var unexplained: [String] = [], used = Set<Int>()
        let directories = [Self.appSources, Self.appSources.deletingLastPathComponent().appendingPathComponent("LodestarCore")]
        for directory in directories {
            for file in Self.swiftFiles(under: directory) {
                let text = Self.code(try String(contentsOf: file, encoding: .utf8))
                for line in text.components(separatedBy: "\n") where line.contains("uppercased()") {
                    // Capitalising the first letter of a word is sentence case.
                    let stripped = line.replacingOccurrences(of: #"(prefix\(1\)|first)\.uppercased\(\)"#, with: "",
                                                             options: .regularExpression)
                    guard stripped.contains("uppercased()") else { continue }
                    if let index = allowed.firstIndex(where: { $0.file == file.lastPathComponent && line.contains($0.snippet) }) {
                        used.insert(index)
                    } else {
                        unexplained.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        XCTAssertEqual(unexplained, [], "show a bare keystroke as typed, lowercase; or say why this is not one, above")
        let stale = allowed.indices.filter { !used.contains($0) }.map { allowed[$0].file + ": " + allowed[$0].snippet }
        XCTAssertEqual(stale, [], "an allowed use that no longer exists comes off the list")
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

    // MARK: - The well (design/12-well.md)

    /// What a text field of a room may be made of: Lodestar's own field,
    /// which draws no bezel, border, ground or focus ring and is edited in the
    /// one editor, never the system's.
    private static let fieldOffenders: [(String, String)] = [
        ("a bezel left on", #"\bisBezeled\s*=\s*true"#),
        ("a focus ring", #"focusRingType\s*=\s*\.(?:default|exterior)"#),
        ("a plain text field", #"\bNSTextField\(\s*\)|\bNSTextField\(frame:|NSSearchField\(|NSSecureTextField\("#),
        ("a plain text view", #"\bNSTextView\(\s*\)|\bNSTextView\(frame:"#),
    ]

    /// A field that is made borderless says it has no bezel either: a field
    /// that leaves `isBezeled` on draws one whatever `isBordered` says.
    static func fieldsLeavingABezel(in text: String) -> [String] {
        var found: [String] = []
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let borderless = try! NSRegularExpression(pattern: #"\b(\w+)\.isBordered\s*=\s*false"#)
        for match in borderless.matches(in: text, range: whole) {
            let receiver = (text as NSString).substring(with: match.range(at: 1))
            // Only a text field has a bezel; a button's isBordered is its own.
            let isField = try! NSRegularExpression(
                pattern: #"(?:let|var)\s+"# + receiver + #"\b[^\n=]*=\s*(?:NSTextField|InputField|WellField)\((?!\s*(?:label|wrapping|string))"#)
            guard isField.firstMatch(in: text, range: whole) != nil else { continue }
            let bare = try! NSRegularExpression(pattern: #"\b"# + receiver + #"\.isBezeled\s*=\s*false"#)
            if bare.firstMatch(in: text, range: whole) == nil { found.append(receiver) }
        }
        return found
    }

    /// No surface leaves a bezel on a text field, draws a focus ring, or makes
    /// a text field or a text view of the system's plain kind: a field is an
    /// `InputField` (or a `WellField`), a note a `NoteWell`.
    func testNoTextFieldLeavesItsBezelOnOrDrawsAFocusRing() throws {
        var found: [String] = []
        for file in Self.swiftFiles(under: Self.appSources) where !Self.homes.contains(file.lastPathComponent) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            if isDebugOnly(raw) { continue }
            let text = Self.code(raw)
            for (what, pattern) in Self.fieldOffenders {
                // The draft is a page you write on, not a field you fill: its
                // text view is the one plain text view, and it is not editable.
                if what == "a plain text view", file.lastPathComponent == "DraftPanel.swift" { continue }
                let regex = try NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                    found.append("\(file.lastPathComponent): \(what): \((text as NSString).substring(with: match.range))")
                }
            }
            for receiver in Self.fieldsLeavingABezel(in: text) {
                found.append("\(file.lastPathComponent): \(receiver) is borderless and still bezeled")
            }
        }
        XCTAssertEqual(found, [], "make it an InputField, set isBezeled = false, and focusRingType = .none")
    }

    func testTheFieldGuardCatchesWhatItNames() throws {
        let samples = ["field.isBezeled = true", "field.focusRingType = .default", "let field = NSTextField()",
                       "NSTextField(frame: .zero)", "let search = NSSearchField()", "let text = NSTextView()"]
        for sample in samples {
            let hit = try Self.fieldOffenders.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertTrue(hit, "the guard misses: \(sample)")
        }
        for sample in ["field.focusRingType = .none", "let field = InputField()", "NSTextField(labelWithString: \"x\")",
                       "field.isBezeled = false", "let well = WellField(frame: .zero)"] {
            let hit = try Self.fieldOffenders.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertFalse(hit, "the guard flags what a field does: \(sample)")
        }
        XCTAssertEqual(Self.fieldsLeavingABezel(in: "let field = InputField()\nfield.isBordered = false"), ["field"])
        XCTAssertEqual(Self.fieldsLeavingABezel(in: "let field = NSTextField()\nfield.isBordered = false\nfield.isBezeled = false"), [])
        XCTAssertEqual(Self.fieldsLeavingABezel(in: "let button = NSButton()\nbutton.isBordered = false"), [],
                       "a button's border is not a text field's bezel")
    }

    /// A field's height is on the size table: no surface names its own
    /// (Keep's source list had a field of 40), and the table's rows are the
    /// ones the contract gives.
    static let fieldHeightLiterals = #"(?:static\s+(?:let|var)\s+\w*[Ff]ield\w*\s*(?::\s*CGFloat)?\s*=\s*[0-9])|(?:[Ff]ield\w*[^\n]*(?:heightAnchor\.constraint\(equalToConstant:|height:)\s*[0-9])"#

    func testNoFieldHeightIsALiteralOffTheSizeTable() throws {
        let files = Self.swiftFiles(under: Self.appSources).filter { $0.lastPathComponent != "Geometry.swift" }
        XCTAssertEqual(try offenders(Self.fieldHeightLiterals, in: files), [],
                       "a field is BarTheme.fieldHeight (32), a bar's BarTheme.inputHeight (60), a band's BarTheme.bandHeight")
        for sample in ["private static let menuField: CGFloat = 40", "field.heightAnchor.constraint(equalToConstant: 36)",
                       "let field = NSRect(x: 0, y: 0, width: 10, height: 36)"] {
            XCTAssertNotNil(sample.range(of: Self.fieldHeightLiterals, options: .regularExpression), "the guard misses: \(sample)")
        }
        for sample in ["field.heightAnchor.constraint(equalToConstant: BarTheme.fieldHeight)",
                       "static let barHeight = BarTheme.bandHeight"] {
            XCTAssertNil(sample.range(of: Self.fieldHeightLiterals, options: .regularExpression), "flags the table: \(sample)")
        }
        XCTAssertEqual(BarTheme.fieldHeight, 32)
        XCTAssertEqual(BarTheme.inputHeight, 60)
        XCTAssertEqual(BarTheme.bandHeight, 40, "a field and its 4-point inset round it")
        XCTAssertEqual(ClipboardStrip.barHeight, BarTheme.bandHeight)
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

    // MARK: - Quiet, never faded; and the dot is drawn (design/13-row.md)

    /// What would draw a row, a card or a control translucent: an alpha or a
    /// layer opacity set to anything but 1. A thing that cannot act is drawn
    /// in the quiet ink, opaque. (Motion has no fades, so there is no
    /// exception: the knob's slide moves a position.)
    private static let translucencyPatterns: [(String, String)] = [
        ("a view's alpha", #"\balphaValue\s*=(?!=)(?!\s*1(?:\.0+)?\s*(?:[;\n}]|$))"#),
        ("a layer's opacity", #"\.opacity\s*=(?!=)(?!\s*1(?:\.0+)?\s*(?:[;\n}]|$))"#),
    ]

    func testNoRowCardOrControlIsDrawnTranslucent() throws {
        var found: [String] = []
        for file in Self.swiftFiles(under: Self.appSources) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            if isDebugOnly(raw) { continue }
            let text = Self.code(raw)
            for (what, pattern) in Self.translucencyPatterns {
                let regex = try NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                    let line = (text as NSString).substring(with: (text as NSString).lineRange(for: match.range))
                    found.append("\(file.lastPathComponent): \(what): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(found, [], "quiet ink, never a fade: draw it in BarTheme.secondaryColor, opaque")
    }

    func testTheTranslucencyGuardBites() throws {
        for sample in ["line.alphaValue = 0.45", "content.alphaValue = shown", "layer?.opacity = isEnabled ? 1 : 0.45",
                       "toggle.layer.opacity = 0.2", "view.alphaValue = 0"] {
            let hit = try Self.translucencyPatterns.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertTrue(hit, "the guard misses: \(sample)")
        }
        for sample in ["view.alphaValue = 1", "layer.opacity = 1.0", "layer.shadowOpacity = Float(share)",
                       "if view.alphaValue == 0.45 {", "view.alphaValue = 1\n"] {
            let hit = try Self.translucencyPatterns.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertFalse(hit, "the guard flags what is opaque: \(sample)")
        }
    }

    /// On every gallery surface, in both looks, nothing a row, a card or a
    /// control is made of is drawn at less than full strength: no view, no
    /// layer under it. A row that cannot act, a switch on and unavailable and
    /// Keep's missing-file card are among the pictures.
    func testNothingOnAnySurfaceIsTranslucent() throws {
        var found: [String] = []
        var checked = 0
        func walkLayers(_ layer: CALayer, _ path: String, _ report: (String) -> Void) {
            if layer.opacity < 1 { report("\(path) layer at \(layer.opacity)") }
            for (index, sub) in (layer.sublayers ?? []).enumerated() { walkLayers(sub, "\(path)/\(index)", report) }
        }
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) && shot.level == 1 && !shot.receded {
                guard let (root, keep) = try? shot.built(in: look) else { continue }
                root.window?.contentView?.layoutSubtreeIfNeeded()
                let name = shot.name(in: look)
                func visit(_ view: NSView) {
                    if !view.isHidden {
                        checked += 1
                        if view.alphaValue < 1 { found.append("\(name): \(type(of: view)) at \(view.alphaValue)") }
                        if let layer = view.layer, layer.opacity < 1 { found.append("\(name): \(type(of: view)) layer at \(layer.opacity)") }
                        // The layers a view draws with itself (a switch's track and knob, a key's
                        // face and side), not its subviews' layers, which are visited as views;
                        // and not the system's own scroll bars, which the Mac shows and hides.
                        if let layer = view.layer, !(view is NSScrollView), !(view is NSScroller) {
                            let theirs = Set(view.subviews.compactMap(\.layer).map(ObjectIdentifier.init))
                            for sub in layer.sublayers ?? [] where !theirs.contains(ObjectIdentifier(sub)) {
                                walkLayers(sub, "\(name): \(type(of: view))") { found.append($0) }
                            }
                        }
                    }
                    view.subviews.forEach(visit)
                }
                visit(root)
                _ = keep
            }
        }
        XCTAssertGreaterThan(checked, 10_000, "every view of every surface was looked at")
        XCTAssertEqual(Array(Set(found)).sorted(), [], "nothing is drawn translucent: opaque, in the quiet ink")
    }

    /// The dot is drawn, 7 across (`RowDot`), never a glyph set in a font.
    private static let dotGlyphPatterns: [(String, String)] = [
        ("a dot glyph", #"[●⬤⏺◉⚫]"#),
        ("the old dot font", #"\bdotFont\b"#),
        ("a dot drawn by hand", #"radius:\s*BarTheme\.dotRadius"#),
    ]

    func testTheDotIsDrawnAndNeverAGlyph() throws {
        var found: [String] = []
        for file in Self.swiftFiles(under: Self.appSources) where file.lastPathComponent != "Row.swift" {
            let text = Self.code(try String(contentsOf: file, encoding: .utf8))
            for (what, pattern) in Self.dotGlyphPatterns {
                let regex = try NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                    found.append("\(file.lastPathComponent): \(what): \((text as NSString).substring(with: match.range))")
                }
            }
        }
        XCTAssertEqual(found, [], "a dot is RowDot (ink for the current choice or your own setting, quiet for a running app)")
        for sample in ["let dotLabel = NSTextField(labelWithString: \"●\")", "dotLabel.font = BarTheme.dotFont",
                       "let mark = \"⏺\"", "ToneView(fill: BarTheme.ink, radius: BarTheme.dotRadius)"] {
            let hit = try Self.dotGlyphPatterns.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertTrue(hit, "the guard misses: \(sample)")
        }
        for sample in ["titleLine.addArrangedSubview(RowDot(.quiet))", "let separator = \" · \""] {
            let hit = try Self.dotGlyphPatterns.contains { _, pattern in
                try NSRegularExpression(pattern: pattern)
                    .firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
            }
            XCTAssertFalse(hit, "the guard flags what draws the dot: \(sample)")
        }
        // And on every surface: no field holds a dot glyph.
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) && shot.level == 1 && !shot.receded {
                guard let (root, keep) = try? shot.built(in: look) else { continue }
                func visit(_ view: NSView) {
                    if let field = view as? NSTextField, field.stringValue.range(of: "[●⬤⏺◉⚫]", options: .regularExpression) != nil {
                        found.append("\(shot.name(in: look)): a field says \"\(field.stringValue)\"")
                    }
                    view.subviews.forEach(visit)
                }
                visit(root)
                _ = keep
            }
        }
        XCTAssertEqual(found, [])
    }
}
