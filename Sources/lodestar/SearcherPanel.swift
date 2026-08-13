import AppKit
import LodestarCore

/// The entry point: a floating fuzzy searcher, styled like it belongs to the
/// OS — glass, SF type, accent-filled selection. Two levels: apps (default),
/// and the windows of one app (`lode tab`, or Tab on a running app row;
/// esc walks back). Enter = focus-or-launch full-screen; shift+enter =
/// beside. ⌘K on an app row opens the graph card beside the list — add
/// or remove chains, written straight into the config — while the list
/// underneath stays frozen exactly as it was. Row views are cached and
/// reused — typing repaints, it never rebuilds — and rows teach the faster
/// paths: graph addresses and window counts on apps, mark paths on windows.
/// The panel never activates lodestar, so focus context stays where it was.
final class SearcherController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private enum Row {
        case app(AppIndex.Entry)
        case window(WindowModel.Window)

        var identity: String {
            switch self {
            case .app(let entry): return "app:\(entry.bundleID ?? entry.url.path)"
            case .window(let window): return "win:\(window.id)"
            }
        }
    }

    private enum Mode {
        case apps
        case windows(pid: pid_t, appName: String, cameFromApps: Bool)
    }

    /// The ⌘K graph card's state. While it is open the searcher freezes:
    /// every key routes here, none reach the query field.
    private enum MenuState {
        case closed
        case list(entry: AppIndex.Entry, chains: [[String]], selected: Int, error: String?)
        case chain(entry: AppIndex.Entry, letters: [String], error: String?)
    }

    private let panel: KeyablePanel
    private let root = NSView()
    private let field = NSTextField()
    private let magnifier = NSImageView()
    private let separator = NSBox()
    private let rowsStack = NSStackView()
    private let footer = NSTextField(labelWithString: "")
    private let appIndex: AppIndex
    private let actions: Actions
    private let model: WindowModel

    /// lowercased app name -> graph chain (e.g. "proton mail" -> "E P")
    var graphAddress: (String) -> String? = { _ in nil }
    /// window id -> mark path, uppercased (e.g. "Q")
    var markPath: (CGWindowID) -> String? = { _ in nil }
    /// lowercased app name -> every chain bound to it (lowercased letters)
    var graphChains: (String) -> [[String]] = { _ in [] }
    /// Why a pending chain can't be added, or nil when it's free.
    var chainProblem: ([String]) -> String? = { _ in nil }
    /// Write the edit into the config; an error string, or nil on success.
    var addToGraph: ([String], AppIndex.Entry) -> String? = { _, _ in "graph editing is unavailable" }
    var removeFromGraph: ([String]) -> String? = { _ in "graph editing is unavailable" }

    private var rows: [Row] = []
    private var rowViews: [SearcherRowView] = []
    private var viewCache: [String: SearcherRowView] = [:]
    private var selected = 0
    private var mode: Mode = .apps
    private var menuState: MenuState = .closed
    private let graphMenu = GraphMenu()

    private let panelWidth = BarTheme.panelWidth
    private let inputHeight = BarTheme.inputHeight
    private let rowHeight = BarTheme.rowHeight
    private let footerHeight = BarTheme.footerHeight

    init(appIndex: AppIndex, actions: Actions, model: WindowModel) {
        self.appIndex = appIndex
        self.actions = actions
        self.model = model
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

        magnifier.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "search"
        )
        magnifier.symbolConfiguration = BarTheme.inputSymbol
        magnifier.contentTintColor = .secondaryLabelColor
        magnifier.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = BarTheme.inputFont
        field.placeholderString = "Where to?"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        footer.font = BarTheme.footerFont
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(magnifier)
        root.addSubview(field)
        root.addSubview(separator)
        root.addSubview(rowsStack)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            magnifier.centerYAnchor.constraint(equalTo: root.topAnchor, constant: inputHeight / 2),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 12),
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

    func show() {
        appIndex.refreshIfStale()
        closeMenu()
        mode = .apps
        field.placeholderString = "Where to?"
        field.stringValue = ""
        requery()
        present()
    }

    /// The window chooser: this app's windows, most recently focused first.
    func showWindowChooser(pid: pid_t, appName: String) {
        mode = .windows(pid: pid, appName: appName, cameFromApps: false)
        field.placeholderString = "\(appName) windows"
        field.stringValue = ""
        requery()
        present()
    }

    func hide() {
        closeMenu()
        panel.orderOut(nil)
    }

    private func present() {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(field)
    }

    // MARK: - Querying

    private func requery() {
        let query = field.stringValue
        switch mode {
        case .apps:
            rows = appIndex.query(query).map(Row.app)
        case .windows(let pid, _, _):
            var windows = model.windows.values.filter { $0.isAlive && $0.pid == pid }
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // Most recently focused first; the window you are already in
                // goes last — "the one I was just in" is row one.
                windows.sort {
                    ($0.lastFocused ?? .distantPast) > ($1.lastFocused ?? .distantPast)
                }
                if windows.count > 1, let focusedID = model.focusedID,
                   windows.first?.id == focusedID {
                    windows.append(windows.removeFirst())
                }
            } else {
                windows = Fuzzy.rank(query: trimmed, candidates: windows,
                                     key: { $0.title.isEmpty ? $0.appName : $0.title })
            }
            rows = windows.prefix(10).map(Row.window)
        }
        selected = 0
        if HotkeyEngine.traceTap {
            Log.info("searcher: '\(query)' -> \(rows.prefix(4).map(rowName).joined(separator: ", "))")
        }
        layoutRows()
        updateFooter()
        reposition()
    }

    private func rowName(_ row: Row) -> String {
        switch row {
        case .app(let entry): return entry.name
        case .window(let window): return window.title
        }
    }

    private static func display(_ chain: [String]) -> String {
        chain.map { $0.uppercased() }.joined(separator: " ")
    }

    /// Reuse row views by identity — typing repaints, it never rebuilds, so
    /// icons never flicker under fast keystrokes.
    private func layoutRows() {
        rowsStack.arrangedSubviews.forEach { rowsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rowViews = rows.enumerated().map { index, row in
            let view = viewCache[row.identity] ?? SearcherRowView(rowHeight: rowHeight)
            viewCache[row.identity] = view
            configure(view, row: row)
            view.setSelected(index == selected)
            rowsStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            return view
        }
        if viewCache.count > 60 {
            let live = Set(rows.map(\.identity))
            viewCache = viewCache.filter { live.contains($0.key) }
        }
    }

    private func configure(_ view: SearcherRowView, row: Row) {
        switch row {
        case .app(let entry):
            var chips: [String] = []
            if let address = graphAddress(entry.name.lowercased()) {
                chips.append(address)
            }
            if entry.isRunning, let pid = entry.pid {
                let count = model.windows.values.filter { $0.isAlive && $0.pid == pid }.count
                if count > 1 { chips.append("⇥ \(count)") }
            }
            view.configure(
                identity: row.identity,
                icon: { NSWorkspace.shared.icon(forFile: entry.url.path) },
                title: entry.name,
                chips: chips,
                showDot: entry.isRunning
            )
        case .window(let window):
            view.configure(
                identity: row.identity,
                icon: { NSRunningApplication(processIdentifier: window.pid)?.icon },
                title: window.title.isEmpty ? window.appName : window.title,
                chips: markPath(window.id).map { ["◆ \($0)"] } ?? [],
                showDot: false
            )
        }
    }

    private func updateFooter() {
        switch mode {
        case .apps:
            footer.stringValue = "↵ open    ⇧↵ beside    ⇥ windows    ⌘K graph    esc close"
        case .windows(_, _, let cameFromApps):
            footer.stringValue = "↵ open    ⇧↵ beside    esc \(cameFromApps ? "back" : "close")"
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
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            pick(beside: shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if case .windows(_, _, true) = mode {
                mode = .apps
                field.placeholderString = "Where to?"
                field.stringValue = ""
                requery()
            } else {
                hide()
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab = "show me the windows" — expand a running app in place.
            if case .apps = mode,
               rows.indices.contains(selected),
               case .app(let entry) = rows[selected],
               entry.isRunning, let pid = entry.pid {
                mode = .windows(pid: pid, appName: entry.name, cameFromApps: true)
                field.placeholderString = "\(entry.name) windows"
                field.stringValue = ""
                requery()
            } else {
                moveSelection(1)
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            moveSelection(-1)
            return true
        default:
            return false
        }
    }

    /// Selection repaints two rows; nothing is rebuilt.
    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let previous = selected
        selected = (selected + delta + rows.count) % rows.count
        if rowViews.indices.contains(previous) { rowViews[previous].setSelected(false) }
        if rowViews.indices.contains(selected) { rowViews[selected].setSelected(true) }
    }

    private func pick(beside: Bool) {
        guard rows.indices.contains(selected) else { return }
        let row = rows[selected]
        hide()
        switch row {
        case .app(let entry):
            actions.pick(entry, beside: beside)
        case .window(let window):
            actions.summonWindow(window.id, beside: beside)
        }
    }

    // MARK: - The graph card (⌘K)

    /// ⌘K opens the card; a second ⌘K (or esc) closes it.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "k" else { return false }
        if case .apps = mode, rows.indices.contains(selected),
           case .app(let entry) = rows[selected] {
            menuState = .list(entry: entry, chains: graphChains(entry.name.lowercased()),
                              selected: 0, error: nil)
            renderMenu()
        }
        return true
    }

    /// Every key while the card is open — the field never sees them, so
    /// the query underneath stays frozen. Runs before AppKit's dispatch,
    /// which is also what lets ⌘K toggle the card closed.
    private func handleMenuKey(_ event: NSEvent) -> Bool {
        if case .closed = menuState { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods == .command {
            if event.charactersIgnoringModifiers?.lowercased() == "k" { closeMenu() }
            return true
        }
        guard mods.isEmpty else { return true }

        switch event.keyCode {
        case 53: // esc walks back one level
            if case .chain(let entry, _, _) = menuState {
                menuState = .list(entry: entry, chains: graphChains(entry.name.lowercased()),
                                  selected: 0, error: nil)
                renderMenu()
            } else {
                closeMenu()
            }
            return true
        case 36, 76: // return
            fireMenuSelection()
            return true
        case 51: // delete backs the chain up
            if case .chain(let entry, var letters, _) = menuState, !letters.isEmpty {
                letters.removeLast()
                menuState = .chain(entry: entry, letters: letters, error: nil)
                renderMenu()
            }
            return true
        case 125, 126: // arrows move the card's selection
            if case .list(let entry, let chains, let selected, _) = menuState, chains.count > 1 {
                let delta = event.keyCode == 125 ? 1 : -1
                menuState = .list(entry: entry, chains: chains,
                                  selected: (selected + delta + chains.count) % chains.count,
                                  error: nil)
                renderMenu()
            }
            return true
        default:
            break
        }

        guard let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty else {
            return true
        }
        switch menuState {
        case .list(let entry, let chains, _, _):
            if chains.isEmpty {
                if typed == "a" { beginChain(entry) }
            } else if chains.count == 1 {
                if typed == "d" { removeChain(chains[0]) }
            } else if let index = Int(typed), (1...chains.count).contains(index) {
                removeChain(chains[index - 1])
            }
        case .chain(let entry, var letters, _):
            for ch in typed where ch.isASCII && ch.isLetter { letters.append(String(ch)) }
            menuState = .chain(entry: entry, letters: letters, error: nil)
            renderMenu()
        case .closed:
            break
        }
        return true
    }

    private func fireMenuSelection() {
        switch menuState {
        case .list(let entry, let chains, let selected, _):
            if chains.isEmpty {
                beginChain(entry)
            } else {
                removeChain(chains[min(selected, chains.count - 1)])
            }
        case .chain(let entry, let letters, _):
            guard !letters.isEmpty, chainProblem(letters) == nil else { return }
            if let problem = addToGraph(letters, entry) {
                menuState = .chain(entry: entry, letters: letters, error: problem)
                renderMenu()
            } else {
                closeMenu()
                requery() // the row's address chip appears — that's the receipt
            }
        case .closed:
            break
        }
    }

    private func beginChain(_ entry: AppIndex.Entry) {
        menuState = .chain(entry: entry, letters: [], error: nil)
        renderMenu()
    }

    private func removeChain(_ chain: [String]) {
        guard case .list(let entry, let chains, let selected, _) = menuState else { return }
        if let problem = removeFromGraph(chain) {
            menuState = .list(entry: entry, chains: chains, selected: selected, error: problem)
            renderMenu()
        } else {
            closeMenu()
            requery()
        }
    }

    private func closeMenu() {
        menuState = .closed
        graphMenu.hide()
    }

    private func renderMenu() {
        switch menuState {
        case .closed:
            graphMenu.hide()
        case .list(let entry, let chains, let selected, let error):
            let items: [GraphMenu.Item]
            if chains.isEmpty {
                items = [GraphMenu.Item(keycap: "a", title: "Add to graph", chain: [])]
            } else if chains.count == 1 {
                items = [GraphMenu.Item(keycap: "d", title: "Remove from graph", chain: [])]
            } else {
                // Several bindings: the chain is what tells the rows apart.
                items = chains.enumerated().map {
                    GraphMenu.Item(keycap: "\($0.offset + 1)", title: "Remove from graph", chain: $0.element)
                }
            }
            graphMenu.present(.items(items, selected: selected, error: error),
                              appName: entry.name,
                              besideRow: selectedRowScreenFrame(), panelFrame: panel.frame)
        case .chain(let entry, let letters, let error):
            let verdict: String
            let problem: Bool
            if let error {
                verdict = error
                problem = true
            } else if letters.isEmpty {
                verdict = "each letter is a key in the chain"
                problem = false
            } else if let blocked = chainProblem(letters) {
                verdict = blocked
                problem = true
            } else {
                verdict = "add lode \(Self.display(letters)) → \(entry.name)"
                problem = false
            }
            graphMenu.present(.chain(letters: letters, verdict: verdict, problem: problem),
                              appName: entry.name,
                              besideRow: selectedRowScreenFrame(), panelFrame: panel.frame)
        }
    }

    private func selectedRowScreenFrame() -> NSRect {
        guard rowViews.indices.contains(selected) else { return panel.frame }
        let view = rowViews[selected]
        return panel.convertToScreen(view.convert(view.bounds, to: nil))
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

/// A reusable searcher row. The icon is loaded once per identity; selection
/// is a repaint, not a rebuild.
private final class SearcherRowView: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var chipBoxes: [NSView] = []
    private var chipLabels: [NSTextField] = []
    private var dot: NSTextField?
    private var identity = ""
    private var trailingSignature = ""
    private var selectedState = false

    init(rowHeight: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        wantsLayer = true
        layer?.cornerRadius = BarTheme.rowRadius

        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
        ])

        name.font = BarTheme.titleFont
        name.lineBreakMode = .byTruncatingTail
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(name)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(identity: String, icon iconLoader: () -> NSImage?, title: String,
                   chips: [String], showDot: Bool) {
        if identity != self.identity {
            self.identity = identity
            icon.image = iconLoader()
        }
        name.stringValue = title

        let signature = chips.joined(separator: "|") + (showDot ? "|●" : "")
        if signature != trailingSignature {
            trailingSignature = signature
            for view in chipBoxes { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            chipBoxes = []
            chipLabels = []
            if let dot { stack.removeArrangedSubview(dot); dot.removeFromSuperview() }
            dot = nil

            for chip in chips {
                let (box, label) = Self.makeChip(chip)
                chipBoxes.append(box)
                chipLabels.append(label)
                stack.addArrangedSubview(box)
            }
            if showDot {
                let dotLabel = NSTextField(labelWithString: "●")
                dotLabel.font = .systemFont(ofSize: 8)
                dot = dotLabel
                stack.addArrangedSubview(dotLabel)
            }
            restyle()
        }
    }

    func setSelected(_ selected: Bool) {
        guard selected != selectedState else { return }
        selectedState = selected
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = selectedState ? NSColor.controlAccentColor.cgColor : nil
        name.textColor = selectedState ? .white : .labelColor
        for label in chipLabels {
            label.textColor = selectedState ? .white : .secondaryLabelColor
        }
        for box in chipBoxes {
            box.layer?.backgroundColor = selectedState
                ? NSColor.white.withAlphaComponent(0.22).cgColor
                : NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
        dot?.textColor = selectedState ? NSColor.white.withAlphaComponent(0.85) : .controlAccentColor
    }

    private static func makeChip(_ text: String) -> (NSView, NSTextField) {
        let label = NSTextField(labelWithString: text)
        label.font = BarTheme.chipFont
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = BarTheme.chipRadius
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        return (box, label)
    }
}

/// A borderless-looking nonactivating panel that accepts key focus.
/// Titled under the hood: a key window with no opaque shape gets its
/// shadow — and the hairline the window server etches around it — drawn
/// on the raw window rect, a square outline floating over the rounded
/// glass. The hidden title bar hands the window server a real rounded
/// shape instead; .fullSizeContentView keeps the content geometry
/// identical to borderless.
final class KeyablePanel: GlassPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// First look at ⌘-chords (the searcher's ⌘K) before AppKit routing.
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    /// First look at every keystroke, ahead of the field editor — how the
    /// graph card captures typing without the query field seeing it.
    var onKeyDown: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let onKeyEquivalent, onKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKeyDown, onKeyDown(event) { return }
        super.sendEvent(event)
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: backingStoreType, defer: flag)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovable = false
    }
}
