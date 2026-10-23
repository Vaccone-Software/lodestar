import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/13-row.md, held by what is laid out and drawn: every list line of
/// every gallery surface is one of the four rows at its height, its words 12
/// in and its trailing parts centred on its first line; names are cut at the
/// tail and sentences wrap; words beside a key stand on that key's line; the
/// coach's record wraps within its column and is never cut.
final class RowTests: XCTestCase {
    override func tearDown() { GalleryLook.reset() }

    private func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    /// A part's alignment rect in `root`: the face of a key, the frame of anything else.
    private func rect(of view: NSView, in root: NSView) -> NSRect {
        root.convert(view.alignmentRect(forFrame: view.frame), from: view.superview)
    }

    private func visibleParts(_ stack: NSStackView) -> [NSView] { stack.arrangedSubviews.filter { !$0.isHidden } }

    private func lit(_ view: NSView) -> Bool {
        var found = false
        walk(view) { if ($0 as? Key)?.state == .lit { found = true } }
        return found
    }

    // MARK: - Every list line is one of the four

    /// A row, a line, a setting and a legend, wherever a surface draws one:
    /// at its height, words and icons 12 inside, detail 2 under its title,
    /// trailing parts 8 apart and centred on the title's first line with the
    /// acting key last; lines touching, a chosen line's slab rounded at 14;
    /// settings at least 48 with their letters in one column; legends 24, 8 apart.
    func testEveryListLineOnEverySurfaceIsOneOfTheFourRows() throws {
        var wrong: [String] = []
        var counts = ["rows": 0, "lines": 0, "settings": 0, "legends": 0, "details": 0]
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) && shot.level == 1 && !shot.receded {
                // The sheets paint by drawing, and the row sheet is held on its own.
                guard let (root, keep) = try? shot.build(look) else { continue }
                root.window?.contentView?.layoutSubtreeIfNeeded()
                root.layoutSubtreeIfNeeded()
                let name = shot.name(in: look)
                var settingTitles: [CGFloat] = [], letters: [CGFloat] = []

                walk(root) { view in
                    guard !view.isHidden, view.bounds.width > 0 else { return }

                    // Only four kinds of view hold a list line: none lays out a row of its own.
                    if view is SlabRow, !(view is ListRow), !(view is ListLine), !(view is LandingStep) {
                        wrong.append("\(name): a \(type(of: view)) is a slab row that is none of the four")
                    }

                    if let row = view as? ListRow {
                        counts["rows", default: 0] += 1
                        let frame = root.convert(row.bounds, from: row)
                        let title = rect(of: row.title, in: root)
                        let expected = row.detail.isHidden ? BarTheme.rowHeight : BarTheme.detailRowHeight
                        if !row.detail.isHidden { counts["details", default: 0] += 1 }
                        if abs(row.frame.height - expected) > 0.5 { wrong.append("\(name): a row is \(row.frame.height), not \(expected)") }
                        // Words and icons 12 inside; 12 from the lead to the words.
                        if let lead = row.lead {
                            let leadRect = rect(of: lead, in: root)
                            if abs(leadRect.minX - frame.minX - Grid.part) > 0.5 { wrong.append("\(name): a row's icon is \(leadRect.minX - frame.minX) in") }
                            if abs(title.minX - leadRect.maxX - Grid.part) > 0.5 { wrong.append("\(name): a row's words are \(title.minX - leadRect.maxX) from its icon") }
                            if abs(leadRect.midY - title.midY) > 0.5 { wrong.append("\(name): a row's icon is off its title's line") }
                            let size = leadRect.height
                            if ![BarTheme.appIconSize, BarTheme.titleIconSize].contains(size) { wrong.append("\(name): a row's icon is \(size)") }
                        } else if abs(title.minX - frame.minX - Grid.part) > 0.5 {
                            wrong.append("\(name): a row's words are \(title.minX - frame.minX) in")
                        }
                        if !row.detail.isHidden {
                            let detail = rect(of: row.detail, in: root)
                            if abs((title.minY - detail.maxY) - BarTheme.detailGap) > 1.5 {
                                wrong.append("\(name): a row's detail is \(title.minY - detail.maxY) under its title")
                            }
                            if abs(detail.minX - title.minX) > 0.5 { wrong.append("\(name): a row's detail is not under its title") }
                        }
                        // Trailing parts: 8 apart, the last 12 from the edge, each on the first line's centre.
                        let parts = visibleParts(row.trailing)
                        for (part, next) in zip(parts, parts.dropFirst()) {
                            let gap = rect(of: next, in: root).minX - rect(of: part, in: root).maxX
                            if abs(gap - Grid.close) > 0.5 { wrong.append("\(name): a row's trailing parts are \(gap) apart") }
                        }
                        if let last = parts.last, abs(frame.maxX - rect(of: last, in: root).maxX - Grid.part) > 0.5 {
                            wrong.append("\(name): a row's last key is \(frame.maxX - rect(of: last, in: root).maxX) from its edge")
                        }
                        for part in parts {
                            let mid = rect(of: part, in: root).midY
                            if abs(mid - title.midY) > 0.5 { wrong.append("\(name): a row's \(type(of: part)) \(mid) is off the title's first line \(title.midY)") }
                        }
                        // The acting key is last.
                        if let litAt = parts.firstIndex(where: lit), litAt != parts.count - 1 {
                            wrong.append("\(name): a row's lit key is not its last part")
                        }
                        // Rows in a pane stand 2 apart, so a slab's side never touches the next row.
                        if let pane = row.superview {
                            let below = pane.subviews.compactMap { $0 as? ListRow }
                                .filter { !$0.isHidden && $0.frame.maxY <= row.frame.minY + 0.5 }
                                .max { $0.frame.maxY < $1.frame.maxY }
                            if let below, abs((row.frame.minY - below.frame.maxY) - BarTheme.rowGap) > 0.5 {
                                wrong.append("\(name): rows are \(row.frame.minY - below.frame.maxY) apart, not 2")
                            }
                        }
                    }

                    if let line = view as? ListLine {
                        counts["lines", default: 0] += 1
                        let frame = root.convert(line.bounds, from: line)
                        if abs(line.frame.height - BarTheme.lineHeight) > 0.5 { wrong.append("\(name): a line is \(line.frame.height), not 32") }
                        let label = rect(of: line.label, in: root)
                        let lead = line.subviews.first { $0 !== line.label && $0 !== line.trailing && !($0 is NSStackView && $0 === line.trailing) }
                        if let lead, !(lead.isHidden) {
                            let leadRect = rect(of: lead, in: root)
                            if abs(leadRect.minX - frame.minX - line.padding) > 0.5 { wrong.append("\(name): a line's lead is \(leadRect.minX - frame.minX) in") }
                            if abs(label.minX - leadRect.maxX - Grid.part) > 0.5 { wrong.append("\(name): a line's words are \(label.minX - leadRect.maxX) from its lead") }
                        } else if abs(label.minX - frame.minX - line.padding) > 0.5 {
                            wrong.append("\(name): a line's words are \(label.minX - frame.minX) in")
                        }
                        // The words and the trailing parts share the line's centre.
                        for part in visibleParts(line.trailing) {
                            if abs(rect(of: part, in: root).midY - label.midY) > 0.5 { wrong.append("\(name): a line's \(type(of: part)) is off its words' line") }
                        }
                        let parts = visibleParts(line.trailing)
                        for (part, next) in zip(parts, parts.dropFirst()) {
                            let gap = rect(of: next, in: root).minX - rect(of: part, in: root).maxX
                            if abs(gap - Grid.close) > 0.5 { wrong.append("\(name): a line's trailing parts are \(gap) apart") }
                        }
                        // A chosen line's slab rounds at the menu's radius less its inset.
                        if line.padding == Grid.part, abs(line.radius - BarTheme.lineRadius) > 0.001 {
                            wrong.append("\(name): a line rounds at \(line.radius), not \(BarTheme.lineRadius)")
                        }
                        // Lines touch: the next line in the same menu starts where this one ends.
                        if let menu = line.superview {
                            let below = menu.subviews.compactMap { $0 as? ListLine }
                                .filter { !$0.isHidden && $0.frame.maxY <= line.frame.minY + 0.5 }
                                .max { $0.frame.maxY < $1.frame.maxY }
                            if let below, line.superview === below.superview {
                                let gap = line.frame.minY - below.frame.maxY
                                if abs(gap) > 0.5, abs(gap - Grid.close * 2) > 0.5 { wrong.append("\(name): lines are \(gap) apart") }
                            }
                        }
                    }

                    if view.identifier?.rawValue == "settings.row", let line = view.subviews.first {
                        counts["settings", default: 0] += 1
                        if view.frame.height < BarTheme.settingMinimumHeight - 0.5 {
                            wrong.append("\(name): a setting is \(view.frame.height), under 48")
                        }
                        var title: NSTextField?
                        walk(line) { if title == nil, let field = $0 as? NSTextField, field.typeStyle?.role == .label { title = field } }
                        if let title { settingTitles.append(rect(of: title, in: root).minX.rounded()) }
                        if let key = line.subviews.compactMap({ $0 as? Key }).first, !key.isHidden {
                            letters.append(rect(of: key, in: root).minX.rounded())
                            if abs(key.frame.minX - Grid.part) > 0.5 { wrong.append("\(name): a setting's letter is \(key.frame.minX) in") }
                        }
                    }

                    if let legend = view as? LegendRow {
                        counts["legends", default: 0] += 1
                        if abs(legend.frame.height - BarTheme.legendHeight) > 0.5 { wrong.append("\(name): a legend is \(legend.frame.height), not 24") }
                        let parts = visibleParts(legend.line)
                        // Keys first, then the words 8 after them.
                        for (index, part) in parts.enumerated() where part is KeyWords && index > 0 {
                            let before = parts[index - 1]
                            guard before is Keycaps.CapGroup || before is KeyStrokes else { continue }
                            let gap = rect(of: part, in: root).minX - rect(of: before, in: root).maxX
                            if abs(gap - Grid.close) > 0.5 { wrong.append("\(name): a legend's words are \(gap) after its keys") }
                        }
                    }
                }
                // A place's letters are one column: the titles all start together.
                if Set(settingTitles).count > 1 { wrong.append("\(name): the titles start at \(Set(settingTitles).sorted())") }
                if Set(letters).count > 1 { wrong.append("\(name): the letters stand at \(Set(letters).sorted())") }
                _ = keep
            }
        }
        XCTAssertEqual(Array(Set(wrong)).sorted(), [])
        XCTAssertGreaterThan(counts["rows"] ?? 0, 30, "rows were looked at")
        XCTAssertGreaterThan(counts["details"] ?? 0, 5, "rows with a line beneath were looked at")
        XCTAssertGreaterThan(counts["lines"] ?? 0, 20, "lines were looked at")
        XCTAssertGreaterThan(counts["settings"] ?? 0, 50, "settings were looked at")
        XCTAssertGreaterThan(counts["legends"] ?? 0, 20, "legends were looked at")
    }
}

