import AppKit
import LodestarCore

/// The ⌘K graph card: a small glass panel floating beside the searcher
/// for adding an app to the graph or removing it. Appearing next to the
/// list — not replacing it — is what says "you are somewhere else now."
/// Display-only: the searcher panel stays key and feeds keys in. Every
/// action leads with the keycap that fires it, and chains are drawn as
/// keycaps too — a chain is keys, so it should look like keys.
final class GraphMenu {
    struct Item {
        let keycap: String
        let title: String
        /// The chain a remove targets, drawn as keycaps after the title.
        let chain: [String]
    }

    enum Content {
        case items([Item], selected: Int, error: String?)
        case chain(letters: [String], verdict: String, problem: Bool)
    }

    private let panel = Glass.makePanel(level: .modalPanel)
    private let root = NSView()
    private var content: NSView?

    init() {
        panel.ignoresMouseEvents = true
        panel.contentView = root
        Glass.installBackdrop(in: root, cornerRadius: 14)
    }

    /// Show `content` beside the searcher, top-aligned with the app's row
    /// so the card visibly belongs to it. Flips to the panel's left edge
    /// when the screen runs out on the right.
    func present(_ content: Content, appName: String, besideRow rowFrame: NSRect, panelFrame: NSRect) {
        build(content, appName: appName)
        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        size.width = max(size.width, 210)

        let visible = ActivePolicy.presentationFrame
        var x = panelFrame.maxX + 12
        if x + size.width > visible.maxX - 8 {
            x = panelFrame.minX - size.width - 12
        }
        let y = max(visible.minY + 8, min(rowFrame.maxY - size.height,
                                          visible.maxY - size.height - 8))
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    // MARK: - Construction

    private func build(_ content: Content, appName: String) {
        self.content?.removeFromSuperview()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch content {
        case .items(let items, let selected, let error):
            stack.addArrangedSubview(label(appName, font: BarTheme.secondaryFont, color: .secondaryLabelColor))
            for (index, item) in items.enumerated() {
                let row = actionRow(item, selected: index == selected)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            if let error {
                stack.addArrangedSubview(label("✕ \(error)", font: BarTheme.secondaryFont, color: .labelColor))
            }
            stack.addArrangedSubview(label("↵ select    esc back", font: BarTheme.footerFont, color: .tertiaryLabelColor))

        case .chain(let letters, let verdict, let problem):
            stack.addArrangedSubview(label("Add \(appName) to graph", font: BarTheme.secondaryFont, color: .secondaryLabelColor))
            let chainRow = NSStackView()
            chainRow.orientation = .horizontal
            chainRow.spacing = 5
            if letters.isEmpty {
                chainRow.addArrangedSubview(label("type letters…", font: BarTheme.titleFont, color: .tertiaryLabelColor))
            } else {
                chainRow.addArrangedSubview(label("lode", font: BarTheme.chipFont, color: .secondaryLabelColor))
                for letter in letters {
                    chainRow.addArrangedSubview(keycap(letter))
                }
            }
            stack.addArrangedSubview(chainRow)
            let verdictLabel = label("\(problem ? "✕" : "↵") \(verdict)",
                                     font: BarTheme.secondaryFont,
                                     color: problem ? .labelColor : .secondaryLabelColor)
            verdictLabel.lineBreakMode = .byTruncatingTail
            verdictLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            stack.addArrangedSubview(verdictLabel)
            stack.addArrangedSubview(label("⌫ back up    esc back", font: BarTheme.footerFont, color: .tertiaryLabelColor))
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -11),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
        ])
        self.content = stack
    }

    private func actionRow(_ item: Item, selected: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        if selected {
            container.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(keycap(item.keycap, inverted: selected))
        stack.addArrangedSubview(label(item.title, font: .systemFont(ofSize: 14),
                                       color: selected ? .white : .labelColor))
        if !item.chain.isEmpty {
            stack.addArrangedSubview(label("lode", font: BarTheme.chipFont,
                                           color: selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor))
            for letter in item.chain {
                stack.addArrangedSubview(keycap(letter, inverted: selected))
            }
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    /// A bordered square that reads as a key on a keyboard — the border is
    /// what separates "press this" from the searcher's informational chips.
    private func keycap(_ text: String, inverted: Bool = false) -> NSView {
        let cap = NSTextField(labelWithString: text.uppercased())
        cap.font = BarTheme.chipFont
        cap.alignment = .center
        cap.textColor = inverted ? .white : .labelColor
        cap.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        box.layer?.borderWidth = 1
        box.layer?.borderColor = (inverted ? NSColor.white.withAlphaComponent(0.55)
                                           : NSColor.labelColor.withAlphaComponent(0.35)).cgColor
        box.layer?.backgroundColor = (inverted ? NSColor.white.withAlphaComponent(0.16)
                                               : NSColor.labelColor.withAlphaComponent(0.06)).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(cap)
        // Exactly square: every cap is a single glyph, and an inequality
        // here leaves the width ambiguous — stack fitting can stretch it.
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 22),
            box.widthAnchor.constraint(equalTo: box.heightAnchor),
            cap.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            cap.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        return field
    }
}
