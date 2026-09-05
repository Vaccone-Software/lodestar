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
/// paths: graph addresses and window counts on apps.
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

    /// One binding the ⌘K card shows: the chain, and — on a browser row —
    /// the profile it opens. A nil profile is the bare app, which inherits:
    /// the browser decides, the way a plain launch always has.
    private struct Binding {
        let chain: [String]
        let profile: BrowserProfile?
    }

    /// The ⌘K graph card's state. While it is open the searcher freezes:
    /// every key routes here, none reach the query field.
    private enum MenuState {
        case closed
        case list(entry: AppIndex.Entry, bindings: [Binding], error: String?)
        case chain(entry: AppIndex.Entry, letters: [String],
                   profile: BrowserProfile?, error: String?)
        /// The profile list, one card further out; the chain card beneath
        /// keeps its place exactly as typed.
        case profiles(entry: AppIndex.Entry, letters: [String],
                      profile: BrowserProfile?)
    }

    /// What a keycap on the list card does — derived once and read by both
    /// the renderer and the keys, so a digit always fires the row it was
    /// drawn beside.
    private enum ListAction {
        case add
        case remove(Binding)
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
    /// lowercased app name -> every chain bound to it (lowercased letters)
    var graphChains: (String) -> [[String]] = { _ in [] }
    /// Everything the graph binds for a browser — the bare app name and
    /// each profile-targeted chain — because to the card a browser row
    /// owns all of them.
    var browserBindings: (ChromiumBrowser, String) -> [(chain: [String], target: GraphTarget)] = { _, _ in [] }
    /// Why a pending chain can't be added, or nil when it's free.
    var chainProblem: ([String]) -> String? = { _ in nil }
    /// Write the edit into the config; an error string, or nil on success.
    /// A nil profile binds the bare app name — the inherit binding.
    var addToGraph: ([String], AppIndex.Entry, BrowserProfile?) -> String? = { _, _, _ in "graph editing is unavailable" }
    var removeFromGraph: ([String]) -> String? = { _ in "graph editing is unavailable" }
    /// Where the launcher's own price is recorded: bar-open → first key →
    /// commit, the rank picked, the list length. Measured here because
    /// this is the only place the clock and the rows exist together.
    var observations: ObservationStore?
    /// How long the footer waits before painting — `SurfaceFade`'s
    /// verdict for the launcher, set by the engine before each show.
    var footerDelay: () -> TimeInterval = { 0 }
    private let footerFade = FooterFade()
    /// The bar was escaped with typing in it: a stumble, which brings the
    /// footer straight back for a while.
    var onAbandon: () -> Void = {}
    /// The app whose closed road has been confirmed once this session —
    /// the second ↵ opens it.
    private var confirmedRoad: String?
    private var openedAt: Date?
    private var firstKeyAt: Date?
    private var rows: [Row] = []
    private var rowViews: [SearcherRowView] = []
    private var viewCache: [String: SearcherRowView] = [:]
    /// Alive windows per pid, rebuilt once per requery for the row chips.
    private var aliveByPid: [pid_t: Int] = [:]
    private var selected = 0
    private var mode: Mode = .apps
    private var menuState: MenuState = .closed
    private let graphCard = OptionsCard()
    private let profilesCard = OptionsCard()

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
        footer.textColor = .secondaryLabelColor
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
        openedAt = Date()
        firstKeyAt = nil
        confirmedRoad = nil
        requery()
        footerFade.apply(to: footer, delay: footerDelay())
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
            // One walk of the model for every row's window-count chip:
            // counting per row re-filtered every tracked window per visible
            // row, per keystroke.
            aliveByPid = model.windows.values.reduce(into: [:]) { counts, w in
                if w.isAlive { counts[w.pid, default: 0] += 1 }
            }
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
                let count = aliveByPid[pid] ?? 0
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
                chips: [],
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
        if firstKeyAt == nil, !field.stringValue.isEmpty { firstKeyAt = Date() }
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
                // An escape after typing is a search that failed to find —
                // a cost paid for nothing, which the demand model should
                // know about.
                if case .apps = mode, !field.stringValue.isEmpty {
                    observations?.launcherAbandoned(typed: field.stringValue.count)
                    onAbandon()
                }
                openedAt = nil
                firstKeyAt = nil
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
        // A closed road. The app has an address the coach was asked to
        // teach, so the launcher asks once more before opening it — the
        // toll Grossman measured moving hands where a chip alone did not.
        // One deliberate ↵ pays it; the closure expires on its own when
        // the address's curve bends.
        if case .app(let entry) = row, let observations,
           let chain = Coach.roadClosed(observations: observations.observations,
                                        app: entry.name),
           confirmedRoad != entry.name.lowercased() {
            confirmedRoad = entry.name.lowercased()
            let shown = "lode " + chain.map { $0.uppercased() }.joined(separator: " ")
            footer.alphaValue = 1
            footer.stringValue = "\(shown) reaches \(entry.name)    ↵ again to open it anyway"
            return
        }
        let now = Date()
        hide()
        // What the search actually cost, measured rather than assumed:
        // the characters, the ranks, and the seconds — everything the
        // launcher-vs-graph comparison needs to be priced in one currency.
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        switch row {
        case .app(let entry):
            let cost = Observations.LauncherCost(
                typed: query.count,
                prefix: String(query.lowercased().prefix(2)),
                rank: selected,
                listLength: rows.count,
                openToFirstKey: firstKeyAt.flatMap { first in
                    openedAt.map { first.timeIntervalSince($0) }
                },
                openToCommit: openedAt.map { now.timeIntervalSince($0) }
            )
            actions.pick(entry, beside: beside, cost: cost)
        case .window(let window):
            observations?.reached(window.appName, via: .chooser, at: now)
            actions.summonWindow(window.id, beside: beside)
        }
        openedAt = nil
        firstKeyAt = nil
    }

    // MARK: - The graph card (⌘K)

    /// ⌘K opens the card; a second ⌘K (or esc) closes it. The close lives
    /// here, not only in handleMenuKey: the key-equivalent circuit sees a
    /// ⌘-chord before the window's sendEvent ever does, so a toggle left
    /// to sendEvent would instead reopen a fresh card over the typing.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "k" else { return false }
        if case .closed = menuState {
            if case .apps = mode, rows.indices.contains(selected),
               case .app(let entry) = rows[selected] {
                menuState = .list(entry: entry, bindings: bindings(for: entry), error: nil)
                renderMenu()
            }
        } else {
            closeMenu()
        }
        return true
    }

    /// The browser a row is, when it is one — what unlocks the profile
    /// grammar on its card.
    private func browser(for entry: AppIndex.Entry) -> ChromiumBrowser? {
        ChromiumBrowser.allCases.first { $0.bundleID == entry.bundleID }
    }

    /// Everything the graph binds for this row. A browser row owns its
    /// profile bindings too; every other app owns only its own name.
    private func bindings(for entry: AppIndex.Entry) -> [Binding] {
        guard let browser = browser(for: entry) else {
            return graphChains(entry.name.lowercased()).map { Binding(chain: $0, profile: nil) }
        }
        return browserBindings(browser, entry.name).map { chain, target in
            guard case .browserProfile(let profile) = target else {
                return Binding(chain: chain, profile: nil)
            }
            return Binding(chain: chain, profile: profile)
        }
    }

    /// The browser's own profiles, in its own casing and order — the digit
    /// rows. Nine at most: past that the digits run out, and a machine
    /// with more profiles than that is a config file's problem.
    private func profileChoices(for browser: ChromiumBrowser) -> [BrowserProfile] {
        ChromiumProfiles.displayNames(for: browser).prefix(9).map {
            BrowserProfile(browser: browser, display: $0)
        }
    }

    /// Whether the row has an address left to gain. A plain app bound once
    /// is done — a second chain would mean the same thing. A browser is
    /// done only when the bare app and every profile are bound, because
    /// its bindings are told apart by target, never by app.
    private func hasUnboundTarget(_ entry: AppIndex.Entry, bindings: [Binding]) -> Bool {
        guard let browser = browser(for: entry) else { return bindings.isEmpty }
        guard bindings.contains(where: { $0.profile == nil }) else { return true }
        let bound = Set(bindings.compactMap { $0.profile?.canonical })
        return profileChoices(for: browser).contains { !bound.contains($0.canonical) }
    }

    /// Why this exact target can't be bound again, or nil. Bindings
    /// conflict on target, never on app: three chains can mean Brave so
    /// long as each opens a different profile, and inherit is its own
    /// answer, colliding only with an existing inherit binding.
    private func duplicateProblem(_ entry: AppIndex.Entry,
                                  profile: BrowserProfile?) -> String? {
        let taken = bindings(for: entry).first {
            switch ($0.profile, profile) {
            case (nil, nil): return true
            case (let bound?, let picked?): return bound.canonical == picked.canonical
            default: return false
            }
        }
        guard let taken else { return nil }
        return "\(targetLabel(entry, profile: profile)) is already lode \(Self.display(taken.chain))"
    }

    /// What ⏎ would bind, named the way the summon flash names it.
    private func targetLabel(_ entry: AppIndex.Entry, profile: BrowserProfile?) -> String {
        profile.map { GraphTarget.browserProfile($0).label } ?? entry.name
    }

    /// The list card's offers, in order: what the row can become, then
    /// what it can stop being.
    private func listActions(entry: AppIndex.Entry,
                             bindings: [Binding]) -> [(keycap: String, action: ListAction)] {
        var actions: [(keycap: String, action: ListAction)] = []
        if hasUnboundTarget(entry, bindings: bindings) {
            actions.append((keycap: "a", action: .add))
        }
        if bindings.count == 1 {
            actions.append((keycap: "d", action: .remove(bindings[0])))
        } else {
            // Nine at most: a tenth keycap would need two keystrokes the
            // card cannot take. Past that the config file is the surface.
            for (index, binding) in bindings.prefix(9).enumerated() {
                actions.append((keycap: "\(index + 1)", action: .remove(binding)))
            }
        }
        return actions
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
            switch menuState {
            case .profiles(let entry, let letters, let profile):
                menuState = .chain(entry: entry, letters: letters, profile: profile,
                                   error: nil)
                renderMenu()
            case .chain(let entry, _, _, _):
                menuState = .list(entry: entry, bindings: bindings(for: entry), error: nil)
                renderMenu()
            default:
                closeMenu()
            }
            return true
        case 36, 76: // return
            fireMenuSelection()
            return true
        case 48: // tab toggles the profile list, the way ⌘K toggles the card
            switch menuState {
            case .chain(let entry, let letters, let profile, _):
                if let browser = browser(for: entry), !profileChoices(for: browser).isEmpty {
                    menuState = .profiles(entry: entry, letters: letters, profile: profile)
                    renderMenu()
                }
            case .profiles(let entry, let letters, let profile):
                menuState = .chain(entry: entry, letters: letters, profile: profile,
                                   error: nil)
                renderMenu()
            default:
                break
            }
            return true
        case 51: // delete backs the chain up
            if case .chain(let entry, var letters, let profile, _) = menuState,
               !letters.isEmpty {
                letters.removeLast()
                menuState = .chain(entry: entry, letters: letters, profile: profile,
                                   error: nil)
                renderMenu()
            }
            return true
        case 125, 126: // swallowed: the card has no selection to move
            return true
        default:
            break
        }

        guard let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty else {
            return true
        }
        switch menuState {
        case .list(let entry, let bindings, _):
            guard let match = listActions(entry: entry, bindings: bindings)
                .first(where: { $0.keycap == typed }) else { break }
            switch match.action {
            case .add: beginChain(entry)
            case .remove(let binding): removeChain(binding.chain)
            }
        case .chain(let entry, var letters, let profile, _):
            for ch in typed where ch.isASCII && ch.isLetter { letters.append(String(ch)) }
            menuState = .chain(entry: entry, letters: letters, profile: profile, error: nil)
            renderMenu()
        case .profiles(let entry, let letters, _):
            // A digit picks and lands back on the chain card, where the
            // verdict now reads the new target. 0 is inherit.
            guard let index = Int(typed) else { break }
            if index == 0 {
                menuState = .chain(entry: entry, letters: letters, profile: nil, error: nil)
                renderMenu()
            } else if let browser = browser(for: entry) {
                let choices = profileChoices(for: browser)
                if choices.indices.contains(index - 1) {
                    menuState = .chain(entry: entry, letters: letters,
                                       profile: choices[index - 1], error: nil)
                    renderMenu()
                }
            }
        case .closed:
            break
        }
        return true
    }

    private func fireMenuSelection() {
        switch menuState {
        case .list(let entry, let bindings, _):
            // Only when there is one thing it could mean. With several
            // offers the rows are told apart by their keys, and a return
            // that quietly picked one of them would fire a row the user
            // never pointed at.
            let actions = listActions(entry: entry, bindings: bindings)
            guard actions.count == 1, let only = actions.first else { return }
            switch only.action {
            case .add: beginChain(entry)
            case .remove(let binding): removeChain(binding.chain)
            }
        case .chain(let entry, let letters, let profile, _):
            guard !letters.isEmpty, chainProblem(letters) == nil,
                  duplicateProblem(entry, profile: profile) == nil else { return }
            if let problem = addToGraph(letters, entry, profile) {
                menuState = .chain(entry: entry, letters: letters, profile: profile,
                                   error: problem)
                renderMenu()
            } else {
                closeMenu()
                requery() // the row's address chip appears — that's the receipt
            }
        case .profiles(let entry, let letters, let profile):
            // ⏎ lands back on the chain card, keeping whatever is picked —
            // the same three ways out the web bar's list has.
            menuState = .chain(entry: entry, letters: letters, profile: profile, error: nil)
            renderMenu()
        case .closed:
            break
        }
    }

    private func beginChain(_ entry: AppIndex.Entry) {
        menuState = .chain(entry: entry, letters: [], profile: nil, error: nil)
        renderMenu()
    }

    private func removeChain(_ chain: [String]) {
        guard case .list(let entry, let bindings, _) = menuState else { return }
        if let problem = removeFromGraph(chain) {
            menuState = .list(entry: entry, bindings: bindings, error: problem)
            renderMenu()
        } else {
            closeMenu()
            requery()
        }
    }

    private func closeMenu() {
        menuState = .closed
        graphCard.hide()
        profilesCard.hide()
    }

    private func renderMenu() {
        let anchor = OptionsCard.Anchor.row(selectedRowScreenFrame(), panel: panel.frame)
        switch menuState {
        case .closed:
            graphCard.hide()
            profilesCard.hide()
        case .list(let entry, let bindings, let error):
            profilesCard.hide()
            let isBrowser = browser(for: entry) != nil
            let items = listActions(entry: entry, bindings: bindings).map { keycap, action in
                switch action {
                case .add:
                    return OptionsCard.Item(keycap: keycap, title: "Add to graph",
                                            symbol: "plus.circle")
                case .remove(let binding):
                    // Several bindings: the chain is what tells the rows
                    // apart, and on a browser the profile says which one
                    // a remove would take.
                    return OptionsCard.Item(keycap: keycap, title: "Remove from graph",
                                            symbol: "minus.circle", isDestructive: true,
                                            chain: bindings.count > 1 ? binding.chain : [],
                                            detail: isBrowser
                                                ? (binding.profile?.display ?? "Inherit") : nil)
                }
            }
            graphCard.present(.items(OptionsCard.Menu(
                items: items, error: error,
                note: bindings.count > 9
                    ? "the digits stop at nine, the config file holds the rest" : nil
            )), anchor: anchor)
        case .chain, .profiles:
            renderChainCard(anchor: anchor)
        }
    }

    /// The chain card, and — while the profile list is open — that list one
    /// card further out, the web bar's cascade exactly.
    private func renderChainCard(anchor: OptionsCard.Anchor) {
        let entry: AppIndex.Entry
        let letters: [String]
        let profile: BrowserProfile?
        let error: String?
        let listOpen: Bool
        switch menuState {
        case .chain(let e, let l, let p, let problem):
            (entry, letters, profile, error, listOpen) = (e, l, p, problem, false)
        case .profiles(let e, let l, let p):
            (entry, letters, profile, error, listOpen) = (e, l, p, nil, true)
        default:
            return
        }

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
        } else if let duplicate = duplicateProblem(entry, profile: profile) {
            verdict = duplicate
            problem = true
        } else {
            verdict = "add lode \(Self.display(letters)) → \(targetLabel(entry, profile: profile))"
            problem = false
        }

        var control: OptionsCard.Item?
        var choices: [BrowserProfile] = []
        if let browser = browser(for: entry) {
            choices = profileChoices(for: browser)
            if !choices.isEmpty {
                control = OptionsCard.Item(
                    keycap: "⇥", title: "Profile",
                    symbol: profile == nil
                        ? "person.crop.circle.dashed" : "person.crop.circle.fill",
                    detail: profile?.display ?? "Inherit")
            }
        }

        graphCard.present(.typing(OptionsCard.Typing(
            header: "Add \(entry.name) to graph",
            body: .keys(letters),
            verdict: verdict,
            problem: problem,
            control: control,
            footer: "⌫ back up    esc back"
        )), anchor: anchor)

        guard listOpen, !choices.isEmpty else {
            profilesCard.hide()
            return
        }
        var items = [OptionsCard.Item(
            keycap: "0", title: "Inherit",
            symbol: profile == nil ? "checkmark.circle.fill" : "circle")]
        for (index, choice) in choices.enumerated() {
            items.append(OptionsCard.Item(
                keycap: "\(index + 1)", title: choice.display,
                symbol: profile?.canonical == choice.canonical
                    ? "checkmark.circle.fill" : "circle"))
        }
        profilesCard.present(.items(OptionsCard.Menu(
            header: "Opens in", items: items, footer: "⇥ back    esc cancel"
        )), anchor: .card(graphCard.frame, panel: panel.frame))
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
        // Absorbs the slack so the address chips land at the trailing edge,
        // in one column down the list — the same place the guides and the
        // clipboard's menu keep their keys.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.widthAnchor.constraint(
            greaterThanOrEqualToConstant: BarTheme.rowKeyGap).isActive = true

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(spacer)

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
                : NSColor.labelColor.withAlphaComponent(0.09).cgColor
        }
        dot?.textColor = selectedState ? NSColor.white.withAlphaComponent(0.85) : .controlAccentColor
    }

    private static func makeChip(_ text: String) -> (NSView, NSTextField) {
        let label = NSTextField(labelWithString: text)
        label.font = BarTheme.chipFont
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = BarTheme.chipRadius
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        // The same chip the guides and the clipboard's menu draw. Left to
        // itself this one sized purely to its text, so a one-letter address
        // came out visibly smaller than the identical chip elsewhere.
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: BarTheme.chipPadX),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -BarTheme.chipPadX),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: BarTheme.chipHeight),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: BarTheme.chipMinWidth),
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