// MARK: - Names are cut at the tail; sentences wrap

extension RowTests {
    /// A name (a row's title and detail, a line's words, the words beside a
    /// key, a setting's title) ends in "…" when it does not fit, on one line;
    /// a sentence (a setting's detail, a problem, a readout) wraps and the row
    /// grows. Held on every gallery surface and on every place of Settings.
    func testEveryNameFieldTruncatesAtTheTailAndEverySentenceFieldWraps() throws {
        var wrong: [String] = []
        var counts = ["names": 0, "sentences": 0]
        func checkName(_ field: NSTextField, _ what: String, _ surface: String) {
            guard !field.stringValue.isEmpty else { return }
            counts["names", default: 0] += 1
            if field.lineBreakMode != .byTruncatingTail { wrong.append("\(surface): \(what) \"\(field.stringValue.prefix(24))\" is \(field.lineBreakMode.rawValue), not tail") }
            if field.maximumNumberOfLines > 1 { wrong.append("\(surface): \(what) \"\(field.stringValue.prefix(24))\" takes several lines") }
        }
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) && shot.level == 1 && !shot.receded {
                guard let (root, keep) = try? shot.build(look) else { continue }
                root.window?.contentView?.layoutSubtreeIfNeeded()
                let name = shot.name(in: look)
                walk(root) { view in
                    if let row = view as? ListRow {
                        checkName(row.title, "a row's title", name)
                        checkName(row.detail, "a row's detail", name)
                    }
                    if let line = view as? ListLine { checkName(line.label, "a line's words", name) }
                    // A record is a sentence: it wraps within its column, held by its own tests.
                    if let words = view as? KeyWords, words.column == nil { checkName(words.label, "the words beside a key", name) }
                }
                _ = keep
            }
        }
        // Settings: every title is a name, every detail, problem and readout a sentence.
        GalleryLook.day.apply()
        for place in SettingsModel.placeNames.indices {
            let settings = GallerySettings.controller()
            settings.renderForTesting(place: place)
            let fields = settings.viewsForTesting(of: NSTextField.self)
            for section in [settings.sectionsForTesting[place]] {
                for row in section.rows {
                    if let title = fields.first(where: { $0.stringValue == row.title && $0.typeStyle?.role == .label }) {
                        checkName(title, "a setting's title", "settings \(section.name)")
                    }
                    for sentence in [row.detail, row.problem].compactMap({ $0 }) where !sentence.isEmpty {
                        guard let field = fields.first(where: { $0.stringValue == sentence }) else { continue }
                        counts["sentences", default: 0] += 1
                        if field.lineBreakMode != .byWordWrapping || field.maximumNumberOfLines != 0 || !(field.cell?.wraps ?? false) {
                            wrong.append("settings \(section.name): the sentence \"\(sentence.prefix(24))\" does not wrap")
                        }
                    }
                    if case .readout(let value, _) = row.control, !value.isEmpty,
                       let field = fields.first(where: { $0.stringValue == value }) {
                        counts["sentences", default: 0] += 1
                        if field.lineBreakMode != .byWordWrapping || !(field.cell?.wraps ?? false) {
                            wrong.append("settings \(section.name): the readout \"\(value.prefix(24))\" does not wrap")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(Array(Set(wrong)).sorted(), [])
        XCTAssertGreaterThan(counts["names"] ?? 0, 100, "names were looked at")
        XCTAssertGreaterThan(counts["sentences"] ?? 0, 30, "sentences were looked at")
    }
}

// MARK: - Words beside a key stand on its line

extension RowTests {
    /// The ink a text field draws, found by drawing `root` with and without its
    /// words: the rows (points up from the bottom of `root`) and columns the
    /// differing pixels span, within `columns` points of the field's start.
    private func ink(of field: NSTextField, in root: NSView, firstPoints: CGFloat = 6, firstLine: Bool = false) -> (low: CGFloat, high: CGFloat, left: CGFloat)? {
        let with = GalleryRender.bitmap(of: root)
        let colour = field.textColor
        field.textColor = .clear
        let without = GalleryRender.bitmap(of: root)
        field.textColor = colour
        guard let a = with.bitmapData, let b = without.bitmapData else { return nil }
        let scale = CGFloat(with.pixelsWide) / root.bounds.width
        var frame = root.convert(field.alignmentRect(forFrame: field.frame), from: field.superview)
        // A wrapped sentence's first line: the top of it, a line's height less the next line's reach.
        let line = ceil((field.font?.ascender ?? 12) - (field.font?.descender ?? -4)) - 3
        if firstLine, frame.height > line + 5 { frame = NSRect(x: frame.minX, y: frame.maxY - line, width: frame.width, height: line) }
        let first = Int((frame.minX * scale).rounded(.down)), last = Int(((frame.minX + firstPoints) * scale).rounded(.up))
        let top = Int(((root.bounds.height - frame.maxY - 2) * scale).rounded(.down))
        let bottom = Int(((root.bounds.height - frame.minY + 2) * scale).rounded(.up))
        var rows: [Int] = [], leftmost = Int.max
        guard max(0, top) < min(with.pixelsHigh, bottom), max(0, first) < min(with.pixelsWide, last) else {
            print("RANGE \(field.stringValue) frame \(frame) root \(root.bounds) top \(top) bottom \(bottom) first \(first) last \(last)")
            return nil
        }
        for row in max(0, top)..<min(with.pixelsHigh, bottom) {
            for column in max(0, first)..<min(with.pixelsWide, last) {
                let at = row * with.bytesPerRow + column * 4
                var difference = 0
                for channel in 0..<4 { difference += abs(Int(a[at + channel]) - Int(b[at + channel])) }
                if difference > 90 { rows.append(row); leftmost = min(leftmost, column) }
            }
        }
        guard let highest = rows.min(), let lowest = rows.max() else { return nil }
        let height = CGFloat(with.pixelsHigh)
        // A pixel row's bottom edge, counted up from the bottom of the picture.
        return ((height - CGFloat(lowest) - 1) / scale, (height - CGFloat(highest)) / scale, CGFloat(leftmost) / scale)
    }

    /// The baseline lowercase legends share on a key's face, in `root`'s coordinates:
    /// where the words beside the key stand, whatever the key itself says.
    private func baseline(of key: Key, in root: NSView) -> CGFloat {
        root.convert(NSPoint(x: 0, y: key.lowercaseBaseline), from: key).y
    }

    private func keys(in view: NSView) -> [Key] {
        var found: [Key] = []
        walk(view) { if let key = $0 as? Key, !key.isHidden { found.append(key) } }
        return found
    }

    /// The coach's record and its way out, a footer's words, and a Settings
    /// title's own keys, drawn and read back by their ink: meta words stand
    /// on the baseline of the key they follow, larger words with their capital
    /// height centred on the key's face. Today (before this contract) the
    /// coach's record and "Not now" and every footer's words stood 1.5 to 2.5
    /// points below their keys' letters.
    func testWordsBesideAKeyStandOnItsLine() throws {
        var wrong: [String] = []
        var measured = 0
        for look in GalleryLook.all {
            look.apply()

            // The coach: the record beside `lode ⌫`'s first key, "Not now" beside the second.
            // A record that wraps stands its first line on the keys' baseline, its
            // second under the first.
            for variant in 0..<3 {
                let (root, keep) = try variant == 2 ? GalleryChrome.coachWrapped() : GalleryChrome.coach(variant == 0)
                root.window?.contentView?.layoutSubtreeIfNeeded()
                var words: [KeyWords] = []
                walk(root) { if let w = $0 as? KeyWords { words.append(w) } }
                let all = keys(in: root).filter { $0.state == .resting }
                // The record and "Not now" stand on one baseline with `lode` (and `⌫`'s face).
                for (word, legend) in zip(words, ["lode", "⌫"]) {
                    guard let key = all.first(where: { $0.legend == legend }) else { continue }
                    guard let found = ink(of: word.label, in: root, firstLine: true) else { wrong.append("\(look.name) coach: no ink for \"\(word.stringValue)\""); continue }
                    measured += 1
                    let want = baseline(of: key, in: root)
                    if abs(found.low - want) > 0.5 {
                        wrong.append("\(look.name) coach \(variant) \"\(word.stringValue.prefix(14))\": words stand on \(found.low), the key \"\(legend)\" on \(want)")
                    }
                }
                _ = keep
            }

            // Feedback's footer: the version at its leading edge stands on the same
            // baseline as "Cancel" and "Send" at the other (it stood 2 points below).
            let (feedback, feedbackKeep) = try GalleryChrome.feedback(45)
            feedback.window?.contentView?.layoutSubtreeIfNeeded()
            var feedbackWords: [KeyWords] = []
            walk(feedback) { if let w = $0 as? KeyWords { feedbackWords.append(w) } }
            let feedbackKey = keys(in: feedback).first { $0.legend == "esc" }
            let version = feedbackWords.first { $0.stringValue.hasPrefix("Lodestar ") }
            if let version, let feedbackKey, let found = ink(of: version.label, in: feedback) {
                measured += 1
                let want = baseline(of: feedbackKey, in: feedback)
                if abs(found.low - want) > 0.5 { wrong.append("\(look.name) feedback: the version stands on \(found.low), the footer's keys' words on \(want)") }
                for word in feedbackWords where word !== version && word.stringValue != "·" {
                    guard let own = ink(of: word.label, in: feedback) else { continue }
                    measured += 1
                    if abs(own.low - found.low) > 0.5 { wrong.append("\(look.name) feedback \"\(word.stringValue)\" is \(own.low), the version \(found.low)") }
                }
            } else {
                wrong.append("\(look.name) feedback: no version footer found")
            }
            _ = feedbackKeep

            // A footer: each word on the baseline of the key before it.
            let footer = Keycaps.line([.init(["esc"], "Back"), .init(["⏎"], "Choose", lit: true),
                                       .init(["lode", "⌫"], "Not now"), .init(["e", "p"], "Open")])
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 56))
            Ceramic.installPane(in: host, cornerRadius: BarTheme.surfaceRadius)
            host.addSubview(footer)
            NSLayoutConstraint.activate([
                footer.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Grid.section),
                footer.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            ])
            let window = GalleryHost.window(host, size: host.frame.size, look: look)
            host.layoutSubtreeIfNeeded()
            var parts: [NSView] = []
            walk(footer) { if $0 is KeyWords || $0 is KeyStrokes { parts.append($0) } }
            for (index, part) in parts.enumerated() {
                guard let words = part as? KeyWords, words.stringValue != "·", index > 0,
                      let strokes = parts[index - 1] as? KeyStrokes, let key = strokes.caps.last else { continue }
                guard let found = ink(of: words.label, in: host) else { wrong.append("\(look.name) footer: no ink for \"\(words.stringValue)\""); continue }
                measured += 1
                let want = baseline(of: key, in: host)
                if abs(found.low - want) > 0.5 {
                    wrong.append("\(look.name) footer \"\(words.stringValue)\": on \(found.low), the key \"\(key.legend)\" on \(want)")
                }
            }
            window.close()

            // A Settings title and its own keys: the title's capital height is centred on the keys' face.
            let settings = GallerySettings.controller()
            var row = SettingsModel.Row(title: "Settings", path: "gestures.settings", control: .toggle(true),
                                        detail: "Opens this window", keycaps: ["lode", ","])
            row.letter = "c"
            let line = settings.settingRowForTesting(row, width: 520, letterWidth: Key.width(of: "c"))
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 96))
            Ceramic.installPane(in: pane, cornerRadius: BarTheme.surfaceRadius)
            pane.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: Grid.section),
                line.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
            ])
            let paneWindow = GalleryHost.window(pane, size: pane.frame.size, look: look)
            pane.layoutSubtreeIfNeeded()
            var title: NSTextField?
            walk(line) { if title == nil, let field = $0 as? NSTextField, field.typeStyle?.role == .label { title = field } }
            let strokes = keys(in: line).filter { $0.legend == "lode" || $0.legend == "," }
            if let title, let key = strokes.first, let found = ink(of: title, in: pane, firstPoints: 9) {
                measured += 1
                // "S" is a round capital: it overshoots the baseline and the cap line a little.
                let middle = (found.low + found.high) / 2
                let face = pane.convert(key.face, from: key)
                if abs(middle - face.midY) > 0.5 {
                    wrong.append("\(look.name) settings title: its capital is centred on \(middle), the keys' face on \(face.midY)")
                }
            } else {
                wrong.append("\(look.name) settings title: not found")
            }
            paneWindow.close()
        }
        XCTAssertEqual(wrong, [])
        XCTAssertGreaterThanOrEqual(measured, 18, "the coach's words, the footer's and the title's were measured")
    }
}

