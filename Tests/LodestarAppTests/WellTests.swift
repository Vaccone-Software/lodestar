import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/12-well.md. Wherever Lodestar takes words it is a well, one radius,
/// holding one caret (the readable accent, 1.5 wide, never blinking) and one
/// selection (ink at 30%), its placeholder quiet at the words' size, its edge
/// twice as firm while the caret is in it. Every test here is offscreen: the
/// real views, drawn into bitmaps and read back; a panel that has the keys for
/// a picture stands where no display is.
final class WellTests: XCTestCase {
    override func tearDown() {
        GalleryLook.reset()
        ActivePolicy.frameOverride = nil
        EyeComfortState.shared.set(enabled: false, level: 1)
    }

    typealias RGB = Readability.RGB

    private func rgb(_ color: NSColor, in look: GalleryLook) -> RGB {
        var out = RGB(red: 0, green: 0, blue: 0)
        NSAppearance(named: look.appearance)?.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? .clear
            out = RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }
        return out
    }

    private func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var out: [T] = []
        walk(root) { if let hit = $0 as? T { out.append(hit) } }
        return out
    }

    /// The text that holds the words of an editable field or text view.
    private func editor(of view: NSView) -> WellText? {
        (view as? NSTextField).flatMap { $0.currentEditor() as? WellText } ?? view as? WellText
    }

    // MARK: - The placeholder

    /// The placeholder is quiet ink in the words' role and size, so typing
    /// replaces it in place, and it holds 4.5 : 1 on the well at every Eye
    /// comfort level, in both looks.
    func testThePlaceholderHoldsFourAndAHalfOnTheWellAtEveryLevel() {
        for look in GalleryLook.all {
            look.apply()
            for (hour, level) in [("full", 1.0), ("evening", GalleryShots.evening), ("bedtime", GalleryShots.bedtime)] {
                EyeComfortState.shared.set(enabled: level < 1, level: level)
                let steps = EyeComfortState.shared.steps(dark: look == .night)
                XCTAssertGreaterThanOrEqual(Readability.contrast(steps.quietInk.luminance, steps.well.luminance), 4.5,
                                            "\(look.name), \(hour): the palette's quiet ink on its well")
                // What is drawn: the placeholder a field wears, resolved where it is drawn.
                let field = InputField()
                field.setRole(.field)
                field.setPlaceholder("Where to?")
                let drawn = rgb(field.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                                    as? NSColor ?? .clear, in: look)
                let well = rgb(BarTheme.wellFill, in: look)
                XCTAssertGreaterThanOrEqual(Readability.contrast(drawn.luminance, well.luminance), 4.5,
                                            "\(look.name), \(hour): the placeholder as drawn on the well as drawn")
            }
        }
    }

    func testThePlaceholderIsTheWordsRoleAndSize() {
        for role in [BarTheme.Role.field, .body] {
            let field = WellField(frame: .zero)
            field.setRole(role)
            field.setPlaceholder("Search")
            let placeholder = field.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            XCTAssertEqual(placeholder?.pointSize, role.size, "the words' size")
            XCTAssertEqual(placeholder, field.font, "the words' face: typing replaces it in place")
        }
    }

    // MARK: - The caret

    /// Where the accent would fall under 3 : 1 on the well, the caret is ink.
    func testTheCaretIsInkWhereTheAccentWouldFallUnderThreeToOneOnTheWell() {
        for look in GalleryLook.all {
            look.apply()
            let steps = look == .night ? Palette.night : Palette.clay
            let accent = rgb(BarTheme.internationalOrange, in: look)
            XCTAssertGreaterThanOrEqual(Readability.contrast(accent.luminance, steps.well.luminance), Readability.markFloor,
                                        "\(look.name): the orange clears 3 : 1 on the well")
            let drawn = rgb(BarTheme.caretFill, in: look)
            XCTAssertEqual(drawn.red, accent.red, accuracy: 0.01, "\(look.name): the caret is the accent")
            XCTAssertEqual(drawn.green, accent.green, accuracy: 0.01)
            XCTAssertEqual(drawn.blue, accent.blue, accuracy: 0.01)
            // An accent that sat on the well falls back to the ink.
            BarTheme.accentColor = { BarTheme.wellFill }
            let fallback = rgb(BarTheme.caretFill, in: look)
            BarTheme.accentColor = { BarTheme.internationalOrange }
            XCTAssertEqual(fallback.red, steps.ink.red, accuracy: 0.01, "\(look.name): ink where the accent is lost")
            XCTAssertEqual(fallback.green, steps.ink.green, accuracy: 0.01)
        }
    }

    /// The selection is one wash: ink at 30%.
    func testTheSelectionIsInkAtThirtyPercent() {
        XCTAssertEqual(BarTheme.washShare, 0.3)
        for look in GalleryLook.all {
            look.apply()
            var fill = NSColor.clear
            NSAppearance(named: look.appearance)?.performAsCurrentDrawingAppearance {
                fill = BarTheme.wash.usingColorSpace(.sRGB) ?? .clear
            }
            XCTAssertEqual(fill.alphaComponent, 0.3, accuracy: 0.002)
            let text = WellText(frame: .zero)
            text.isFieldEditor = true
            let window = GalleryHost.window(NSView(), size: NSSize(width: 100, height: 40), look: look)
            window.contentView?.addSubview(text)
            let attributes = text.selectedTextAttributes
            XCTAssertEqual((attributes[.backgroundColor] as? NSColor)?.alphaComponent ?? 0, 0.3, accuracy: 0.002,
                           "\(look.name): a field editor's selection is the one wash")
        }
    }

    /// One caret in every real field a cell of the sheet holds: the readable
    /// accent, 1.5 wide, as tall as the line, standing at the insertion point,
    /// and the system's own set clear.
    func testTheCaretOfARealFieldIsTheReadableAccentOnePointFiveWide() throws {
        for look in GalleryLook.all {
            look.apply()
            for cell in GalleryWell.cells(look: look) {
                guard let focus = cell.focus else { continue }
                let text = try XCTUnwrap(editor(of: focus), "\(cell.caption): the words are edited in the one editor")
                XCTAssertTrue(text.holdsCaret, cell.caption)
                XCTAssertEqual(text.insertionPointColor, .clear, "the system's caret is set clear: \(cell.caption)")
                let mark = text.caret
                // A selection has no caret, in any field: the wash says it.
                let selected = text.selectedRange().length > 0
                if selected {
                    XCTAssertTrue(mark.isHidden, "\(cell.caption): a selection has no caret")
                    continue
                }
                XCTAssertEqual(mark.frame.width, BarTheme.caretWidth, "\(look.name): \(cell.caption)")
                XCTAssertEqual(mark.frame.height, BarTheme.caretHeight(forPointSize: text.font?.pointSize ?? 0),
                               "as tall as the words' line: \(cell.caption)")
                XCTAssertFalse(mark.isHidden, cell.caption)

                // Drawn: the caret's columns are the accent, 1.5 points of them.
                let rep = GalleryRender.bitmap(of: cell.root)
                let scale = CGFloat(rep.pixelsWide) / rep.size.width
                let box = text.convert(mark.frame, to: cell.root)
                let row = Int((cell.root.bounds.height - box.midY) * scale)
                let accent = rgb(BarTheme.caretFill, in: look)
                var accentColumns = 0, otherSaturated = 0
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                    let color = RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
                    let isAccent = abs(color.red - accent.red) < 0.05 && abs(color.green - accent.green) < 0.05
                        && abs(color.blue - accent.blue) < 0.05
                    if isAccent { accentColumns += 1 }
                    // A saturated pixel that is not ours is a system caret.
                    else if max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue) > 0.3 {
                        otherSaturated += 1
                    }
                }
                XCTAssertEqual(CGFloat(accentColumns) / scale, BarTheme.caretWidth, accuracy: 0.01,
                               "\(look.name): \(cell.caption): the caret is 1.5 points of the accent")
                XCTAssertEqual(otherSaturated, 0, "\(look.name): \(cell.caption): no caret but ours")
            }
        }
    }

    /// The caret never blinks: held for longer than a blink's period it is
    /// there, whole, every time it is looked at, and nothing animates it.
    func testTheCaretNeverBlinks() throws {
        GalleryLook.day.apply()
        let cells = GalleryWell.cells(look: .day).filter { $0.focus != nil }.prefix(3)
        XCTAssertEqual(cells.count, 3)
        for cell in cells {
            let text = try XCTUnwrap(editor(of: try XCTUnwrap(cell.focus)))
            let mark = text.caret
            XCTAssertNil(mark.layer?.animationKeys(), "nothing animates the caret")
            var seen: [Bool] = []
            for _ in 0..<4 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.45))
                seen.append(!mark.isHidden && mark.alphaValue == 1 && text.holdsCaret)
            }
            XCTAssertEqual(seen, [true, true, true, true], "\(cell.caption): still across two periods of a blink")
            XCTAssertNil(mark.layer?.animationKeys())
        }
    }

    /// The caret comes in and leaves with the field's focus, and the well's
    /// edge follows at once.
    func testTheFocusedWellsEdgeFollowsTheCaret() throws {
        GalleryLook.day.apply()
        let steps = Palette.clay
        let cell = GalleryWell.cells(look: .day).first { $0.caption.hasPrefix("a field, typed") }
        let panel = try XCTUnwrap(cell?.panel)
        let field = try XCTUnwrap(find(WellField.self, in: panel.contentView!).first)
        func edgeAlpha() throws -> CGFloat {
            let rep = GalleryRender.bitmap(of: panel.contentView!)
            let scale = CGFloat(rep.pixelsWide) / rep.size.width
            // The edge is half a point, one row of pixels at twice the size: the
            // top row of the field, the ink laid over the well at the edge's share.
            let x = Int(field.frame.midX * scale)
            let top = rep.colorAt(x: x, y: 0)?.usingColorSpace(.sRGB) ?? .clear
            let well = steps.well.color.usingColorSpace(.sRGB) ?? .clear
            let ink = steps.ink.color.usingColorSpace(.sRGB) ?? .clear
            return (well.redComponent - top.redComponent) / (well.redComponent - ink.redComponent)
        }
        XCTAssertTrue(WellText.holds(field))
        XCTAssertEqual(try edgeAlpha(), steps.wellFocusedEdgeAlpha, accuracy: 0.03,
                       "the half point of edge is one row of pixels at twice the resting share")
        panel.makeFirstResponder(nil)
        XCTAssertFalse(WellText.holds(field))
        XCTAssertEqual(try edgeAlpha(), steps.wellEdgeAlpha, accuracy: 0.03, "back to the resting weight")
    }

    // MARK: - Every field of every surface

    /// The pictures the contract lists exist, in both looks: the sheet, Settings'
    /// search, Feedback with the caret in a field, Keep's search, Bring's, the
    /// list of sources, the save band, and a card being named.
    func testTheGalleryHasEveryStateTheContractNames() {
        let wanted: [(String, String)] = [
            ("foundation", "well"), ("settings", "search-clipboard"), ("settings", "search-empty"),
            ("feedback", "writing"), ("feedback", "writing-reply-typed"), ("keep", "third-chosen-search"),
            ("keep", "search-empty"), ("keep", "bring-search"), ("keep", "source-menu"), ("keep", "save-band"),
            ("keep", "save-band-typed"), ("keep", "naming-keepsake"), ("keep", "naming-keepsake-typed"),
            ("keep", "naming-unkept-clip"), ("launcher", "typed-ma"), ("ask", "typed-address"), ("commands", "typed-pa"),
        ]
        for (surface, state) in wanted {
            let shot = GalleryShots.all.first { $0.surface == surface && $0.state == state }
            XCTAssertEqual(shot?.looks, GalleryLook.all, "\(surface)-\(state) is drawn in day and night")
        }
        for hour in ["evening", "bedtime"] {
            XCTAssertNotNil(GalleryShots.all.first { $0.surface == "foundation" && $0.state == "well-\(hour)" },
                            "the well sheet is drawn at \(hour)")
        }
    }

    /// Whether a field sits in a well: it is one, it is inside one, or it
    /// stands on one a bar lays under it (the field is laid over the well,
    /// within its frame).
    private func isInWell(_ field: NSView, root: NSView) -> Bool {
        if field is WellField { return true }
        let mine = field.convert(field.bounds, to: root)
        var up = field.superview
        while let view = up {
            if view is WellView { return true }
            for sibling in view.subviews.compactMap({ $0 as? WellView }) where sibling.holdsField {
                if sibling.convert(sibling.bounds, to: root).insetBy(dx: -0.5, dy: -0.5).contains(mine) { return true }
            }
            up = view.superview
        }
        return false
    }

    /// Every editable text view on every gallery surface sits in a well (the
    /// draft, a page you write on, is not a field, and is not editable text
    /// either), draws no bezel, border or focus ring of the system's, is
    /// edited in the one editor, and its caret is the one caret.
    func testEveryEditableTextViewOnEverySurfaceIsAWellWithTheOneCaret() throws {
        var found: [String] = [], wrong: [String] = []
        var surfaces = Set<String>()
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) && shot.level == 1 && !shot.receded {
                guard let (root, keep) = try? shot.build(look) else { continue }
                let name = shot.name(in: look)
                root.window?.contentView?.layoutSubtreeIfNeeded()
                var fields: [NSView] = []
                walk(root) { view in
                    if let field = view as? NSTextField, field.isEditable { fields.append(field) }
                    if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { fields.append(text) }
                }
                for field in fields {
                    found.append(name)
                    surfaces.insert(shot.surface)
                    if !isInWell(field, root: root) { wrong.append("\(name): \(type(of: field)) is not in a well") }
                    if let text = field as? NSTextField {
                        if text.isBezeled || text.isBordered { wrong.append("\(name): \(type(of: field)) draws a bezel") }
                        if text.focusRingType != .none { wrong.append("\(name): \(type(of: field)) draws a focus ring") }
                        if !(text.cell is InputCell) { wrong.append("\(name): \(type(of: field)) is not edited in the one editor") }
                    } else if (field as? NSTextView)?.focusRingType != NSFocusRingType.none {
                        wrong.append("\(name): \(type(of: field)) draws a focus ring")
                    }
                    guard let window = field.window, window.makeFirstResponder(field) else {
                        wrong.append("\(name): \(type(of: field)) cannot take the caret")
                        continue
                    }
                    guard let text = editor(of: field) else {
                        wrong.append("\(name): \(type(of: field)) has no WellText to hold the caret")
                        continue
                    }
                    let mark = text.caret
                    if text.insertionPointColor != .clear { wrong.append("\(name): the system's caret is not clear") }
                    if mark.frame.width != BarTheme.caretWidth { wrong.append("\(name): the caret is \(mark.frame.width) wide") }
                    if !text.holdsCaret { wrong.append("\(name): the text does not hold the caret") }
                    if mark.layer?.animationKeys() != nil { wrong.append("\(name): the caret is animated") }
                }
                _ = keep
            }
        }
        XCTAssertEqual(wrong, [], "every field is a well with the one caret")
        for surface in ["launcher", "ask", "commands", "settings", "feedback"] {
            XCTAssertTrue(surfaces.contains(surface), "a field was found on \(surface): \(surfaces.sorted())")
        }
        XCTAssertGreaterThan(found.count, 40)
    }

    /// Every input well rounds at 8.4 (the control's rung) and every field
    /// band at 12.4 (8.4 and the field's 4-point inset in it): Keep's search
    /// and save bands and Bring's, the list of sources' field, Settings' fields
    /// and search, the bars' wells, Feedback's note and reply.
    func testEveryInputWellRoundsAtEightPointFourAndEveryFieldBandAtTwelvePointFour() throws {
        XCTAssertEqual(BarTheme.controlRadius, 8.4, accuracy: 0.01)
        XCTAssertEqual(BarTheme.bandRadius, BarTheme.controlRadius + 4, accuracy: 0.0001)
        XCTAssertEqual(BarTheme.bandRadius, 12.4, accuracy: 0.01)
        XCTAssertEqual(BarTheme.bandHeight, BarTheme.fieldHeight + BarTheme.bandInset * 2)
        var wells = 0, bands = 0
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) && shot.level == 1 && !shot.receded {
                guard let (root, keep) = try? shot.build(look) else { continue }
                let name = shot.name(in: look)
                root.window?.contentView?.layoutSubtreeIfNeeded()
                walk(root) { view in
                    if let well = view as? WellView, well.holdsField {
                        wells += 1
                        XCTAssertEqual(well.cornerRadius, BarTheme.controlRadius, accuracy: 0.0001,
                                       "\(name): an input well rounds at 8.4, not \(well.cornerRadius)")
                    }
                    if view is WellField {
                        wells += 1
                        XCTAssertEqual(view.frame.height, BarTheme.fieldHeight, "\(name): a field is 32 tall")
                    }
                }
                for strip in keep.compactMap({ $0 as? ClipboardStrip }) {
                    for (plate, field) in [strip.shownBand].compactMap({ $0 }) {
                        bands += 1
                        let surface = try XCTUnwrap(plate as? ObjectSurface, "\(name): a band is a surface")
                        XCTAssertEqual(surface.radius, BarTheme.bandRadius, accuracy: 0.0001,
                                       "\(name): a field band rounds at 12.4, not a capsule")
                        XCTAssertEqual(field.frame.height, BarTheme.fieldHeight, "\(name): the band's field is 32 tall")
                        XCTAssertEqual(field.frame.minX, BarTheme.bandInset, "\(name): 4 inside the band")
                        XCTAssertEqual(plate.bounds.width - field.frame.maxX, BarTheme.bandInset)
                        XCTAssertEqual(field.frame.minY, BarTheme.bandInset)
                        XCTAssertEqual(field.cornerRadius, BarTheme.controlRadius, accuracy: 0.0001)
                        XCTAssertEqual(plate.frame.height, BarTheme.bandHeight, "\(name): the band is its field and its inset")
                    }
                    if let list = strip.shownSourceField {
                        XCTAssertEqual(list.frame.height, BarTheme.fieldHeight, "\(name): the sources' filter is a field, 32 tall")
                        XCTAssertEqual(list.cornerRadius, BarTheme.controlRadius, accuracy: 0.0001)
                    }
                }
            }
        }
        XCTAssertGreaterThan(wells, 20, "input wells were found")
        XCTAssertGreaterThan(bands, 6, "Keep's and Bring's bands were found")
    }

    /// The words of every field stand 12 inside the well; a key or a symbol at
    /// its leading edge stands 12 in, and the words start 12 after it.
    func testWordsStandTwelveInsideEveryWell() throws {
        GalleryLook.day.apply()
        for cell in GalleryWell.cells(look: .day) {
            if let field = find(WellField.self, in: cell.root).first {
                let cellFrame = field.cell?.drawingRect(forBounds: field.bounds) ?? .zero
                XCTAssertEqual(cellFrame.minX, BarTheme.wordPadding, "\(cell.caption): a field's words are 12 in")
            }
            if let well = find(NoteWell.self, in: cell.root).first {
                let text = well.text
                XCTAssertEqual(Grid.hair + text.textContainerInset.width + (text.textContainer?.lineFragmentPadding ?? 5),
                               BarTheme.wordPadding, "a note's words are 12 in")
            }
        }
        // Settings' search: the key 12 in, the words 12 after it.
        let (root, keep) = try GallerySettings.window(look: .day) {
            $0.renderForTesting(place: nil)
            $0.searchForTesting("")
        }
        root.layoutSubtreeIfNeeded()
        let well = try XCTUnwrap(find(WellView.self, in: root).first { !find(InputField.self, in: $0).isEmpty })
        XCTAssertEqual(well.frame.height, BarTheme.fieldHeight, "the search is a field, 32 tall")
        let key = try XCTUnwrap(find(Key.self, in: well).first)
        let field = try XCTUnwrap(find(InputField.self, in: well).first)
        XCTAssertEqual(key.frame.minX, BarTheme.wordPadding, "the key is 12 in")
        // A field's words begin at its alignment rect, which the constraints lay out.
        XCTAssertEqual(field.alignmentRect(forFrame: field.frame).minX, key.frame.maxX + BarTheme.wordPadding,
                       "the words start 12 after it")
        _ = keep
        // Feedback: the note and the reply.
        let (feedback, held) = try GalleryChrome.feedback(45)
        feedback.layoutSubtreeIfNeeded()
        let note = try XCTUnwrap(find(NoteWell.self, in: feedback).first)
        XCTAssertEqual(Grid.hair + note.text.textContainerInset.width + (note.text.textContainer?.lineFragmentPadding ?? 5),
                       BarTheme.wordPadding, "the note's words are 12 in, not 10")
        XCTAssertEqual(note.frame.height, 150, "a note is 150 tall in Feedback")
        let reply = try XCTUnwrap(find(RoomField.self, in: feedback).first)
        XCTAssertEqual(reply.field.alignmentRect(forFrame: reply.field.frame).minX, BarTheme.wordPadding,
                       "the reply's words are 12 in")
        XCTAssertEqual(reply.cornerRadius, BarTheme.controlRadius)
        _ = held
    }

    /// Where the first line of a note sits, from the well's top edge to its
    /// baseline, in points.
    private func firstBaseline(of well: NoteWell) throws -> CGFloat {
        well.layoutSubtreeIfNeeded()
        let text = well.text
        let layout = try XCTUnwrap(text.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var baseline: CGFloat?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard let line = fragment.textLineFragments.first else { return true }
            baseline = text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.glyphOrigin.y
            return false
        }
        let inWell = text.convert(NSPoint(x: 0, y: try XCTUnwrap(baseline)), to: well)
        return well.bounds.height - inWell.y
    }

    /// A note's first line stands 12 from the well's top edge, its ascent
    /// below it: on the sheet, where the note is pinned by both sides, and in
    /// Feedback, where it has a width of its own.
    func testANotesFirstLineStandsTwelveFromTheTopHoweverItIsConstrained() throws {
        for look in GalleryLook.all {
            look.apply()
            let cell = try XCTUnwrap(GalleryWell.cells(look: look).first { $0.caption.hasPrefix("a note") })
            let sheet = try XCTUnwrap(find(NoteWell.self, in: cell.root).first)
            let ascent = try XCTUnwrap(sheet.text.font).ascender
            XCTAssertEqual(try firstBaseline(of: sheet), BarTheme.wordPadding + ascent, accuracy: 1.5,
                           "\(look.name): on the sheet")
            let (feedback, keep) = try GalleryChrome.feedback(48)
            feedback.layoutSubtreeIfNeeded()
            let note = try XCTUnwrap(find(NoteWell.self, in: feedback).first)
            XCTAssertEqual(try firstBaseline(of: note), BarTheme.wordPadding + ascent, accuracy: 1.5,
                           "\(look.name): in Feedback")
            _ = keep
        }
    }

    /// Keep's drawn fields hold the caret as a CaretMark, still, in the
    /// accent, at the words' line height; the list of sources' field and the
    /// name of a keepsake being written too, and the selected name is the
    /// one wash and has no caret.
    func testKeepsDrawnFieldsHoldTheOneCaret() throws {
        for look in GalleryLook.all {
            look.apply()
            let shots = GalleryShots.all.filter { $0.surface == "keep" && $0.looks.contains(look) && $0.level == 1 }
            XCTAssertGreaterThan(shots.count, 8)
            var marks = 0
            for shot in shots {
                let (root, _) = try shot.build(look)
                root.window?.contentView?.layoutSubtreeIfNeeded()
                for well in find(WellView.self, in: root) where well.holdsField {
                    let carets = find(CaretMark.self, in: well)
                    XCTAssertLessThanOrEqual(carets.count, 1, "\(shot.name(in: look)): one caret in a well")
                    for mark in carets {
                        marks += 1
                        XCTAssertEqual(mark.frame.width, BarTheme.caretWidth)
                        XCTAssertTrue([BarTheme.caretHeight, BarTheme.bodyCaretHeight].contains(mark.frame.height),
                                      "as tall as the line: 20 beside the field's words, 18 beside the body's")
                        XCTAssertNil(mark.layer?.animationKeys())
                        XCTAssertEqual(mark.frame.midY, well.bounds.midY, accuracy: 0.5, "centred in its well")
                    }
                    // The caret is in a well whose edge is the deeper one.
                    XCTAssertTrue(well.isFocused)
                }
            }
            XCTAssertGreaterThan(marks, 5, "\(look.name): Keep's carets were found")
        }
    }

    /// The list of sources has the caret while it is open, and the band over
    /// the right hand, which it covers, rests: one caret on the surface.
    func testOnlyOneCaretStandsInKeepWhileTheListOfSourcesIsOpen() throws {
        GalleryLook.day.apply()
        let shot = try XCTUnwrap(GalleryShots.all.first { $0.surface == "keep" && $0.state == "source-menu" })
        let (root, keep) = try shot.build(.day)
        let strip = try XCTUnwrap(keep.compactMap { $0 as? ClipboardStrip }.first)
        let band = try XCTUnwrap(strip.shownBand)
        XCTAssertFalse(band.field.isFocused, "the band's well rests while the list is open")
        XCTAssertTrue(try XCTUnwrap(strip.shownSourceField).isFocused)
        XCTAssertEqual(find(CaretMark.self, in: root).count, 1)
    }
}
