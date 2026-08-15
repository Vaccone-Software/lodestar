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

    func toggle(sections: () -> [Section]) {
        if panel.isVisible { hide() } else { show(sections()) }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show(_ sections: [Section]) {
        content?.removeFromSuperview()

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 36
        columns.translatesAutoresizingMaskIntoConstraints = false

        for section in sections where !section.rows.isEmpty {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6

            let header = NSTextField(labelWithString: section.header.uppercased())
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            column.addArrangedSubview(header)
            column.setCustomSpacing(9, after: header)

            for row in section.rows.prefix(14) {
                column.addArrangedSubview(makeRow(row))
            }
            if section.rows.count > 14 {
                let more = NSTextField(labelWithString: "+\(section.rows.count - 14) more")
                more.font = .systemFont(ofSize: 11)
                more.textColor = .tertiaryLabelColor
                column.addArrangedSubview(more)
            }
            columns.addArrangedSubview(column)
        }

        let footer = NSTextField(labelWithString: "lode ? closes · everything here is live — bind more and it grows")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(columns)
        stack.addArrangedSubview(footer)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -26),
        ])
        content = stack

        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        size.width = min(size.width, 1500)
        let visible = ActivePolicy.presentationFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func makeRow(_ row: GuideRow) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 9

        let keycap = NSTextField(labelWithString: row.key)
        keycap.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        keycap.textColor = .labelColor
        keycap.alignment = .center
        keycap.translatesAutoresizingMaskIntoConstraints = false

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        chip.layer?.cornerRadius = 5
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(keycap)
        NSLayoutConstraint.activate([
            keycap.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            keycap.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            keycap.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2),
            keycap.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2),
            chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])

        let text = NSTextField(labelWithString: row.label)
        text.font = .systemFont(ofSize: 12.5)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail

        container.addArrangedSubview(chip)
        if let icon = row.icon {
            let iconView = NSImageView(image: icon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 17),
                iconView.heightAnchor.constraint(equalToConstant: 17),
            ])
            container.addArrangedSubview(iconView)
        }
        container.addArrangedSubview(text)
        return container
    }
}