#if DEBUG
/// Visual harness for the searcher's rows. The controller needs the whole
/// app standing behind it; a row needs nothing, and the row is where the
/// shared chip lives.
enum SearcherRowPreview {
    static func show() -> NSPanel {
        let panel = Glass.makePanel(level: .statusBar)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: BarTheme.panelWidth, height: 230))
        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        func icon(_ path: String) -> NSImage? {
            FileManager.default.fileExists(atPath: path)
                ? NSWorkspace.shared.icon(forFile: path) : nil
        }
        let samples: [(String, String, [String], Bool)] = [
            ("/Applications/Safari.app", "Safari", ["W"], false),
            ("/System/Applications/Mail.app", "Mail", ["E P", "⇥ 3"], true),
            ("/System/Applications/Notes.app", "Notes", ["N"], false),
            ("/System/Applications/Utilities/Terminal.app", "Terminal", [], false),
        ]
        for (offset, sample) in samples.enumerated() {
            let row = SearcherRowView(rowHeight: BarTheme.rowHeight)
            row.configure(identity: sample.1, icon: { icon(sample.0) },
                          title: sample.1, chips: sample.2, showDot: sample.3)
            row.setSelected(offset == 1)
            stack.addArrangedSubview(row)
            // As the real list does: rows span the panel, so the name
            // stretches and the chips land at the trailing edge.
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
        ])
        panel.contentView = root
        panel.setFrame(NSRect(x: 400, y: 400, width: BarTheme.panelWidth, height: 230),
                       display: true)
        panel.orderFrontRegardless()
        return panel
    }
}
#endif
