import AppKit
import LodestarCore

/// The settings window: `SettingsModel` (LodestarCore) decides what exists
/// and what the keys mean; this draws it and translates. One keyable glass
/// window — draggable, but born centered every time, because a window that
/// remembers where it was is state nobody asked to manage — rail on the
/// left wearing digits, rows on the right wearing letters, `/` to search,
/// escape popping one layer at a time. Every control shows the config path
/// it writes, every write goes through the same pruning path ⌘K uses, and
/// the tables' add grammars pick from ground truth wherever the machine
/// knows the answer better than typing would.
final class SettingsController: NSObject, NSTextFieldDelegate {
    var config = Config() {
        didSet { if panel.isVisible { render() } }
    }

    // Wired by the app delegate.
    /// Write one config value at a dotted path. Returns an error, or nil.
    var apply: ((String, ConfigValue) -> String?)?
    /// Free-table entry edits, batched into one write: removals first,
    /// then sets, each addressed by path components — a key holding dots
    /// (a bundle id, a route pattern) cannot ride a dotted string.
    var applyEntries: (([[String]], [([String], ConfigValue)]) -> String?)?
    var machineState: () -> SettingsModel.MachineState = { .init() }
    /// The machine's calendars and accounts, once access is granted.
    var calendarChoices: () -> [String] = { [] }
    /// A bundle identifier's human name, for the exclusion list.
    var appDisplayName: (String) -> String? = { _ in nil }
    /// The doctor's findings, rendered beside the rows that fix them.
    var problems: () -> [String] = { [] }
    /// Running apps, for the clipboard exclusion picker.
    var appChoices: () -> [(name: String, bundleID: String)] = { [] }

    private let panel = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let root = NSView()

    private var sections: [SettingsModel.Section] = []
    private var pane = 0
    private var layer = SettingsModel.Layer.browsing
    private var labeled: [String: Int] = [:]
    private var rowViews: [Int: NSView] = [:]
    private var fields: [Int: NSTextField] = [:]
    private var popups: [Int: NSPopUpButton] = [:]
    /// The switches, kept across renders by their config path. A render
    /// rebuilds every control, and a switch rebuilt mid-slide arrived at
    /// rest before the eye saw it move; the same view survives instead,
    /// and only its state is told.
    private var switches: [String: AccentSwitch] = [:]
    private var recycledSwitches: [String: AccentSwitch] = [:]
    /// Every editable field on screen, for first-responder tracking: a
    /// field entered by mouse must enter the editing layer exactly as one
    /// entered by letter does, or arrows die in it.
    private var editableFields: [NSTextField] = []
    private var searchField: NSTextField?
    private var hits: [SettingsModel.Hit] = []
    private var hitSelection = 0
    private var hitsStack: NSStackView?
    private var highlightRow: Int?
    private var railRows: [NSView] = []
    /// The add-bars' live inputs, keyed by table kind.
    private var addInputs: [String: NSControl] = [:]
    /// The bars themselves, so focus anywhere inside one reads as editing.
    private var addBars: [NSView] = []
    /// The entry an add-bar is editing, per kind — Add then replaces it,
    /// which is what lets a rename be one gesture.
    private var editing: [String: String] = [:]
    /// The entry rendered as inline fields instead of text.
    private var inlineEdit: (kind: String, key: String)?
    /// Keyboard focus within a list: (pane row, entry index).
    private var listFocus: (row: Int, entry: Int)?
    /// A search landing armed this row: return activates it.
    private var armedRow: Int?
    /// The changed view: every non-default row, one page.
    private var showingChanged = false
    /// Popup token tables, so a selected label resolves to its profile.
    private var popupTokens: [String: [String]] = [:]
    private var lastRenderedPane = -1
    /// See render(): the doctor's findings and the machine probes, memoized
    /// for one second so per-keystroke renders stop re-reading the disk.
    private var doctorCache: (machine: SettingsModel.MachineState,
                              problems: [String], at: Date)?
    private weak var paneScroll: NSScrollView?

    private static let width: CGFloat = 880
    private static let height: CGFloat = 620
    private static let railWidth: CGFloat = 196

    override init() {
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        // Settings is a room, not a bar: it may activate the app, which is
        // what lets popup menus track their clicks. The bars stay
        // nonactivating; this one window trades that for working controls.
        panel.styleMask.remove(.nonactivatingPanel)
        panel.autorecalculatesKeyViewLoop = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = root
        _ = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
        panel.onKeyDown = { [weak self] event in
            guard let self, let key = Keys.name(for: Int64(event.keyCode)) else { return false }
            return self.handle(key: key, event: event)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Clicking back into settings after visiting another app must take
    /// focus again, or hover and keys both die quietly.
    private var clickMonitor: Any?

    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, event.window === self.panel, !self.panel.isKeyWindow
            else { return event }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
            return event
        }
    }

    private func unwatchClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func toggle() {
        isVisible ? close() : open()
    }

