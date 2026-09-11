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
        panel = Glass.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = root
        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
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
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: ModePill.inset),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -ModePill.inset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: ModePill.inset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -ModePill.inset),
        ])
        content = stack

        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        size.width = min(size.width, 1500)
        let visible = ActivePolicy.presentationFrame
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
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
        columns.spacing = ModePill.inset
        columns.translatesAutoresizingMaskIntoConstraints = false
        // Inside a bar the glass has a width of its own: the stacks give
        // way before the glass does, and a long label truncates.
        columns.setClippingResistancePriority(.init(900), for: .horizontal)

        for section in sections where !section.rows.isEmpty {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6
            column.setClippingResistancePriority(.init(900), for: .horizontal)

            // The pill's rule: one text size, tone for hierarchy. A header
            // is the body voice, quiet, never caps.
            let header = NSTextField(labelWithString: section.header)
            header.font = BarTheme.bodyFont
            header.textColor = BarTheme.secondaryColor
            column.addArrangedSubview(header)
            column.setCustomSpacing(ModePill.wordGap, after: header)

            for row in section.rows.prefix(14) {
                column.addArrangedSubview(makeRow(row))
            }
            if section.rows.count > 14 {
                let more = NSTextField(labelWithString: "+\(section.rows.count - 14) more")
                more.font = BarTheme.footerFont
                more.textColor = BarTheme.secondaryColor
                column.addArrangedSubview(more)
            }
            columns.addArrangedSubview(column)
        }
        return columns
    }

    private static func makeRow(_ row: GuideRow) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = BarTheme.rowGap

        let keycap = NSTextField(labelWithString: row.key)
        keycap.font = BarTheme.chipFont
        keycap.textColor = .labelColor
        keycap.alignment = .center
        keycap.translatesAutoresizingMaskIntoConstraints = false

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        chip.layer?.cornerRadius = BarTheme.chipRadius
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(keycap)
        NSLayoutConstraint.activate([
            keycap.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: BarTheme.chipPadX),
            keycap.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -BarTheme.chipPadX),
            keycap.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: BarTheme.chipHeight),
            chip.widthAnchor.constraint(greaterThanOrEqualToConstant: BarTheme.chipMinWidth),
        ])

        let text = NSTextField(labelWithString: row.label)
        text.font = BarTheme.rowLabelFont
        // A dormant gesture draws quiet, cap and all: the eye reads the
        // sheet for what it uses, and a row it never uses recedes.
        text.textColor = row.dimmed ? BarTheme.secondaryColor : .labelColor
        keycap.textColor = row.dimmed ? BarTheme.secondaryColor : .labelColor
        if row.dimmed { chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor }
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        container.setClippingResistancePriority(.init(900), for: .horizontal)

        container.addArrangedSubview(chip)
        if let icon = row.icon {
            let iconView = NSImageView(image: icon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: BarTheme.rowIcon),
                iconView.heightAnchor.constraint(equalToConstant: BarTheme.rowIcon),
            ])
            container.addArrangedSubview(iconView)
        }
        container.addArrangedSubview(text)
        return container
    }
}
