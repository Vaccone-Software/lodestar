import AppKit
import LodestarCore

/// The settings window: `SettingsModel` (LodestarCore) decides what exists
/// and what the keys mean; this draws it and translates. One keyable glass
/// window, born centered every time. It opens on the overview: the ten
/// places on a ring around the mark, each with its picture and one line
/// saying what that part of Lodestar is doing. A digit opens a place from
/// anywhere; a place is its picture and sentence on the left and its rows,
/// grouped under headers, on the right, each wearing the letter the catalog
/// gave it. `/` searches, escape steps back one level: a page to its place,
/// a place to the overview, the overview to closed. Every write goes
/// through the same pruning path ⌘K uses, and the tables' add grammars
/// pick from ground truth wherever the machine knows the answer better.
final class SettingsController: NSObject, NSTextFieldDelegate {
    /// The window's keys live on the sheet: ? asks the engine for it, and
    /// escape takes the sheet down before it closes the window.
    var dismissSheet: () -> Bool = { false }

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
    /// A bundle identifier's human name and icon, for the app lists: an
    /// app is shown as people know it, never by its identifier.
    var appDisplayName: (String) -> String? = { _ in nil }
    var appIcon: (String) -> NSImage? = { _ in nil }
    /// The doctor's findings, rendered beside the rows that fix them.
    var problems: () -> [String] = { [] }
    /// The boards the Keyboards page can speak for: attached right now by
    /// the roster, plus any the config has declared keys for. Its own
    /// closure rather than a field of the machine state, because the
    /// machine state is memoized and this must never be.
    var attachedKeyboards: () -> [SettingsModel.Keyboard] = { [] }
    /// Running apps, for the clipboard exclusion picker.
    var appChoices: () -> [(name: String, bundleID: String)] = { [] }
    /// A row's verb that is not a config write: a permission's pane, a
    /// record deleted. Wired by the app delegate.
    var perform: (String) -> Void = { _ in }
    /// ⌘Z and ⇧⌘Z: the window's own last change, undone and made again.
    var undo: () -> Bool = { false }
    var redo: () -> Bool = { false }
    /// A question in plain words, answered with the name of the row it
    /// means, or nil. Apple's on-device model where macOS 26 has it.
    var ask: ((String, [SettingsModel.Section], @escaping (String?) -> Void) -> Void)?

    private let panel = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let root = NSView()

    private var sections: [SettingsModel.Section] = []
    /// The place open, or nil for the overview.
    private var place: Int?
    /// Where a page returns to: the place it was opened from.
    private var pageReturn: Int?
    /// A destructive row's verb, waiting for its letter a second time.
    private var armedAction: Int?
    /// The row a search landed on, and the place and page it is on: it
    /// wears the accent's border there, and only there, until the next key
    /// or click.
    private var landed: (place: Int?, page: String?, row: Int)?
    /// The landed row, when it is on what is showing.
    private var landedRow: Int? {
        guard let landed, landed.place == place, landed.page == openPage else { return nil }
        return landed.row
    }
    /// The model's answer for the query standing in the field.
    private var suggestion: SettingsModel.Hit?
    private var asking = false
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
    private var placeViews: [NSView] = []
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
    /// Popup token tables, so a selected label resolves to its profile.
    private var popupTokens: [String: [String]] = [:]
    private var lastRenderedPane: Int? = -1
    /// The pages behind the panes, rebuilt with them; the one open, by
    /// name, or nil while a pane is showing; and what the window has
    /// chosen on it, which the config does not own.
    private var pages: [SettingsModel.Section] = []
    private var openPage: String?
    private var selectedKeyboard: String?
    private var lastRenderedPage: String?
    /// The Keyboards page's watch: the rule in `KeyboardWatch`, and the
    /// turns that feed it while the page stands.
    private var keyboards = KeyboardWatch()
    private var keyboardTurns: Timer?

    /// What the pane column is showing: the open page, or the pane the
    /// rail has lit. Every handler that reads a row by index reads it
    /// from here, never from `sections[pane]` directly.
    private var current: SettingsModel.Section {
        openPage.flatMap { name in pages.first { $0.name == name } } ?? sections[place ?? 0]
    }
    /// See render(): the doctor's findings and the machine probes, memoized
    /// for one second so per-keystroke renders stop re-reading the disk.
    private var doctorCache: (machine: SettingsModel.MachineState,
                              problems: [String], at: Date)?
    private weak var paneScroll: NSScrollView?

    private static let width: CGFloat = 1000
    private static let height: CGFloat = 680
    /// The place's own column: its picture, name and sentence.
    private static let leftColumn: CGFloat = 228

