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
    private static let homes: Set<String> = ["Glass.swift", "ModePill.swift"]

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
    /// clay. `Glass.resolved(_:in:)` and `ToneView` are the two ways.
    func testNoDynamicColourIsFixedOutsideItsAppearance() throws {
        let files = Self.swiftFiles(under: Self.appSources).filter { !$0.lastPathComponent.contains("Preview") }
        let hits = try offenders(
            #"(labelColor|secondaryColor|readableAccent|secondaryLabelColor|tertiaryLabelColor|separatorColor|controlAccentColor|textColor)[^\n]*\.cgColor"#,
            in: files)
        XCTAssertEqual(hits, [], "resolve it with Glass.resolved(_:in:) or draw it in a ToneView")
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
    /// `Glass.makePanel` stands on the drawn soft shadow and its fine
    /// edge, the bars' and the draft's, never the system's.
    func testEverySurfaceStandsOnTheDrawnShadow() throws {
        var missing: [String] = [], stale: [String] = []
        for (name, text) in try sources() where name != "Glass.swift" && text.contains("makePanel(") {
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
    /// `Glass.makePanel` sets it only for `SoftShadow.host` to take away.
    func testNoWindowWearsTheSystemShadow() throws {
        let offenders = try sources()
            .filter { $0.name != "Glass.swift" && $0.text.contains("hasShadow = true") }
            .map(\.name)
        XCTAssertEqual(offenders, [], "host the surface on SoftShadow instead")
    }

    /// One curve for everything that moves: `BarTheme.motion`. Three
    /// curves chosen surface by surface made the app move like three
    /// materials.
    func testEverythingMovesOnOneCurve() throws {
        let offenders = try sources()
            .filter { $0.text.contains("CAMediaTimingFunction(") && !($0.name == "Glass.swift"
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
        for (name, text) in try sources() where name != "Glass.swift" {
            let count = text.components(separatedBy: "labelColor.withAlphaComponent(").count - 1
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
        let notYet: Set<String> = ["SettingsController.swift", "Glass.swift"]
        var offenders: [String] = [], stale: [String] = []
        for (name, text) in try sources() {
            let uses = text.contains("NSPopUpButton")
            if notYet.contains(name) { if !uses { stale.append(name) } } else if uses { offenders.append(name) }
        }
        XCTAssertEqual(offenders, [], "draw the menu: a system popup wears the system's accent")
        XCTAssertEqual(stale, [], "moved off the system popup: take it off the not-yet list")
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
            if view.layer?.cornerRadius == BarTheme.chipRadius, !(view is KeyFace) { out.append(view) }
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
        let allowed: Set<String> = ["Glass.swift", "WebBar.swift", "CommandsBar.swift", "SplitPreview.swift"]
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
