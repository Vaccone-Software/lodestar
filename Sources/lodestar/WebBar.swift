import AppKit
import LodestarCore

/// The web bar (`lode ⏎`): a second, deliberately separate grammar. Every
/// row here is a destination on the web — quick links pinned to profiles,
/// bare domains routed by rules, anything else a search — and each row wears
/// the profile it will open in. Chromium family only for now.
final class WebBarController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    struct WebRow {
        enum Kind { case link, domain, search }
        let kind: Kind
        let title: String
        let url: String
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
    var perform: (_ url: String, _ profile: BrowserProfile, _ beside: Bool) -> Void = { _, _, _ in }

    private var rows: [WebRow] = []
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
        footer.textColor = .tertiaryLabelColor
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

    func show() {
        field.stringValue = ""
        requery()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(field)
    }

    func hide() {
        panel.orderOut(nil)
    }

    // MARK: - Resolution

    /// The profile a destination opens in: explicit pin, then routes
    /// (longest substring match), then the fallback.
    private func resolveProfile(pinned: String?, routedOn text: String) -> BrowserProfile {
        if let pinned, let profile = config.browserProfiles[pinned] {
            return profile
        }
        if let key = WebRouting.route(text, routes: config.webRoutes),
           let profile = config.browserProfiles[key] {
            return profile
        }
        if config.webFallback != "most-recent",
           let profile = config.browserProfiles[config.webFallback] {
            return profile
        }
        if let recent = mostRecentProfile() {
            return recent
        }
        return config.browserProfiles.values.min { $0.display < $1.display }
            ?? BrowserProfile(browser: .brave, display: "Default")
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
                profile: resolveProfile(pinned: link.profileKey, routedOn: "\(link.name) \(link.url)")
            ))
        }
        if WebRouting.isDomainLike(query) {
            built.append(WebRow(
                kind: .domain,
                title: query,
                url: WebRouting.normalize(query),
                profile: resolveProfile(pinned: nil, routedOn: query)
            ))
        }
        if !query.isEmpty {
            built.append(WebRow(
                kind: .search,
                title: "Search “\(query)”",
                url: WebRouting.searchURL(template: config.webSearchURL, query: query),
                profile: resolveProfile(pinned: nil, routedOn: query)
            ))
        }

        rows = built
        selected = 0
        if HotkeyEngine.traceTap {
            Log.info("webbar: '\(query)' -> \(rows.map { "\($0.title)@\($0.profile.display)" }.joined(separator: " | "))")
        }
        renderRows()
        reposition()
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
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
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
    }

    private func pick(beside: Bool) {
        guard rows.indices.contains(selected) else { return }
        let row = rows[selected]
        hide()
        perform(row.url, row.profile, beside)
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
