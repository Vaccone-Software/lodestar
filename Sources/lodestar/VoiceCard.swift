import AppKit
import LodestarCore

/// The rows every glass surface draws: a label, its app icon when it has
/// one, and the key at the trailing edge as a cap. One builder, so a key
/// never looks like two different things on two surfaces.
enum GuideRows {
    /// Screen width decides the column count; rows fill column-major so the
    /// eye scans top-to-bottom.
    static func columns(_ rows: [GuideRow]) -> NSView {
        let screenWidth = ActivePolicy.presentationFrame.width
        let maxColumns = max(1, min(4, Int(screenWidth * 0.7 / 330)))
        let perColumnTarget = 6
        let columns = min(maxColumns, max(1, (rows.count + perColumnTarget - 1) / perColumnTarget))
        let perColumn = (rows.count + columns - 1) / columns

        // Hold the icon column only when this guide actually has icons —
        // otherwise every label in a set like the scroll guide is indented
        // against nothing.
        let hasIcons = rows.contains { $0.icon != nil }

        let grid = NSStackView()
        grid.orientation = .horizontal
        grid.alignment = .top
        grid.spacing = Grid.section

        for column in 0..<columns {
            let start = column * perColumn
            guard start < rows.count else { break }
            let slice = rows[start..<min(start + perColumn, rows.count)]
            let columnStack = NSStackView()
            columnStack.orientation = .vertical
            // Equal widths down the column, which is what lets each row's
            // key sit at the same trailing edge instead of trailing its own
            // label.
            columnStack.alignment = .width
            columnStack.spacing = 0
            for row in slice {
                columnStack.addArrangedSubview(GuideRows.row(row, reserveIcon: hasIcons))
            }
            grid.addArrangedSubview(columnStack)
        }
        return grid
    }

    /// A guide's row is a line of the row contract (`ListLine`): the thing, then
    /// its key at the end, 32 tall and touching the next, so a 24 key has 8
    /// between it and the next. The icon's slot is held even when a row has
    /// none, so the names line up down the column rather than stepping in and
    /// out. A guide is not a menu and nothing in it is chosen, so its lines
    /// stand on the card's own inset.
    static func row(_ guideRow: GuideRow, reserveIcon: Bool) -> NSView {
        let line = ListLine(padding: 0)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: BarTheme.lineHeight).isActive = true
        line.label.stringValue = guideRow.label
        line.label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        if reserveIcon {
            let view = NSImageView(image: guideRow.icon ?? NSImage())
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: BarTheme.symbolSize),
                view.heightAnchor.constraint(equalToConstant: BarTheme.symbolSize),
            ])
            line.setLead(view)
        }
        // One key per keystroke, through the one key; groups that are not one
        // sequence (alternatives) stand apart.
        let strokes = KeyStrokes(groups: guideRow.groups, double: guideRow.double, lit: guideRow.lit)
        let chip: NSView = guideRow.action.map { Keycaps.CapGroup(strokes: strokes, action: $0) } ?? strokes
        // The key lands at the trailing edge, where a menu keeps its shortcut.
        line.setTrailing([chip])
        return line
    }

}

/// Lodestar speaking, as one composition: the sentence in the voice, the
/// keymap as keys, the measurements in the interface's face, the answers
/// as key rows. The HUD, the meeting, and the walk's lessons all draw it,
/// each on its own glass.
enum VoiceCard {
    /// With `mark`, the card is Lodestar speaking about itself: the mark
    /// stands before the words, lit as far as the thing spoken of has come.
    static func build(sentence: String, keymap: Coach.Keymap? = nil, detail: String?,
                      rows: [GuideRow], mark: LitMark? = nil) -> NSStackView {
        let words = words(sentence: sentence, keymap: keymap, detail: detail, rows: rows)
        guard let mark else { return words }
        let card = NSStackView(views: [mark, words])
        card.orientation = .horizontal
        card.alignment = .centerY
        card.spacing = markGap
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    /// The mark to the words: a little more than a wing, so the picture
    /// reads as standing beside the sentence rather than a glyph in it.
    static let markGap = Grid.group

    private static func words(sentence: String, keymap: Coach.Keymap?, detail: String?,
                              rows: [GuideRow]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Grid.part
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The card is as wide as its longest line up to the measure: a
        // one-line note is a small card, an offer with key rows takes the
        // whole measure. A wrapping label reports no width of its own, so
        // the width is measured from the words and set.
        var width = min(BarTheme.measure, BarTheme.width(of: sentence, in: .voice))
        if let detail { width = min(BarTheme.measure, max(width, BarTheme.width(of: detail, in: .meta))) }
        if !rows.isEmpty { width = BarTheme.measure }

        let voice = NSTextField(wrappingLabelWithString: sentence)
        voice.setRole(.voice)
        voice.textColor = BarTheme.ink
        voice.preferredMaxLayoutWidth = width
        voice.translatesAutoresizingMaskIntoConstraints = false
        voice.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(voice)

        // The keymap as keys: caps for the keys, then the target in the
        // body voice. A keymap drawn as prose reads as prose.
        if let keymap {
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = Grid.tight
            line.addArrangedSubview(Keycaps.strokes(keymap.keys))
            let arrow = NSTextField(labelWithString: "→")
            arrow.setRole(.meta)
            arrow.textColor = BarTheme.secondaryColor
            line.addArrangedSubview(arrow)
            let target = NSTextField(labelWithString: keymap.target)
            target.setRole(.body)
            target.textColor = BarTheme.ink
            line.addArrangedSubview(target)
            line.setCustomSpacing(Grid.close, after: line.arrangedSubviews[0])
            line.setCustomSpacing(Grid.close, after: arrow)
            stack.addArrangedSubview(line)
        }

        if let detail {
            let facts = NSTextField(wrappingLabelWithString: detail)
            facts.setRole(.meta)
            facts.textColor = BarTheme.secondaryColor
            facts.preferredMaxLayoutWidth = width
            facts.translatesAutoresizingMaskIntoConstraints = false
            facts.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(facts)
        }

        if !rows.isEmpty {
            let columns = GuideRows.columns(rows)
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(Grid.section, after: last) }
            stack.addArrangedSubview(columns)
            columns.widthAnchor.constraint(equalToConstant: width).isActive = true
        }

        return stack
    }
}
