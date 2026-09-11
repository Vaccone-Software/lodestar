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
        grid.spacing = 30

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
            columnStack.spacing = 6
            for row in slice {
                columnStack.addArrangedSubview(GuideRows.row(row, reserveIcon: hasIcons))
            }
            grid.addArrangedSubview(columnStack)
        }
        return grid
    }

    static func row(_ guideRow: GuideRow, reserveIcon: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = BarTheme.rowGap

        // Icon, name, then key — the order the clipboard's actions menu
        // reads in. The icon's slot is held even when a row has none, so
        // the names line up down the column rather than stepping in and out.
        var iconView: NSImageView?
        if reserveIcon {
            let view = NSImageView(image: guideRow.icon ?? NSImage())
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: BarTheme.rowIcon),
                view.heightAnchor.constraint(equalToConstant: BarTheme.rowIcon),
            ])
            iconView = view
        }

        let text = NSTextField(labelWithString: guideRow.label)
        text.font = BarTheme.rowLabelFont
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Absorbs the slack, so the key lands at the trailing edge where a
        // menu keeps its shortcut.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.widthAnchor.constraint(
            greaterThanOrEqualToConstant: BarTheme.rowKeyGap).isActive = true

        // One cap per press, through the shared shape. A row whose keys are
        // alternatives rather than a sequence passes them as one string and
        // still gets one cap, which is what `J K` — either one — needs.
        let chip: NSView
        let caps = guideRow.keys.map { Keycaps.cap($0) }
        if let action = guideRow.action {
            chip = Keycaps.CapGroup(caps: caps, action: action)
        } else if caps.count == 1 {
            chip = caps[0]
        } else {
            let group = NSStackView(views: caps)
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 4
            group.setContentHuggingPriority(.required, for: .horizontal)
            chip = group
        }

        if let iconView { row.addArrangedSubview(iconView) }
        row.addArrangedSubview(text)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(chip)
        return row
    }

}

/// Lodestar speaking, as one composition: the sentence in the voice, the
/// keymap as keys, the measurements in the interface's face, the answers
/// as key rows. The HUD, the meeting, and the walk's lessons all draw it,
/// each on its own glass.
enum VoiceCard {
    static func build(sentence: String, keymap: Coach.Keymap? = nil, detail: String?,
                      rows: [GuideRow]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ModePill.wordGap
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The card is as wide as its longest line up to the measure: a
        // one-line note is a small card, an offer with key rows takes the
        // whole measure. A wrapping label reports no width of its own, so
        // the width is measured from the words and set.
        func natural(_ text: String, _ font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        var width = min(BarTheme.voiceWidth, natural(sentence, BarTheme.voiceFont))
        if let detail { width = min(BarTheme.voiceWidth, max(width, natural(detail, BarTheme.secondaryFont))) }
        if !rows.isEmpty { width = BarTheme.voiceWidth }

        let voice = NSTextField(wrappingLabelWithString: sentence)
        voice.font = BarTheme.voiceFont
        voice.textColor = .labelColor
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
            line.spacing = 4
            for key in keymap.keys { line.addArrangedSubview(Keycaps.cap(key)) }
            let arrow = NSTextField(labelWithString: "→")
            arrow.font = BarTheme.secondaryFont
            arrow.textColor = BarTheme.secondaryColor
            line.addArrangedSubview(arrow)
            let target = NSTextField(labelWithString: keymap.target)
            target.font = BarTheme.bodyFont
            target.textColor = .labelColor
            line.addArrangedSubview(target)
            line.setCustomSpacing(8, after: line.arrangedSubviews[keymap.keys.count - 1])
            line.setCustomSpacing(8, after: arrow)
            stack.addArrangedSubview(line)
        }

        if let detail {
            let facts = NSTextField(wrappingLabelWithString: detail)
            facts.font = BarTheme.secondaryFont
            facts.textColor = BarTheme.secondaryColor
            facts.preferredMaxLayoutWidth = width
            facts.translatesAutoresizingMaskIntoConstraints = false
            facts.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(facts)
        }

        if !rows.isEmpty {
            let columns = GuideRows.columns(rows)
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(ModePill.wingGap, after: last) }
            stack.addArrangedSubview(columns)
            columns.widthAnchor.constraint(equalToConstant: width).isActive = true
        }

        return stack
    }
}
