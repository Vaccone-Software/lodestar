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
        /// Recognised before it is read, as in the clipboard's menu.
        let symbol: String
        /// The chain a remove targets, drawn as keycaps beside the key.
        let chain: [String]
    }

    enum Content {
        case items([Item], error: String?)
        case chain(letters: [String], verdict: String, problem: Bool)
    }

    private let panel = Glass.makePanel(level: .modalPanel)
    private let root = NSView()
    private var content: NSView?

    init() {
        panel.ignoresMouseEvents = true
        panel.contentView = root
        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
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
        case .items(let items, let error):
            // No app name: the card is top-aligned with the row it belongs
            // to and that row is lit, so naming the app again is furniture.
            for item in items {
                let row = actionRow(item)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            if let error {
                stack.addArrangedSubview(label("✕ \(error)", font: BarTheme.secondaryFont, color: .labelColor))
            }
            stack.addArrangedSubview(label("esc back", font: BarTheme.footerFont, color: .tertiaryLabelColor))

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

    /// Icon, name, then key — the clipboard menu's row exactly. Nothing is
    /// highlighted: every action here is fired by the key it shows, so a
    /// selection would only be a second way to mean the same thing.
    private func actionRow(_ item: Item) -> NSView {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = BarTheme.rowGap
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(
            systemSymbolName: item.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage())
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: BarTheme.rowIcon),
            icon.heightAnchor.constraint(equalToConstant: BarTheme.rowIcon),
        ])

        let title = label(item.title, font: BarTheme.rowLabelFont, color: .labelColor)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.widthAnchor.constraint(
            greaterThanOrEqualToConstant: BarTheme.rowKeyGap).isActive = true

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        // Several bindings carry the same title and differ only by chain, so
        // the chain travels with the title it distinguishes. Only the key
        // you press sits at the trailing edge — beside it the chain would
        // read as one run of chips and hide which one is pressable.
        for letter in item.chain {
            stack.addArrangedSubview(keycap(letter, quiet: true))
        }
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(keycap(item.keycap))

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    /// The chip every other surface draws. It used to wear a border here, to
    /// separate "press this" from the searcher's informational chips — but
    /// the guides and the clipboard's menu now draw the pressable key flat
    /// too, so the border was the one thing out of step.
    private func keycap(_ text: String, quiet: Bool = false) -> NSView {
        let cap = NSTextField(labelWithString: text.uppercased())
        cap.font = BarTheme.chipFont
        cap.alignment = .center
        cap.textColor = quiet ? .tertiaryLabelColor : .secondaryLabelColor
        cap.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = BarTheme.chipRadius
        box.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(quiet ? 0.05 : 0.09).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: BarTheme.chipPadX),
            cap.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -BarTheme.chipPadX),
            cap.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: BarTheme.chipHeight),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: BarTheme.chipMinWidth),
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

#if DEBUG
/// Visual harness for the ⌘K graph card, which otherwise needs the searcher
/// and the whole app index standing behind it.
extension GraphMenu {
    static func preview(_ which: Int) -> GraphMenu {
        let menu = GraphMenu()
        let panel = NSRect(x: 300, y: 300, width: 640, height: 420)
        let row = NSRect(x: 300, y: 620, width: 640, height: 48)
        switch which {
        case 1:
            menu.present(.items([Item(keycap: "d", title: "Remove from graph",
                                      symbol: "minus.circle", chain: [])], error: nil),
                         appName: "Ghostty", besideRow: row, panelFrame: panel)
        case 2:
            menu.present(.items([Item(keycap: "a", title: "Add to graph",
                                      symbol: "plus.circle", chain: [])], error: nil),
                         appName: "Linear", besideRow: row, panelFrame: panel)
        case 4:
            menu.present(.chain(letters: ["e", "o"], verdict: "adds lode E O", problem: false),
                         appName: "Microsoft Outlook", besideRow: row, panelFrame: panel)
        default:
            menu.present(.items([Item(keycap: "1", title: "Remove from graph",
                                      symbol: "minus.circle", chain: ["e", "o"]),
                                 Item(keycap: "2", title: "Remove from graph",
                                      symbol: "minus.circle", chain: ["m"])], error: nil),
                         appName: "Microsoft Outlook", besideRow: row, panelFrame: panel)
        }
        return menu
    }
}
#endif
