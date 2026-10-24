import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/02-type.md: one family, one scale, three weights, one step
/// heavier at night, tabular figures for a number that changes in place.
final class TypeRolesTests: XCTestCase {
    override func tearDown() {
        GalleryLook.reset()
        ActivePolicy.frameOverride = nil
    }

    private static let scale: Set<CGFloat> = [13, 16, 18, 23]
    private static let dayWeights: Set<String> = ["regular", "medium", "semibold"]
    private static let heavier = ["regular": "medium", "medium": "semibold", "semibold": "bold"]

    private func weight(_ font: NSFont) -> String { GalleryFoundations.weightName(font) }

    // MARK: - The roles

    /// Every font the theme defines is a role; none is a serif or a mono,
    /// none is off the scale, and by day none is outside the three weights.
    func testEveryRoleIsTheSansOnTheScaleInTheThreeWeights() {
        XCTAssertEqual(BarTheme.Role.allCases.count, 18, "the contract's table")
        let system = NSFont.systemFont(ofSize: 13).familyName
        for role in BarTheme.Role.allCases {
            for night in [false, true] {
                let font = role.font(night: night)
                let named = "\(role.rawValue) at \(night ? "night" : "day"): \(font.fontName)"
                XCTAssertFalse(font.fontName.lowercased().contains("newyork"), "no serif: \(named)")
                if role.isMono {
                    // Mono is where vim is: the draft and the editor's lens, one cell a letter.
                    XCTAssertTrue(font.isFixedPitch, "the draft is mono: \(named)")
                    XCTAssertTrue(["draft", "draftMarked"].contains(role.rawValue))
                    let cells = ["i", "W", " ", "m"].map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                    XCTAssertTrue(cells.allSatisfy { abs($0 - cells[0]) < 0.001 }, "one cell a letter: \(named)")
                } else {
                    XCTAssertEqual(font.familyName, system, "the system's sans: \(named)")
                    XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.monoSpace), "no mono: \(named)")
                    XCTAssertFalse(font.isFixedPitch, "no mono: \(named)")
                }
                XCTAssertTrue(Self.scale.contains(font.pointSize), "on the scale: \(named) is \(font.pointSize)")
                XCTAssertGreaterThanOrEqual(font.pointSize, 13, "13 is the floor: \(named)")
            }
            XCTAssertTrue(Self.dayWeights.contains(weight(role.font(night: false))),
                          "\(role.rawValue) is regular, medium or semibold by day")
        }
    }

    /// Mono is only the draft's two roles.
    func testMonoIsOnlyTheDraft() {
        XCTAssertEqual(Set(BarTheme.Role.allCases.filter(\.isMono)), [.draft, .draftMarked])
        for role in BarTheme.Role.allCases where !role.isMono {
            XCTAssertFalse(role.font(night: false, tabular: true).isFixedPitch, role.rawValue)
        }
    }

    /// The contract's table, role by role.
    func testTheRolesAreTheContractsTable() {
        let table: [(BarTheme.Role, CGFloat, String)] = [
            (.field, 23, "regular"), (.voice, 18, "regular"), (.title, 18, "regular"),
            (.roomTitle, 18, "semibold"), (.body, 16, "regular"), (.quietVoice, 16, "regular"),
            (.typed, 16, "semibold"), (.emphasis, 16, "semibold"), (.figure, 18, "semibold"),
            (.largeFigure, 23, "semibold"), (.meta, 13, "regular"), (.name, 13, "medium"),
            (.label, 16, "medium"), (.control, 16, "regular"), (.heading, 13, "semibold"),
            (.key, 13, "semibold"), (.draft, 16, "regular"), (.draftMarked, 16, "semibold"),
        ]
        XCTAssertEqual(Set(table.map { $0.0 }), Set(BarTheme.Role.allCases), "every role is in the table")
        for (role, size, name) in table {
            let font = role.font(night: false)
            XCTAssertEqual(font.pointSize, size, role.rawValue)
            XCTAssertEqual(weight(font), name, role.rawValue)
        }
    }

    /// The theme builds no font outside the roles. The dot is drawn, 7 across,
    /// never a glyph (design/13-row.md), so there is no exception.
    func testTheThemeDefinesNoFontOutsideTheRoles() throws {
        let regex = try NSRegularExpression(pattern: #"static\s+(?:let|var|func)\s+(\w+)[^\n]*NSFont"#)
        var names: [String] = []
        for file in ["Ceramic.swift", "ModePill.swift"] {
            let text = DesignDriftTests.code(try String(
                contentsOf: DesignDriftTests.appSources.appendingPathComponent(file), encoding: .utf8))
            for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                names.append((text as NSString).substring(with: match.range(at: 1)))
            }
        }
        XCTAssertEqual(names, [])
    }

    // MARK: - Night

    /// At night every role is one weight heavier, at the same size.
    func testNightIsOneStepHeavierAtTheSameSize() {
        for role in BarTheme.Role.allCases {
            let day = role.font(night: false), night = role.font(night: true)
            XCTAssertEqual(night.pointSize, day.pointSize, "size never changes with the look: \(role.rawValue)")
            XCTAssertEqual(weight(night), Self.heavier[weight(day)], "\(role.rawValue): \(weight(day)) to \(weight(night))")
            XCTAssertEqual(role.font(in: NSAppearance(named: .aqua)!), day)
            XCTAssertEqual(role.font(in: NSAppearance(named: .darkAqua)!), night)
        }
    }

    /// Every kind of thing that draws text, built in a window of the day
    /// look: a label, a wrapping label, a field with its placeholder, a
    /// text view, a button, a popup, and runs of an attributed label.
    private func specimens(_ role: BarTheme.Role) -> [(name: String, view: NSView, font: () -> NSFont?)] {
        let label = NSTextField(labelWithString: "Label")
        label.setRole(role)
        let wrapping = NSTextField(wrappingLabelWithString: "A wrapping label of several words")
        wrapping.setRole(role)
        let field = NSTextField()
        field.setRole(role)
        field.setPlaceholder("Placeholder")
        let textView = NSTextView()
        textView.setRole(role)
        let button = NSButton(title: "Button", target: nil, action: nil)
        button.setRole(role)
        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["One", "Two"])
        popup.setRole(role)
        let attributed = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "Attributed", attributes: BarTheme.attributes(role)))
        attributed.followLook()
        return [
            ("label", label, { label.font }), ("wrapping label", wrapping, { wrapping.font }),
            ("field", field, { field.font }),
            ("placeholder", field, { field.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }),
            ("text view", textView, { textView.font }), ("button", button, { button.font }),
            ("popup", popup, { popup.font }),
            ("attributed", attributed, { attributed.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }),
        ]
    }

    private func settle() { GalleryHost.settle(0.05) }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    /// A surface on screen when the Mac turns dark: its window takes the
    /// look, and every word on it takes night's weight, with nothing built
    /// again. Then back.
    func testAWindowOnScreenTakesTheLooksWeightWhenItChanges() {
        for role in BarTheme.Role.allCases {
            let items = specimens(role)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            for item in items where item.view.superview == nil { content.addSubview(item.view) }
            let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            window.appearance = NSAppearance(named: .aqua)
            settle()
            for item in items {
                XCTAssertEqual(item.font(), role.font(night: false), "\(role.rawValue) \(item.name) by day")
            }
            window.appearance = NSAppearance(named: .darkAqua)
            settle()
            for item in items {
                let font = item.font()
                XCTAssertEqual(font, role.font(night: true), "\(role.rawValue) \(item.name) after the look changed")
                XCTAssertEqual(font.map(weight), Self.heavier[weight(role.font(night: false))],
                               "\(role.rawValue) \(item.name) is one step heavier")
            }
            window.appearance = NSAppearance(named: .aqua)
            settle()
            for item in items {
                XCTAssertEqual(item.font(), role.font(night: false), "\(role.rawValue) \(item.name) back by day")
            }
            window.close()
        }
    }

    /// The Mac's own flip is the application's appearance, which a window
    /// with none of its own follows.
    func testAWindowThatFollowsTheMacTakesTheLooksWeightWhenTheMacTurns() {
        GalleryLook.day.apply()
        let role = BarTheme.Role.body
        let items = specimens(role)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        for item in items where item.view.superview == nil { content.addSubview(item.view) }
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        settle()
        for item in items { XCTAssertEqual(item.font(), role.font(night: false), "\(item.name) by day") }
        GalleryLook.night.apply()
        settle()
        for item in items { XCTAssertEqual(item.font(), role.font(night: true), "\(item.name) when the Mac turned") }
        window.close()
    }

    /// Real surfaces, built in the day and left on screen while the look
    /// turns: the draft's runs, the key marks, the pill, the room's button.
    func testRealSurfacesTakeNightsWeightWithoutBeingBuiltAgain() throws {
        GalleryLook.day.apply()
        let panel = DraftPanel()
        defer { panel.hide() }
        var view = DraftView(buffer: Draft.Buffer(text: "hello world", cursor: 1), mode: .normal,
                             editor: .normal, speech: nil, destination: ("Notes", nil), replacing: false)
        view.findTargets = [2]
        panel.show(view)
        func fonts() -> (plain: NSFont?, marked: NSFont?) {
            let storage = panel.textView.textStorage
            return (storage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                    storage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        }
        XCTAssertEqual(fonts().plain, BarTheme.Role.draft.font(night: false))
        XCTAssertEqual(fonts().marked, BarTheme.Role.draftMarked.font(night: false))

        let mark = KeyMark.peek("37")
        let button = RoomButton(title: "Send", target: nil, action: nil)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        host.addSubview(mark)
        host.addSubview(button)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle()
        func markFont() -> NSFont? {
            (allViews(mark).compactMap { $0 as? Key }.first)?.legendFont
        }
        XCTAssertEqual(markFont(), BarTheme.Role.largeFigure.font(night: false))
        XCTAssertEqual(button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                       BarTheme.Role.control.font(night: false))

        GalleryLook.night.apply()
        settle()
        XCTAssertEqual(fonts().plain, BarTheme.Role.draft.font(night: true), "the draft's text")
        XCTAssertEqual(fonts().marked, BarTheme.Role.draftMarked.font(night: true), "its lit letters")
        XCTAssertEqual(markFont(), BarTheme.Role.largeFigure.font(night: true), "a key mark")
        XCTAssertEqual(button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                       BarTheme.Role.control.font(night: true), "a room's button")
        window.close()
    }

    // MARK: - Settings and the fields

    /// A list of labels is medium: on a Settings page nothing is heavier
    /// than the room's title, a row's title is the label role, a group's
    /// header the heading, and a value (a popup's, a status word) is control.
    func testASettingsPageIsLabelsInMediumUnderOneRoomTitle() throws {
        GalleryLook.day.apply()
        var seen: Set<BarTheme.Role> = []
        for shot in GalleryShots.all where shot.surface == "settings" && shot.looks.contains(.day) {
            let (view, keep) = try shot.built(in: .day)
            GalleryHost.settle(0.02)
            for word in words(in: view) {
                for style in word.styles.compactMap({ $0 }) {
                    seen.insert(style.role)
                    XCTAssertLessThanOrEqual(style.role.weight.rawValue, BarTheme.Role.roomTitle.weight.rawValue,
                                             "\(shot.name(in: .day)): \"\(word.text.prefix(24))\" is \(style.role)")
                    XCTAssertNotEqual(style.role, .emphasis, "\(shot.name(in: .day)): a row is a label, not an emphasis")
                }
            }
            _ = keep
        }
        for role in [BarTheme.Role.label, .heading, .control, .roomTitle] {
            XCTAssertTrue(seen.contains(role), "Settings draws \(role.rawValue)")
        }
        XCTAssertEqual(BarTheme.Role.label.weight, .medium)
        XCTAssertEqual(BarTheme.Role.label.size, 16)
        XCTAssertEqual(BarTheme.Role.control.size, 16)
        XCTAssertEqual(BarTheme.Role.heading.size, 13)
    }

    /// A bar's field is the field role at 23; a field inside a room (Settings'
    /// search and the values you type, Feedback's note and email) is body.
    func testABarsFieldIs23AndARoomsFieldIsBody() throws {
        GalleryLook.day.apply()
        var bars = 0, rooms = 0
        for shot in GalleryShots.all where shot.looks.contains(.day)
            && ["launcher", "ask", "commands", "settings", "feedback"].contains(shot.surface) {
            let (view, keep) = try shot.built(in: .day)
            GalleryHost.settle(0.02)
            for field in allViews(view).compactMap({ $0 as? NSTextField }) where field.isEditable {
                guard let role = field.typeStyle?.role else { continue }
                if shot.surface == "settings" || shot.surface == "feedback" {
                    rooms += 1
                    XCTAssertEqual(role, .body, "\(shot.name(in: .day)): a field in a room")
                } else {
                    bars += 1
                    XCTAssertEqual(role, .field, "\(shot.name(in: .day)): a bar's field")
                }
            }
            _ = keep
        }
        XCTAssertGreaterThan(bars, 0)
        XCTAssertGreaterThan(rooms, 0)
    }

    /// Hierarchy is never letter-spacing: no text on any surface is tracked.
    func testNoTextOnAnySurfaceIsTracked() throws {
        GalleryLook.day.apply()
        for shot in GalleryShots.all where shot.looks.contains(.day) {
            let (view, keep) = try shot.built(in: .day)
            GalleryHost.settle(0.02)
            for field in allViews(view).compactMap({ $0 as? NSTextField }) where field.attributedStringValue.length > 0 {
                var tracked = false
                let text = field.attributedStringValue
                text.enumerateAttribute(.kern, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    if let value = value as? CGFloat, value != 0 { tracked = true }
                }
                XCTAssertFalse(tracked, "\(shot.name(in: .day)): \"\(text.string.prefix(20))\" is tracked")
            }
            _ = keep
        }
    }

    // MARK: - Figures

    /// Every digit as wide as every other, in the roles that are numbers.
    func testAFigureRoleHoldsItsDigitsToOneWidth() {
        for role in [BarTheme.Role.figure, .largeFigure] {
            for night in [false, true] {
                XCTAssertTrue(GalleryFoundations.isTabular(role.font(night: night)), role.rawValue)
            }
        }
        XCTAssertFalse(GalleryFoundations.isTabular(BarTheme.Role.meta.font(night: false)),
                       "the sans's own digits are proportional, so the test can tell")
        XCTAssertTrue(GalleryFoundations.isTabular(BarTheme.Role.meta.font(night: false, tabular: true)))
        XCTAssertTrue(GalleryFoundations.isTabular(BarTheme.Role.meta.font(night: true, tabular: true)))
        XCTAssertEqual(BarTheme.Role.meta.font(night: false, tabular: true).pointSize, 13, "tabular is not a size")
    }

    // MARK: - Every word of every surface

    /// The text a view draws, with the fonts it draws it in.
    private struct Word {
        let kind: String
        let text: String
        let fonts: [NSFont?]
        let styles: [BarTheme.Style?]
        let editable: Bool
        /// The look the word is drawn in: a word on a slab is in the other one.
        let appearance: NSAppearance
    }

    private func styles(in text: NSAttributedString) -> (fonts: [NSFont?], styles: [BarTheme.Style?]) {
        var fonts: [NSFont?] = [], styles: [BarTheme.Style?] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            // An attachment (a secret's bar) is drawn, not read.
            fonts.append(attributes[.font] as? NSFont)
            styles.append(attributes[.lodestarStyle] as? BarTheme.Style)
        }
        return (fonts, styles)
    }

    private func words(in view: NSView) -> [Word] {
        var out: [Word] = []
        func visit(_ view: NSView) {
            if let field = view as? NSTextField {
                if !field.stringValue.isEmpty {
                    if let style = field.typeStyle {
                        out.append(Word(kind: "field", text: field.stringValue, fonts: [field.font], styles: [style],
                                        editable: field.isEditable, appearance: field.effectiveAppearance))
                    } else {
                        let found = styles(in: field.attributedStringValue)
                        out.append(Word(kind: "field", text: field.stringValue, fonts: found.fonts, styles: found.styles,
                                        editable: field.isEditable, appearance: field.effectiveAppearance))
                    }
                } else if let placeholder = field.placeholderAttributedString, placeholder.length > 0 {
                    let found = styles(in: placeholder)
                    out.append(Word(kind: "placeholder", text: placeholder.string, fonts: found.fonts,
                                    styles: found.styles, editable: true, appearance: field.effectiveAppearance))
                }
            } else if let button = view as? NSButton, !button.title.isEmpty || button.attributedTitle.length > 0 {
                if let style = button.typeStyle {
                    out.append(Word(kind: "button", text: button.title, fonts: [button.font], styles: [style], editable: false, appearance: button.effectiveAppearance))
                } else {
                    let found = styles(in: button.attributedTitle)
                    out.append(Word(kind: "button", text: button.attributedTitle.string, fonts: found.fonts,
                                    styles: found.styles, editable: false, appearance: view.effectiveAppearance))
                }
                // The button draws its own title: whatever it is made of inside
                // is the button's, not a word of its own.
                return
            } else if let textView = view as? NSTextView, !textView.isFieldEditor, let storage = textView.textStorage,
                      storage.length > 0 {
                let found = styles(in: storage)
                out.append(Word(kind: "text view", text: storage.string, fonts: found.fonts, styles: found.styles, editable: false, appearance: view.effectiveAppearance))
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return out
    }

    /// A surface as the gallery builds it, in each look, with every word
    /// it holds.
    private func surfaces(_ body: (GalleryShot, GalleryLook, [Word], NSAppearance) -> Void) throws {
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) {
                let (view, keep) = try shot.built(in: look)
                GalleryHost.settle(0.02)
                body(shot, look, words(in: view), view.effectiveAppearance)
                _ = keep
            }
        }
    }

    /// No word of any surface is left in a default font: each says its role,
    /// and the font it is drawn in is the role's in the look it is drawn in,
    /// one step heavier at night, at the same size.
    func testEveryWordOnEverySurfaceIsARoleInTheLookItIsDrawnIn() throws {
        var unnamed: [String] = [], wrong: [String] = []
        try surfaces { shot, look, words, appearance in
            for word in words {
                let name = "\(shot.name(in: look)): \(word.kind) \"\(word.text.prefix(30))\""
                if word.styles.isEmpty || word.styles.contains(where: { $0 == nil }) {
                    unnamed.append(name)
                    continue
                }
                for (font, style) in zip(word.fonts, word.styles) {
                    guard let style else { continue }
                    // A word on a slab is drawn in the other look, and is held to it.
                    if font != style.font(in: word.appearance) {
                        wrong.append("\(name) is \(font?.fontName ?? "no font"), not \(style.role.rawValue) in \(BarTheme.isNight(word.appearance) ? "night" : "day")")
                    }
                }
            }
        }
        XCTAssertEqual(unnamed, [], "every word names a role")
        XCTAssertEqual(wrong, [], "and is drawn in it, in the look it is in")
    }

    /// A number that changes in place is set in tabular figures: the
    /// countdown, the peek, the counts. Read off every surface: a label that
    /// is nothing but a number is one of them, unless it is a key's letter
    /// (the 1 to 4 on a card), which is a key and never changes in place.
    func testANumberThatChangesInPlaceIsInTabularFigures() throws {
        var loose: [String] = [], seen = 0
        try surfaces { shot, look, words, _ in
            for word in words where !word.editable {
                let text = word.text.trimmingCharacters(in: .whitespaces)
                guard text.contains(where: \.isNumber), text.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "," }),
                      !word.styles.contains(where: { $0?.role == .key }) else { continue }
                seen += 1
                for font in word.fonts {
                    if let font, !GalleryFoundations.isTabular(font) {
                        loose.append("\(shot.name(in: look)): \"\(text)\" in \(font.fontName)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(seen, 0, "the surfaces draw numbers")
        XCTAssertEqual(loose, [], "tabular figures: setRole(_, tabular: true), or a figure role")
    }

    /// The three the contract names, each built and read: the peek, the
    /// meeting's countdown, and the counts on Keep's bar and source list.
    func testTheCountdownThePeekAndTheCountsAreTabular() throws {
        GalleryLook.day.apply()
        let peek = KeyMark.peek("37")
        let peekFont = allViews(peek).compactMap { $0 as? Key }.first?.legendFont
        XCTAssertTrue(peekFont.map(GalleryFoundations.isTabular) ?? false, "the peek")
        XCTAssertEqual(peekFont?.pointSize, BarTheme.Scale.input)

        var numbers: [String: [NSFont]] = [:]
        for shot in GalleryShots.all where ["meeting", "keep"].contains(shot.surface) && shot.looks.contains(.day) {
            let (view, keep) = try shot.build(.day)
            for word in words(in: view) where !word.text.isEmpty && word.text.allSatisfy(\.isNumber)
                && !word.styles.contains(where: { $0?.role == .key }) {
                numbers[shot.surface, default: []] += word.fonts.compactMap { $0 }
            }
            _ = keep
        }
        XCTAssertFalse(numbers["meeting", default: []].isEmpty, "the countdown is drawn")
        XCTAssertFalse(numbers["keep", default: []].isEmpty, "a count is drawn")
        for font in numbers.values.flatMap({ $0 }) { XCTAssertTrue(GalleryFoundations.isTabular(font), font.fontName) }
    }
}
