import AppKit
import LodestarCore

/// One line of the chain guide: keycap → destination, with its app icon.
struct GuideRow {
    let key: String
    let label: String
    let icon: NSImage?

    init(key: String, label: String, icon: NSImage? = nil) {
        self.key = key
        self.label = label
        self.icon = icon
    }
}

/// The chain guide: a floating glass panel that IS the pending state made
/// visible. While a chain is active it stays up, showing the typed prefix
/// and every legal continuation; flashes fade on their own. Rows flow into
/// columns sized by the screen — a laptop gets two, a big display three or
/// four.
final class HUD {
    private let panel: NSPanel
    private let root = NSView()
    private var content: NSStackView?
    private var hideTimer: Timer?

    init() {
        panel = Glass.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = root
        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
    }

    // MARK: - Public surface

    /// Persistent guide for an active chain. Stays until updated or hidden.
    func showGuide(title: String, rows: [GuideRow], footer: String) {
        hideTimer?.invalidate()
        hideTimer = nil
        build(title: title, titleIcon: nil, rows: Array(rows.prefix(24)), footer: footer)
        present()
    }

    /// A transient message, optionally wearing the app it acted on.
    func flash(_ text: String, icon: NSImage? = nil, seconds: TimeInterval = 1.4) {
        build(title: text, titleIcon: icon, rows: [], footer: nil)
        present()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
    }

    // MARK: - Construction

    private func build(title: String, titleIcon: NSImage?, rows: [GuideRow], footer: String?) {
        content?.removeFromSuperview()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        if let titleIcon {
            let iconView = NSImageView(image: titleIcon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 20),
                iconView.heightAnchor.constraint(equalToConstant: 20),
            ])
            titleRow.addArrangedSubview(iconView)
        }
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleRow.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(titleRow)

        if !rows.isEmpty {
            stack.setCustomSpacing(10, after: titleRow)
            stack.addArrangedSubview(makeColumns(rows))
        }

        if let footer {
            let footerLabel = NSTextField(labelWithString: footer)
            footerLabel.font = .systemFont(ofSize: 11, weight: .regular)
            footerLabel.textColor = .secondaryLabelColor
            if let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(10, after: last)
            }
            stack.addArrangedSubview(footerLabel)
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
        ])
        content = stack
    }

    /// Screen width decides the column count; rows fill column-major so the
    /// eye scans top-to-bottom.
    private func makeColumns(_ rows: [GuideRow]) -> NSView {
        let screenWidth = ActivePolicy.presentationFrame.width
        let maxColumns = max(1, min(4, Int(screenWidth * 0.7 / 330)))
        let perColumnTarget = 6
        let columns = min(maxColumns, max(1, (rows.count + perColumnTarget - 1) / perColumnTarget))
        let perColumn = (rows.count + columns - 1) / columns

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
            columnStack.alignment = .leading
            columnStack.spacing = 6
            for row in slice {
                columnStack.addArrangedSubview(makeRow(row))
            }
            grid.addArrangedSubview(columnStack)
        }
        return grid
    }

    private func makeRow(_ guideRow: GuideRow) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let keycap = NSTextField(labelWithString: guideRow.key)
        keycap.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        keycap.textColor = .labelColor
        keycap.alignment = .center
        keycap.translatesAutoresizingMaskIntoConstraints = false

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        chip.layer?.cornerRadius = 6
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(keycap)
        NSLayoutConstraint.activate([
            keycap.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 7),
            keycap.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -7),
            keycap.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
            keycap.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -3),
            chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

        let text = NSTextField(labelWithString: guideRow.label)
        text.font = .systemFont(ofSize: 13, weight: .regular)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(chip)
        if let icon = guideRow.icon {
            let iconView = NSImageView(image: icon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 19),
                iconView.heightAnchor.constraint(equalToConstant: 19),
            ])
            row.addArrangedSubview(iconView)
        }
        row.addArrangedSubview(text)
        return row
    }

    private func present() {
        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        size.width = min(max(size.width, 200), 1100)
        size.height = max(size.height, 44)

        let visible = ActivePolicy.presentationFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 96
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}
