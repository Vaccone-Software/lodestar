import AppKit
import LodestarCore

/// The web bar (`lode ⏎`): a second, deliberately separate grammar. Every
/// row here is a destination on the web — named links, bare domains routed
/// by pattern, anything else a search — and each row wears the profile it
/// will open in. ⌘K promotes the selected row: a domain becomes a named
/// link or a route, a link can be routed or removed, all written straight
/// into the config. Chromium family only for now.
final class WebBarController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    struct WebRow {
        enum Kind {
            case link, domain, search

            /// The state machine's own vocabulary for the same three things.
            var menuKind: WebMenu.RowKind {
                switch self {
                case .link: return .link
                case .domain: return .domain
                case .search: return .search
                }
            }
        }

        let kind: Kind
        let title: String
        /// The destination, ready to open: the scheme already added.
        let url: String
        /// What was typed, before normalizing — what a saved link stores, so
        /// the config keeps the line you would have written by hand.
        let raw: String
        /// The link's name, when this row is one: what a remove targets.
        var name: String?
        /// The link's pinned profile, when it has one.
        var pinnedProfileKey: String?
        let profile: BrowserProfile
    }

    private let panel: KeyablePanel
    private let root = NSView()
    private let field = NSTextField()
    private let globe = NSImageView()
    private let separator = NSBox()
    private let rowsStack = NSStackView()
    private let footer = NSTextField(labelWithString: "↵ open    ⇧↵ beside    esc close")

    /// Wired by the app delegate; refreshed on config reload.
    var config = Config()
    /// The profile of the most recently focused browser window, if any.
    var mostRecentProfile: () -> BrowserProfile? = { nil }
    var perform: (_ url: String, _ profile: BrowserProfile, _ beside: Bool,
                  _ row: String) -> Void = { _, _, _, _ in }
    /// The ⌘K writes. Each returns an error string, or nil on success.
    var addLink: (_ name: String, _ url: String, _ profileKey: String?) -> String? = { _, _, _ in
        "link editing is unavailable"
    }
    var removeLink: (_ name: String) -> String? = { _ in "link editing is unavailable" }
    var addRoute: (_ pattern: String, _ profileKey: String) -> String? = { _, _ in
        "route editing is unavailable"
    }
    var removeRoute: (_ pattern: String) -> String? = { _ in "route editing is unavailable" }

    private var rows: [WebRow] = []
    private var selected = 0
    /// Every decision the ⌘K card makes lives in Core, where it is tested.
    private var menu = WebMenu()
    private let card = OptionsCard()
    private let profileCard = OptionsCard()

    private let panelWidth = BarTheme.panelWidth
    private let inputHeight = BarTheme.inputHeight
    private let rowHeight = BarTheme.rowHeight
    private let footerHeight = BarTheme.footerHeight

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: inputHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.delegate = self
        panel.contentView = root
        panel.onKeyEquivalent = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }
        panel.onKeyDown = { [weak self] event in
            self?.handleMenuKey(event) ?? false
        }

        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)

        globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "web")
        globe.symbolConfiguration = BarTheme.inputSymbol
        globe.contentTintColor = .secondaryLabelColor
        globe.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = BarTheme.inputFont
        field.placeholderString = "Where on the web?"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        footer.font = BarTheme.footerFont
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(globe)
        root.addSubview(field)
        root.addSubview(separator)
        root.addSubview(rowsStack)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            globe.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            globe.centerYAnchor.constraint(equalTo: root.topAnchor, constant: inputHeight / 2),
            field.leadingAnchor.constraint(equalTo: globe.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            field.centerYAnchor.constraint(equalTo: root.topAnchor, constant: inputHeight / 2),
            separator.topAnchor.constraint(equalTo: root.topAnchor, constant: inputHeight),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            rowsStack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            rowsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            rowsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -7),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    /// How long the footer waits before painting — `SurfaceFade`'s
    /// verdict for this bar, set by the engine before each show.
    var footerDelay: () -> TimeInterval = { 0 }
    private let footerFade = FooterFade()

    func show() {
        closeMenu()
        field.stringValue = ""
        requery()
        footerFade.apply(to: footer, delay: footerDelay())
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(field)
    }

    func hide() {
        closeMenu()
        panel.orderOut(nil)
    }
    // MARK: - Resolution

    /// Everything resolution and the ⌘K card need from the config, rebuilt
    /// per query so a reload is picked up without wiring.
    private var context: WebContext {
        WebContext(config: config, mostRecent: mostRecentProfile())
    }

    private func resolveProfile(pinned: String?, routedOn text: String) -> BrowserProfile {
        context.resolve(pinned: pinned, routedOn: text).profile
    }

    private func requery() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        var built: [WebRow] = []

        let links = query.isEmpty
            ? config.webLinks
            : Fuzzy.rank(query: query, candidates: config.webLinks, key: { "\($0.name) \($0.url)" })
        for link in links.prefix(5) {
            built.append(WebRow(
                kind: .link,
                title: "\(link.name)  ·  \(link.url)",
                url: WebRouting.normalize(link.url),
                raw: link.url,
                name: link.name,
                pinnedProfileKey: link.profileKey,
                profile: resolveProfile(pinned: link.profileKey, routedOn: "\(link.name) \(link.url)")
            ))
        }
        if WebRouting.isDomainLike(query) {
            built.append(WebRow(
                kind: .domain,
                title: query,
                url: WebRouting.normalize(query),
                raw: query,
                profile: resolveProfile(pinned: nil, routedOn: query)
            ))
        }
        if !query.isEmpty {
            built.append(WebRow(
                kind: .search,
                title: "Search “\(query)”",
                url: WebRouting.searchURL(template: config.webSearchURL, query: query),
                raw: query,
                profile: resolveProfile(pinned: nil, routedOn: query)
            ))
        }

        rows = built
        selected = 0
        if HotkeyEngine.traceTap {
            // Shape, never content: which kinds of row the query produced and
            // where each would open. Enough to debug routing; not a record of
            // where you went, even behind the trace flag.
            let shape = rows.map { "\($0.kind)@\($0.profile.display)" }.joined(separator: " | ")
            Log.info("webbar: \(query.count) chars -> \(shape)")
        }
        renderRows()
        updateFooter()
        reposition()
    }

    /// The hint names what ⌘K would actually offer on this row, read off the
    /// same options the card would show — so it can never drift from them.
    /// Two verbs is the budget; a footer is a hint, not the menu.
    private func updateFooter() {
        var verbs = ""
        if let row = menuRow() {
            let words = menu.options(for: row, in: context).items.prefix(2).map(Self.verb)
            if !words.isEmpty { verbs = "    ⌘K " + words.joined(separator: " · ") }
        }
        footer.stringValue = "↵ open    ⇧↵ beside" + verbs + "    esc close"
    }

    private static func verb(_ item: WebMenu.Item) -> String {
        switch item.role {
        case .addLink: return "link"
        case .route: return "route"
        case .removeLink: return "remove"
        case .removeRoute: return "unroute"
        case .profile, .choice: return ""
        }
    }

    /// Row views are pooled and mutated — typing repaints, it never rebuilds.
    private var rowViews: [WebRowView] = []

    private func renderRows() {
        while rowViews.count < rows.count {
            let view = WebRowView(height: rowHeight)
            rowViews.append(view)
            rowsStack.addArrangedSubview(view)
        }
        for (index, view) in rowViews.enumerated() {
            if index < rows.count {
                view.isHidden = false
                view.configure(rows[index])
                view.setSelected(index == selected)
            } else {
                view.isHidden = true
            }
        }
    }

    private func reposition() {
        let count = CGFloat(rows.count)
        let rowsArea = count > 0 ? 1 + 8 + count * rowHeight + CGFloat(max(0, rows.count - 1)) * 2 + 6 : 0
        let height = inputHeight + rowsArea + footerHeight
        let visible = ActivePolicy.presentationFrame
        let origin = NSPoint(
            x: visible.midX - panelWidth / 2,
            y: visible.minY + visible.height * 0.64 - height
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: panelWidth, height: height)), display: true)
    }

    // MARK: - Keyboard

    func controlTextDidChange(_ notification: Notification) {
        requery()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // ⌃J/⌃K walk the list beside the arrows, and ⌃N/⌃P arrive here as
        // the arrows themselves — one policy, three panels.
        if let delta = ListKeys.delta(for: commandSelector,
                                      letter: NSApp.currentEvent?.charactersIgnoringModifiers,
                                      control: NSApp.currentEvent?.modifierFlags
                                          .contains(.control) ?? false) {
            moveSelection(delta)
            return true
        }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            pick(beside: shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + delta + rows.count) % rows.count
        renderRows()
        updateFooter()
    }

    private func pick(beside: Bool) {
        guard rows.indices.contains(selected) else { return }
        let row = rows[selected]
        hide()
        let kind: String
        switch row.kind {
        case .link: kind = "link"
        case .domain: kind = "domain"
        case .search: kind = "search"
        }
        perform(row.url, row.profile, beside, kind)
    }

    // MARK: - The ⌘K card

    /// ⌘K opens the card on the selected row; a second ⌘K (or esc) closes it.
    /// The state machine decides what is on offer and what each key does —
    /// this end translates keystrokes, draws what it returns, and performs
    /// the writes it asks for.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "k" else { return false }
        menu.toggle(on: menuRow(), in: context)
        renderMenu()
        return true
    }

    /// Every key while the card is open — the field never sees them, so the
    /// query underneath stays frozen. Runs before AppKit's dispatch, which is
    /// also what lets ⌘K toggle the card closed.
    private func handleMenuKey(_ event: NSEvent) -> Bool {
        guard menu.isOpen else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods == .command {
            if event.charactersIgnoringModifiers?.lowercased() == "k" { closeMenu() }
            return true
        }
        guard mods.isEmpty, let key = Self.menuKey(for: event) else { return true }
        perform(menu.handle(key, in: context))
        return true
    }

    /// AppKit keystroke → the card's own alphabet. Arrow keys land here as
    /// nil and are swallowed: the card has no selection to move.
    private static func menuKey(for event: NSEvent) -> WebMenu.Key? {
        switch event.keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 48: return .tab
        case 51: return .delete
        default:
            guard let typed = event.charactersIgnoringModifiers?.lowercased(),
                  let character = typed.first, typed.count == 1 else { return nil }
            return .character(character)
        }
    }

    /// The row the card acts on, in the state machine's terms.
    private func menuRow() -> WebMenu.Row? {
        guard rows.indices.contains(selected) else { return nil }
        let row = rows[selected]
        return WebMenu.Row(kind: row.kind.menuKind, raw: row.raw, name: row.name,
                           pinnedProfileKey: row.pinnedProfileKey)
    }

    /// Do what the card asked for. A write that fails puts its reason back on
    /// the card; one that lands closes it, and the bar redraws — the new row,
    /// or the missing one, is the receipt.
    private func perform(_ effect: WebMenu.Effect) {
        let failure: String?
        switch effect {
        case .nothing:
            renderMenu()
            return
        case .dismissed:
            closeMenu()
            return
        case .addLink(let name, let url, let profileKey):
            failure = addLink(name, url, profileKey)
        case .removeLink(let name):
            failure = removeLink(name)
        case .addRoute(let pattern, let profileKey):
            failure = addRoute(pattern, profileKey)
        case .removeRoute(let pattern):
            failure = removeRoute(pattern)
        }
        if let failure {
            menu.failed(failure)
            renderMenu()
        } else {
            closeMenu()
            requery()
        }
    }

    private func closeMenu() {
        menu.close()
        profileCard.hide()
        card.hide()
    }

    // MARK: - Card rendering

    private func renderMenu() {
        let rendering = menu.rendering(in: context)
        let anchor = OptionsCard.Anchor.row(selectedRowScreenFrame(), panel: panel.frame)

        if let options = rendering.options {
            card.present(.items(OptionsCard.Menu(
                items: options.items.map(Self.item),
                error: options.error,
                note: options.note
            )), anchor: anchor)
        } else if let compose = rendering.compose {
            card.present(.typing(OptionsCard.Typing(
                header: compose.header,
                body: .text(compose.text, placeholder: compose.placeholder),
                verdict: compose.verdict,
                problem: compose.problem,
                control: compose.control.map(Self.item),
                detail: compose.detail,
                footer: compose.footer
            )), anchor: anchor)
        } else {
            card.hide()
        }

        if let profiles = rendering.profiles {
            profileCard.present(.items(OptionsCard.Menu(
                header: profiles.header,
                items: profiles.items.map(Self.item),
                footer: profiles.footer
            )), anchor: .card(card.frame, panel: panel.frame))
        } else {
            profileCard.hide()
        }
    }

    /// The card's own vocabulary of roles, given symbols here — the state
    /// machine names what a row *is*, and only this end knows what that looks
    /// like.
    private static func item(_ item: WebMenu.Item) -> OptionsCard.Item {
        let symbol: String
        switch item.role {
        case .addLink: symbol = "link.badge.plus"
        case .route: symbol = "arrow.triangle.branch"
        case .removeLink, .removeRoute: symbol = "minus.circle"
        case .profile(let pinned):
            symbol = pinned ? "person.crop.circle.fill" : "person.crop.circle.dashed"
        case .choice(let selected):
            symbol = selected ? "checkmark.circle.fill" : "circle"
        }
        return OptionsCard.Item(keycap: item.key, title: item.title, symbol: symbol,
                                isDestructive: item.role.isDestructive, detail: item.detail)
    }

    private func selectedRowScreenFrame() -> NSRect {
        guard rowViews.indices.contains(selected), !rowViews[selected].isHidden else {
            return panel.frame
        }
        let view = rowViews[selected]
        return panel.convertToScreen(view.convert(view.bounds, to: nil))
    }
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