    override init() {
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        // Settings is a room, not a bar: it may activate the app, which is
        // what lets popup menus track their clicks. The bars stay
        // nonactivating; this one window trades that for working controls.
        panel.styleMask.remove(.nonactivatingPanel)
        panel.autorecalculatesKeyViewLoop = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        // A room floats like every other object, on its own drawn shadow.
        SoftShadow.host(root, in: panel, cornerRadius: BarTheme.glassRadius)
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
            guard let self, event.window === self.panel else { return event }
            // A click moves on from a landing, as a key does.
            self.clearLanding()
            guard !self.panel.isKeyWindow else { return event }
            SystemEvents.activateLodestar()
            self.panel.makeKeyAndOrderFront(nil)
            return event
        }
    }

    private func unwatchClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// `lode ,`: the place for whatever is in front, or the overview.
    func toggle(place name: String? = nil) {
        if isVisible { close(); return }
        open(place: name.flatMap { SettingsModel.placeIndex($0) })
    }

    func open(atPane index: Int) { open(place: index) }

    func open(place index: Int? = nil) {
        place = index.map { max(0, min($0, SettingsModel.paneKeys.count - 1)) }
        openPage = nil
        pageReturn = nil
        armedAction = nil
        layer = .browsing
        highlightRow = nil
        // Nothing survives from the last visit: a window that opens into
        // a stale editor is a window that lies.
        listFocus = nil
        armedRow = nil
        inlineEdit = nil
        editing = [:]
        render()
        let visible = ActivePolicy.presentationFrame
        panel.setGlassFrame(NSRect(x: visible.midX - Self.width / 2,
                              y: visible.midY - Self.height / 2 + 20,
                              width: Self.width, height: Self.height), display: true)
        SystemEvents.activateLodestar()
        watchClicks()
        panel.makeKeyAndOrderFront(nil)
        // AppKit hands focus to the first field in the key loop, which
        // would swallow the row letters. Browsing owns the keys until a
        // letter or a click asks for a field.
        panel.makeFirstResponder(nil)
    }

    func close() {
        unwatchClicks()
        stopKeyboardWatch()
        panel.orderOut(nil)
    }

    // MARK: - The Keyboards page's watch

    /// Start or stop the watch to match what the window is showing.
    /// Called at the end of every render, so opening the page starts it
    /// and leaving the page — or the window — ends it.
    private func updateKeyboardWatch() {
        guard openPage == SettingsModel.keyboardsPage else {
            stopKeyboardWatch()
            return
        }
        keyboards.drew(attachedKeyboards().map(\.id))
        guard keyboardTurns == nil else { return }
        keyboardTurns = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.keyboardWatchTick()
        }
    }

    /// One turn. The window's own going is not checked: the panel is
    /// borderless and every way out of it — escape, the menu item, a
    /// click outside — is `close`, which stops the watch itself.
    private func keyboardWatchTick() {
        guard openPage == SettingsModel.keyboardsPage else {
            stopKeyboardWatch()
            return
        }
        if keyboards.shouldRedraw(attachedKeyboards().map(\.id)) { render() }
    }

    private func stopKeyboardWatch() {
        keyboardTurns?.invalidate()
        keyboardTurns = nil
        keyboards.stopped()
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

    /// Shift as it arrived with the key being handled, for the branches
    /// below the responder checks that see only the key's name.
    private var shiftHeld = false

    private func handle(key: String, event: NSEvent) -> Bool {
        // The landing border stands until the next key, wherever that key
        // goes: the row's own field took the keys after a landing on a
        // number or text, and the border used to outlive it. Return works
        // the landed row and moves on after.
        if key != "return" { clearLanding() }
        if event.modifierFlags.contains(.command) {
            // ⌘Z in a field is the field's; on the page it is the window's.
            guard key == "z", !inEditingContext(), layer != .searching else { return false }
            if event.modifierFlags.contains(.shift) { _ = redo() } else if !undo() { NSSound.beep() }
            return true
        }
        shiftHeld = event.modifierFlags.contains(.shift)
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
        if listFocus != nil { return listKey(key) }
        // A destructive verb asks twice: its own letter again performs it,
        // any other key lets it go. No timer: the ask stands until answered.
        if let armed = armedAction {
            armedAction = nil
            if place != nil || openPage != nil, current.rows.indices.contains(armed),
               current.rows[armed].letter == key, let action = current.rows[armed].action {
                perform(action.id)
                render()
                return true
            }
            render()
        }
        if key == "return", let armed = armedRow {
            armedRow = nil
            activate(row: armed)
            return true
        }
        if key != "return" { armedRow = nil }
        if key == "escape" {
            if dismissSheet() { return true }
            if openPage != nil {
                backPressed()
            } else if place != nil {
                showOverview()
            } else {
                close()
            }
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
        if let index = paneAddress(key) {
            go(to: index)
            return true
        }
        if place != nil || openPage != nil, let row = current.rows.firstIndex(where: { $0.letter == key }) {
            activate(row: row)
            return true
        }
        return true
    }

    private func go(to index: Int) {
        place = index
        openPage = nil
        pageReturn = nil
        highlightRow = nil
        listFocus = nil
        inlineEdit = nil
        editing = [:]
        armedAction = nil
        layer = .browsing
        render()
        panel.makeFirstResponder(nil)
    }

    private func showOverview() {
        place = nil
        openPage = nil
        pageReturn = nil
        highlightRow = nil
        listFocus = nil
        armedAction = nil
        render()
        panel.makeFirstResponder(nil)
    }

    /// A digit is a place's address, everywhere but inside a field.
    private func paneAddress(_ key: String) -> Int? {
        SettingsModel.pane(forKey: key, count: sections.count)
    }

    /// Inside a list: arrows select, return edits, delete removes, a is
    /// the add line, escape steps back out.
    private func listKey(_ key: String) -> Bool {
        guard let focus = listFocus,
              case .table(let kind, let entries) = current.rows[focus.row].control
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
            // A digit is a place's address everywhere, list mode included.
            if let index = paneAddress(key) { go(to: index) }
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
        let shown = shownHits
        switch key {
        case "escape":
            layer = .browsing
            suggestion = nil
            render()
            return true
        case "return":
            guard shown.indices.contains(hitSelection) else { return true }
            land(on: shown[hitSelection])
            return true
        case "down":
            hitSelection = max(0, min(shown.count - 1, hitSelection + 1))
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

    /// The model's pick first, then the plain matches, twelve in all.
    private var shownHits: [SettingsModel.Hit] {
        var list = hits
        if let suggestion { list.removeAll { $0 == suggestion }; list.insert(suggestion, at: 0) }
        return Array(list.prefix(12))
    }

    /// Go to a hit's place and light its row: the accent's border, drawn
    /// once, standing until the next key. Return then does what the row's
    /// letter would.
    private func land(on hit: SettingsModel.Hit) {
        layer = .browsing
        suggestion = nil
        place = hit.section
        openPage = nil
        pageReturn = nil
        highlightRow = hit.row
        landed = (hit.section, nil, hit.row)
        render()
    }

    // MARK: - Field focus

    func controlTextDidChange(_ notification: Notification) {
        guard layer == .searching, let field = searchField,
              (notification.object as? NSTextField) === field else { return }
        let query = field.stringValue
        hits = SettingsModel.search(query, in: sections)
        hitSelection = 0
        suggestion = nil
        renderHits()
        // A question in words, not a name: Apple's model reads it against
        // every row and answers with the row it means.
        let words = query.split(separator: " ").count
        guard words >= 3, let ask else { return }
        asking = true
        renderHits()
        ask(query, sections) { [weak self] name in
            guard let self, self.layer == .searching, self.searchField?.stringValue == query else { return }
            self.asking = false
            if let name, let hit = SettingsModel.hit(forName: name, in: self.sections) {
                self.suggestion = hit
            }
            self.hitSelection = 0
            self.renderHits()
        }
    }

    // MARK: - Activation and writes

    private func activate(row index: Int) {
        let row = current.rows[index]
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
        case .page(let name):
            open(page: name)
        case .selector:
            popups[index]?.performClick(nil)
        case .readout:
            guard let action = row.action else { break }
            if action.destructive {
                armedAction = index
                render()
            } else {
                perform(action.id)
            }
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

    @objc private func placeClicked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view, let index = placeViews.firstIndex(where: { $0 === view }) else { return }
        go(to: index)
    }

    @objc private func overviewPressed() { showOverview() }

    @objc private func searchPressed() {
        layer = .searching
        hits = []
        hitSelection = 0
        render()
        if let searchField { panel.makeFirstResponder(searchField) }
    }

    @objc private func actionPressed(_ sender: NSButton) {
        guard let index = owningRow(of: sender), current.rows.indices.contains(index),
              let action = current.rows[index].action else { return }
        if action.destructive, armedAction != index {
            armedAction = index
            render()
            return
        }
        armedAction = nil
        perform(action.id)
        render()
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
        // A declared key placement has no default to write back to:
        // standard is the line's absence.
        if dotted.hasPrefix("health.keyboards.") {
            writeEntries(remove: [path])
            return
        }
        // A fact only the person can give (Born, Dominant hand) has no
        // default: resetting it is the line's absence.
        guard let value = ConfigDefaults.tree.value(at: path) else {
            writeEntries(remove: [path])
            return
        }
        write(dotted, value)
    }

    @objc private func togglePressed(_ sender: AccentSwitch) {
        guard let index = owningRow(of: sender) else { return }
        let row = current.rows[index]
        if case .toggle(let value) = row.control, !row.dimmed {
            write(row.path, .bool(!value))
        } else {
            render() // a dimmed switch snaps back
        }
    }

    @objc private func choicePressed(_ sender: NSPopUpButton) {
        guard let index = owningRow(of: sender) else { return }
        let row = current.rows[index]
        guard case .choice(let options, _, _) = row.control,
              options.indices.contains(sender.indexOfSelectedItem) else { return }
        // Every option is the value the config stores — a mode word, or a
        // profile reference like brave:Xonar.
        let chosen = options[sender.indexOfSelectedItem]
        if row.path.hasPrefix("health.keyboards.") {
            // A key's placement is one entry of a free table: standard
            // is the entry's absence, so choosing it removes the line
            // rather than writing an empty one.
            let path = row.path.split(separator: ".").map(String.init)
            if chosen.isEmpty {
                writeEntries(remove: [path])
            } else {
                writeEntries(set: [(path, .string(chosen))])
            }
            return
        }
        // Not set, for a key with no default, removes the line rather
        // than writing an empty string the schema refuses.
        if chosen.isEmpty, ConfigDefaults.tree.value(at: row.path.split(separator: ".").map(String.init)) == nil {
            writeEntries(remove: [row.path.split(separator: ".").map(String.init)])
            return
        }
        write(row.path, .string(chosen))
    }

    @objc private func selectorPressed(_ sender: NSPopUpButton) {
        guard let index = owningRow(of: sender) else { return }
        let row = current.rows[index]
        guard case .selector(let options, _, _) = row.control,
              options.indices.contains(sender.indexOfSelectedItem) else { return }
        selectedKeyboard = options[sender.indexOfSelectedItem]
        render()
    }

    @objc private func pagePressed(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, !name.isEmpty else { return }
        open(page: name)
    }

    @objc private func backPressed() {
        openPage = nil
        if let pageReturn { place = pageReturn }
        pageReturn = nil
        highlightRow = nil
        render()
        panel.makeFirstResponder(nil)
    }

    /// A page opens from the place it was reached from, and escape
    /// returns there: Words is one page, behind both Write and Speak.
    private func open(page name: String) {
        guard let page = pages.first(where: { $0.name == name }) else { return }
        pageReturn = place ?? page.parent.flatMap { parent in sections.firstIndex { $0.name == parent } }
        openPage = name
        armedAction = nil
        highlightRow = nil
        listFocus = nil
        armedRow = nil
        inlineEdit = nil
        editing = [:]
        render()
        panel.makeFirstResponder(nil)
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
        case .clipboardTimeZones: return ["clipboard", "time-zones", key]
        case .keyRemaps: return ["keys", key]
        case .editorSkipApps: return ["editor", "skip-apps", key]
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
        // A landing belongs to the place it was found in: leaving ends it.
        if let landed, landed.place != place || landed.page != openPage { self.landed = nil }
        let keepScroll = lastRenderedPane == place && lastRenderedPage == openPage
        let offset = paneScroll?.contentView.bounds.origin
        lastRenderedPane = place
        lastRenderedPage = openPage
        // The doctor and the machine probes hit disk and LaunchServices;
        // render runs per keystroke while the window is up. A one-second
        // memo keeps them fresh at human speed and off the key path — a
        // commit reloads the config, which pushes fresh state through the
        // next render anyway.
        let now = Date()
        var machine: SettingsModel.MachineState
        let findings: [String]
        if let cached = doctorCache, now.timeIntervalSince(cached.at) < 1 {
            (machine, findings) = (cached.machine, cached.problems)
        } else {
            machine = machineState()
            findings = problems()
            doctorCache = (machine, findings, now)
        }
        // The probe above is memoized because it hits disk and
        // LaunchServices and this runs per keystroke. The device list is
        // not, ever: it is a registry read, it is what the Keyboards page
        // is *about*, and a memo of it is how that page came to name a
        // keyboard that had been unpaired for hours while the one in the
        // hands was missing. Read here, outside the memo, so that opening
        // the page — which renders — cannot draw a stale one.
        machine.keyboards = attachedKeyboards()
        sections = SettingsModel.catalog(config: config, machine: machine,
                                         problems: findings)
        pages = SettingsModel.pages(config: config, machine: machine,
                                    view: SettingsModel.ViewState(selectedKeyboard: selectedKeyboard))
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
        placeViews = []
        paneScroll = nil
        for view in root.subviews where view.identifier?.rawValue == "settings.content" { view.removeFromSuperview() }

        let content: NSView
        if layer == .searching {
            content = buildSearchPane()
        } else if place == nil && openPage == nil {
            content = buildOverview()
        } else {
            content = buildPlacePage()
        }
        content.identifier = NSUserInterfaceItemIdentifier("settings.content")
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
        ])
        if keepScroll, let offset, let paneScroll {
            root.layoutSubtreeIfNeeded()
            paneScroll.contentView.scroll(to: offset)
            paneScroll.reflectScrolledClipView(paneScroll.contentView)
        }
        updateKeyboardWatch()
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

    /// A choice, behaving as the system's popup does (keys, tabbing, the
    /// tokens the rows store) and drawn as Lodestar's: the room field's
    /// face, and a menu whose rows rise like the bars' rows with the
    /// accent's dot on the current one, rather than the system's bezel and
    /// a highlight in the Mac's accent.
    private final class KeyPopUp: NSPopUpButton, NSMenuDelegate {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            isBordered = false
            wantsLayer = true
            layer?.cornerRadius = BarTheme.controlRadius
            layer?.borderWidth = 1
            menu?.delegate = self
            tint()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            tint()
        }

        private func tint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = Glass.resolved(BarTheme.well, in: self)
                layer?.borderColor = Glass.resolved(BarTheme.hairline, in: self)
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            let font = BarTheme.secondaryFont
            let widest = menu.items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let width = max(bounds.width, widest + 70)
            for item in menu.items where !item.isSeparatorItem {
                item.view = ChoiceMenuItemView(item: item, chosen: item == selectedItem, width: width, popup: self)
            }
        }
    }

    private final class HandStack: NSStackView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    // MARK: - The overview

    /// The ten places on a ring around the mark: each its picture, its
    /// digit and name, and one line saying what it is doing. A place that
    /// needs the person wears a dot beside its name; nothing points.
    private func buildOverview() -> NSView {
        let field = FlippedView()
        let width = Self.width - 64, height = Self.height - 50
        // Sized so neighbours never touch: down the sides the places sit
        // 2·ry·sin 18° apart (143), and a place stands 136 tall.
        let center = NSPoint(x: width / 2, y: height / 2 - 8)
        let rx: CGFloat = 372, ry: CGFloat = 232

        let ring = ToneView(edge: NSColor.labelColor.withAlphaComponent(Tone.systemDark ? 0.06 : 0.11), edgeWidth: 1, radius: ry)
        ring.frame = NSRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)
        field.addSubview(ring)

        field.addSubview(MarkPool(frame: NSRect(x: center.x - rx * 1.1, y: center.y - ry * 1.25,
                                                width: rx * 2.2, height: ry * 2.5)))

        let markSize = BarTheme.settingsMarkSize
        let mark = NSImageView(frame: NSRect(x: center.x - markSize / 2, y: center.y - markSize / 2,
                                             width: markSize, height: markSize))
        mark.image = Self.markImage(size: markSize)
        field.addSubview(mark)

        for (index, section) in sections.enumerated() {
            let angle = (-90 + 36 * CGFloat(index)) * .pi / 180
            let point = NSPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
            // The mark is the light: each place's shadow falls away from it,
            // so the ring reads as objects around one light. (Flipped field:
            // y grows down here and up in the picture.)
            let tile = buildPlaceTile(section, index: index, away: CGVector(dx: cos(angle), dy: -sin(angle)))
            // The picture sits on the ring; its name and line hang below.
            tile.frame = NSRect(x: point.x - 110, y: point.y - 45, width: 220, height: 148)
            field.addSubview(tile)
            placeViews.append(tile)
        }

        let title = label("Settings", size: BarTheme.Scale.title, weight: .semibold, color: .labelColor)
        title.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        field.addSubview(title)
        // The room's ways are its keys, drawn as every footer draws them.
        let searchRow = Keycaps.line([
            .init(["/"], "Search", action: { [weak self] in self?.searchPressed() }),
        ])
        searchRow.frame = NSRect(x: width - 120, y: 0, width: 120, height: 24)
        field.addSubview(searchRow)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.heightAnchor.constraint(equalToConstant: height).isActive = true
        return field
    }

    private func buildPlaceTile(_ section: SettingsModel.Section, index: Int, away: CGVector? = nil) -> NSView {
        let tile = HandStack()
        tile.orientation = .vertical
        tile.alignment = .centerX
        tile.spacing = 5
        let picture = PictureView()
        picture.away = away
        picture.image = Self.picture(section.picture)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.widthAnchor.constraint(equalToConstant: 120).isActive = true
        picture.heightAnchor.constraint(equalToConstant: 90).isActive = true
        tile.addArrangedSubview(picture)
        let head = NSStackView()
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8
        head.addArrangedSubview(keycap(SettingsModel.paneKey(index, count: sections.count) ?? ""))
        head.addArrangedSubview(label(section.name, size: BarTheme.Scale.body, weight: .medium, color: .labelColor))
        if section.attention { head.addArrangedSubview(Self.dot()) }
        tile.addArrangedSubview(head)
        tile.addArrangedSubview(label(section.status, size: BarTheme.Scale.meta, weight: .regular,
                                      color: BarTheme.secondaryColor))
        tile.setAccessibilityElement(true)
        tile.setAccessibilityRole(.button)
        tile.setAccessibilityLabel("\(section.name), \(section.status)\(section.attention ? ", needs attention" : "")")
        tile.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(placeClicked(_:))))
        return tile
    }

    // MARK: - A place

    /// The door page: the place's picture, name and sentence on the left;
    /// its rows on the right, a header above every group and each group
    /// in one card.
    private func buildPlacePage() -> NSView {
        let section = current
        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 36
        columns.addArrangedSubview(buildPlaceColumn(section))

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 22
        list.translatesAutoresizingMaskIntoConstraints = false
        var groups: [(name: String, rows: [Int])] = []
        for (index, row) in section.rows.enumerated() {
            let name = row.group ?? section.name
            if groups.last?.name == name { groups[groups.count - 1].rows.append(index) }
            else { groups.append((name, [index])) }
        }
        let cardWidth = Self.width - 64 - Self.leftColumn - 36 - 18
        for group in groups {
            let block = NSStackView()
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 8
            let header = label(group.name, size: BarTheme.Scale.meta, weight: .regular, color: BarTheme.secondaryColor)
            let headerWrap = NSStackView(views: [header])
            headerWrap.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
            block.addArrangedSubview(headerWrap)
            let card = Self.card()
            let rowsStack = NSStackView()
            rowsStack.orientation = .vertical
            rowsStack.alignment = .leading
            rowsStack.spacing = 0
            rowsStack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(rowsStack)
            NSLayoutConstraint.activate([
                rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
                rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                card.widthAnchor.constraint(equalToConstant: cardWidth),
            ])
            for (position, index) in group.rows.enumerated() {
                if position > 0 { rowsStack.addArrangedSubview(Self.hairline(width: cardWidth)) }
                let row = section.rows[index]
                if let letter = row.letter { labeled[letter] = index }
                let line = buildRow(row, index: index, width: cardWidth)
                // The row's breathing room, held by its own container: a
                // stack's insets gave way to the card's fitting height.
                let view = NSView()
                view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(line)
                NSLayoutConstraint.activate([
                    line.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
                    line.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
                    line.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    line.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                ])
                rowViews[index] = view
                rowsStack.addArrangedSubview(view)
                if index == landedRow { addLanding(to: view) }
                if index == highlightRow {
                    highlightRow = nil
                    let control = row.control
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        switch control {
                        case .number, .text:
                            if let field = self.fields[index] { self.panel.makeFirstResponder(field) }
                        case .toggle, .choice:
                            self.armedRow = index
                        default:
                            break
                        }
                    }
                }
            }
            block.addArrangedSubview(card)
            list.addArrangedSubview(block)
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = FlippedView.wrapping(list, width: cardWidth + 18)
        scroll.widthAnchor.constraint(equalToConstant: cardWidth + 18).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: Self.height - 50).isActive = true
        // A long place fades into the window's foot rather than being cut
        // by it: the last few points go soft, and scrolling brings them up.
        scroll.wantsLayer = true
        let fade = CAGradientLayer()
        let height = Self.height - 50, soft: CGFloat = 28
        fade.frame = CGRect(x: 0, y: 0, width: cardWidth + 18, height: height)
        // The scroll view's layer is flipped: location 0 is the top.
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, NSNumber(value: Double(1 - soft / height)), 1]
        scroll.layer?.mask = fade
        paneScroll = scroll
        columns.addArrangedSubview(scroll)
        return columns
    }

    private func buildPlaceColumn(_ section: SettingsModel.Section) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: Self.leftColumn).isActive = true
        column.heightAnchor.constraint(equalToConstant: Self.height - 50).isActive = true

        let backTo = openPage == nil ? "Settings" : (pageReturn.map { sections[$0].name } ?? section.parent ?? "Settings")
        let backRow = Keycaps.line([
            .init(["esc"], backTo, action: { [weak self] in
                guard let self else { return }
                if self.openPage == nil { self.overviewPressed() } else { self.backPressed() }
            }),
        ])
        column.addArrangedSubview(backRow)
        column.setCustomSpacing(20, after: backRow)

        // The place's picture floats on its own shadow, as it does on the
        // overview: a picture is an object with no floor, never one set in
        // a box.
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: Self.leftColumn).isActive = true
        card.heightAnchor.constraint(equalToConstant: 172).isActive = true
        let picture = PictureView()
        picture.image = Self.picture(section.picture)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(picture)
        NSLayoutConstraint.activate([
            picture.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            picture.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: 186),
            picture.heightAnchor.constraint(equalToConstant: 140),
        ])
        if openPage == nil, let place {
            let digit = keycap(SettingsModel.paneKey(place, count: sections.count) ?? "")
            digit.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(digit)
            NSLayoutConstraint.activate([
                digit.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                digit.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            ])
        }
        column.addArrangedSubview(card)
        column.setCustomSpacing(20, after: card)
        let name = label(section.name, size: BarTheme.Scale.title, weight: .semibold, color: .labelColor)
        column.addArrangedSubview(name)
        column.setCustomSpacing(8, after: name)
        let sentence = NSTextField(wrappingLabelWithString: section.sentence)
        sentence.font = BarTheme.settingsSentenceFont
        sentence.textColor = .labelColor
        sentence.isSelectable = false
        sentence.preferredMaxLayoutWidth = Self.leftColumn
        column.addArrangedSubview(sentence)
        column.addArrangedSubview(spacer(vertical: true))
        if let note = section.note {
            let quiet = NSTextField(wrappingLabelWithString: note)
            quiet.font = BarTheme.secondaryFont
            quiet.textColor = BarTheme.secondaryColor
            quiet.isSelectable = false
            quiet.preferredMaxLayoutWidth = Self.leftColumn
            column.addArrangedSubview(quiet)
        }
        return column
    }

    private func buildRow(_ row: SettingsModel.Row, index: Int, width: CGFloat) -> NSView {
        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 14
        line.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        if row.dimmed { line.alphaValue = 0.45 }

        let letter = label(row.letter ?? "", size: BarTheme.Scale.meta, weight: .medium,
                           color: BarTheme.secondaryColor, mono: true)
        letter.translatesAutoresizingMaskIntoConstraints = false
        letter.widthAnchor.constraint(equalToConstant: 12).isActive = true
        line.addArrangedSubview(letter)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 7
        titleRow.addArrangedSubview(label(row.title, size: BarTheme.Scale.body, weight: .medium, color: .labelColor))
        for cap in row.keycaps { titleRow.addArrangedSubview(keycap(cap)) }
        text.addArrangedSubview(titleRow)
        let armed = armedAction == index
        if let detail = armed ? row.action?.confirm : row.detail, !detail.isEmpty {
            let wrapped = NSTextField(wrappingLabelWithString: detail)
            wrapped.font = BarTheme.secondaryFont
            wrapped.textColor = armed ? .labelColor : BarTheme.secondaryColor
            wrapped.isSelectable = false
            wrapped.preferredMaxLayoutWidth = width - 230
            text.addArrangedSubview(wrapped)
        }
        if let problem = row.problem {
            let flagged = NSTextField(wrappingLabelWithString: problem)
            flagged.font = BarTheme.secondaryFont
            flagged.textColor = .labelColor
            flagged.isSelectable = false
            flagged.preferredMaxLayoutWidth = width - 250
            let mark = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle",
                                                  accessibilityDescription: "Problem") ?? NSImage())
            mark.symbolConfiguration = BarTheme.symbol
            mark.contentTintColor = .labelColor
            let flaggedRow = NSStackView(views: [mark, flagged])
            flaggedRow.orientation = .horizontal
            flaggedRow.alignment = .firstBaseline
            flaggedRow.spacing = 6
            text.addArrangedSubview(flaggedRow)
        }
        if !row.presets.isEmpty {
            let presetRow = NSStackView()
            presetRow.orientation = .horizontal
            presetRow.spacing = 7
            for preset in row.presets {
                let button = RoomButton(title: preset.label, target: self, action: #selector(presetPressed(_:)))
                button.identifier = NSUserInterfaceItemIdentifier("preset|\(row.path)|\(preset.value)")
                presetRow.addArrangedSubview(button)
            }
            text.setCustomSpacing(8, after: text.arrangedSubviews.last!)
            text.addArrangedSubview(presetRow)
        }
        if case .table(let kind, let entries) = row.control {
            text.setCustomSpacing(8, after: text.arrangedSubviews.last!)
            text.addArrangedSubview(buildTable(kind: kind, entries: entries, paneRow: index))
        }
        line.addArrangedSubview(text)
        line.addArrangedSubview(spacer())
        // Yours: a value you set wears a mark and the way back, beside it.
        if !row.isDefault, !row.path.isEmpty {
            switch row.control {
            case .choice, .number, .text:
                // An action is a key, never a word in grey that happens
                // to be clickable.
                let reset = RoomButton(title: "Reset", target: self, action: #selector(resetPressed(_:)))
                reset.identifier = NSUserInterfaceItemIdentifier(row.path)
                line.addArrangedSubview(reset)
            default:
                break
            }
            if case .table = row.control {} else { line.addArrangedSubview(Self.dot()) }
        }
        if let action = row.action {
            let button = RoomButton(title: armed ? "Confirm" : action.label, target: self,
                                    action: #selector(actionPressed(_:)))
            button.destructive = armed
            if case .readout(let value, _) = row.control, !value.isEmpty {
                line.addArrangedSubview(buildControl(row, index: index))
            }
            line.addArrangedSubview(button)
        } else {
            line.addArrangedSubview(buildControl(row, index: index))
        }
        line.setAccessibilityElement(true)
        line.setAccessibilityLabel([row.title, row.detail].compactMap { $0 }.joined(separator: ". "))
        line.setAccessibilityHelp(row.letter.map { "Press \($0)" })
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
            // Shown and greyed: an editor model this Mac is too small for
            // says what it needs rather than vanishing.
            if !row.disabledChoices.isEmpty {
                popup.autoenablesItems = false
                for (item, option) in zip(popup.itemArray, options) where row.disabledChoices.contains(option) {
                    item.isEnabled = false
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
            // As wide as what it holds: a year, a folder, an address.
            let width: CGFloat = row.path == "web.search-url" ? 280 : row.path == "health.born" ? 72 : 180
            let field = editableField(value, width: width)
            field.identifier = NSUserInterfaceItemIdentifier(row.path)
            field.setPlaceholder(placeholder)
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
        case .page(let name):
            let open = RoomButton(title: "Open", target: self, action: #selector(pagePressed(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(name)
            return open
        case .selector(let options, let labels, let current):
            let popup = KeyPopUp()
            popup.addItems(withTitles: labels)
            if let at = options.firstIndex(of: current) {
                popup.selectItem(at: at)
            }
            popup.font = .systemFont(ofSize: BarTheme.Scale.meta)
            popup.target = self
            popup.action = #selector(selectorPressed(_:))
            popups[index] = popup
            return popup
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
            let sub = entry.sub
            if kind == .excludeApps || kind == .editorSkipApps {
                // The app's icon and name, as the Dock shows it. The
                // identifier is shown only for an app no longer on this
                // Mac, when it is all there is to recognise.
                if let name = appDisplayName(entry.key) { display = name }
                let icon = NSImageView(image: appIcon(entry.key) ?? NSImage())
                icon.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    icon.widthAnchor.constraint(equalToConstant: BarTheme.rowIcon),
                    icon.heightAnchor.constraint(equalToConstant: BarTheme.rowIcon),
                ])
                row.addArrangedSubview(icon)
                row.setCustomSpacing(8, after: icon)
            }
            let name = label(display, size: BarTheme.Scale.meta, weight: .regular, color: .labelColor)
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
            let button = RoomButton(title: "Remove", target: self,
                                    action: #selector(removePressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("\(addKey(kind))|\(entry.key)")
            row.addArrangedSubview(button)
            // The entry the keys are on rises, as the launcher's chosen row
            // does: the raised step and its lit edge, never the accent
            // washed across it.
            if let focus = listFocus, focus.row == paneRow, focus.entry == entryIndex {
                raise(row, sides: 8, ends: 3)
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
            "editorSkipApps": .editorSkipApps, "clipboardTimeZones": .clipboardTimeZones,
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
            field.setPlaceholder(placeholder)
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
        case .excludeApps, .editorSkipApps:
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
        case .clipboardTimeZones:
            let zone = field("City or zone", width: 170)
            bar.addArrangedSubview(zone)
            addInputs[addKey(kind)] = zone
        case .keyRemaps:
            let code = field("Keycode", width: 80)
            let name = popup(Set(Keys.ansi.values).sorted(), width: 90)
            bar.addArrangedSubview(code)
            bar.addArrangedSubview(name)
            addInputs[addKey(kind)] = code
            addInputs["keys.name"] = name
        }
        let commit = RoomButton(title: inline ? "Save" : "Add", target: self,
                                action: #selector(addPressed(_:)))
        commit.identifier = NSUserInterfaceItemIdentifier(addKey(kind))
        guard inline else {
            bar.addArrangedSubview(commit)
            addBars.append(bar)
            return bar
        }
        // The editor's fields already fill the column; the verbs get
        // their own line rather than falling off its right edge.
        let cancel = RoomButton(title: "Cancel", target: self,
                                action: #selector(cancelInlinePressed(_:)))
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
        case "editorSkipApps":
            let name = popupChoice("editorSkipApps")
            guard let bundleID = appChoices().first(where: { $0.name == name })?.bundleID
            else { return }
            writeEntries(set: [(entryPath(.editorSkipApps, bundleID.lowercased()), .bool(true))])
        case "excludePatterns":
            let pattern = fieldText("excludePatterns")
            guard !pattern.isEmpty else { return }
            writeEntries(set: [(entryPath(.excludePatterns, pattern), .bool(true))])
        case "draftWords":
            let word = fieldText("draftWords").trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { return }
            writeEntries(set: [(entryPath(.draftWords, word), .bool(true))])
        case "clipboardTimeZones":
            // A city, an identifier, or an abbreviation, stored as the zone's
            // identifier so the config says one thing for one place.
            // A name that is no zone is refused the way a Mac refuses a key,
            // with the text left in the field to correct.
            guard let zone = ClipTime.zone(named: fieldText("clipboardTimeZones")) else {
                NSSound.beep()
                return
            }
            writeEntries(set: [(entryPath(.clipboardTimeZones, zone.identifier), .bool(true))])
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
        list.spacing = 22
        let backRow = Keycaps.line([
            .init(["esc"], place.map { sections[$0].name } ?? "Settings",
                  action: { [weak self] in self?.searchBackPressed() }),
        ])
        list.addArrangedSubview(backRow)

        let fieldRow = NSStackView()
        fieldRow.orientation = .horizontal
        fieldRow.alignment = .centerY
        fieldRow.spacing = 12
        fieldRow.addArrangedSubview(keycap("/"))
        let field = NSTextField()
        field.setPlaceholder(ask == nil ? "Search every setting" : "Search, or ask in your own words")
        field.font = BarTheme.handFont(BarTheme.Scale.title)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: Self.width - 140).isActive = true
        searchField = field
        fieldRow.addArrangedSubview(field)
        list.addArrangedSubview(fieldRow)
        list.addArrangedSubview(Self.hairline(width: Self.width - 64))

        let results = NSStackView()
        results.orientation = .vertical
        results.alignment = .leading
        results.spacing = 6
        results.translatesAutoresizingMaskIntoConstraints = false
        hitsStack = results
        list.addArrangedSubview(results)
        renderHits()
        return list
    }

    @objc private func searchBackPressed() {
        layer = .browsing
        suggestion = nil
        render()
    }

    @objc private func hitClicked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view, let index = hitsStack?.arrangedSubviews.firstIndex(of: view) else { return }
        let shown = shownHits
        guard shown.indices.contains(index) else { return }
        land(on: shown[index])
    }

    private func renderHits() {
        guard let hitsStack else { return }
        for view in hitsStack.arrangedSubviews { view.removeFromSuperview() }
        let width = Self.width - 64
        for (index, hit) in shownHits.enumerated() {
            let selected = index == hitSelection
            let row = HandStack()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            let parts = hit.address.split(separator: " ").map(String.init)
            // The chosen result is the launcher's chosen row: it rises, and
            // its keys light where the hand goes next.
            for part in parts {
                let cap = Keycaps.cap(part)
                cap.lit = selected
                row.addArrangedSubview(cap)
            }
            row.addArrangedSubview(label(hit.title, size: BarTheme.Scale.body, weight: .medium, color: .labelColor))
            row.addArrangedSubview(label(hit.sectionName, size: BarTheme.Scale.meta, weight: .regular,
                                         color: BarTheme.secondaryColor))
            row.addArrangedSubview(spacer())
            if index == 0, suggestion != nil {
                row.addArrangedSubview(label("Suggested", size: BarTheme.Scale.meta, weight: .regular,
                                             color: BarTheme.secondaryColor))
            }
            if selected { raise(row, sides: 0, ends: 0) }
            row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(hitClicked(_:))))
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.button)
            row.setAccessibilityLabel("\(hit.title), \(hit.sectionName), \(hit.address)")
            hitsStack.addArrangedSubview(row)
        }
        let query = searchField?.stringValue ?? ""
        if asking {
            hitsStack.addArrangedSubview(label("Reading the question", size: BarTheme.Scale.meta,
                                               weight: .regular, color: BarTheme.secondaryColor))
        } else if shownHits.isEmpty, !query.isEmpty {
            hitsStack.addArrangedSubview(label("Nothing matches", size: BarTheme.Scale.body,
                                               weight: .regular, color: BarTheme.secondaryColor))
        }
    }

    // MARK: - The landing

    private weak var landing: NSView?

    /// The row a search landed on rises, the way a bar's chosen row
    /// does: the raised step with its lit top edge, there at once and gone
    /// at once. It is a chosen row, not an alarm, so it neither glows nor
    /// settles.
    private func addLanding(to row: NSView) {
        landing = raise(row, sides: -4, ends: -3)
        DispatchQueue.main.async { [weak row] in
            row?.scrollToVisible(row?.bounds.insetBy(dx: 0, dy: -24) ?? .zero)
        }
    }

    /// Raise a row onto the bars' step, the one way this window says
    /// chosen: a landing, the entry the keys are on, the result picked.
    /// The step reaches `sides` past the row's sides and `ends` past its
    /// top and bottom; a negative reach tucks it inside.
    @discardableResult
    private func raise(_ row: NSView, sides: CGFloat, ends: CGFloat) -> NSView {
        let step = LandingStep()
        step.translatesAutoresizingMaskIntoConstraints = false
        step.setupRaised()
        step.applyRaised(true)
        row.addSubview(step, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            step.topAnchor.constraint(equalTo: row.topAnchor, constant: -ends),
            step.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: ends),
            step.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: -sides),
            step.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: sides),
        ])
        return step
    }

    /// The landing is over: the row settles back, and is not raised again.
    private func clearLanding() {
        guard landed != nil else { return }
        landed = nil
        removeLanding()
    }

    private func removeLanding() {
        landing?.removeFromSuperview()
        landing = nil
    }

    // MARK: - Pieces

    /// The mark in the person's accent, its faces shaded the way the icon
    /// is, from the one definition everything draws the mark from.
    static func markImage(size: CGFloat) -> NSImage {
        let accent = BarTheme.accent.usingColorSpace(.sRGB) ?? .orange
        let rgb = Mark.RGB(red: Double(accent.redComponent), green: Double(accent.greenComponent),
                           blue: Double(accent.blueComponent))
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = rect.width / 2 * 0.96
            let center = NSPoint(x: rect.midX, y: rect.midY)
            for face in Mark.faces {
                let fill = Mark.fill(tone: face.tone, accent: rgb)
                let color = NSColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1)
                let path = NSBezierPath()
                for (i, point) in face.points.enumerated() {
                    let p = NSPoint(x: center.x + point.x * radius, y: center.y - point.y * radius)
                    if i == 0 { path.move(to: p) } else { path.line(to: p) }
                }
                path.close()
                color.setFill(); color.setStroke()
                path.lineWidth = 0.5
                path.lineJoinStyle = .round
                path.fill(); path.stroke()
            }
            return true
        }
    }

    /// A place's picture: shipped in the app's resources beside the
    /// doors. A bare build (the tests, `swift run`) finds them in the
    /// checkout's packaging folder, and without either the card is empty.
    static func picture(_ name: String) -> NSImage? {
        guard !name.isEmpty, let night = file(name) else { return nil }
        return TonedPicture.make(night: night, day: file(name + "-sand"))
    }

    private static func file(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png") { return NSImage(contentsOf: url) }
        #if DEBUG
        let packaging = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("packaging")
        for folder in ["places", "doors"] {
            let url = packaging.appendingPathComponent(folder).appendingPathComponent("\(name).png")
            if let image = NSImage(contentsOf: url) { return image }
        }
        #endif
        return nil
    }

    /// One group's card: a surface on the glass, rounded on the ladder.
    static func card() -> NSView {
        let card = ToneView(fill: BarTheme.well,
                            edge: BarTheme.hairline, edgeWidth: 1,
                            radius: BarTheme.surfaceRadius)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    static func hairline(width: CGFloat) -> NSView {
        let line = ToneView(fill: BarTheme.hairline)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        return line
    }

    static func dot() -> NSView {
        let dot = ToneView(fill: .labelColor, radius: BarTheme.dotRadius)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: BarTheme.dotDiameter).isActive = true
        dot.heightAnchor.constraint(equalToConstant: BarTheme.dotDiameter).isActive = true
        dot.setAccessibilityElement(true)
        dot.setAccessibilityLabel("Set by you")
        return dot
    }

    private func editableField(_ value: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(string: value)
        field.font = BarTheme.handFont(BarTheme.Scale.meta)
        field.delegate = self
        // No target/action on purpose: an action fires on *every* end of
        // editing, so a re-render or a tab committed half-typed values.
        // Return commits through the delegate instead.
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        editableFields.append(field)
        return field
    }

    /// A key you can press is drawn as the key it is: the shared cap. A
    /// lit cap is the pane or row that is current, lit as the launcher
    /// lights the keys of its chosen row.
    private func chip(_ text: String, lit: Bool) -> NSView {
        let cap = Keycaps.cap(text)
        cap.lit = lit
        return cap
    }

    /// A row's own keys, beside its title: the shared cap.
    private func keycap(_ text: String) -> NSView {
        Keycaps.cap(text)
    }

    private func chipSpacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: BarTheme.chipMinWidth).isActive = true
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func spacer(vertical: Bool = false) -> NSView {
        let view = NSView()
        let axis: NSLayoutConstraint.Orientation = vertical ? .vertical : .horizontal
        view.setContentHuggingPriority(.init(1), for: axis)
        view.setContentCompressionResistancePriority(.init(1), for: axis)
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
    /// `lodestar __strip-preview 89` stages the overview, 90…99 each place.
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
            var state = SettingsModel.MachineState(accessibility: "Granted", screenRecording: "Not asked yet",
                         calendars: "Granted", browserRole: "Brave holds the role.",
                         savedBrowser: "Brave  (com.brave.Browser)",
                         detectedProfiles: detected)
            state.isDark = Tone.systemDark
            return state
        }
        controller.place = index < 0 ? nil : index
        DispatchQueue.main.async {
            controller.open(place: index < 0 ? nil : index)
            let env = ProcessInfo.processInfo.environment
            // LODESTAR_SETTINGS_SEARCH stages the search with a query typed;
            // LODESTAR_SETTINGS_LAND ("5 d") stages a landing on that row.
            if let query = env["LODESTAR_SETTINGS_SEARCH"] {
                controller.searchPressed()
                controller.searchField?.stringValue = query
                controller.hits = SettingsModel.search(query, in: controller.sections)
                controller.hitSelection = 0
                controller.renderHits()
            }
            if let land = env["LODESTAR_SETTINGS_LAND"], let place = Int(land.prefix(1)),
               controller.sections.indices.contains(place),
               let row = controller.sections[place].rows.firstIndex(where: { $0.letter == String(land.suffix(1)) }) {
                let section = controller.sections[place]
                controller.land(on: SettingsModel.Hit(section: place, row: row, title: section.rows[row].title,
                                                      sectionName: section.name, address: land))
            }
        }
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
            view.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 32),
        ])
        return view
    }
}

