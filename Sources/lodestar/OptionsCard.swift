import AppKit
import LodestarCore

/// The ⌘K card: a small glass panel floating beside a bar — the searcher's
/// graph card, the web bar's quick-link card, and whatever comes next.
/// Appearing next to the list — not replacing it — is what says "you are
/// somewhere else now." Display-only: the bar's panel stays key and feeds
/// keys in. Rows are the clipboard menu's rows — icon, name, then the key
/// that fires them — and a chain is drawn as keycaps, because a chain is
/// keys, while a name is drawn as the word it is.
final class OptionsCard {
    struct Item {
        let keycap: String
        let title: String
        /// Recognised before it is read, as in the clipboard's menu.
        let symbol: String
        /// Drawn in red, for the same reason the clipboard's Delete is.
        var isDestructive = false
        /// The chain a remove targets, drawn as keycaps beside the key.
        var chain: [String] = []
        /// A word that qualifies the row — the browser a profile belongs to.
        /// A chip, not a keycap: it is read, not pressed, so it keeps its
        /// own case instead of being shouted in caps.
        var detail: String?
    }

    /// A list of keyed rows: a row's actions, or the values of one field.
    struct Menu {
        /// Names what the list is for. A row's actions need no header — the
        /// lit row beside the card already says whose they are — but a list
        /// of values for a field has to say which field.
        var header: String?
        var items: [Item] = []
        /// Something was asked for and denied. Wears a ✕.
        var error: String?
        /// Nothing was asked for; this is what the card would need. Quiet,
        /// and never a ✕ — pressing a key is not a mistake.
        var note: String?
        var footer: String?
    }

    /// Something being typed into the card. One layout for both, because
    /// the shape is the same question — here is what you have so far, here
    /// is what ⏎ would do with it.
    struct Typing {
        enum Body {
            /// A graph chain: keys, drawn as keycaps.
            case keys([String])
            /// A link's name: a word, drawn as a word.
            case text(String, placeholder: String)
        }

        let header: String
        let body: Body
        /// What ⏎ commits, or why it can't.
        let verdict: String
        var problem = false
        /// A setting this card carries, drawn as a row like any other keyed
        /// row: its label, its current value, and the key that changes it.
        /// A footer hint would say the same words, but nothing about them
        /// would look like a control.
        var control: Item?
        /// A quieter line — where the destination opens, and why there.
        var detail: String?
        let footer: String
    }

    enum Content {
        case items(Menu)
        case typing(Typing)
    }

    /// Where the card unfurls from.
    enum Anchor {
        /// Beside a bar, top-aligned with the row it belongs to.
        case row(NSRect, panel: NSRect)
        /// Beside another card, top edges level — one column further out,
        /// the way the clipboard's pin menu unfurls, and away from the bar
        /// so it never lands back on top of it.
        case card(NSRect, panel: NSRect)
    }

    private let panel = Glass.makePanel(level: .modalPanel)
    private let root = NSView()
    private var content: NSView?

    init() {
        panel.ignoresMouseEvents = true
        panel.contentView = root
        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
    }

    /// The card's frame on screen, so a second card can unfurl beside it.
    var frame: NSRect { panel.frame }

    var isVisible: Bool { panel.isVisible }

