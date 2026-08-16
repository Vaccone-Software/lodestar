import AppKit
import LodestarCore

/// The walkthrough: one card per tool, in the order the tools build on each
/// other.
///
/// Lodestar changes nothing until it is summoned, which is exactly why a new
/// user can keep it and exactly why they might never find it. So this hands
/// over the vocabulary and then stops, because after that the app teaches
/// itself through guides, chips and the cheat sheet.
///
/// Three decisions shape it. A card is **named for its tool** and opens by
/// saying what that tool is, in the plainest sentence available; no card
/// explains when to reach for one, because somebody who knows what the graph
/// is can work that out and nobody enjoys being told. The **secondary keys sit
/// on a second card** beside the first, so a definition is never crowded by a
/// key table. And a card **never leaves**: where a tool cannot be understood
/// from a sentence — the clipboard's home row, the way the graph branches —
/// the card draws it, at the real geometry, rather than opening the real panel
/// and taking the reader somewhere else.
final class OnboardingController: NSObject {
    var onFinished: (() -> Void)?
    /// Accept the drafted graph. An error string, or nil on success.
    var acceptGraph: ([StarterGraph.Proposal]) -> String? = { _ in "the graph is unavailable" }
    var config = Config()

    enum Card: Int, CaseIterable {
        case permission, searcher, graph, breaths, inside, actions, clipboard, ask
    }

    private var card: Card = .permission
    private var proposals: [StarterGraph.Proposal] = []
    /// macOS shows its Accessibility prompt once per app. After that the only
    /// way through is the settings pane, so the card offers that instead.
    private var prompted = false

    private static let cardWidth: CGFloat = 560
    private static let inset: CGFloat = 30
    private static let minimumHeight: CGFloat = 320
    /// Room kept clear at the foot of every card for the dots and the keys.
    private static let footerBand: CGFloat = 52
    private static let textWidth: CGFloat = 470
    private static let detailWidth: CGFloat = 272

    private var backdrops: [NSWindow] = []
    private let panel = Glass.makePanel(level: .modalPanel)
    private let root = NSView()
    private let detailPanel = Glass.makePanel(level: .modalPanel)
    private let detailRoot = NSView()
    private var trustPoll: Timer?

    override init() {
        super.init()
        panel.ignoresMouseEvents = true
        panel.contentView = root
        _ = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
        detailPanel.ignoresMouseEvents = true
        detailPanel.contentView = detailRoot
        _ = Glass.installBackdrop(in: detailRoot, cornerRadius: BarTheme.glassRadius)
    }

    // MARK: - Presentation

    var isVisible: Bool { !backdrops.isEmpty }

    func show() {
        guard backdrops.isEmpty else { return }
        card = .permission
        prompted = false
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.contentView = Backdrop(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            backdrops.append(window)
        }
        prepare()
        render()
        pollTrust()
    }

    func finish() {
        trustPoll?.invalidate(); trustPoll = nil
        panel.orderOut(nil)
        detailPanel.orderOut(nil)
        for window in backdrops { window.orderOut(nil) }
        backdrops = []
        onFinished?()
    }

    // MARK: - Keys

    /// Every key while the walkthrough owns the screen. Everything is
    /// swallowed except the modifier combinations that belong to macOS: a lode
    /// gesture that reached the engine summoned a window behind the card, and
    /// escape then closed that window instead of the walkthrough.
    func handle(key: String, held: Bool, shift: Bool, other: Bool) -> Bool {
        guard isVisible else { return false }

        if other {
            // ⇧⌘V is the one combination that is ours: it would lay the real
            // clipboard strip over the card.
            return key == "v" && shift
        }
        if key == "escape" {
            finish()
            return true
        }
        if key == "return", !held {
            advance()
            return true
        }
        if key == "delete" {
            // Backspace is back, except where there is something to unsay.
            if card == .graph, !proposals.isEmpty {
                proposals.removeLast()
                render()
            } else {
                back()
            }
            return true
        }
        if card == .permission, key == "space" {
            grantAccess()
            return true
        }
        return true
    }