extension SettingsController {
    /// For the tests: a key pressed while browsing, as the panel delivers it.
    @discardableResult
    func pressForTesting(_ key: String) -> Bool { browsingKey(key) }
    /// For the tests: a key as the panel's key handler takes it, before
    /// any field or layer sees it.
    @discardableResult
    func keyForTesting(_ key: String) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: key,
                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
        return handle(key: key, event: event)
    }
    /// For the tests: a search landing on a row.
    func landForTesting(place: Int, row: Int) {
        land(on: SettingsModel.Hit(section: place, row: row, title: "", sectionName: "", address: ""))
    }
    /// For the tests: is a landing border on screen, and on which row?
    var landingForTesting: Int? { landing?.superview == nil ? nil : landedRow }
    /// For the tests: the place open, nil on the overview.
    var placeForTesting: Int? { place }
    /// For the tests: the page open, by name.
    var pageForTesting: String? { openPage }
    /// For the tests: the place the scoped door chose.
    func openForTesting(place name: String?) { open(place: name.flatMap { SettingsModel.placeIndex($0) }) }

    /// For the tests: the switch standing for a config path right now.
    func switchView(for path: String) -> AccentSwitch? { switches[path] }
    /// For the tests: a render, the way a config write causes one.
    func rerender() { render() }

    /// Machine state moved (a model downloading): drawn again when the
    /// pane is open and nothing is being typed into it — a render
    /// rebuilds the fields, and a half-typed word must not be lost to a
    /// progress figure.
    func machineStateChanged() {
        guard panel.isVisible, layer != .editing else { return }
        render()
    }
}


/// The step a Settings row rises onto when a search lands on it: the bars'
/// own raised row.
private final class LandingStep: RaisedRow {}

/// The mark's light on the light page: a faint warm pool spreading from
/// the star under the ring, so the shadows falling away from it have a
/// source. The night needs none; the mark already glows on Slip. The pool
/// is the mark's own light, so it is the person's accent: a fixed orange
/// beside any other accent was a second light in the room.
final class MarkPool: NSView {
    private let glow = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.type = .radial
        glow.locations = [0, 0.45, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(glow)
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glow.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        glow.frame = bounds
        glow.isHidden = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let light = BarTheme.accent.usingColorSpace(.sRGB) ?? .orange
        // Warmer and paler as it spreads, as the fixed pool was.
        let spread = light.blended(withFraction: 0.18, of: .white) ?? light
        glow.colors = [light.withAlphaComponent(0.13).cgColor,
                       spread.withAlphaComponent(0.05).cgColor,
                       spread.withAlphaComponent(0).cgColor]
    }
}
