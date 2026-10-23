import AppKit
import LodestarCore

/// `lode ?` — the whole system on one glass sheet, generated from live
/// config and state so it can never go stale. Toggles with the same key;
/// any other lode gesture dismisses it.
final class CheatSheet {
    struct Section {
        let header: String
        let rows: [GuideRow]
    }

    private let panel: NSPanel
    private let root = NSView()
    private var content: NSStackView?

    init() {
        panel = Ceramic.makePanel(level: .statusBar, takesKeys: false)
        // Shown, never touched: the drawn shadow, and no mouse anywhere.
        SoftShadow.host(root, in: panel, cornerRadius: BarTheme.surfaceRadius, takesPointer: false)
        Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)
    }

    var isVisible: Bool { panel.isVisible }

    /// The sheet as its own panel, at the middle of the screen: the idle
    /// system and the settings window, which have nothing to grow from.
    /// A bar and the pill grow to hold their own keys instead (`BarKeys`,
    /// `ModePill.toggleKeys`), so one object changes size rather than a
    /// second one arriving.
    func toggle(sections: () -> [Section]) {
        if panel.isVisible { hide() } else { show(sections()) }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show(_ sections: [Section]) {
        content?.removeFromSuperview()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(Self.columns(sections))

        // The pill's inset on every side, so the sheet is built on the
        // lens's own proportions.
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Grid.section),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Grid.section),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Grid.section),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Grid.section),
        ])
        content = stack

        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        size.width = min(size.width, 1500)
        let visible = ActivePolicy.presentationFrame
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        panel.setPaneFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// The keys, as columns: one per section, a quiet header over each.
    /// Shared with the bars and the pill, so the keys read the same
    /// wherever they unfold.
    static func columns(_ sections: [Section]) -> NSView {
        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        // The pill's inset between columns: inside a bar the width is
        // the bar's, and the sections have to share it.
        columns.spacing = Grid.section
        columns.translatesAutoresizingMaskIntoConstraints = false
        // Inside a bar the glass has a width of its own: the stacks give
        // way before the glass does, and a long label truncates.
        columns.setClippingResistancePriority(.init(900), for: .horizontal)

        for section in sections where !section.rows.isEmpty {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            // Legends stand 8 apart.
            column.spacing = BarTheme.legendGap
            column.setClippingResistancePriority(.init(900), for: .horizontal)

            // The pill's rule: one text size, tone for hierarchy. A header
            // is the body voice, quiet, never caps.
            let header = NSTextField(labelWithString: section.header)
            header.setRole(.body)
            header.textColor = BarTheme.secondaryColor
            column.addArrangedSubview(header)
            column.setCustomSpacing(Grid.part, after: header)

            for row in section.rows.prefix(14) {
                column.addArrangedSubview(makeRow(row))
            }
            if section.rows.count > 14 {
                let more = NSTextField(labelWithString: "+\(section.rows.count - 14) more")
                more.setRole(.meta)
                more.textColor = BarTheme.secondaryColor
                column.addArrangedSubview(more)
            }
            columns.addArrangedSubview(column)
        }
        return columns
    }

    /// One gesture of the sheet, a legend of the row contract: its keys first,
    /// then what they do, 8 apart, 24 tall (the key's height). The words are the
    /// body's, larger than a key's own, so they stand with their capital height
    /// centred on the key's face (`KeyWords`).
    private static func makeRow(_ row: GuideRow) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = Grid.close

        // The one key: a key per keystroke, groups that are not one sequence apart.
        // A dormant gesture draws quiet, as every quiet key is: the resting key
        // left unfilled.
        let chip = KeyStrokes(groups: row.groups, double: row.double, quiet: row.dimmed)

        // A dormant gesture draws quiet, cap and all: the eye reads the
        // sheet for what it uses, and a row it never uses recedes.
        let text = KeyWords(row.label, role: .body, color: row.dimmed ? BarTheme.secondaryColor : BarTheme.ink)
        text.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        container.setClippingResistancePriority(.init(900), for: .horizontal)

        container.addArrangedSubview(chip)
        if let icon = row.icon {
            let iconView = NSImageView(image: icon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: BarTheme.symbolSize),
                iconView.heightAnchor.constraint(equalToConstant: BarTheme.symbolSize),
            ])
            container.addArrangedSubview(iconView)
        }
        container.addArrangedSubview(text)
        return container
    }
}