    /// The system prompt first, because a permission you can grant from where
    /// you are standing is the whole point of asking. macOS only ever shows it
    /// once, so from the second press this opens the pane instead.
    private func grantAccess() {
        if !prompted, !Permissions.isTrusted {
            prompted = true
            _ = Permissions.requestIfNeeded()
            render()
            return
        }
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func back() {
        guard let previous = Card(rawValue: card.rawValue - 1) else { return }
        card = previous
        prepare()
        render()
    }

    private func advance() {
        if card == .graph, !proposals.isEmpty {
            if let problem = acceptGraph(proposals) { Log.error("onboarding", ["graph": problem]) }
            proposals = []
        }
        guard let next = Card(rawValue: card.rawValue + 1) else {
            finish()
            return
        }
        card = next
        prepare()
        render()
    }

    private func prepare() {
        guard card == .graph else { return }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        proposals = config.graph.children.isEmpty
            ? StarterGraph.propose(running: running, existing: config.graph,
                                   reserved: Config.reservedTopLevel)
            : []
    }

    private func pollTrust() {
        guard !Permissions.isTrusted else { return }
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, Permissions.isTrusted else { return }
            self.trustPoll?.invalidate(); self.trustPoll = nil
            if self.card == .permission { self.render() }
        }
    }

    // MARK: - Copy

    /// One gesture, and what to call it. A card with two tools on it needs the
    /// caption; a card with one does not.
    private struct KeyLine {
        var caps: [String]
        var caption: String?
    }

    private enum Detail {
        /// A heading, for a side card carrying two tools' keys.
        case group(String)
        /// One meaning, and every key that carries it. Separate caps, because
        /// `j k h l` in one cap reads as a sequence to type in order.
        case row([String], String)
        case note(String)
    }

    private enum Illustration {
        /// Their own graph, or the draft being offered.
        case graph([(path: [String], label: String)])
        case clipboard
    }

    private struct Content {
        /// The tool's name. Nothing else belongs in a title.
        var title: String
        /// What the thing **is**, before anything about how to work it.
        var definition: String
        var keys: [KeyLine] = []
        var illustration: Illustration?
        /// The side card: the keys that are not the way in.
        var detail: [Detail] = []
        var state: String?
        var stateIsGood = false
        var footer: String
    }