    func open(atPane index: Int = 0) {
        pane = max(0, min(index, 8))
        layer = .browsing
        highlightRow = nil
        // Nothing survives from the last visit: a window that opens into
        // a stale editor or a changed view is a window that lies.
        showingChanged = false
        listFocus = nil
        armedRow = nil
        inlineEdit = nil
        editing = [:]
        render()
        let visible = ActivePolicy.presentationFrame
        panel.setFrame(NSRect(x: visible.midX - Self.width / 2,
                              y: visible.midY - Self.height / 2 + 20,
                              width: Self.width, height: Self.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        watchClicks()
        panel.makeKeyAndOrderFront(nil)
        // AppKit hands focus to the first field in the key loop, which
        // would swallow the row letters. Browsing owns the keys until a
        // letter or a click asks for a field.
        panel.makeFirstResponder(nil)
    }

    func close() {
        unwatchClicks()
        panel.orderOut(nil)
    }

    // MARK: - Keys: three layers, escape pops one

    /// Which field the window's field editor is serving right now. The
    /// stored layer cannot answer this: a field entered by mouse never
    /// announced itself, and escape then closed the window instead of
    /// unfocusing — found by the first person who clicked into one.
    private func activeField() -> NSTextField? {
        guard let editor = panel.firstResponder as? NSTextView,
              let field = editor.delegate as? NSTextField else { return nil }
        return field
    }

    /// Focus is inside an add bar or inline editor when the first
    /// responder is one of its controls or their field editors — the
    /// state where tab must walk the bar rather than feed the page.
    private func inEditingContext() -> Bool {
        if let field = activeField(), field !== searchField { return true }
        guard let responder = panel.firstResponder as? NSView else { return false }
        if addInputs.values.contains(where: { responder === $0
            || responder.isDescendant(of: $0) }) { return true }
        return addBars.contains { responder.isDescendant(of: $0) }
    }

    private func handle(key: String, event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        // A popup or button holding key focus owns the keys that operate
        // it: space and return press, arrows choose, tab moves on, escape
        // hands the keys back. One inside an add bar owns letters too —
        // jumping the page mid-add would throw the half-typed entry away.
        if let control = panel.firstResponder as? NSControl,
           control.window === panel, !(control is NSTextField) {
            let inBar = addBars.contains { control.isDescendant(of: $0) }
            switch key {
            case "space", "return":
                // Pressed here rather than left to AppKit: a focused
                // button takes space but not return on its own, and the
                // two must not behave differently.
                control.performClick(nil)
                return true
            case "up", "down", "left", "right", "tab":
                return false
            case "escape":
                panel.makeFirstResponder(nil)
                if inBar, inlineEdit != nil || !editing.isEmpty {
                    inlineEdit = nil
                    editing = [:]
                    layer = .browsing
                    render()
                }
                return true
            default:
                if inBar { return false }
            }
        }
        if inEditingContext() {
            if key == "escape" {
                panel.makeFirstResponder(nil)
                inlineEdit = nil
                editing = [:]
                layer = .browsing
                render()
                return true
            }
            return false // the bar owns typing, tab, and space
        }
        if key == "tab" { return false } // let AppKit start the key loop
        switch layer {
        case .browsing:
            return browsingKey(key)
        case .searching:
            return searchingKey(key)
        case .editing:
            layer = .browsing
            return browsingKey(key)
        }
    }

    private func browsingKey(_ key: String) -> Bool {
        if showingChanged {
            if key == "escape" {
                showingChanged = false
                render()
            } else if let digit = Int(key), (1...9).contains(digit),
                      digit <= sections.count {
                // The changed view is a stop, not a mode: any pane
                // address leaves it and goes there.
                showingChanged = false
                pane = digit - 1
                render()
            }
            return true
        }
        if listFocus != nil { return listKey(key) }
        if key == "return", let armed = armedRow {
            armedRow = nil
            activate(row: armed)
            return true
        }
        if key != "return" { armedRow = nil }
        if key == "escape" {
            close()
            return true
        }
        if key == "/" {
            layer = .searching
            hits = []
            hitSelection = 0
            render()
            if let searchField { panel.makeFirstResponder(searchField) }
            return true
        }
        if let digit = Int(key), (1...9).contains(digit), digit <= sections.count {
            pane = digit - 1
            highlightRow = nil
            listFocus = nil
            inlineEdit = nil
            editing = [:]
            render()
            panel.makeFirstResponder(nil)
            return true
        }
        if let row = labeled[key] {
            activate(row: row)
            return true
        }
        return true
    }

    /// Inside a list: arrows select, return edits, delete removes, a is
    /// the add line, escape steps back out.
    private func listKey(_ key: String) -> Bool {
        guard let focus = listFocus,
              case .table(let kind, let entries) = sections[pane].rows[focus.row].control
        else { listFocus = nil; return true }
        switch key {
        case "escape":
            listFocus = nil
            render()
        case "down":
            listFocus = (focus.row, min(entries.count - 1, focus.entry + 1))
            render()
        case "up":
            listFocus = (focus.row, max(0, focus.entry - 1))
            render()
        case "return":
            guard entries.indices.contains(focus.entry) else { break }
            if kind == .links || kind == .routes {
                beginInlineEdit(kind: kind, key: entries[focus.entry].key)
            }
        case "delete":
            guard entries.indices.contains(focus.entry) else { break }
            // Focus settles before the remove: the write renders, and the
            // render must already know where the selection lands.
            listFocus = entries.count <= 1 ? nil : (focus.row, max(0, focus.entry - 1))
            removeEntry(kind: kind, key: entries[focus.entry].key)
        case "a":
            listFocus = nil
            // Repaint before the field takes over: without it the row
            // keeps its focus tint and the window shows two focuses.
            render()
            if let input = addInputs[addKey(kind)] {
                panel.makeFirstResponder(input)
            }
        default:
            // A digit is a pane address everywhere, list mode included.
            if let digit = Int(key), (1...9).contains(digit), digit <= sections.count {
                listFocus = nil
                pane = digit - 1
                highlightRow = nil
                render()
                panel.makeFirstResponder(nil)
            }
        }
        return true
    }

    private func beginInlineEdit(kind: SettingsModel.TableKind, key: String) {
        inlineEdit = ("\(kind)", key)
        listFocus = nil
        switch kind {
        case .links: editing["links"] = key
        case .routes: editing["routes"] = key
        default: break
        }
        render()
        if let first = addInputs[addKey(kind)] {
            panel.makeFirstResponder(first)
        }
    }

    private func searchingKey(_ key: String) -> Bool {
        switch key {
        case "escape":
            layer = .browsing
            render()
            return true
        case "return":
            guard hits.indices.contains(hitSelection) else { return true }
            let hit = hits[hitSelection]
            pane = hit.section
            highlightRow = hit.row
            layer = .browsing
            render()
            return true
        case "down":
            // Twelve hits are drawn; the selection stays where the eye is.
            hitSelection = max(0, min(min(11, hits.count - 1), hitSelection + 1))
            renderHits()
            return true
        case "up":
            hitSelection = max(0, hitSelection - 1)
            renderHits()
            return true
        default:
            return false
        }
    }

    // MARK: - Field focus

    func controlTextDidChange(_ notification: Notification) {
        guard layer == .searching, let field = searchField,
              (notification.object as? NSTextField) === field else { return }
        hits = SettingsModel.search(field.stringValue, in: sections)
        hitSelection = 0
        renderHits()
    }

    // MARK: - Activation and writes

    private func activate(row index: Int) {
        let row = sections[pane].rows[index]
        if row.dimmed { return }
        switch row.control {
        case .toggle(let value):
            write(row.path, .bool(!value))
        case .choice:
            // Open, never cycle: cycling wrote values that skipped the
            // path where tokens resolve, and a menu is what a person
            // expects a letter to summon anyway.
            popups[index]?.performClick(nil)
        case .number, .text:
            if let field = fields[index] {
                layer = .editing
                panel.makeFirstResponder(field)
            }
        case .table(let kind, let entries):
            if !entries.isEmpty {
                listFocus = (index, 0)
                render()
            } else if let input = addInputs[addKey(kind)] {
                panel.makeFirstResponder(input)
            }
        case .readout:
            break
        }
    }

    /// Return is the only commit. A field left any other way — tab,
    /// click, teardown — writes nothing, which is what makes tab safe to
    /// walk a bar with: the first draft fired the field's action on every
    /// end of editing, so tabbing out of a half-typed link *added* it.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let field = control as? NSTextField, field !== searchField else { return false }
        commit(field)
        return true
    }

    /// A row field abandoned without return snaps back to what the config
    /// says, so what the window shows is never a value that was not
    /// written. Bar fields keep their text — tab walks a bar mid-thought.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field !== searchField,
              let path = field.identifier?.rawValue, !path.isEmpty,
              !path.hasPrefix("bar|") else { return }
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        guard movement != NSTextMovement.return.rawValue,
              let row = sections.lazy.flatMap(\.rows).first(where: { $0.path == path })
        else { return }
        switch row.control {
        case .number(let value, _, _, _): field.stringValue = String(value)
        case .text(let value, _): field.stringValue = value
        default: break
        }
    }