// MARK: - The coach's record wraps and is never cut

extension RowTests {
    /// Every record the coach writes (the first clause of the chip's evidence,
    /// whichever kind of offer it is), with the longest app names the gallery
    /// uses and the biggest numbers a record carries, is whole on a card at its
    /// widest, 540 (design/13-row.md, rule 5): nothing is cut or clipped, every
    /// part of the card is inside its bounds, and `lode ⌫` and "Not now" stand
    /// on the first line's baseline, with the card as tall as its lines.
    func testEveryCoachRecordIsWholeAtTheCardsWidest() throws {
        let longest = (GalleryLauncher.addresses.keys.map(CoachCard.displayName) + ["Brave Browser", "Messages", "Mail"])
            .sorted { BarTheme.width(of: $0, in: .meta) > BarTheme.width(of: $1, in: .meta) }
        let first = longest[0], second = longest[1]
        // The record of each kind of offer, as `Coach.chip` writes it at the largest numbers it carries.
        let kinds: [(String, Recommendation)] = [
            ("bind", Recommendation(kind: .bind, target: first, detail: "\(first) is searched often", secondsPerWeek: 4000,
                                    probability: 0.95, evidence: [], edit: .bindTarget(chain: ["f"], target: first))),
            ("shorten", Recommendation(kind: .shorten, target: "a b c d", detail: "d", secondsPerWeek: 4000, probability: 0.95,
                                       evidence: [], display: first, edit: .supersede(old: ["a", "b", "c", "d"], new: ["a"], target: first))),
            ("flatten", Recommendation(kind: .flatten, target: "a b c d", detail: "d", secondsPerWeek: 4000, probability: 0.95,
                                       evidence: [], display: first, edit: .supersede(old: ["a", "b", "c", "d"], new: ["a"], target: first))),
            ("retire", Recommendation(kind: .retire, target: "a b c", detail: "never typed", secondsPerWeek: 0, probability: 0.95,
                                      evidence: [], edit: .removeChain(chain: ["a", "b", "c"]))),
            ("route", Recommendation(kind: .route, target: "a-very-long-hostname.example.com", detail: "always lands in work",
                                     secondsPerWeek: 4000, probability: 0.9, evidence: [],
                                     edit: .addRoute(pattern: "a-very-long-hostname.example.com", profileKey: "work"))),
            ("nudge", Recommendation(kind: .nudge, target: first, detail: "\(first) is reached by the launcher", secondsPerWeek: 4000,
                                     probability: 0.9, evidence: [], display: first, edit: .closeRoad(app: first, chain: ["a", "b"]))),
            ("meetings", Recommendation(kind: .meetings, target: "meetings", detail: "about 99 meetings a week joined by hand",
                                        secondsPerWeek: 4000, probability: 0.9, evidence: [], edit: .enableMeetings)),
            // Advisor writes a breath's detail as "A and B travel together N× at lift L · …".
            ("breath", Recommendation(kind: .breath, target: "\(first) + \(second)",
                                      detail: "\(first) and \(second) travel together 9999× at lift 99.9 · composed side by side 99× · a breath would bring them back with one key",
                                      secondsPerWeek: 4000, probability: 0.9, evidence: [], display: "\(first) + \(second)",
                                      edit: .composeBreath(apps: [first, second], path: "b"))),
        ]
        var wrong: [String] = []
        var wrapped = 0
        for look in GalleryLook.all {
            look.apply()
            for (kind, recommendation) in kinds {
                var observations = Observations()
                // The numbers a bind, a shorten, a flatten and a route carry are read from the record.
                for _ in 0..<200 {
                    var reach = ObservationEvent(t: Date(), kind: .reach)
                    reach.app = recommendation.target.lowercased()
                    reach.route = "searcher"
                    reach.typed = 3
                    observations.apply(reach)
                }
                let chip = Coach.chip(for: recommendation, observations: observations)
                let record = CoachCard.record(from: chip.evidence)
                let card = CoachCard.build(.init(sentence: chip.sentence, icons: [], name: "\(first) and \(second)",
                                                 address: ["lode", "'", "w"], record: record, accept: {}, decline: {}))
                let host = NSView(frame: NSRect(x: 0, y: 0, width: BarTheme.offerMaxWidth, height: 300))
                card.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(card)
                NSLayoutConstraint.activate([
                    card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    card.topAnchor.constraint(equalTo: host.topAnchor),
                    card.widthAnchor.constraint(lessThanOrEqualToConstant: BarTheme.offerMaxWidth),
                ])
                let window = GalleryHost.window(host, size: host.frame.size, look: look)
                host.layoutSubtreeIfNeeded()
                let name = "\(look.name) \(kind)"
                var words: [KeyWords] = []
                walk(host) { if let w = $0 as? KeyWords { words.append(w) } }
                guard let shown = words.first(where: { $0.stringValue == record }) else { wrong.append("\(name): no record"); continue }
                let label = shown.label
                let lines = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height ?? 0
                if lines > label.frame.height + 0.5 { wrong.append("\(name): \"\(record)\" needs \(lines), has \(label.frame.height)") }
                if label.frame.width < label.intrinsicContentSize.width - 0.5 && label.cell?.wraps != true {
                    wrong.append("\(name): \"\(record)\" is cut on one line")
                }
                if label.frame.height > 20 { wrapped += 1 }
                // The card is as wide as the rule says, and everything on it is inside it.
                if card.frame.width > BarTheme.offerMaxWidth + 0.5 || card.frame.width < BarTheme.offerWidth - 0.5 {
                    wrong.append("\(name): the card is \(card.frame.width) wide")
                }
                walk(card) { view in
                    guard view !== card, !view.isHidden, view.frame.width > 0 else { return }
                    let at = card.convert(view.frame, from: view.superview)
                    if at.minX < -0.5 || at.minY < -0.5 || at.maxX > card.bounds.width + 0.5 || at.maxY > card.bounds.height + 0.5 {
                        wrong.append("\(name): \(type(of: view)) falls outside the card: \(at) of \(card.bounds)")
                    }
                }
                // Not now's keys and words stand on the record's first line.
                let all = keys(in: card).filter { $0.state == .resting }
                if let key = all.first(where: { $0.legend == "⌫" }),
                   let found = ink(of: label, in: host, firstLine: true) {
                    let want = baseline(of: key, in: host)
                    if abs(found.low - want) > 0.5 { wrong.append("\(name): the record's first line stands on \(found.low), the keys on \(want)") }
                } else {
                    wrong.append("\(name): no keys or no ink")
                }
                if let notNow = words.first(where: { $0.stringValue == "Not now" }) {
                    if notNow.label.frame.width < notNow.label.intrinsicContentSize.width - 0.5 { wrong.append("\(name): \"Not now\" is cut") }
                    let up = host.convert(label.frame, from: shown).maxY, down = host.convert(notNow.label.frame, from: notNow).maxY
                    if down > up + 0.5 || down < up - 40 { wrong.append("\(name): \"Not now\" is not on the first line") }
                }
                window.close()
            }
        }
        XCTAssertEqual(wrong, [])
        XCTAssertGreaterThan(wrapped, 0, "the longest breath wraps, so the wrap was measured")
    }