    private func content() -> Content {
        switch card {
        case .permission:
            let granted = Permissions.isTrusted
            return Content(
                title: "Accessibility",
                definition: "Lodestar needs one permission from macOS. Accessibility is what "
                    + "lets it see your windows, move them, and read the menus of the app you "
                    + "are in. It is the only permission it ever asks for.",
                keys: granted ? [] : [KeyLine(caps: ["space"],
                                              caption: prompted ? "open System Settings"
                                                                : "grant access")],
                state: granted ? "Granted" : "Not granted yet",
                stateIsGood: granted,
                footer: "↵ continue")
        case .searcher:
            return Content(
                title: "Searcher",
                definition: "Your apps, found by name. Type a few letters and press return. "
                    + "The app comes to the front, launching first if it was not running.",
                keys: [KeyLine(caps: ["lode", "space"])],
                detail: [.row(["↵"], "opens it full screen"),
                         .row(["⇧↵"], "opens it beside the window you are in"),
                         .row(["⌘K"], "options for the highlighted row")],
                footer: "↵ continue    ⌫ back")
        case .graph:
            return Content(
                title: "Graph",
                definition: "Letters that lead to apps. Hold lode, type the letters, and you "
                    + "are there. No list, no searching. One letter is usually enough. Where "
                    + "several apps want the same letter it branches, and the next letter chooses.",
                illustration: .graph(graphLines()),
                detail: [.row(["letter"], "goes there, full screen"),
                         .row(["⇧letter"], "opens it beside the window you are in"),
                         .row(["⌘K"], "in the searcher, gives that app a letter")],
                state: proposals.isEmpty ? nil : "Drafted from the apps you have open",
                footer: proposals.isEmpty
                    ? "↵ continue    ⌫ back"
                    : "↵ take these letters    ⌫ drop the last one")
        case .breaths:
            return Content(
                title: "Breaths",
                definition: "A saved arrangement of windows. Put the set you are working in "
                    + "under a letter: the apps, their positions, the display each one is on. "
                    + "One gesture brings all of it back.",
                keys: [KeyLine(caps: ["lode", "'"])],
                detail: [.row(["⇧letter"], "saves what is on screen now"),
                         .row(["letter"], "puts it back"),
                         .row(["⌫"], "arms delete, then type the letter")],
                footer: "↵ continue    ⌫ back")
        case .inside:
            return Content(
                title: "Hints and scrolling",
                definition: "Two ways to work the window you are already in. Hints put a "
                    + "letter on every button, link and field: type the letter to press it. "
                    + "Scroll mode moves the page from the home row.",
                keys: [KeyLine(caps: ["lode", ";"], caption: "hints"),
                       KeyLine(caps: ["lode", ","], caption: "scroll")],
                detail: [.group("HINTS"),
                         .row(["⇧label"], "right clicks it instead"),
                         .row(["⇧;"], "stays up after each click, for filling in a form"),
                         .group("SCROLL"),
                         .row(["j", "k", "h", "l"], "down, up, left, right. Hold to keep going"),
                         .row(["d", "u"], "half a page"),
                         .row(["gg", "⇧G"], "top and bottom")],
                footer: "↵ continue    ⌫ back")
        case .actions:
            return Content(
                title: "Action menu",
                definition: "Every menu command in the app you are in, searchable. Type what "
                    + "it is called, like Export or Zoom In, and press return to run it. You "
                    + "never have to remember which menu holds it.",
                keys: [KeyLine(caps: ["lode", "."])],
                footer: "↵ continue    ⌫ back")
        case .clipboard:
            return Content(
                title: "Clipboard",
                definition: "A history of everything you copy, laid out along the bottom of "
                    + "the screen under the home row: the newest clip on A, the one before it on "
                    + "S, and so on to the right. Press the letter to paste it.",
                keys: [KeyLine(caps: ["⇧⌘V"])],
                illustration: .clipboard,
                detail: [.row(["letter"], "pastes it as plain text"),
                         .row(["⇧letter"], "pastes it with its formatting"),
                         .row((1...Clipboard.pinSlots).map(String.init),
                              "the pins: a clip you keep, in a slot that never moves"),
                         .row(["⌘letter"], "pin, delete, or stop saving from that app"),
                         .row(["/"], "searches the history")],
                footer: "↵ continue    ⌫ back")
        case .ask:
            return Content(
                title: "Ask",
                definition: "Type a destination or a question. A saved name or a domain opens "
                    + "the page, anything else searches. Your routes decide which browser "
                    + "profile it opens in, so work links land in your work profile.",
                keys: [KeyLine(caps: ["lode", "⏎"])],
                detail: [.row(["⌘K"], "saves what you typed as a name, or routes it to a profile"),
                         .note("Make Lodestar your default browser and links clicked in any "
                               + "app take the same routes. Route Clicked Links, in the menu "
                               + "bar.")],
                footer: "↵ done    ⌫ back")
        }
    }

    /// Their graph, shallow, with a branch in it wherever they have one —
    /// because the branching is the part a sentence cannot carry. Falls back
    /// to the draft being offered, which is real too.
    private func graphLines(limit: Int = 4) -> [(path: [String], label: String)] {
        // Every proposal, not the first few: return writes all of them, and a
        // card that shows four of five is offering something it will not do.
        if !proposals.isEmpty {
            return proposals.map { (path: [$0.letter], label: $0.app) }
        }
        var branched: [(path: [String], label: String)] = []
        var flat: [(path: [String], label: String)] = []
        for letter in config.graph.children.keys.sorted() {
            guard let child = config.graph.children[letter] else { continue }
            if let target = child.target {
                flat.append((path: [letter], label: target.label))
            } else if branched.isEmpty {
                // The first branching letter, and only that one: two lines
                // sharing a first letter say what branching is; four say it
                // four times.
                for next in child.children.keys.sorted().prefix(2) {
                    guard let leaf = child.children[next], let target = leaf.target else { continue }
                    branched.append((path: [letter, next], label: target.label))
                }
            }
        }
        return Array((branched + flat).prefix(limit))
    }

