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
        /// Shown, not pressed: a quiet key, in its own case.
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

    private let panel = Ceramic.makePanel(level: .modalPanel)
    private let root = NSView()
    private var content: NSView?

    init() {
        // Fed by the bar's keys, never the mouse: the drawn shadow, gated
        // shut.
        SoftShadow.host(root, in: panel, cornerRadius: BarTheme.surfaceRadius, takesPointer: false)
        Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)
    }

    /// The card's frame on screen, so a second card can unfurl beside it.
    var frame: NSRect { panel.paneFrame }

    var isVisible: Bool { panel.isVisible }

    /// Show `content` at `anchor`, sized to itself.
    func present(_ content: Content, anchor: Anchor) {
        build(content)
        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        panel.setPaneFrame(Self.place(size, anchor: anchor), display: true)
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
            x = panelFrame.maxX + Grid.part
            if x + size.width > visible.maxX - Grid.close {
                x = panelFrame.minX - size.width - Grid.part
            }
            topY = row.maxY
        case .card(let card, let panelFrame):
            // Outward from the bar, so a cascade walks away from it rather
            // than back across it.
            let rightward = card.midX >= panelFrame.midX
            x = rightward ? card.maxX + Grid.part : card.minX - size.width - Grid.part
            if rightward, x + size.width > visible.maxX - Grid.close {
                x = card.minX - size.width - Grid.part
            } else if !rightward, x < visible.minX + Grid.close {
                x = card.maxX + Grid.part
            }
            topY = card.maxY
        }
        let y = max(visible.minY + Grid.close, min(topY - size.height,
                                          visible.maxY - size.height - Grid.close))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Construction

    private func build(_ content: Content) {
        self.content?.removeFromSuperview()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Grid.close
        stack.translatesAutoresizingMaskIntoConstraints = false

        /// What is not a line (a header, a note, a footer) stands where a
        /// line's words do: 12 inside the line, which is 8 inside the card.
        func addWords(_ view: NSView) {
            let holder = NSStackView(views: [view])
            holder.orientation = .horizontal
            holder.edgeInsets = NSEdgeInsets(top: 0, left: Grid.part, bottom: 0, right: Grid.part)
            holder.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(holder)
        }
        /// Lines of one menu touch.
        func addLines(_ items: [Item]) {
            guard !items.isEmpty else { return }
            let lines = NSStackView()
            lines.orientation = .vertical
            lines.alignment = .leading
            lines.spacing = 0
            lines.translatesAutoresizingMaskIntoConstraints = false
            for item in items {
                let line = actionRow(item)
                lines.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(lines)
            lines.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        switch content {
        case .items(let menu):
            // A row's actions carry no app name: the card is top-aligned
            // with the row it belongs to and that row is lit, so naming it
            // again is furniture. A field's values do get a header — nothing
            // else on screen says which field they belong to.
            if let header = menu.header {
                addWords(label(header, role: .meta, color: BarTheme.secondaryColor))
            }
            addLines(menu.items)
            if let error = menu.error {
                addWords(label("✕ \(error)", role: .meta, color: BarTheme.ink))
            }
            if let note = menu.note {
                let noteLabel = label(note, role: .meta, color: BarTheme.secondaryColor)
                noteLabel.lineBreakMode = .byTruncatingTail
                noteLabel.widthAnchor.constraint(lessThanOrEqualToConstant: BarTheme.measure).isActive = true
                addWords(noteLabel)
            }
            if let footer = menu.footer {
                addWords(Self.footerLine(footer))
            }

        case .typing(let typing):
            addWords(label(typing.header, role: .meta, color: BarTheme.secondaryColor))
            let bodyRow = NSStackView()
            bodyRow.orientation = .horizontal
            bodyRow.alignment = .centerY
            bodyRow.spacing = Grid.tight
            switch typing.body {
            case .keys(let letters):
                if letters.isEmpty {
                    bodyRow.addArrangedSubview(label("type letters", role: .title,
                                                     color: BarTheme.secondaryColor))
                } else {
                    // What was typed is a sequence: lode, then a key for each
                    // keystroke, 4 apart.
                    bodyRow.addArrangedSubview(keycap("lode", quiet: true))
                    for letter in letters {
                        bodyRow.addArrangedSubview(keycap(letter))
                    }
                }
            case .text(let text, let placeholder):
                // A name is one word you will type into the bar, so it is
                // shown as that word — keycaps would claim it is a chord.
                // What was typed is ink at the title's size; the placeholder is
                // Lodestar's and quiet.
                bodyRow.addArrangedSubview(label(text.isEmpty ? placeholder : text,
                                                 role: .title,
                                                 color: text.isEmpty ? BarTheme.secondaryColor : BarTheme.ink))
            }
            addWords(bodyRow)
            let verdictLabel = label("\(typing.problem ? "✕" : "↵") \(typing.verdict)",
                                     role: .meta,
                                     color: typing.problem ? BarTheme.ink : BarTheme.secondaryColor)
            verdictLabel.lineBreakMode = .byTruncatingTail
            verdictLabel.widthAnchor.constraint(lessThanOrEqualToConstant: BarTheme.measure).isActive = true
            addWords(verdictLabel)
            if let control = typing.control { addLines([control]) }
            if let detail = typing.detail {
                let detailLabel = label(detail, role: .meta,
                                        color: BarTheme.secondaryColor)
                detailLabel.lineBreakMode = .byTruncatingTail
                detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: BarTheme.measure).isActive = true
                addWords(detailLabel)
            }
            addWords(Self.footerLine(typing.footer))
        }

        // The lines stand 8 inside the card, and a card of words as far as a
        // line's words stand in; a long name is cut at the tail, never grows the
        // card past a sentence's measure.
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: BarTheme.lineInset),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -BarTheme.lineInset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: BarTheme.lineInset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -BarTheme.lineInset),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: BarTheme.measure),
        ])
        self.content = stack
    }

    /// A line of the row contract (`ListLine`): a symbol, the name cut at the
    /// tail, and the key that fires it at the end, the keys that only say
    /// something (a chain, a browser) quiet before it, 8 apart. Nothing is
    /// highlighted: every action here is fired by the key it shows, so a
    /// selection would only be a second way to mean the same thing.
    private func actionRow(_ item: Item) -> NSView {
        let line = ListLine(frame: .zero)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: BarTheme.lineHeight).isActive = true
        // Told by its place under the rule, never painted.
        line.setLead(ListLine.symbol(item.symbol))
        line.label.stringValue = item.title
        var trailing: [NSView] = []
        if let detail = item.detail { trailing.append(keycap(detail, quiet: true)) }
        // Several bindings carry the same title and differ only by chain, so
        // the chain travels with the title it distinguishes: a sequence, quiet,
        // before the one key you press, which stands last.
        if !item.chain.isEmpty { trailing.append(KeyStrokes(item.chain, quiet: true)) }
        trailing.append(keycap(item.keycap))
        line.setTrailing(trailing)
        return line
    }

    /// The one key, as typed: lowercase for a bare keystroke. Quiet where it
    /// is shown, not pressed.
    private func keycap(_ text: String, quiet: Bool = false) -> Key {
        Key(text, state: quiet ? .quiet : .resting)
    }

    /// A footer's keys, drawn as keys. Footers arrive as "key verb" pairs
    /// four spaces apart ("⌫ back up    esc back"), the form the menus have
    /// always written; the key is the first word of each, and the rest is
    /// what it does.
    static func footerLine(_ text: String) -> NSView {
        let gestures = text.components(separatedBy: "    ").compactMap { part -> Keycaps.Gesture? in
            let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard let key = words.first else { return nil }
            return Keycaps.Gesture([String(key)], words.count > 1 ? String(words[1]) : "")
        }
        return Keycaps.line(gestures)
    }

    private func label(_ text: String, role: BarTheme.Role, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setRole(role)
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
                                        verdict: "adds lode e o",
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
