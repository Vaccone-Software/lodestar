import AppKit
import LodestarCore

/// The commands bar (`lode -`): the frontmost app's entire menu bar,
/// fuzzy-searchable, `↵` executes. Rows wear the item's native shortcut
/// as a chip — every search teaches the app's own faster path.
final class CommandsBarController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let panel: KeyablePanel
    private let root = NSView()
    private let field = NSTextField()
    private let symbol = NSImageView()
    /// The field is a place you put something, so it sinks: a well one pane-inset
    /// inside the pane, rounded as a thing nested in it.
    private let well = WellView(cornerRadius: BarTheme.paneRowRadius)
    private let rowsStack = NSStackView()

    private var items: [Commands.Row] = []
    private var rows: [Commands.Row] = []
    private var selected = 0

    private let panelWidth = BarTheme.panelWidth
    private let inputHeight = BarTheme.inputHeight
    private let rowHeight = BarTheme.detailRowHeight

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
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.delegate = self
        SoftShadow.host(root, in: panel, cornerRadius: BarTheme.surfaceRadius)

        Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)

        symbol.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "menus")
        symbol.symbolConfiguration = BarTheme.inputSymbol
        symbol.contentTintColor = BarTheme.secondaryColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.setRole(.field)
        field.textColor = BarTheme.ink
        field.setPlaceholder("Do what?")
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        well.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.spacing = Grid.hair
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        keys.install(root: root, below: rowsStack)

        root.addSubview(well)
        root.addSubview(symbol)
        root.addSubview(field)
        root.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: BarTheme.fieldInset),
            symbol.centerYAnchor.constraint(equalTo: root.topAnchor, constant: BarTheme.fieldArea - inputHeight / 2),
            field.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: Grid.part),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -BarTheme.fieldInset),
            field.centerYAnchor.constraint(equalTo: root.topAnchor, constant: BarTheme.fieldArea - inputHeight / 2),
            well.topAnchor.constraint(equalTo: root.topAnchor, constant: BarTheme.paneInset),
            well.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: BarTheme.paneInset),
            well.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -BarTheme.paneInset),
            well.heightAnchor.constraint(equalToConstant: inputHeight),
            rowsStack.topAnchor.constraint(equalTo: well.bottomAnchor, constant: Grid.close),
            rowsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: BarTheme.paneInset),
            rowsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -BarTheme.paneInset),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    /// The bar's keys, held in its own glass on lode ?.
    private let keys = BarKeys()
    var keysShown: Bool { keys.isShown }

    func toggleKeys(_ sections: [CheatSheet.Section]) {
        if keys.isShown { hideKeys() } else { showKeys(sections) }
    }

    func showKeys(_ sections: [CheatSheet.Section]) {
        guard panel.isVisible else { return }
        keys.show(sections)
        root.layoutSubtreeIfNeeded()
        KeysSheet.open(panel, to: SoftShadow.outset(barFrame()))
    }

    func hideKeys() {
        guard let view = keys.hide() else { return }
        KeysSheet.close(panel, to: SoftShadow.outset(barFrame()), removing: view)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    private var harvestGeneration = 0

    func show() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // The panel appears immediately; the AX walk of the menu tree runs
        // off the main thread — a hung app can never freeze lodestar here.
        harvestGeneration += 1
        let generation = harvestGeneration
        let name = app.localizedName ?? "App"
        let pid = app.processIdentifier
        items = []
        field.setPlaceholder("Do what?")
        field.stringValue = ""
        requery()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(field)
        BarTheme.lightCaret(of: field)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let harvested = MenuItems.items(forAppWithPID: pid)
            DispatchQueue.main.async {
                guard let self, self.harvestGeneration == generation, self.isVisible else { return }
                self.items = Commands.rows(menus: harvested, app: name)
                
                self.requery()
            }
        }
    }

    func hide() {
        keys.hide()?.removeFromSuperview()
        panel.orderOut(nil)
    }

    // MARK: - Querying

    private func requery() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            rows = Array(items.prefix(8))
        } else {
            rows = Array(Fuzzy.rank(query: query, candidates: items,
                                    key: { $0.searchKey }).prefix(8))
        }
        selected = 0
        if HotkeyEngine.traceTap {
            Log.info("do: '\(query)' -> \(rows.prefix(4).map(\.title).joined(separator: " | "))")
        }
        renderRows()
        reposition()
    }

    /// Row views are pooled and mutated — typing repaints, it never rebuilds.
    private var rowViews: [CommandsRowView] = []

    private func renderRows() {
        let mixed = Commands.mixedSources(rows)
        while rowViews.count < rows.count {
            let view = CommandsRowView(height: rowHeight)
            rowViews.append(view)
            rowsStack.addArrangedSubview(view)
        }
        for (index, view) in rowViews.enumerated() {
            if index < rows.count {
                view.isHidden = false
                view.configure(rows[index], showSource: mixed)
                view.setSelected(index == selected)
            } else {
                view.isHidden = true
            }
        }
    }

    /// Where the bar stands for what it holds: its top edge fixed, so
    /// growing to hold its keys extends it downward.
    private func barFrame() -> NSRect {
        let count = CGFloat(rows.count)
        let rowsArea = BarTheme.rowsArea(count: rows.count, rowHeight: rowHeight)
        let height = BarTheme.fieldArea + rowsArea + keys.height
        let visible = ActivePolicy.presentationFrame
        let origin = NSPoint(
            x: visible.midX - panelWidth / 2,
            y: visible.minY + visible.height * BarTheme.topLine - height
        )
        return NSRect(origin: origin, size: NSSize(width: panelWidth, height: height))
    }

    private func reposition() {
        panel.setFrame(SoftShadow.outset(barFrame()), display: true)
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
            pick()
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
    }

    private func pick() {
        guard rows.indices.contains(selected) else { return }
        let row = rows[selected]
        hide()
        switch row.verb {
        case .menu(let item):
            let ok = MenuItems.press(item)
            Log.info("menu-press", ["path": item.path.joined(separator: "›"), "ok": ok])
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    #if DEBUG
    /// `lodestar __strip-preview 16` stages the bar mid-search. Synthetic
    /// menus on purpose — a real harvest would photograph whatever app is
    /// frontmost on the machine taking the picture. The element is a dummy;
    /// a preview renders rows and never presses one.
    static func preview(query: String, rows given: [Commands.Row]? = nil) -> CommandsBarController {
        let bar = CommandsBarController()
        let dummy = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        func item(_ path: [String], _ shortcut: String? = nil) -> MenuItems.Item {
            MenuItems.Item(element: dummy, path: path, shortcut: shortcut)
        }
        let menus = [
            item(["Edit", "Paste"], "⌘V"),
            item(["Edit", "Paste and Match Style"], "⌥⇧⌘V"),
            item(["Format", "Font", "Paste Style"], "⌥⌘V"),
            item(["File", "Pin Note"]),
            item(["File", "Page Setup…"], "⇧⌘P"),
            item(["File", "Export as PDF…"]),
            item(["Edit", "Copy"], "⌘C"),
            item(["Window", "Photo Browser"]),
        ]
        bar.items = given ?? Commands.rows(menus: menus, app: "Notes")
        bar.field.stringValue = query
        bar.panel.makeKeyAndOrderFront(nil)
        bar.panel.orderFrontRegardless()
        bar.panel.makeFirstResponder(bar.field)
        BarTheme.lightCaret(of: bar.field)
        bar.field.currentEditor()?.selectedRange = NSRange(location: query.count, length: 0)
        bar.requery()
        return bar
    }
    #endif
}

/// One reusable commands row: title over breadcrumb, a source chip when the
/// list mixes feeds, and the native-shortcut chip at the edge.
private final class CommandsRowView: RaisedRow {
    private let title = NSTextField(labelWithString: "")
    private let crumb = NSTextField(labelWithString: "")
    /// The app's own shortcut for the command, a real key: lit when chosen.
    private let chip = KeyFace("")
    private var chipLabel: NSTextField { chip.label }
    /// ⏎ on the chosen row, lit: the key that runs it.
    private let enter = KeyFace("⏎")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let sourceChip = FlatChip()
    private let trailing = NSStackView()
    private var selectedState = false

    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setupRaised()
        enter.lit = true
        enter.isHidden = true

        title.setRole(.title)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        crumb.setRole(.meta)
        crumb.lineBreakMode = .byTruncatingTail
        crumb.translatesAutoresizingMaskIntoConstraints = false

        for (box, label) in [(sourceChip, sourceLabel)] {
            label.setRole(.key)
            label.translatesAutoresizingMaskIntoConstraints = false
            box.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Grid.half),
                label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Grid.half),
                label.topAnchor.constraint(equalTo: box.topAnchor, constant: Grid.hair),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Grid.hair),
            ])
        }

        // A trailing stack, so a hidden chip leaves no hole: the source
        // chip appears only when the list mixes feeds, and the shortcut
        // chip only when the app printed one.
        trailing.orientation = .horizontal
        trailing.spacing = Grid.close
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.addArrangedSubview(sourceChip)
        trailing.addArrangedSubview(chip)
        trailing.addArrangedSubview(enter)

        addSubview(title)
        addSubview(crumb)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Grid.part),
            title.topAnchor.constraint(equalTo: topAnchor, constant: Grid.tight),
            crumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Grid.part),
            crumb.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Grid.hair),
            trailing.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Grid.part),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor,
                                            constant: -Grid.part),
            crumb.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor,
                                            constant: -Grid.part),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: Commands.Row, showSource: Bool) {
        if title.stringValue != row.title { title.stringValue = row.title }
        if crumb.stringValue != row.crumb { crumb.stringValue = row.crumb }

        // Hidden state set unconditionally: the guard is only a repaint
        // saver, and a chip born visible must still learn it is empty.
        let source = showSource ? row.source : ""
        if sourceLabel.stringValue != source { sourceLabel.stringValue = source }
        sourceChip.isHidden = source.isEmpty
        let shortcut = row.shortcut ?? ""
        if chipLabel.stringValue != shortcut { chipLabel.stringValue = shortcut }
        chip.isHidden = shortcut.isEmpty
    }

    func setSelected(_ selected: Bool) {
        guard selected != selectedState else { return }
        selectedState = selected
        restyle()
    }

    /// Chosen, the row rises and its keys light: the app's shortcut and
    /// ⏎. Which feed it came from is a fact, not a key, so it stays quiet.
    private func restyle() {
        applyRaised(selectedState)
        title.textColor = BarTheme.ink
        crumb.textColor = BarTheme.secondaryColor
        sourceLabel.textColor = BarTheme.secondaryColor
        chip.lit = selectedState
        enter.isHidden = !selectedState
    }
}