    // MARK: - Drawing

    private func render() {
        for view in root.subviews where view is NSStackView { view.removeFromSuperview() }
        let content = content()

        // The body starts at the top of the card and the footer sits at its
        // foot. Centred, the sparse cards were a title floating in the middle
        // of an empty pane; anchored at both ends the slack reads as room.
        let stack = buildStack(content)
        let footer = buildFooter(content)
        root.addSubview(stack)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.inset),
        ])
        root.layoutSubtreeIfNeeded()

        // Both panels take the taller of the two. They read as one object, and
        // sized independently the side card was silently cropping its last
        // key — which is exactly the key nobody would then learn.
        let side = buildDetail(content.detail)
        let height = max(Self.minimumHeight,
                         stack.fittingSize.height + Self.inset * 2 + Self.footerBand,
                         (side?.fittingSize.height ?? 0) + Self.inset * 2 + 10)

        let visible = ActivePolicy.presentationFrame
        let gap: CGFloat = side == nil ? 0 : 14
        let sideWidth: CGFloat = side == nil ? 0 : Self.detailWidth
        let originX = visible.midX - (Self.cardWidth + gap + sideWidth) / 2
        let originY = visible.midY - height / 2 + 30
        panel.setFrame(NSRect(x: originX, y: originY,
                              width: Self.cardWidth, height: height), display: true)
        panel.orderFrontRegardless()

        guard side != nil else {
            detailPanel.orderOut(nil)
            return
        }
        detailPanel.setFrame(NSRect(x: originX + Self.cardWidth + gap, y: originY,
                                    width: sideWidth, height: height), display: true)
        detailPanel.orderFrontRegardless()
    }

    private func buildStack(_ content: Content) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = label(content.title, size: 25, weight: .semibold, color: .labelColor)
        stack.addArrangedSubview(title)
        let body = wrapped(content.definition, size: 14.5, color: .secondaryLabelColor)
        stack.addArrangedSubview(body)
        stack.setCustomSpacing(5, after: title)
        stack.setCustomSpacing(18, after: body)

        for line in content.keys {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            for cap in line.caps { row.addArrangedSubview(keycap(cap)) }
            if let caption = line.caption {
                let text = label(caption, size: 12.5, weight: .regular, color: .tertiaryLabelColor)
                row.addArrangedSubview(text)
                row.setCustomSpacing(11, after: row.arrangedSubviews[line.caps.count - 1])
            }
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(content.keys.count > 1 ? 7 : 16, after: row)
        }
        if content.keys.count > 1, let view = stack.arrangedSubviews.last {
            stack.setCustomSpacing(16, after: view)
        }

        if let illustration = content.illustration {
            let drawing = draw(illustration)
            stack.addArrangedSubview(drawing)
            stack.setCustomSpacing(18, after: drawing)
        }

        if let state = content.state {
            stack.addArrangedSubview(
                label(state, size: 12.5, weight: .medium,
                      color: content.stateIsGood ? .controlAccentColor : .tertiaryLabelColor))
        }
        return stack
    }

    private func buildFooter(_ content: Content) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(dots())
        stack.addArrangedSubview(label(content.footer, size: 11.5, weight: .regular,
                                       color: .tertiaryLabelColor))
        return stack
    }

    /// The side card: the keys that are not the way in, grouped where a card
    /// carries two tools so a key can never be read against the wrong one.
    /// Installed and measured here, positioned by the caller.
    private func buildDetail(_ rows: [Detail]) -> NSStackView? {
        detailRoot.subviews.filter { $0 is NSStackView }.forEach { $0.removeFromSuperview() }
        guard !rows.isEmpty else { return nil }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false

        for entry in rows {
            switch entry {
            case .group(let title):
                let heading = label(title, size: 9.5, weight: .semibold, color: .controlAccentColor)
                stack.addArrangedSubview(heading)
                stack.setCustomSpacing(7, after: heading)
            case .note(let text):
                if let previous = stack.arrangedSubviews.last {
                    stack.setCustomSpacing(17, after: previous)
                }
                stack.addArrangedSubview(wrappedSmall(text))
            case .row(let keys, let text):
                let caps = NSStackView()
                caps.orientation = .horizontal
                caps.spacing = 5
                for key in keys { caps.addArrangedSubview(keycap(key)) }
                let row = NSStackView()
                row.orientation = .vertical
                row.alignment = .leading
                row.spacing = 3
                row.addArrangedSubview(caps)
                row.addArrangedSubview(wrappedSmall(text))
                stack.addArrangedSubview(row)
            }
        }

        detailPanel.setFrame(NSRect(x: 0, y: 0, width: Self.detailWidth, height: 600),
                             display: false)
        detailRoot.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: detailRoot.topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: detailRoot.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: detailRoot.trailingAnchor,
                                            constant: -18),
        ])
        detailRoot.layoutSubtreeIfNeeded()
        return stack
    }
    // MARK: - Illustrations

    private func draw(_ illustration: Illustration) -> NSView {
        switch illustration {
        case .graph(let lines): return drawGraph(lines)
        case .clipboard: return drawClipboard()
        }
    }

    /// Each line is a real address: the keys, in order, and where they land.
    private func drawGraph(_ lines: [(path: [String], label: String)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        let depth = lines.map(\.path.count).max() ?? 1
        for line in lines {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            row.addArrangedSubview(keycap("lode", dim: true))
            for key in line.path { row.addArrangedSubview(keycap(key.uppercased())) }
            for _ in line.path.count..<depth { row.addArrangedSubview(gap(width: 27)) }
            let arrow = label("→", size: 12, weight: .regular, color: .quaternaryLabelColor)
            row.addArrangedSubview(arrow)
            row.setCustomSpacing(11, after: row.arrangedSubviews[depth])
            row.setCustomSpacing(11, after: arrow)
            row.addArrangedSubview(label(line.label, size: 13, weight: .regular,
                                         color: .secondaryLabelColor))
            stack.addArrangedSubview(row)
        }
        return stack
    }

    /// The strip's own geometry at a quarter scale: pins climbing the left
    /// edge from the corner, and the whole home row running right along the
    /// bottom, since that is the number of cards that will be there. Drawn rather than described because where a clip sits is the
    /// thing being taught, and drawn to the real proportions so that what is
    /// learned here is what appears later.
    private func drawClipboard() -> NSView {
        let cardW: CGFloat = 40, cardH: CGFloat = 24, gap: CGFloat = 2.5
        let letters = Clipboard.recentLabels.map { $0.uppercased() }
        let width = CGFloat(letters.count) * (cardW + gap) - gap
        let height = CGFloat(Clipboard.pinSlots + 1) * (cardH + gap) - gap

        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: height),
        ])

        func plate(_ text: String, faint: Bool) -> NSView {
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 5
            box.layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(faint ? 0.07 : 0.13).cgColor
            box.layer?.borderWidth = 1
            box.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            let chip = NSTextField(labelWithString: text)
            chip.font = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
            chip.textColor = faint ? .secondaryLabelColor : .labelColor
            chip.sizeToFit()
            chip.frame.origin = NSPoint(x: 5, y: cardH - chip.frame.height - 4)
            box.addSubview(chip)
            return box
        }

        for (index, letter) in letters.enumerated() {
            let card = plate(letter, faint: false)
            card.frame = NSRect(x: CGFloat(index) * (cardW + gap), y: 0,
                                width: cardW, height: cardH)
            view.addSubview(card)
        }
        for slot in 1...Clipboard.pinSlots {
            let card = plate("\(slot)", faint: true)
            card.frame = NSRect(x: 0, y: CGFloat(slot) * (cardH + gap),
                                width: cardW, height: cardH)
            view.addSubview(card)
        }
        return view
    }

    // MARK: - Pieces

    /// A hole the width of a keycap, so a column of addresses lines up.
    private func gap(width: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: width).isActive = true
        return spacer
    }

    private func dots() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 7
        for candidate in Card.allCases {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = candidate == card
                ? NSColor.controlAccentColor.cgColor
                : NSColor.labelColor.withAlphaComponent(
                    candidate.rawValue < card.rawValue ? 0.45 : 0.15).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            row.addArrangedSubview(dot)
        }
        return row
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func wrapped(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = label(text, size: size, weight: .regular, color: color)
        field.preferredMaxLayoutWidth = Self.textWidth
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    private func wrappedSmall(_ text: String) -> NSTextField {
        let field = label(text, size: 12, weight: .regular, color: .secondaryLabelColor)
        field.preferredMaxLayoutWidth = Self.detailWidth - 44
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    private func keycap(_ text: String, dim: Bool = false) -> NSView {
        let cap = NSTextField(labelWithString: text)
        cap.font = .systemFont(ofSize: 12.5, weight: .medium)
        cap.textColor = dim ? .secondaryLabelColor : .labelColor
        cap.alignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(dim ? 0.07 : 0.11).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            cap.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            cap.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 24),
        ])
        return box
    }
}

