import AppKit
import LodestarCore

/// The entry point: a floating fuzzy searcher, styled like it belongs to the
/// OS — glass, SF type, accent-filled selection. Two levels: apps (default),
/// and the windows of one app (`hyper tab`, or Tab on a running app row;
/// esc walks back). Enter = focus-or-launch full-screen; shift+enter =
/// beside. Row views are cached and reused — typing repaints, it never
/// rebuilds — and rows teach the faster paths: graph addresses and window
/// counts on apps, mark paths on windows. The panel never activates
/// lodestar, so focus context stays where it was.
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

    private var rows: [Row] = []
    private var rowViews: [SearcherRowView] = []
    private var viewCache: [String: SearcherRowView] = [:]
    private var selected = 0
    private var mode: Mode = .apps

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
            footer.stringValue = "↵ open    ⇧↵ beside    ⇥ windows    esc close"
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