    /// A record that wraps keeps its second line under its first, flush with
    /// its leading edge, and the card holds both.
    func testAWrappedRecordsLinesStandUnderEachOther() throws {
        for look in GalleryLook.all {
            look.apply()
            let (root, keep) = try GalleryChrome.coachWrapped()
            root.window?.contentView?.layoutSubtreeIfNeeded()
            var record: KeyWords?
            walk(root) { if let w = $0 as? KeyWords, w.stringValue == GalleryChrome.wrappedRecord { record = w } }
            let shown = try XCTUnwrap(record, "\(look.name): the record")
            let label = shown.label
            XCTAssertGreaterThan(label.frame.height, 28, "\(look.name): two lines")
            let lines = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height ?? 0
            XCTAssertLessThanOrEqual(lines, label.frame.height + 0.5, "\(look.name): every line fits its frame")
            let card = try XCTUnwrap(GalleryLauncher.find(NSView.self, in: root, where: { $0.accessibilityRole() == .group && $0.accessibilityLabel()?.contains(GalleryChrome.wrappedRecord) == true }))
            let at = card.convert(shown.frame, from: shown.superview)
            XCTAssertEqual(at.minX, CoachCard.textInset, accuracy: 0.5, "\(look.name): flush with the card's inset")
            XCTAssertEqual(card.frame.width, CoachCard.maxWidth, accuracy: 0.5, "\(look.name): a wrapped record's card is the widest")
            XCTAssertLessThanOrEqual(at.minY, card.bounds.height, "\(look.name)")
            XCTAssertGreaterThanOrEqual(at.minY, 0, "\(look.name): the last line is on the card")
            _ = keep
        }
    }
}