/// What sits behind the walkthrough: the desktop blurred past reading, a wash of
/// dark over it, and a sky. An earlier version drew one large mark instead and it
/// read as a decal pasted onto the desktop.
private final class Backdrop: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        let sky = Sky(frame: bounds)
        sky.autoresizingMask = [.width, .height]
        addSubview(sky)
    }

    required init?(coder: NSCoder) { nil }
}

private final class Sky: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.64).setFill()
        bounds.fill()

        // The one place colour belongs: a wash in the user's own accent behind
        // where the reading happens, so this is not another grey sheet.
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 30)
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        if let gradient = NSGradient(colors: [accent.withAlphaComponent(0.11),
                                              accent.withAlphaComponent(0.0)]) {
            gradient.draw(fromCenter: center, radius: 0,
                          toCenter: center, radius: bounds.width * 0.42, options: [])
        }

        var seed: UInt64 = 0x5EED_1ADE_5748
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % 100_000) / 100_000
        }

        for index in 0..<240 {
            let x = next() * bounds.width
            let y = next() * bounds.height
            let roll = next()
            // Thinned where the card sits: stars behind text are noise.
            if hypot(x - center.x, y - center.y) < 400, roll > 0.2 { continue }
            let size = roll > 0.95 ? 2.4 : (roll > 0.74 ? 1.7 : 1.1)
            let alpha = roll > 0.95 ? 0.32 : (roll > 0.74 ? 0.19 : 0.10)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
            if index.isMultiple(of: 41) {
                let reach = 6.0 + roll * 5
                NSColor.white.withAlphaComponent(0.13).setStroke()
                let spikes = NSBezierPath()
                spikes.lineWidth = 0.7
                spikes.move(to: NSPoint(x: x - reach, y: y))
                spikes.line(to: NSPoint(x: x + reach, y: y))
                spikes.move(to: NSPoint(x: x, y: y - reach))
                spikes.line(to: NSPoint(x: x, y: y + reach))
                spikes.stroke()
            }
        }
    }
}

#if DEBUG
/// Visual harness: every card, without a whole app or a state file that says the
/// walkthrough has not been seen.
extension OnboardingController {
    /// `empty` is the case that cannot be looked at otherwise: a machine with
    /// no graph, where the card offers a draft instead of showing theirs.
    static func preview(_ index: Int, empty: Bool = false) -> OnboardingController {
        let controller = OnboardingController()
        var (config, _) = Config.load()
        if empty { config.graph = GraphNode() }
        controller.config = config
        controller.show()
        controller.jump(to: index)
        return controller
    }

    func jump(to index: Int) {
        guard let target = Card(rawValue: index) else { return }
        card = target
        prepare()
        render()
    }
}
#endif