    /// Show `content` at `anchor`, sized to itself.
    func present(_ content: Content, anchor: Anchor) {
        build(content)
        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        size.width = max(size.width, 210)
        panel.setFrame(Self.place(size, anchor: anchor), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Beside its anchor, never off screen. Flips to the other side when the
    /// screen runs out, and clamps vertically rather than hanging off.
    private static func place(_ size: NSSize, anchor: Anchor) -> NSRect {
        let visible = ActivePolicy.presentationFrame
        var x: CGFloat
        let topY: CGFloat
        switch anchor {
        case .row(let row, let panelFrame):
            x = panelFrame.maxX + 12
            if x + size.width > visible.maxX - 8 {
                x = panelFrame.minX - size.width - 12
            }
            topY = row.maxY
        case .card(let card, let panelFrame):
            // Outward from the bar, so a cascade walks away from it rather
            // than back across it.
            let rightward = card.midX >= panelFrame.midX
            x = rightward ? card.maxX + 12 : card.minX - size.width - 12
            if rightward, x + size.width > visible.maxX - 8 {
                x = card.minX - size.width - 12
            } else if !rightward, x < visible.minX + 8 {
                x = card.maxX + 12
            }
            topY = card.maxY
        }
        let y = max(visible.minY + 8, min(topY - size.height,
                                          visible.maxY - size.height - 8))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Construction

    private func build(_ content: Content) {
        self.content?.removeFromSuperview()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch content {
        case .items(let menu):
            // A row's actions carry no app name: the card is top-aligned
            // with the row it belongs to and that row is lit, so naming it
            // again is furniture. A field's values do get a header — nothing
            // else on screen says which field they belong to.
            if let header = menu.header {
                stack.addArrangedSubview(label(header, font: BarTheme.secondaryFont,
                                               color: BarTheme.secondaryColor))
            }
            for item in menu.items {
                let row = actionRow(item)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            if let error = menu.error {
                stack.addArrangedSubview(label("✕ \(error)", font: BarTheme.secondaryFont,
                                               color: .labelColor))
            }
            if let note = menu.note {
                let noteLabel = label(note, font: BarTheme.secondaryFont, color: BarTheme.secondaryColor)
                noteLabel.lineBreakMode = .byTruncatingTail
                noteLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
                stack.addArrangedSubview(noteLabel)
            }
            if let footer = menu.footer {
                stack.addArrangedSubview(label(footer, font: BarTheme.footerFont,
                                               color: BarTheme.secondaryColor))
            }

        case .typing(let typing):
            stack.addArrangedSubview(label(typing.header, font: BarTheme.secondaryFont,
                                           color: BarTheme.secondaryColor))
            let bodyRow = NSStackView()
            bodyRow.orientation = .horizontal
            bodyRow.spacing = 5
            switch typing.body {
            case .keys(let letters):
                if letters.isEmpty {
                    bodyRow.addArrangedSubview(label("type letters", font: BarTheme.titleFont,
                                                     color: BarTheme.secondaryColor))
                } else {
                    bodyRow.addArrangedSubview(label("lode", font: BarTheme.chipFont,
                                                     color: BarTheme.secondaryColor))
                    for letter in letters {
                        bodyRow.addArrangedSubview(keycap(letter))
                    }
                }
            case .text(let text, let placeholder):
                // A name is one word you will type into the bar, so it is
                // shown as that word — keycaps would claim it is a chord.
                bodyRow.addArrangedSubview(label(text.isEmpty ? placeholder : text,
                                                 font: BarTheme.titleFont,
                                                 color: text.isEmpty ? BarTheme.secondaryColor : .labelColor))
            }
            stack.addArrangedSubview(bodyRow)
            let verdictLabel = label("\(typing.problem ? "✕" : "↵") \(typing.verdict)",
                                     font: BarTheme.secondaryFont,
                                     color: typing.problem ? .labelColor : BarTheme.secondaryColor)
            verdictLabel.lineBreakMode = .byTruncatingTail
            verdictLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            stack.addArrangedSubview(verdictLabel)
            if let control = typing.control {
                let row = actionRow(control)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            if let detail = typing.detail {
                let detailLabel = label(detail, font: BarTheme.secondaryFont,
                                        color: BarTheme.secondaryColor)
                detailLabel.lineBreakMode = .byTruncatingTail
                detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
                stack.addArrangedSubview(detailLabel)
            }
            stack.addArrangedSubview(label(typing.footer, font: BarTheme.footerFont,
                                           color: BarTheme.secondaryColor))
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

        let tint: NSColor = item.isDestructive ? .systemRed : .labelColor
        let icon = NSImageView(image: NSImage(
            systemSymbolName: item.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage())
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: BarTheme.rowIcon),
            icon.heightAnchor.constraint(equalToConstant: BarTheme.rowIcon),
        ])

        let title = label(item.title, font: BarTheme.rowLabelFont, color: tint)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.widthAnchor.constraint(
            greaterThanOrEqualToConstant: BarTheme.rowKeyGap).isActive = true

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        if let detail = item.detail {
            stack.addArrangedSubview(keycap(detail, quiet: true, caps: false))
        }
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
    private func keycap(_ text: String, quiet: Bool = false, caps: Bool = true) -> NSView {
        let cap = NSTextField(labelWithString: caps ? text.uppercased() : text)
        cap.font = BarTheme.chipFont
        cap.alignment = .center
        cap.textColor = quiet ? BarTheme.secondaryColor : .labelColor
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
/// Visual harness for the ⌘K cards, which otherwise need a bar and the whole
/// app index standing behind them.
extension OptionsCard {
    static func preview(_ which: Int) -> [OptionsCard] {
        let card = OptionsCard()
        let panel = NSRect(x: 300, y: 300, width: 640, height: 420)
        let row = NSRect(x: 300, y: 620, width: 640, height: 48)
        let anchor = Anchor.row(row, panel: panel)
        switch which {
        case 1:
            card.present(.items(Menu(items: [Item(keycap: "d", title: "Remove from graph",
                                                  symbol: "minus.circle", isDestructive: true)])),
                         anchor: anchor)
        case 2:
            card.present(.items(Menu(items: [Item(keycap: "a", title: "Add to graph",
                                                  symbol: "plus.circle")])), anchor: anchor)
        case 4:
            card.present(.typing(Typing(header: "Add Microsoft Outlook to graph",
                                        body: .keys(["e", "o"]),
                                        verdict: "adds lode E O",
                                        footer: "⌫ back up    esc back")), anchor: anchor)
        case 5:
            // The web bar's pair, cascading: the name being typed, with its
            // profile row, and the value list one column further out.
            card.present(.typing(Typing(header: "Add a link",
                                        body: .text("yt", placeholder: "type a name"),
                                        verdict: "add lode ⏎ yt → https://youtube.com",
                                        control: Item(keycap: "⇥", title: "Profile",
                                                      symbol: "person.crop.circle.dashed",
                                                      detail: "Inherit"),
                                        detail: "opens in Google · route · youtube",
                                        footer: "⌫ back up    esc back")),
                         anchor: anchor)
            let profiles = OptionsCard()
            profiles.present(.items(Menu(
                header: "Opens in",
                items: [
                    Item(keycap: "0", title: "Inherit", symbol: "checkmark.circle.fill",
                         detail: "Google · route"),
                    Item(keycap: "1", title: "google", symbol: "circle", detail: "Brave"),
                    Item(keycap: "2", title: "work", symbol: "circle", detail: "Chrome"),
                ],
                footer: "⇥ back    esc cancel"
            )), anchor: .card(card.frame, panel: panel))
            return [card, profiles]
        case 6:
            // A search row's card — one promotion offered, one explained
            // away — beside the route it composes.
            card.present(.items(Menu(
                items: [Item(keycap: "r", title: "Route this search",
                             symbol: "arrow.triangle.branch")],
                note: "routes match what you type, so there is nothing to name"
            )), anchor: anchor)
            let route = OptionsCard()
            route.present(.typing(Typing(header: "Route by pattern",
                                         body: .text("acme", placeholder: "type a pattern"),
                                         verdict: "anything matching acme opens in work",
                                         control: Item(keycap: "⇥", title: "Profile",
                                                       symbol: "person.crop.circle.fill",
                                                       detail: "work"),
                                         detail: "Work · Chrome",
                                         footer: "⌫ back up    esc back")),
                          anchor: .card(card.frame, panel: panel))
            return [card, route]
        default:
            card.present(.items(Menu(items: [
                Item(keycap: "1", title: "Remove from graph", symbol: "minus.circle",
                     isDestructive: true, chain: ["e", "o"]),
                Item(keycap: "2", title: "Remove from graph", symbol: "minus.circle",
                     isDestructive: true, chain: ["m"]),
            ])), anchor: anchor)
        }
        return [card]
    }
}
#endif