    /// Resolved by the config path stamped on the field, never by index:
    /// end-editing fires during pane switches and re-renders, when any
    /// index into the current pane is a lie — found by a crash log.
    private func commit(_ field: NSTextField) {
        if let id = field.identifier?.rawValue, id.hasPrefix("bar|") {
            // Return inside an add bar means Add: type, tab, type, return.
            performAdd(String(id.dropFirst(4)))
            return
        }
        guard let path = field.identifier?.rawValue, !path.isEmpty,
              let row = sections.lazy.flatMap(\.rows).first(where: { $0.path == path })
        else { return }
        switch row.control {
        case .number(_, let low, let high, _):
            let clamped = max(low, min(high, Int(field.integerValue)))
            write(row.path, .int(clamped))
        case .text:
            write(row.path, .string(field.stringValue))
        default:
            break
        }
        panel.makeFirstResponder(nil)
        layer = .browsing
    }

    private func write(_ path: String, _ value: ConfigValue) {
        guard !path.isEmpty else { return }
        if let problem = apply?(path, value) {
            Log.error("settings", ["write": path, "problem": problem])
        }
    }

    @objc private func changedPressed() {
        showingChanged = true
        listFocus = nil
        render()
    }

    @objc private func railClicked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view,
              let index = railRows.firstIndex(where: { $0 === view }) else { return }
        pane = index
        highlightRow = nil
        layer = .browsing
        showingChanged = false
        listFocus = nil
        armedRow = nil
        inlineEdit = nil
        editing = [:]
        render()
        panel.makeFirstResponder(nil)
    }

    @objc private func presetPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "preset" else { return }
        write(parts[1], .string(parts[2]))
    }

    /// Back to the default, read from the same tree the dot compares
    /// against — resetting is a write like any other.
    @objc private func resetPressed(_ sender: NSButton) {
        guard let dotted = sender.identifier?.rawValue, !dotted.isEmpty else { return }
        let path = dotted.split(separator: ".").map(String.init)
        guard let value = ConfigDefaults.tree.value(at: path) else { return }
        write(dotted, value)
    }

    @objc private func togglePressed(_ sender: AccentSwitch) {
        guard let index = owningRow(of: sender) else { return }
        let row = sections[pane].rows[index]
        if case .toggle(let value) = row.control, !row.dimmed {
            write(row.path, .bool(!value))
        } else {
            render() // a dimmed switch snaps back
        }
    }

    @objc private func choicePressed(_ sender: NSPopUpButton) {
        guard let index = owningRow(of: sender) else { return }
        let row = sections[pane].rows[index]
        guard case .choice(let options, _, _) = row.control,
              options.indices.contains(sender.indexOfSelectedItem) else { return }
        // Every option is the value the config stores — a mode word, or a
        // profile reference like brave:Xonar.
        write(row.path, .string(options[sender.indexOfSelectedItem]))
    }

    private func owningRow(of control: NSView) -> Int? {
        rowViews.first { control.isDescendant(of: $0.value) }?.key
    }

    // MARK: - Table edits (one entry at its own path, never the whole table)

    /// Rewriting a table whole from the parsed config silently erased any
    /// sibling the loader had rejected — a link the doctor flagged as
    /// fixable vanished when its neighbor was edited. Every edit now
    /// touches only the entry it names.
    private func entryPath(_ kind: SettingsModel.TableKind, _ key: String) -> [String] {
        switch kind {
        case .links: return ["web", "links", key]
        case .routes: return ["web", "routes", key]
        case .calendars: return ["meetings", "calendars", key]
        case .excludeApps: return ["clipboard", "exclude-apps", key]
        case .excludePatterns: return ["clipboard", "exclude", key]
        case .draftWords: return ["draft", "words", key]
        case .keyRemaps: return ["keys", key]
        }
    }

    private func writeEntries(remove removals: [[String]] = [],
                              set sets: [([String], ConfigValue)] = []) {
        guard !removals.isEmpty || !sets.isEmpty else { return }
        if let problem = applyEntries?(removals, sets) {
            Log.error("settings", ["write": "entries", "problem": problem])
        }
    }

    private func removeEntry(kind: SettingsModel.TableKind, key: String) {
        writeEntries(remove: [entryPath(kind, key)])
    }

    /// Always the table form: the schema declares a link as a section
    /// with keys, and the editor once wrote bare strings that the loader
    /// dropped and the doctor flagged — a problem this window created and
    /// could not fix.
    private func linkValue(url: String, profile: String?) -> ConfigValue {
        var table: [String: ConfigValue] = ["url": .string(url)]
        if let profile, !profile.isEmpty {
            table["profile"] = .string(config.browserProfiles[profile.lowercased()]?
                .reference ?? profile)
        }
        return .table(table)
    }

    /// A reference as the file writes it, wearing the browser's own casing.
    private func reference(_ key: String) -> String {
        config.browserProfiles[key]?.reference ?? key
    }

    // MARK: - Drawing

    /// Re-entrancy latch. Tearing down a focused field ends its editing,
    /// and anything that fires from there — a write, a config reload —
    /// can ask for another render while this one is mid-surgery. The
    /// second request runs after, whole, instead of interleaving two
    /// view trees into the window: the interleaving is exactly what once
    /// left a frozen copy of the pane floating over the live one.
    private var inRender = false
    private var renderQueued = false

    private func render() {
        if inRender {
            renderQueued = true
            return
        }
        inRender = true
        defer {
            inRender = false
            if renderQueued {
                renderQueued = false
                DispatchQueue.main.async { [weak self] in self?.render() }
            }
        }
        let keepScroll = lastRenderedPane == pane && !showingChanged
        let offset = paneScroll?.contentView.bounds.origin
        lastRenderedPane = pane
        // The doctor and the machine probes hit disk and LaunchServices;
        // render runs per keystroke while the window is up. A one-second
        // memo keeps them fresh at human speed and off the key path — a
        // commit reloads the config, which pushes fresh state through the
        // next render anyway.
        let now = Date()
        let machine: SettingsModel.MachineState
        let findings: [String]
        if let cached = doctorCache, now.timeIntervalSince(cached.at) < 1 {
            (machine, findings) = (cached.machine, cached.problems)
        } else {
            machine = machineState()
            findings = problems()
            doctorCache = (machine, findings, now)
        }
        sections = SettingsModel.catalog(config: config, machine: machine,
                                         problems: findings)
        recycledSwitches = switches
        switches = [:]
        // End any editing before the views under it go away — a field
        // editor serving a removed field is how ghost text gets drawn.
        if let responder = panel.firstResponder as? NSView,
           responder !== root, responder.isDescendant(of: root) {
            panel.makeFirstResponder(nil)
        }
        for view in root.subviews where view is NSStackView { view.removeFromSuperview() }
        rowViews = [:]
        fields = [:]
        popups = [:]
        editableFields = []
        addInputs = [:]
        addBars = []
        popupTokens = [:]
        searchField = nil
        labeled = [:]
        railRows = []

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 4
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.addArrangedSubview(buildRail())
        if showingChanged {
            columns.addArrangedSubview(buildChangedPane())
        } else {
            columns.addArrangedSubview(layer == .searching ? buildSearchPane() : buildPane())
        }
        root.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            columns.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            columns.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            columns.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
        ])
        if keepScroll, let offset, let paneScroll {
            root.layoutSubtreeIfNeeded()
            paneScroll.contentView.scroll(to: offset)
            paneScroll.reflectScrolledClipView(paneScroll.contentView)
        }
        // A reload mid-search rebuilt the field; typing must not die with
        // the old one. The hits die with it, though: results standing for
        // a query the empty field no longer shows would be an answer with
        // no question.
        if layer == .searching, let searchField {
            if searchField.stringValue.isEmpty, !hits.isEmpty {
                hits = []
                renderHits()
            }
            panel.makeFirstResponder(searchField)
        }
    }

    /// Buttons and click targets wear the pointing hand, and join the
    /// key view loop so tab reaches them and space presses them — the
    /// letters and digits are the point of this window, and a control
    /// the keyboard cannot reach breaks the promise.
    private final class HandButton: NSButton {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    private final class KeyPopUp: NSPopUpButton {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    private final class HandStack: NSStackView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    private func buildRail() -> NSView {
        let rail = NSStackView()
        rail.orientation = .vertical
        rail.alignment = .leading
        rail.spacing = 18
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.widthAnchor.constraint(equalToConstant: Self.railWidth).isActive = true
        for (index, section) in sections.enumerated() {
            let row = HandStack()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.addArrangedSubview(chip(String(index + 1), lit: index == pane))
            row.addArrangedSubview(label(section.name, size: BarTheme.Scale.body,
                                         weight: index == pane ? .semibold : .regular,
                                         color: index == pane ? .labelColor : BarTheme.secondaryColor))
            let click = NSClickGestureRecognizer(target: self,
                                                 action: #selector(railClicked(_:)))
            row.addGestureRecognizer(click)
            railRows.append(row)
            rail.addArrangedSubview(row)
        }
        rail.addArrangedSubview(spacer())
        let changed = HandButton(title: "● changed from default", target: self,
                                 action: #selector(changedPressed))
        changed.isBordered = false
        changed.font = .systemFont(ofSize: BarTheme.Scale.meta)
        changed.contentTintColor = BarTheme.secondaryColor
        rail.addArrangedSubview(changed)
        rail.addArrangedSubview(label("/ search", size: BarTheme.Scale.meta,
                                      weight: .regular, color: BarTheme.secondaryColor))
        rail.addArrangedSubview(label("esc closes", size: BarTheme.Scale.meta,
                                      weight: .regular, color: BarTheme.secondaryColor))
        return rail
    }

    private func buildPane() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 20
        list.translatesAutoresizingMaskIntoConstraints = false

        list.addArrangedSubview(label(sections[pane].name.uppercased(), size: BarTheme.Scale.meta,
                                      weight: .semibold, color: BarTheme.secondaryColor))

        let rows = sections[pane].rows
        var letters = SettingsModel.labels(for: rows.count).makeIterator()
        var lastGroup: String?
        for (index, row) in rows.enumerated() {
            if let group = row.group, group != lastGroup {
                let header = label(group.uppercased(), size: BarTheme.Scale.meta, weight: .semibold,
                                   color: BarTheme.secondaryColor)
                if let last = list.arrangedSubviews.last {
                    list.setCustomSpacing(24, after: last)
                }
                list.addArrangedSubview(header)
                list.setCustomSpacing(10, after: header)
                lastGroup = group
            }
            var interactive: Bool
            if case .readout = row.control { interactive = false } else { interactive = !row.dimmed }
            let letter = interactive ? letters.next() : nil
            if let letter { labeled[letter] = index }
            let view = buildRow(row, index: index, letter: letter)
            rowViews[index] = view
            list.addArrangedSubview(view)
            list.setCustomSpacing(row.detail == nil ? 20 : 25, after: view)
            if index == highlightRow {
                pulse(view)
                let control = row.control
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch control {
                    case .number, .text:
                        if let field = self.fields[index] {
                            self.panel.makeFirstResponder(field)
                        }
                    case .toggle, .choice:
                        self.armedRow = index
                    default:
                        break
                    }
                }
            }
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = FlippedView.wrapping(list, width: Self.width - Self.railWidth - 60)
        paneScroll = scroll
        return scroll
    }

    /// Everything the dot marks, on one page: the config's difference
    /// from defaults, as a view. Escape returns.
    private func buildChangedPane() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 20
        list.translatesAutoresizingMaskIntoConstraints = false
        list.addArrangedSubview(label("CHANGED FROM DEFAULT", size: BarTheme.Scale.meta,
                                      weight: .semibold, color: BarTheme.secondaryColor))
        var any = false
        for (sectionIndex, section) in sections.enumerated() {
            let changed = section.rows.enumerated().filter { !$0.element.isDefault
                && !$0.element.path.isEmpty }
            guard !changed.isEmpty else { continue }
            any = true
            let header = label(section.name.uppercased(), size: BarTheme.Scale.meta, weight: .semibold,
                               color: BarTheme.secondaryColor)
            list.addArrangedSubview(header)
            for (rowIndex, row) in changed {
                let line = HandStack()
                line.orientation = .horizontal
                line.alignment = .centerY
                line.spacing = 9
                line.addArrangedSubview(label(row.title, size: BarTheme.Scale.body, weight: .regular,
                                              color: .labelColor))
                line.addArrangedSubview(label(row.path, size: BarTheme.Scale.meta, weight: .regular,
                                              color: BarTheme.secondaryColor, mono: true))
                let go = NSClickGestureRecognizer(target: self,
                                                  action: #selector(changedRowClicked(_:)))
                line.addGestureRecognizer(go)
                line.identifier = NSUserInterfaceItemIdentifier("\(sectionIndex)|\(rowIndex)")
                list.addArrangedSubview(line)
            }
        }
        if !any {
            list.addArrangedSubview(label("Everything is at its default.", size: BarTheme.Scale.body,
                                          weight: .regular, color: BarTheme.secondaryColor))
        }
        list.addArrangedSubview(label("esc returns", size: BarTheme.Scale.meta, weight: .regular,
                                      color: BarTheme.secondaryColor))
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = FlippedView.wrapping(list, width: Self.width - Self.railWidth - 60)
        return scroll
    }

    @objc private func changedRowClicked(_ gesture: NSClickGestureRecognizer) {
        guard let id = gesture.view?.identifier?.rawValue else { return }
        let parts = id.split(separator: "|").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        showingChanged = false
        pane = parts[0]
        highlightRow = parts[1]
        render()
    }

    private func buildRow(_ row: SettingsModel.Row, index: Int, letter: String?) -> NSView {
        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12
        if row.dimmed { line.alphaValue = 0.45 }

        line.addArrangedSubview(letter.map { chip($0, lit: false) } ?? chipSpacer())

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 7
        titleRow.addArrangedSubview(label(row.title, size: BarTheme.Scale.body, weight: .regular,
                                          color: .labelColor))
        for cap in row.keycaps {
            titleRow.addArrangedSubview(keycap(cap))
        }
        if !row.isDefault {
            titleRow.addArrangedSubview(label("●", size: 8, weight: .regular,
                                              color: BarTheme.accent))
            switch row.control {
            case .choice, .number, .text:
                let reset = HandButton(title: "reset", target: self,
                                       action: #selector(resetPressed(_:)))
                reset.bezelStyle = .inline
                reset.controlSize = .regular
                reset.font = .systemFont(ofSize: BarTheme.Scale.meta, weight: .medium)
                reset.contentTintColor = BarTheme.secondaryColor
                reset.identifier = NSUserInterfaceItemIdentifier(row.path)
                titleRow.addArrangedSubview(reset)
            default:
                break
            }
        }
        text.addArrangedSubview(titleRow)
        if !row.path.isEmpty {
            text.addArrangedSubview(label(row.path, size: BarTheme.Scale.meta, weight: .regular,
                                          color: BarTheme.secondaryColor, mono: true))
        }
        if let detail = row.detail {
            let wrapped = NSTextField(wrappingLabelWithString: detail)
            wrapped.font = .systemFont(ofSize: BarTheme.Scale.meta)
            wrapped.textColor = BarTheme.secondaryColor
            wrapped.isSelectable = false
            wrapped.preferredMaxLayoutWidth = 400
            text.addArrangedSubview(wrapped)
        }
        if let problem = row.problem {
            let flagged = NSTextField(wrappingLabelWithString: problem)
            flagged.font = .systemFont(ofSize: BarTheme.Scale.meta)
            flagged.textColor = .systemOrange
            flagged.isSelectable = false
            flagged.preferredMaxLayoutWidth = 400
            text.addArrangedSubview(flagged)
        }
        if !row.presets.isEmpty {
            text.setCustomSpacing(9, after: text.arrangedSubviews.last!)
            for chunk in stride(from: 0, to: row.presets.count, by: 3) {
                let presetRow = NSStackView()
                presetRow.orientation = .horizontal
                presetRow.spacing = 7
                for preset in row.presets[chunk..<min(chunk + 3, row.presets.count)] {
                    let button = HandButton(title: preset.label, target: self,
                                            action: #selector(presetPressed(_:)))
                    button.bezelStyle = .inline
                    button.controlSize = .regular
                    button.font = .systemFont(ofSize: BarTheme.Scale.meta, weight: .medium)
                    button.identifier = NSUserInterfaceItemIdentifier(
                        "preset|\(row.path)|\(preset.value)")
                    presetRow.addArrangedSubview(button)
                }
                text.addArrangedSubview(presetRow)
            }
        }
        if case .table(let kind, let entries) = row.control {
            text.setCustomSpacing(8, after: text.arrangedSubviews.last!)
            text.addArrangedSubview(buildTable(kind: kind, entries: entries,
                                               paneRow: index))
        }
        line.addArrangedSubview(text)
        line.addArrangedSubview(spacer())
        line.addArrangedSubview(buildControl(row, index: index))
        return line
    }

    private func buildControl(_ row: SettingsModel.Row, index: Int) -> NSView {
        switch row.control {
        case .toggle(let value):
            let toggle: AccentSwitch
            if let kept = recycledSwitches[row.path] {
                kept.removeFromSuperview()
                kept.set(value ? .on : .off, animated: true)
                toggle = kept
            } else {
                toggle = AccentSwitch(frame: .zero)
                toggle.state = value ? .on : .off
            }
            switches[row.path] = toggle
            toggle.isEnabled = !row.dimmed
            toggle.target = self
            toggle.action = #selector(togglePressed(_:))
            return toggle
        case .choice(let options, let labels, let current):
            let popup = KeyPopUp()
            popup.addItems(withTitles: labels)
            // A choice of colours wears the colours, so the two can be
            // compared by eye where they are chosen.
            if row.path == "appearance.accent" {
                for (item, option) in zip(popup.itemArray, options) {
                    if let accent = Config.Accent(rawValue: option) {
                        item.image = BarTheme.swatch(BarTheme.accent(for: accent))
                    }
                }
            }
            if let at = options.firstIndex(of: current) {
                popup.selectItem(at: at)
            }
            popup.font = .systemFont(ofSize: BarTheme.Scale.meta)
            popup.target = self
            popup.action = #selector(choicePressed(_:))
            popups[index] = popup
            return popup
        case .number(let value, _, _, let unit):
            let holder = NSStackView()
            holder.orientation = .horizontal
            holder.alignment = .centerY
            holder.spacing = 6
            let field = editableField(String(value), width: 68)
            field.identifier = NSUserInterfaceItemIdentifier(row.path)
            fields[index] = field
            holder.addArrangedSubview(field)
            if let unit {
                holder.addArrangedSubview(label(unit, size: BarTheme.Scale.meta, weight: .regular,
                                                color: BarTheme.secondaryColor))
            }
            return holder
        case .text(let value, let placeholder):
            let field = editableField(value, width: 240)
            field.identifier = NSUserInterfaceItemIdentifier(row.path)
            field.placeholderString = placeholder
            fields[index] = field
            return field
        case .readout(let value, let sub):
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .trailing
            column.spacing = 3
            let read = NSTextField(wrappingLabelWithString: value)
            read.font = .systemFont(ofSize: BarTheme.Scale.body)
            read.textColor = BarTheme.secondaryColor
            read.alignment = .right
            read.isSelectable = false
            read.preferredMaxLayoutWidth = 230
            column.addArrangedSubview(read)
            if let sub {
                column.addArrangedSubview(label(sub, size: BarTheme.Scale.meta, weight: .regular,
                                                color: BarTheme.secondaryColor, mono: true))
            }
            return column
        case .table:
            return NSView() // the table renders under the title column
        }
    }

    // MARK: - Tables

    private func addKey(_ kind: SettingsModel.TableKind) -> String { "\(kind)" }

    private func buildTable(kind: SettingsModel.TableKind,
                            entries: [SettingsModel.TableEntry],
                            paneRow: Int) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        var lastHeader: String?
        for (entryIndex, entry) in entries.enumerated() {
            if let header = entry.header, header != lastHeader {
                let title = label(header, size: BarTheme.Scale.meta, weight: .semibold,
                                  color: BarTheme.secondaryColor)
                if let last = column.arrangedSubviews.last {
                    column.setCustomSpacing(10, after: last)
                }
                column.addArrangedSubview(title)
                lastHeader = header
            }
            // The entry being edited becomes its own fields, in place.
            if let inlineEdit, inlineEdit.kind == "\(kind)", inlineEdit.key == entry.key {
                column.addArrangedSubview(buildInlineEditor(kind: kind))
                continue
            }
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            var display = entry.display
            var sub = entry.sub
            if kind == .excludeApps {
                if let name = appDisplayName(entry.key) {
                    display = name
                    sub = entry.key
                }
            }
            let name = label(display, size: BarTheme.Scale.body, weight: .regular, color: .labelColor)
            row.addArrangedSubview(name)
            var subLabel: NSTextField?
            if let sub {
                let mono = label(sub, size: BarTheme.Scale.meta, weight: .regular,
                                 color: BarTheme.secondaryColor, mono: true)
                subLabel = mono
                row.addArrangedSubview(mono)
            }
            if kind == .links || kind == .routes {
                // On the words, never the row: a recognizer spanning the
                // row raced the Remove button living inside it.
                for target in [name, subLabel].compactMap({ $0 }) {
                    let click = NSClickGestureRecognizer(
                        target: self, action: #selector(entryClicked(_:)))
                    target.addGestureRecognizer(click)
                    target.identifier = NSUserInterfaceItemIdentifier(
                        "\(addKey(kind))|\(entry.key)")
                }
            }
            let button = HandButton(title: "Remove", target: self,
                                    action: #selector(removePressed(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = .systemFont(ofSize: BarTheme.Scale.body)
            button.identifier = NSUserInterfaceItemIdentifier("\(addKey(kind))|\(entry.key)")
            row.addArrangedSubview(button)
            if let focus = listFocus, focus.row == paneRow, focus.entry == entryIndex {
                row.wantsLayer = true
                row.layer?.backgroundColor = BarTheme.accent
                    .withAlphaComponent(0.14).cgColor
                row.layer?.cornerRadius = 5
            }
            column.addArrangedSubview(row)
        }
        // One editor at a time: while an entry is being edited inline,
        // its fields are the add inputs, and a second bar would steal
        // them back.
        if inlineEdit?.kind != "\(kind)" {
            if let last = column.arrangedSubviews.last {
                column.setCustomSpacing(10, after: last)
            }
            column.addArrangedSubview(buildAddBar(kind: kind))
        }
        return column
    }

    /// The inline editor an entry becomes: the same fields the add line
    /// has, prefilled, with Save and Cancel.
    private func buildInlineEditor(kind: SettingsModel.TableKind) -> NSView {
        let bar = buildAddBar(kind: kind, inline: true)
        switch kind {
        case .links:
            if let link = config.webLinks.first(where: { $0.name == editing["links"] }) {
                (addInputs["links"] as? NSTextField)?.stringValue = link.name
                (addInputs["links.url"] as? NSTextField)?.stringValue = link.url
                selectToken(popup: "links.profile", key: link.profileKey)
            }
        case .routes:
            if let original = editing["routes"], let profile = config.webRoutes[original] {
                (addInputs["routes"] as? NSTextField)?.stringValue = original
                selectToken(popup: "routes.profile", key: profile)
            }
        default:
            break
        }
        return bar
    }

    @objc private func entryClicked(_ gesture: NSClickGestureRecognizer) {
        guard let id = gesture.view?.identifier?.rawValue else { return }
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let kind: SettingsModel.TableKind? = ["links": .links, "routes": .routes][parts[0]]
        if let kind { beginInlineEdit(kind: kind, key: parts[1]) }
    }

    @objc private func cancelInlinePressed(_ sender: NSButton) {
        inlineEdit = nil
        editing = [:]
        render()
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let kind: SettingsModel.TableKind? = [
            "links": .links, "routes": .routes,
            "calendars": .calendars, "excludeApps": .excludeApps,
            "excludePatterns": .excludePatterns, "keyRemaps": .keyRemaps,
            "draftWords": .draftWords,
        ][parts[0]]
        if let kind { removeEntry(kind: kind, key: parts[1]) }
    }

    /// The detected profiles as popup rows: labels for the eye, tokens
    /// for the write. A token *is* the value the config stores —
    /// `brave:Xonar` — so choosing is writing, with nothing in between.
    private func profilePopup(extra: [String] = [], width: CGFloat = 150)
        -> (popup: NSPopUpButton, tokens: [String]) {
        let detected = machineState().detectedProfiles
        let labels = extra + detected.map { "\($0.browserLabel) · \($0.name)" }
        let tokens = extra + detected.map {
            SettingsModel.profileReference(browser: $0.browser, name: $0.name)
        }
        let popup = KeyPopUp()
        popup.addItems(withTitles: labels.isEmpty ? ["none found"] : labels)
        popup.font = .systemFont(ofSize: BarTheme.Scale.meta)
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: width + 40).isActive = true
        return (popup, tokens)
    }

    /// Select the popup row matching a stored reference (or "inherit").
    /// Case folds away: the config may hold `brave:xonar` for a profile
    /// the browser spells `Xonar`.
    private func selectToken(popup name: String, key: String?) {
        guard let popup = addInputs[name] as? NSPopUpButton,
              let tokens = popupTokens[name] else { return }
        guard let key else {
            popup.selectItem(at: 0)
            return
        }
        if let index = tokens.firstIndex(where: { $0.lowercased() == key.lowercased() }) {
            popup.selectItem(at: index)
        }
    }

    /// The chosen token from a tokenized popup.
    private func chosenToken(_ name: String) -> String? {
        guard let popup = addInputs[name] as? NSPopUpButton,
              let tokens = popupTokens[name],
              tokens.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return tokens[popup.indexOfSelectedItem]
    }

    /// One compact line per table: the fields an entry needs, then Add —
    /// or Save and Cancel when it stands in for an entry being edited.
    private func buildAddBar(kind: SettingsModel.TableKind, inline: Bool = false) -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 7
        func field(_ placeholder: String, width: CGFloat) -> NSTextField {
            let field = editableField("", width: width)
            field.placeholderString = placeholder
            field.identifier = NSUserInterfaceItemIdentifier("bar|\(addKey(kind))")
            return field
        }
        func popup(_ titles: [String], width: CGFloat = 130) -> NSPopUpButton {
            let popup = KeyPopUp()
            popup.addItems(withTitles: titles.isEmpty ? ["none found"] : titles)
            popup.font = .systemFont(ofSize: BarTheme.Scale.meta)
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: width + 40).isActive = true
            return popup
        }
        switch kind {
        case .links:
            let name = field("Name", width: 110)
            let url = field("URL", width: 180)
            let (profile, tokens) = profilePopup(extra: ["inherit"], width: 130)
            bar.addArrangedSubview(name)
            bar.addArrangedSubview(url)
            bar.addArrangedSubview(profile)
            addInputs[addKey(kind)] = name
            addInputs["links.url"] = url
            addInputs["links.profile"] = profile
            popupTokens["links.profile"] = tokens
        case .routes:
            let pattern = field("Pattern", width: 150)
            let (profile, tokens) = profilePopup(width: 130)
            bar.addArrangedSubview(pattern)
            bar.addArrangedSubview(profile)
            addInputs[addKey(kind)] = pattern
            addInputs["routes.profile"] = profile
            popupTokens["routes.profile"] = tokens
        case .calendars:
            let calendar = popup(calendarChoices(), width: 170)
            let (profile, tokens) = profilePopup(width: 130)
            bar.addArrangedSubview(calendar)
            bar.addArrangedSubview(profile)
            addInputs[addKey(kind)] = calendar
            addInputs["calendars.profile"] = profile
            popupTokens["calendars.profile"] = tokens
        case .excludeApps:
            let app = popup(appChoices().map(\.name), width: 170)
            bar.addArrangedSubview(app)
            addInputs[addKey(kind)] = app
        case .excludePatterns:
            let pattern = field("Text", width: 170)
            bar.addArrangedSubview(pattern)
            addInputs[addKey(kind)] = pattern
        case .draftWords:
            let word = field("Word", width: 170)
            bar.addArrangedSubview(word)
            addInputs[addKey(kind)] = word
        case .keyRemaps:
            let code = field("Keycode", width: 80)
            let name = popup(Set(Keys.ansi.values).sorted(), width: 90)
            bar.addArrangedSubview(code)
            bar.addArrangedSubview(name)
            addInputs[addKey(kind)] = code
            addInputs["keys.name"] = name
        }
        let commit = HandButton(title: inline ? "Save" : "Add", target: self,
                                action: #selector(addPressed(_:)))
        commit.bezelStyle = .rounded
        commit.controlSize = .regular
        commit.font = .systemFont(ofSize: BarTheme.Scale.body)
        commit.identifier = NSUserInterfaceItemIdentifier(addKey(kind))
        guard inline else {
            bar.addArrangedSubview(commit)
            addBars.append(bar)
            return bar
        }
        // The editor's fields already fill the column; the verbs get
        // their own line rather than falling off its right edge.
        let cancel = HandButton(title: "Cancel", target: self,
                                action: #selector(cancelInlinePressed(_:)))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .regular
        cancel.font = .systemFont(ofSize: BarTheme.Scale.body)
        let verbs = NSStackView(views: [commit, cancel])
        verbs.orientation = .horizontal
        verbs.spacing = 7
        let column = NSStackView(views: [bar, verbs])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        addBars.append(column)
        return column
    }

    @objc private func addPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        performAdd(id)
    }

    private func performAdd(_ id: String) {
        func fieldText(_ key: String) -> String {
            ((addInputs[key] as? NSTextField)?.stringValue ?? "")
                .trimmingCharacters(in: .whitespaces)
        }
        func popupChoice(_ key: String) -> String {
            (addInputs[key] as? NSPopUpButton)?.titleOfSelectedItem ?? ""
        }
        switch id {
        case "links":
            let name = fieldText("links").lowercased()
            let url = fieldText("links.url")
            guard !name.isEmpty, !url.isEmpty else { return }
            var profileKey: String?
            if let token = chosenToken("links.profile"), token != "inherit" {
                profileKey = token
            }
            // Editor state clears before the write: the write renders,
            // and a render that still believes in the editor redraws it.
            // A rename removes the old entry and sets the new in the same
            // write — one reload, no window where the link is gone.
            let replacing = editing["links"]
            editing["links"] = nil
            inlineEdit = nil
            writeEntries(
                remove: replacing.flatMap { $0 == name ? nil : [entryPath(.links, $0)] } ?? [],
                set: [(entryPath(.links, name), linkValue(url: url, profile: profileKey))])
        case "routes":
            let pattern = fieldText("routes").lowercased()
            guard !pattern.isEmpty, let profile = chosenToken("routes.profile") else { return }
            let original = editing["routes"]
            editing["routes"] = nil
            inlineEdit = nil
            writeEntries(
                remove: original.flatMap { $0 == pattern ? nil : [entryPath(.routes, $0)] } ?? [],
                set: [(entryPath(.routes, pattern), .string(reference(profile)))])
        case "calendars":
            let calendar = popupChoice("calendars")
            guard calendar != "none found", !calendar.isEmpty,
                  let profile = chosenToken("calendars.profile") else { return }
            writeEntries(set: [(entryPath(.calendars, calendar), .string(reference(profile)))])
        case "excludeApps":
            let name = popupChoice("excludeApps")
            guard let bundleID = appChoices().first(where: { $0.name == name })?.bundleID
            else { return }
            writeEntries(set: [(entryPath(.excludeApps, bundleID.lowercased()), .bool(true))])
        case "excludePatterns":
            let pattern = fieldText("excludePatterns")
            guard !pattern.isEmpty else { return }
            writeEntries(set: [(entryPath(.excludePatterns, pattern), .bool(true))])
        case "draftWords":
            let word = fieldText("draftWords").trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { return }
            writeEntries(set: [(entryPath(.draftWords, word), .bool(true))])
        case "keyRemaps":
            let code = fieldText("keyRemaps")
            let name = popupChoice("keys.name")
            guard Int64(code) != nil, !name.isEmpty else { return }
            writeEntries(set: [(entryPath(.keyRemaps, code), .string(name))])
        default:
            break
        }
    }

    // MARK: - Search pane

    private func buildSearchPane() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField()
        field.placeholderString = "Search settings"
        field.font = .systemFont(ofSize: BarTheme.Scale.body)
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        searchField = field
        list.addArrangedSubview(field)
        let results = NSStackView()
        results.orientation = .vertical
        results.alignment = .leading
        results.spacing = 6
        results.translatesAutoresizingMaskIntoConstraints = false
        hitsStack = results
        list.addArrangedSubview(results)
        renderHits()
        let holder = NSStackView(views: [list])
        holder.orientation = .vertical
        holder.alignment = .leading
        return holder
    }

    private func renderHits() {
        guard let hitsStack else { return }
        for view in hitsStack.arrangedSubviews { view.removeFromSuperview() }
        for (index, hit) in hits.prefix(12).enumerated() {
            let selected = index == hitSelection
            hitsStack.addArrangedSubview(
                label("\(hit.sectionName)  ·  \(hit.title)", size: BarTheme.Scale.body,
                      weight: selected ? .semibold : .regular,
                      color: selected ? .labelColor : BarTheme.secondaryColor))
        }
        if hits.isEmpty, searchField?.stringValue.isEmpty == false {
            hitsStack.addArrangedSubview(label("nothing matches", size: BarTheme.Scale.body,
                                               weight: .regular, color: BarTheme.secondaryColor))
        }
    }

    private func pulse(_ view: NSView) {
        highlightRow = nil // once; a later render must not relight it
        view.wantsLayer = true
        view.layer?.backgroundColor = BarTheme.accent
            .withAlphaComponent(0.16).cgColor
        view.layer?.cornerRadius = 6
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak view] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                view?.animator().layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    // MARK: - Pieces

    private func editableField(_ value: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(string: value)
        field.font = .systemFont(ofSize: BarTheme.Scale.meta)
        field.delegate = self
        // No target/action on purpose: an action fires on *every* end of
        // editing, so a re-render or a tab committed half-typed values.
        // Return commits through the delegate instead.
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        editableFields.append(field)
        return field
    }

    private func chip(_ text: String, lit: Bool) -> NSView {
        let cap = NSTextField(labelWithString: text)
        cap.font = .systemFont(ofSize: BarTheme.Scale.meta, weight: .medium)
        cap.textColor = lit ? BarTheme.accent : BarTheme.secondaryColor
        cap.alignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        box.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(lit ? 0.12 : 0.06).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            cap.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 21),
            box.heightAnchor.constraint(equalToConstant: 19),
        ])
        return box
    }

    /// The keycap the walk draws, at settings scale.
    private func keycap(_ text: String) -> NSView {
        let cap = NSTextField(labelWithString: text)
        cap.font = .systemFont(ofSize: BarTheme.Scale.meta, weight: .medium)
        cap.textColor = BarTheme.secondaryColor
        cap.alignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            cap.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            cap.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 18),
        ])
        return box
    }

    private func chipSpacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 21).isActive = true
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    // MARK: - Staging

    #if DEBUG
    /// `lodestar __strip-preview 70…78` stages each settings pane.
    static func preview(_ index: Int) -> SettingsController {
        let controller = SettingsController()
        let (config, _) = Config.load()
        controller.config = config
        controller.machineState = {
            var detected: [SettingsModel.DetectedProfile] = []
            for browser in ChromiumBrowser.allCases {
                for name in ChromiumProfiles.displayNames(for: browser) {
                    detected.append(SettingsModel.DetectedProfile(
                        browser: browser.rawValue, browserLabel: browser.label, name: name))
                }
            }
            return .init(accessibility: "Granted", screenRecording: "Not asked yet",
                         calendars: "Granted", browserRole: "Brave holds the role.",
                         savedBrowser: "Brave  (com.brave.Browser)",
                         detectedProfiles: detected)
        }
        DispatchQueue.main.async { controller.open(atPane: index) }
        return controller
    }
    #endif
}

/// AppKit scroll views grow content upward without this; settings read
/// top-down like every document.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    static func wrapping(_ stack: NSStackView, width: CGFloat) -> FlippedView {
        let view = FlippedView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.widthAnchor.constraint(equalToConstant: width - 16),
            view.widthAnchor.constraint(equalToConstant: width),
            view.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 8),
        ])
        return view
    }
}

extension SettingsController {
    /// For the tests: the switch standing for a config path right now.
    func switchView(for path: String) -> AccentSwitch? { switches[path] }
    /// For the tests: a render, the way a config write causes one.
    func rerender() { render() }
}
