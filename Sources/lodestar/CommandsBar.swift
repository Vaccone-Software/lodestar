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
    private let separator = NSBox()
    private let rowsStack = NSStackView()
    private let footer = NSTextField(labelWithString: "↵ run    esc close")

    private var items: [Commands.Row] = []
    private var rows: [Commands.Row] = []
    private var selected = 0

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

        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)

        symbol.image = NSImage(systemSymbolName: "filemenu.and.selection", accessibilityDescription: "menus")
        symbol.symbolConfiguration = BarTheme.inputSymbol
        symbol.contentTintColor = BarTheme.secondaryColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = BarTheme.inputFont
        field.placeholderString = "Do what?"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        footer.font = BarTheme.footerFont
        footer.textColor = BarTheme.secondaryColor
        footer.alignment = .center
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(symbol)
        root.addSubview(field)
        root.addSubview(separator)
        root.addSubview(rowsStack)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            symbol.centerYAnchor.constraint(equalTo: root.topAnchor, constant: inputHeight / 2),
            field.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 12),
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

    private var harvestGeneration = 0

    /// How long the footer waits before painting — `SurfaceFade`'s
    /// verdict for this bar, set by the engine before each show.
    var footerDelay: () -> TimeInterval = { 0 }
    private let footerFade = FooterFade()

    func show() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        footerFade.apply(to: footer, delay: footerDelay())
        // The panel appears immediately; the AX walk of the menu tree runs
        // off the main thread — a hung app can never freeze lodestar here.
        harvestGeneration += 1
        let generation = harvestGeneration
        let name = app.localizedName ?? "App"
        let pid = app.processIdentifier
        items = []
        field.placeholderString = "Do what?"
        field.stringValue = ""
        requery()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(field)
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
    static func preview(query: String) -> CommandsBarController {
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
        bar.items = Commands.rows(menus: menus, app: "Notes")
        bar.field.stringValue = query
        bar.panel.makeKeyAndOrderFront(nil)
        bar.panel.orderFrontRegardless()
        bar.panel.makeFirstResponder(bar.field)
        bar.field.currentEditor()?.selectedRange = NSRange(location: query.count, length: 0)
        bar.requery()
        return bar
    }
    #endif
}

/// One reusable commands row: title over breadcrumb, a source chip when the
/// list mixes feeds, and the native-shortcut chip at the edge.
private final class CommandsRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let crumb = NSTextField(labelWithString: "")
    private let chipLabel = NSTextField(labelWithString: "")
    private let chip = NSView()
    private let sourceLabel = NSTextField(labelWithString: "")
    private let sourceChip = NSView()
    private let trailing = NSStackView()
    private var selectedState = false

    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        wantsLayer = true
        layer?.cornerRadius = BarTheme.rowRadius

        title.font = BarTheme.titleFont
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        crumb.font = BarTheme.secondaryFont
        crumb.lineBreakMode = .byTruncatingTail
        crumb.translatesAutoresizingMaskIntoConstraints = false

        for (box, label) in [(chip, chipLabel), (sourceChip, sourceLabel)] {
            label.font = BarTheme.chipFont
            label.translatesAutoresizingMaskIntoConstraints = false
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
        }

        // A trailing stack, so a hidden chip leaves no hole: the source
        // chip appears only when the list mixes feeds, and the shortcut
        // chip only when the app printed one.
        trailing.orientation = .horizontal
        trailing.spacing = 8
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.addArrangedSubview(sourceChip)
        trailing.addArrangedSubview(chip)

        addSubview(title)
        addSubview(crumb)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            crumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            crumb.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor,
                                            constant: -12),
            crumb.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor,
                                            constant: -12),
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

    private func restyle() {
        layer?.backgroundColor = selectedState ? NSColor.controlAccentColor.cgColor : nil
        title.textColor = selectedState ? .white : .labelColor
        crumb.textColor = selectedState ? NSColor.white.withAlphaComponent(0.75) : BarTheme.secondaryColor
        for label in [chipLabel, sourceLabel] {
            label.textColor = selectedState ? .white : BarTheme.secondaryColor
        }
        for box in [chip, sourceChip] {
            box.layer?.backgroundColor = selectedState
                ? NSColor.white.withAlphaComponent(0.22).cgColor
                : NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}
