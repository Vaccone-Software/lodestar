import AppKit
import LodestarCore

/// Menu search (`lode .`): the frontmost app's entire menu bar, fuzzy-
/// searchable, `↵` executes. Rows wear the item's native shortcut as a
/// chip — every search teaches the app's own faster path.
final class MenuSearchController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let panel: KeyablePanel
    private let root = NSView()
    private let field = NSTextField()
    private let symbol = NSImageView()
    private let separator = NSBox()
    private let rowsStack = NSStackView()
    private let footer = NSTextField(labelWithString: "↵ run    esc close")

    private var items: [MenuItems.Item] = []
    private var rows: [MenuItems.Item] = []
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
        symbol.contentTintColor = .secondaryLabelColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = BarTheme.inputFont
        field.placeholderString = "Menus"
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

    func show() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // The panel appears immediately; the AX walk of the menu tree runs
        // off the main thread — a hung app can never freeze lodestar here.
        harvestGeneration += 1
        let generation = harvestGeneration
        let name = app.localizedName ?? "App"
        let pid = app.processIdentifier
        items = []
        field.placeholderString = "\(name) menus…"
        field.stringValue = ""
        requery()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(field)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let harvested = MenuItems.items(forAppWithPID: pid)
            DispatchQueue.main.async {
                guard let self, self.harvestGeneration == generation, self.isVisible else { return }
                self.items = harvested
                self.field.placeholderString = "\(name) menus"
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
                                    key: { $0.path.joined(separator: " ") }).prefix(8))
        }
        selected = 0
        if HotkeyEngine.traceTap {
            Log.info("menus: '\(query)' -> \(rows.prefix(4).map { $0.path.joined(separator: "›") }.joined(separator: " | "))")
        }
        renderRows()
        reposition()
    }

    /// Row views are pooled and mutated — typing repaints, it never rebuilds.
    private var rowViews: [MenuRowView] = []

    private func renderRows() {
        while rowViews.count < rows.count {
            let view = MenuRowView(height: rowHeight)
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
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
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
        let item = rows[selected]
        hide()
        let ok = MenuItems.press(item)
        Log.info("menu-press", ["path": item.path.joined(separator: "›"), "ok": ok])
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

/// One reusable menu row: title over breadcrumb, native-shortcut chip.
private final class MenuRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let crumb = NSTextField(labelWithString: "")
    private let chipLabel = NSTextField(labelWithString: "")
    private let chip = NSView()
    private var toChip: [NSLayoutConstraint] = []
    private var toEdge: [NSLayoutConstraint] = []
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

        chipLabel.font = BarTheme.chipFont
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = BarTheme.chipRadius
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipLabel)

        addSubview(title)
        addSubview(crumb)
        addSubview(chip)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            crumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            crumb.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            chipLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2),
            chipLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        toChip = [
            title.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -12),
            crumb.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -12),
        ]
        toEdge = [
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            crumb.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ]
        NSLayoutConstraint.activate(toEdge)
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ item: MenuItems.Item) {
        let newTitle = item.path.last ?? ""
        let newCrumb = item.path.dropLast().joined(separator: " › ")
        if title.stringValue != newTitle { title.stringValue = newTitle }
        if crumb.stringValue != newCrumb { crumb.stringValue = newCrumb }

        let shortcut = item.shortcut ?? ""
        if chipLabel.stringValue != shortcut {
            chipLabel.stringValue = shortcut
            let hasChip = !shortcut.isEmpty
            chip.isHidden = !hasChip
            NSLayoutConstraint.deactivate(hasChip ? toEdge : toChip)
            NSLayoutConstraint.activate(hasChip ? toChip : toEdge)
        }
    }

    func setSelected(_ selected: Bool) {
        guard selected != selectedState else { return }
        selectedState = selected
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = selectedState ? NSColor.controlAccentColor.cgColor : nil
        title.textColor = selectedState ? .white : .labelColor
        crumb.textColor = selectedState ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        chipLabel.textColor = selectedState ? .white : .secondaryLabelColor
        chip.layer?.backgroundColor = selectedState
            ? NSColor.white.withAlphaComponent(0.22).cgColor
            : NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
}