/// One reusable web-bar row: symbol, destination, profile chip.
private final class WebRowView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let chipLabel = NSTextField(labelWithString: "")
    private let chip = NSView()
    private var kind: WebBarController.WebRow.Kind?
    private var selectedState = false

    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        wantsLayer = true
        layer?.cornerRadius = BarTheme.rowRadius

        icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false

        title.font = BarTheme.titleFont
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        chipLabel.font = BarTheme.chipFont
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = BarTheme.chipRadius
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipLabel)

        addSubview(icon)
        addSubview(title)
        addSubview(chip)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            chipLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2),
            chipLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -12),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: WebBarController.WebRow) {
        if kind != row.kind {
            kind = row.kind
            let symbol: String
            switch row.kind {
            case .link: symbol = "link"
            case .domain: symbol = "globe"
            case .search: symbol = "magnifyingglass"
            }
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if title.stringValue != row.title { title.stringValue = row.title }
        if chipLabel.stringValue != row.profile.display { chipLabel.stringValue = row.profile.display }
    }

    func setSelected(_ selected: Bool) {
        guard selected != selectedState else { return }
        selectedState = selected
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = selectedState ? NSColor.controlAccentColor.cgColor : nil
        icon.contentTintColor = selectedState ? .white : .secondaryLabelColor
        title.textColor = selectedState ? .white : .labelColor
        chipLabel.textColor = selectedState ? .white : .secondaryLabelColor
        chip.layer?.backgroundColor = selectedState
            ? NSColor.white.withAlphaComponent(0.22).cgColor
            : NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
}

#if DEBUG
/// Visual harness: the real bar, with a query already typed. In this file
/// because `field` and `requery` are private to it, and the harness must use
/// the real input path rather than a second one that can drift.
extension WebBarController {
    static func preview(query: String, config: Config) -> WebBarController {
        let bar = WebBarController()
        bar.config = config
        bar.show()
        bar.field.stringValue = query
        // Setting the value selects it, and a highlighted query reads as
        // something the user is about to replace rather than something typed.
        bar.field.currentEditor()?.selectedRange = NSRange(location: query.count, length: 0)
        bar.requery()
        return bar
    }
}
#endif
