import Foundation

/// The settings window's mind: which panes exist, which rows each holds,
/// what every row is worth right now, and the three-layer key grammar the
/// window obeys. Pure — the panel draws this and translates clicks; every
/// decision that can be wrong lives here where a test can reach it.
///
/// The grammar is the house's, recombined: digits address places (panes,
/// exactly as `lode 1…9` addresses windows), letters address things (rows,
/// exactly as hints label a window), `/` searches (exactly as the strip
/// does), and escape pops one layer at a time — field to labels, search to
/// labels, labels to closed.
///
/// The covenant, enforced by SettingsCoverageTests: every config leaf has
/// a row here, so the window and the file cannot drift — in either
/// direction, ever. A setting not worth a row is a setting to retire, not
/// to hide.
public enum SettingsModel {
    // MARK: - Rows

    /// The editable tables, each with its own add grammar in the shell.
    public enum TableKind: Equatable {
        case links
        case routes
        case calendars
        case excludeApps
        case excludePatterns
        case draftWords
        case keyRemaps
        case editorSkipApps
        case clipboardTimeZones
    }

    public struct TableEntry: Equatable {
        /// What identifies the entry to a write (registry key, pattern,
        /// calendar name, keycode…).
        public let key: String
        /// What the row shows.
        public let display: String
        /// The differentiator, shown smaller and monospaced: an identifier,
        /// a destination, the profile a rule lands in.
        public let sub: String?
        /// In the user's set. False renders as addable rather than
        /// removable — how detected browser profiles offer themselves.
        public let present: Bool
        /// A mini heading drawn when it changes between entries, so a
        /// list of profiles reads by browser instead of repeating it.
        public let header: String?

        public init(key: String, display: String, sub: String? = nil,
                    present: Bool = true, header: String? = nil) {
            self.key = key
            self.display = display
            self.sub = sub
            self.present = present
            self.header = header
        }
    }

    public enum Control: Equatable {
        case toggle(Bool)
        /// One of a closed set; `labels` is what the popup shows, `options`
        /// what the config stores, index-aligned.
        case choice(options: [String], labels: [String], current: String)
        case number(Int, min: Int, max: Int, unit: String?)
        case text(String, placeholder: String)
        /// Machine states and notes the config does not own. The sub is
        /// the identifier line every list row also wears.
        case readout(String, sub: String?)
        /// An editable table: rows with remove, and an add grammar per kind.
        case table(kind: TableKind, entries: [TableEntry])
        /// A door to a page: the section it opens, by name.
        case page(String)
        /// A choice the window keeps rather than the config: which of
        /// several things a page is showing. Index-aligned like `choice`.
        case selector(options: [String], labels: [String], current: String)
    }

    public struct Preset: Equatable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Action: Equatable {
        public let id: String
        public let label: String
        public let destructive: Bool
        /// What the second press is asked for with, in words.
        public let confirm: String?

        public init(id: String, label: String, destructive: Bool = false, confirm: String? = nil) {
            self.id = id
            self.label = label
            self.destructive = destructive
            self.confirm = confirm
        }
    }

    public struct Row: Equatable {
        public let title: String
        /// The config path the control writes, dotted — shown under the
        /// title so the pane teaches the file. Empty for readouts.
        public let path: String
        public let control: Control
        /// One sentence when the title cannot carry the meaning alone.
        public let detail: String?
        /// Keycap glyphs the row wears (the gestures pane).
        public let keycaps: [String]
        public let isDefault: Bool
        /// Visible but inert — the coach row without observations.
        public let dimmed: Bool
        /// A subgroup heading, drawn when it changes between rows — how
        /// the gestures pane reads as four short lists instead of one
        /// long one.
        public let group: String?
        /// One-click values for a text control, for the answers most
        /// people want without knowing the format.
        public let presets: [Preset]
        /// The doctor's finding about this row, rendered where it can be
        /// fixed rather than in a terminal nobody runs on a good day.
        public let problem: String?
        /// Choices shown and not choosable: an editor model too big for
        /// this Mac is listed with what it needs, and greyed.
        public var disabledChoices: Set<String> = []
        /// The row's address inside its place, fixed by the catalog: a
        /// letter belongs to the row, never to the render, so a neighbour
        /// dimming or a readout appearing never moves it.
        public var letter: String?
        /// A verb the row can perform that is not a config write: open
        /// the pane of System Settings that grants a permission, delete a
        /// record. `destructive` asks for the letter twice.
        public var action: Action?

        public init(title: String, path: String = "", control: Control,
                    detail: String? = nil, keycaps: [String] = [],
                    isDefault: Bool = true, dimmed: Bool = false,
                    group: String? = nil, presets: [Preset] = [],
                    problem: String? = nil) {
            self.title = title
            self.path = path
            self.control = control
            self.detail = detail
            self.keycaps = keycaps
            self.isDefault = isDefault
            self.dimmed = dimmed
            self.group = group
            self.presets = presets
            self.problem = problem
        }

        /// The same row under a subgroup heading.
        public func inGroup(_ group: String) -> Row {
            var row = Row(title: title, path: path, control: control, detail: detail, keycaps: keycaps,
                          isDefault: isDefault, dimmed: dimmed, group: group, presets: presets, problem: problem)
            row.disabledChoices = disabledChoices
            row.letter = letter
            row.action = action
            return row
        }

        /// The same row wearing a verb.
        public func doing(_ action: Action) -> Row {
            var row = self
            row.action = action
            return row
        }
    }

    public struct Section: Equatable {
        public let name: String
        public let rows: [Row]
        /// A page rather than a place: reached from a row of the named
        /// place, never on the overview, and escape returns to it. Nil for
        /// the places the number row addresses.
        public let parent: String?
        /// The picture the place wears, by resource name (its door's, or
        /// its own in the same clay).
        public var picture: String
        /// What Lodestar says about the place, in its own voice, under the
        /// place's name.
        public var sentence: String
        /// One line on the overview: what this part of Lodestar is doing.
        public var status: String
        /// Something here needs the person: a dot beside the name.
        public var attention: Bool
        /// A quiet line at the foot of the page's left column.
        public var note: String?

        public init(name: String, rows: [Row], parent: String? = nil, picture: String = "",
                    sentence: String = "", status: String = "", attention: Bool = false,
                    note: String? = nil) {
            self.name = name
            self.parent = parent
            self.picture = picture
            self.sentence = sentence
            self.status = status
            self.note = note
            // Letters are the catalog's: one per row, in reading order,
            // readouts and dimmed rows included.
            let alphabet = SettingsModel.labelAlphabet
            self.rows = rows.enumerated().map { index, row in
                var lettered = row
                lettered.letter = alphabet.indices.contains(index) ? alphabet[index] : nil
                return lettered
            }
            self.attention = attention || self.rows.contains { $0.problem != nil }
        }
    }

    /// One keyboard, as the Keyboards page names it.
    public struct Keyboard: Equatable {
        /// `vendor:product:hash`, the roster's id and the config's key.
        public let id: String
        public let name: String
        public let builtIn: Bool
        public let attached: Bool

        public init(id: String, name: String, builtIn: Bool, attached: Bool) {
            self.id = id
            self.name = name
            self.builtIn = builtIn
            self.attached = attached
        }
    }

    /// What the window is showing that the config does not own: the
    /// keyboard the Keyboards page is opened to.
    public struct ViewState: Equatable {
        public var selectedKeyboard: String?

        public init(selectedKeyboard: String? = nil) {
            self.selectedKeyboard = selectedKeyboard
        }
    }

    // MARK: - The catalog

    /// Machine facts the config does not own, supplied by the shell.
    public struct MachineState {
        public var accessibility: String
        public var screenRecording: String
        public var calendars: String
        public var browserRole: String
        /// The browser links return to, by its human name.
        public var savedBrowser: String
        /// Its identifier, worn the way every list row wears one.
        public var savedBrowserID: String?
        /// Every profile the installed browsers actually have.
        public var detectedProfiles: [DetectedProfile]
        /// Every audio input the machine has right now, by name, and
        /// which of them the system calls its default.
        public var inputDevices: [String] = []
        public var defaultInput: String?
        /// Every keyboard the Keyboards page can speak for: the ones
        /// attached, by the roster, and the ones the config has declared
        /// keys for, attached or not.
        public var keyboards: [Keyboard] = []
        /// The editor's engines this Mac may run, their names, and where
        /// the one in use stands.
        public var editorEngines: [String] = []
        public var editorEngineLabels: [String] = []
        public var editorEngineCurrent = ""
        /// The dictation model in use, or what it is fetching, for its row.
        public var earStatus = ""
        /// The health record's size warning, once it is near its bound.
        public var healthWarning: String?
        /// What Automatic picks for dictation on this Mac, named in its label.
        public var draftModelAutomatic = "Full"
        /// Each dictation tier as its row lists it, Apple only first: the
        /// models it runs, or what this Mac lacks for it.
        public var draftModelLabels = ["Apple only", "Standard", "Full", "Max"]
        /// The tiers this Mac has too little memory for: listed, greyed.
        public var draftModelsUnavailable: Set<String> = []
        public var editorModelStatus = ""
        /// Engines this Mac cannot run (too little memory, no Apple
        /// Intelligence): listed, greyed.
        public var editorEnginesUnavailable: Set<String> = []
        /// The English the Mac's own languages point to, for Automatic.
        public var editorRegionInferred = "en_US"
        /// The units the Mac's region measures in, for Units until one is chosen.
        public var unitsInferred = ClipQuantity.System.imperial.rawValue
        /// Whether the Mac is in dark mode: the night is chosen only there,
        /// since light mode is always clay.
        public var isDark = true
        /// How many breaths are saved, for Switch's line on the overview.
        public var breaths = 0
        /// The config's recent changes, newest first, for the History page.
        public var history: [HistoryItem] = []

        public init(accessibility: String = "unknown", screenRecording: String = "unknown",
                    calendars: String = "unknown", browserRole: String = "unknown",
                    savedBrowser: String = "none recorded yet",
                    savedBrowserID: String? = nil,
                    detectedProfiles: [DetectedProfile] = []) {
            self.accessibility = accessibility
            self.screenRecording = screenRecording
            self.calendars = calendars
            self.browserRole = browserRole
            self.savedBrowser = savedBrowser
            self.savedBrowserID = savedBrowserID
            self.detectedProfiles = detectedProfiles
        }
    }

    /// One change, as the History page shows it.
    public struct HistoryItem: Equatable {
        public let id: String
        public let title: String
        public let detail: String
        public let today: Bool

        public init(id: String, title: String, detail: String, today: Bool) {
            self.id = id
            self.title = title
            self.detail = detail
            self.today = today
        }
    }

    public struct DetectedProfile: Equatable {
        public let browser: String
        public let browserLabel: String
        public let name: String

        public init(browser: String, browserLabel: String, name: String) {
            self.browser = browser
            self.browserLabel = browserLabel
            self.name = name
        }
    }

    /// The gestures pane's vocabulary: the feature's plain name and the
    /// keycaps it answers to. The roster's `about` strings are guide copy;
    /// a settings row wants a noun and its keys, nothing else.
    static let gestureNames: [String: (name: String, caps: [String], detail: String?)] = [
        "launcher": ("Launcher", ["lode", "␣"],
                     "Type a few letters of any app and press return."),
        "graph": ("Letters", ["lode", "a…z"],
                  "Letters that lead straight to apps. Hold lode and press one."),
        "web-bar": ("Ask", ["lode", "⏎"],
                    "Type a destination or a question. It opens in the "
                    + "right browser profile."),
        "commands": ("Commands", ["lode", "-"], nil),
        "draft": ("Draft", ["lode", "."], "Speak into it and ⏎ pastes where your cursor was. ⇧. revises the field."),
        "scroll": ("Scroll", ["lode", "`"], nil),
        "hints": ("Click hints", ["lode", ";"], nil),
        "select": ("Select text", ["lode", "/"], nil),
        "breaths": ("Breaths", ["lode", "'"],
                    "Saved window arrangements, restored with a letter."),
        "maximize": ("Maximize", ["lode", "0"], nil),
        "index-jump": ("Jump to window", ["lode", "1…9"], nil),
        "flip-orientation": ("Flip layout", ["lode", "\\"], nil),
        "layout-undo": ("Layout undo", ["lode", "←", "→"], nil),
        "display-move": ("Display move", ["lode", "[", "]"], nil),
        "settings": ("Settings", ["lode", ","], nil),
    ]

    /// A profile the way the config writes it: `browser:Name`, casing
    /// intact. The pickers' tokens are the stored values — nothing stands
    /// between a choice and the file.
    public static func profileReference(browser: String, name: String) -> String {
        "\(browser):\(name)"
    }

    public static func catalog(config: Config, machine: MachineState,
                               problems: [String] = []) -> [Section] {
        let defaults = ConfigDefaults.tree

        /// The doctor's line for a config path, matched on its prefix —
        /// "web.routes.x: …" lands under the routes row.
        func problem(at path: String) -> String? {
            problems.first { finding in
                finding.hasPrefix(path) || finding.hasPrefix(path + ".")
                    || finding.contains(" \(path) ")
            }
        }

        func isDefault(_ path: [String], _ current: ConfigValue) -> Bool {
            defaults.value(at: path) == current
        }

        var sections: [Section] = []
        func granted(_ state: String) -> Bool { state.lowercased() == "granted" }
        func gesture(_ name: String, group: String, detail: String? = nil) -> Row {
            let verb = Gestures.roster.first { $0.name == name }
            let named = Self.gestureNames[name] ?? (name, [], nil)
            let enabled = !config.disabledGestures.isSuperset(of: Set(verb?.keys ?? []))
            return Row(title: named.name, path: "gestures.\(name)", control: .toggle(enabled),
                       detail: detail ?? named.detail, keycaps: named.caps, isDefault: enabled, group: group)
        }
        func on(_ name: String) -> Bool {
            let keys = Set(Gestures.roster.first { $0.name == name }?.keys ?? [])
            return !config.disabledGestures.isSuperset(of: keys)
        }
        func permission(_ title: String, state: String, detail: String, pane: String, group: String) -> Row {
            let row = Row(title: title, control: .readout(granted(state) ? "Granted" : "Not granted", sub: nil),
                          detail: detail, group: group)
            return granted(state) ? row : row.doing(Action(id: "open-\(pane)", label: "Open System Settings"))
        }

        // 0 · General
        sections.append(Section(name: "General", rows: [
            Row(title: "Start at login", path: "app.start-at-login",
                control: .toggle(config.startAtLogin), isDefault: config.startAtLogin, group: "Lodestar"),
            Row(title: "Automatic updates", path: "app.auto-update",
                control: .toggle(config.autoUpdate), isDefault: config.autoUpdate, group: "Lodestar"),
            Row(title: "Menu bar icon", path: "app.show-menu-bar",
                control: .toggle(config.showMenuBar), isDefault: config.showMenuBar, group: "Lodestar"),
            Row(title: "Accent", path: "appearance.accent",
                control: .choice(options: ["system", "orange"],
                                 labels: ["System", "International Orange"],
                                 current: config.accent.rawValue),
                detail: "The cursor, lit letters and the echoed query",
                isDefault: config.accent == .system, group: "Look and sound"),
            Row(title: "Sounds", path: "app.sounds",
                control: .toggle(config.sounds),
                detail: "Lodestar's alert, and the draft's notes when the microphone is live and when the words land",
                isDefault: config.sounds, group: "Look and sound"),
            Row(title: "Active display", path: "app.active-display",
                control: .choice(options: ["pointer", "focus"],
                                 labels: ["Under the pointer", "With the focused window"],
                                 current: config.activeDisplayMode == .focus ? "focus" : "pointer"),
                detail: "Which display summoned windows land on",
                isDefault: config.activeDisplayMode == .pointer, group: "Look and sound"),
            permission("Accessibility", state: machine.accessibility,
                       detail: "Seeing windows, moving them and reading menus. Lodestar cannot work without it",
                       pane: "accessibility", group: "Permission"),
            Row(title: "History", control: .page(historyPage),
                detail: "Every change, from here, the file, the coach or the editor, and the way back. ⌘Z undoes the last one made here",
                group: "History"),
        ], picture: "place-general",
           sentence: "Lodestar starts with your Mac and keeps itself up to date",
           status: "Startup, updates and look",
           attention: !granted(machine.accessibility) && machine.accessibility != "unknown"))

        // 1 · Write: the editor
        var model: Row
        if !machine.editorEngines.isEmpty {
            model = Row(title: "Model", path: "editor.model",
                control: .choice(options: machine.editorEngines, labels: machine.editorEngineLabels,
                                 current: machine.editorEngineCurrent),
                detail: machine.editorModelStatus + ". Spelling reads typos without a model, the others read grammar too",
                isDefault: config.editorModel.isEmpty, group: "Editor")
            model.disabledChoices = machine.editorEnginesUnavailable
        } else {
            model = Row(title: "Model", path: "editor.model",
                control: .readout(machine.editorModelStatus, sub: nil),
                detail: "Loads when you start writing and lets its memory go two minutes after you stop",
                isDefault: config.editorModel.isEmpty, group: "Editor")
        }
        let words = Row(title: "Words", path: "draft.words", control: .page(wordsPage),
                        detail: config.draftWords.isEmpty
                            ? "Names and terms, written the way you write them. Shared by Write and Speak"
                            : "\(config.draftWords.count) words, shared by Write and Speak",
                        isDefault: config.draftWords.isEmpty, group: "Words and apps")
        sections.append(Section(name: "Write", rows: [
            Row(title: "Editor", path: "editor.enabled",
                control: .toggle(config.editorEnabled),
                detail: "Marks mistakes as you write, in every app. Your text never leaves this Mac and is never kept",
                keycaps: ["lode", "⇥"], isDefault: !config.editorEnabled, group: "Editor",
                problem: problem(at: "editor.enabled")),
            model,
            Row(title: "Spelling", path: "editor.language",
                control: .choice(options: [""] + EditorRegion.choices.map(\.code),
                                 labels: ["Automatic · \(EditorRegion.name(of: machine.editorRegionInferred))"]
                                    + EditorRegion.choices.map(\.name),
                                 current: config.editorLanguage),
                detail: "Automatic follows your Mac's language and region",
                isDefault: config.editorLanguage.isEmpty, group: "Editor"),
            words,
            Row(title: "Skip in", path: "editor.skip-apps",
                control: .table(kind: .editorSkipApps, entries: config.editorSkipApps.sorted().map {
                    TableEntry(key: $0, display: $0) }),
                detail: "Fields in these apps are never read",
                isDefault: config.editorSkipApps.isEmpty, group: "Words and apps"),
        ], picture: "door-write",
           sentence: "The editor marks mistakes as you write, in every app",
           status: "Spelling and grammar"))

        // 2 · Switch
        sections.append(Section(name: "Switch", rows: [
            gesture("launcher", group: "Launcher and letters", detail: "Type a few letters of any app and press return"),
            gesture("graph", group: "Launcher and letters", detail: "Letters that lead straight to apps. Hold lode and press one"),
            gesture("index-jump", group: "Launcher and letters"),
            gesture("maximize", group: "Windows"),
            gesture("flip-orientation", group: "Windows"),
            gesture("layout-undo", group: "Windows"),
            gesture("display-move", group: "Windows"),
            gesture("breaths", group: "Breaths", detail: "Saved window arrangements, restored with a letter"),
        ], picture: "door-switch",
           sentence: "Every app and window, a letter or two away",
           status: "Apps and windows"))

        // 3 · Keep: the clipboard
        let unitsOptions = [""] + ClipQuantity.System.allCases.reversed().map(\.rawValue)
        let inferredUnits = machine.unitsInferred == ClipQuantity.System.metric.rawValue ? "Metric" : "Imperial"
        sections.append(Section(name: "Keep", rows: [
            Row(title: "Keep", path: "clipboard.enabled",
                control: .toggle(config.clipboardEnabled),
                detail: "Every copy, searchable from the strip",
                keycaps: ["⇧⌘V"], isDefault: config.clipboardEnabled, group: "Keep"),
            Row(title: "Size limit", path: "clipboard.max-size-mb",
                control: .number(config.clipboardMaxBytes / 1_000_000, min: 10, max: 20_000, unit: "MB"),
                detail: "Older clips leave first past this. Pins stay",
                isDefault: config.clipboardMaxBytes == 500_000_000,
                dimmed: !config.clipboardEnabled, group: "Keep"),
            Row(title: "Save images to", path: "clipboard.save-to",
                control: .text(config.clipboardSaveFolder, placeholder: "~/Downloads"),
                detail: "Where an image saved from the strip lands",
                isDefault: config.clipboardSaveFolder == "~/Downloads", group: "Keep"),
            Row(title: "Excluded apps", path: "clipboard.exclude-apps",
                control: .table(kind: .excludeApps, entries: config.clipboardExcludedApps
                    .sorted().map { TableEntry(key: $0, display: $0) }),
                detail: "Nothing copied in these apps is ever recorded",
                isDefault: config.clipboardExcludedApps.isEmpty, group: "Never recorded"),
            Row(title: "Excluded text", path: "clipboard.exclude",
                control: .table(kind: .excludePatterns, entries: config.clipboardExcludePatterns
                    .sorted().map { TableEntry(key: $0, display: $0) }),
                detail: "A clip containing one of these is never recorded. Matching ignores case",
                isDefault: config.clipboardExcludePatterns.isEmpty, group: "Never recorded"),
            Row(title: "Units", path: "app.units",
                control: .choice(options: unitsOptions,
                                 labels: ["Automatic · \(inferredUnits)", "Imperial", "Metric"],
                                 current: config.units),
                detail: "What a copied measurement is read into",
                isDefault: config.units.isEmpty, group: "How clips read"),
            Row(title: "Time zones", path: "clipboard.time-zones",
                control: .table(kind: .clipboardTimeZones, entries: config.clipboardTimeZones.compactMap { id in
                    TimeZone(identifier: id).map { TableEntry(key: id, display: ClipTime.label($0)) }
                }),
                detail: "A timestamp is read into your zone, UTC and these",
                isDefault: config.clipboardTimeZones.isEmpty, group: "How clips read"),
            Row(title: "Clear history", control: .readout("", sub: nil),
                detail: "Every clip, pins included, gone from this Mac", group: "History")
                .doing(Action(id: "clear-clipboard", label: "Clear", destructive: true,
                              confirm: "Press the letter again to clear the history. It cannot be undone")),
        ], picture: "door-keep",
           sentence: "Keep holds what you copy, and records nothing in the apps you exclude",
           status: "Clipboard history"))

        // 4 · Speak: the draft
        let inputOptions = [""] + machine.inputDevices
        let inputLabels = ["System · " + (machine.defaultInput ?? "Default")] + machine.inputDevices
        var speakModel = Row(title: "Model", path: "draft.model",
            control: .choice(options: ["", "apple", "standard", "full", "max"],
                             labels: ["Automatic · \(machine.draftModelAutomatic)"] + machine.draftModelLabels,
                             current: config.draftModel),
            detail: (machine.earStatus.isEmpty ? "" : machine.earStatus + ". ")
                + "Hears what you said again while you keep talking, writes it better, and takes out the words you take back",
            isDefault: config.draftModel.isEmpty, group: "Draft")
        speakModel.disabledChoices = machine.draftModelsUnavailable
        sections.append(Section(name: "Speak", rows: [
            gesture("draft", group: "Draft", detail: "Speak into it and ⏎ pastes where your cursor was"),
            Row(title: "Microphone", path: "draft.input",
                control: .choice(options: inputOptions, labels: inputLabels,
                                 current: inputOptions.contains(config.draftInput) ? config.draftInput : ""),
                detail: "What the draft listens to. It names it while listening",
                isDefault: config.draftInput.isEmpty, group: "Draft"),
            speakModel,
            words.inGroup("Words"),
        ], picture: "door-speak",
           sentence: "Speak, and the draft writes it down and hears you again to get it right",
           status: "Dictation"))

        // 5 · Operate: what the app in front shows
        let screenGranted = granted(machine.screenRecording)
        sections.append(Section(name: "Operate", rows: [
            gesture("hints", group: "Click hints", detail: "A letter on everything you can click"),
            gesture("scroll", group: "Scroll"),
            Row(title: "Smooth scrolling", path: "scroll.smooth",
                control: .toggle(config.scrollSmooth), isDefault: config.scrollSmooth, group: "Scroll"),
            Row(title: "Scroll speed", path: "scroll.speed",
                control: .number(Int(config.scrollSpeed), min: 200, max: 4000, unit: "px/s"),
                detail: config.scrollSmooth ? "How fast smooth scrolling moves" : "Applies when smooth scrolling is on",
                isDefault: isDefault(["scroll", "speed"], .int(Int(config.scrollSpeed))),
                dimmed: !config.scrollSmooth, group: "Scroll"),
            Row(title: "Scroll step", path: "scroll.step",
                control: .number(Int(config.scrollStep), min: 10, max: 400, unit: "px"),
                detail: config.scrollSmooth ? "Applies when smooth scrolling is off" : "How far each keypress moves",
                isDefault: isDefault(["scroll", "step"], .int(Int(config.scrollStep))),
                dimmed: config.scrollSmooth, group: "Scroll"),
            gesture("select", group: "Select", detail: "Select text you can see by typing it"),
            Row(title: "Copy on select", path: "select.copy-on-complete",
                control: .toggle(config.selectCopyOnComplete),
                detail: "A finished selection is copied the moment its second end lands",
                isDefault: !config.selectCopyOnComplete, group: "Select"),
            gesture("commands", group: "Commands", detail: "The app's menu commands, by name"),
            permission("Screen Recording", state: machine.screenRecording,
                       detail: "Reading text in apps that do not share it, for select",
                       pane: "screen-recording", group: "Permission"),
        ], picture: "place-operate",
           sentence: "Click, scroll and select in the app in front, from the keys",
           status: "Click, scroll and select",
           attention: !screenGranted && machine.screenRecording != "unknown"))

        // 6 · Web. No profile inventory to manage: the pickers list what
        // the browsers actually have, references store `browser:Name`
        // directly, and the doctor says so when one names a profile the
        // machine no longer holds.
        func shownReference(_ key: String) -> String {
            config.browserProfiles[key]?.reference ?? key
        }
        var fallbackOptions = ["most-recent"]
        var fallbackLabels = ["Automatic · Your last browser"]
        for detected in machine.detectedProfiles {
            fallbackOptions.append(Self.profileReference(browser: detected.browser,
                                                         name: detected.name))
            fallbackLabels.append("\(detected.browserLabel) · \(detected.name)")
        }
        var fallbackCurrent = "most-recent"
        if config.webFallback != "most-recent" {
            if let index = fallbackOptions.firstIndex(where: { $0.lowercased() == config.webFallback }) {
                fallbackCurrent = fallbackOptions[index]
            } else if let profile = config.browserProfiles[config.webFallback] {
                fallbackOptions.append(profile.reference)
                fallbackLabels.append("\(profile.browser.label) · \(profile.display) (not found)")
                fallbackCurrent = profile.reference
            }
        }
        let linkEntries = config.webLinks.sorted { $0.name < $1.name }
            .map { link -> TableEntry in
                let pin = link.profileKey.map { "  →  \(shownReference($0))" } ?? ""
                return TableEntry(key: link.name, display: link.name, sub: "\(link.url)\(pin)")
            }
        let routeEntries = config.webRoutes.sorted { $0.key < $1.key }
            .map { TableEntry(key: $0.key, display: $0.key, sub: "→  \(shownReference($0.value))") }
        sections.append(Section(name: "Web", rows: [
            gesture("web-bar", group: "Ask", detail: "Type a destination or a question. It opens in the right browser profile"),
            Row(title: "Fallback profile", path: "web.fallback",
                control: .choice(options: fallbackOptions, labels: fallbackLabels, current: fallbackCurrent),
                detail: "Where a destination opens when no rule decides",
                isDefault: config.webFallback == "most-recent", group: "Ask",
                problem: problem(at: "web.fallback")),
            Row(title: "Search engine", path: "web.search-url",
                control: .text(config.webSearchURL, placeholder: "https://…?q=%s"),
                detail: "Where a query goes when what you typed is not a link. Your words go where the %s is",
                isDefault: isDefault(["web", "search-url"], .string(config.webSearchURL)), group: "Ask",
                presets: [
                    Preset(label: "Brave Search", value: "https://search.brave.com/search?q=%s"),
                    Preset(label: "Google", value: "https://www.google.com/search?q=%s"),
                ]),
            Row(title: "Links", path: "web.links",
                control: .table(kind: .links, entries: linkEntries),
                detail: "A short name you type in Ask, and the page it opens. A pinned profile overrides every rule",
                isDefault: config.webLinks.isEmpty, group: "Links and routes",
                problem: problem(at: "web.links")),
            Row(title: "Routes", path: "web.routes",
                control: .table(kind: .routes, entries: routeEntries),
                detail: "Pattern → profile, matched against anything you type or click",
                isDefault: config.webRoutes.isEmpty, group: "Links and routes",
                problem: problem(at: "web.routes")),
            Row(title: "Route clicked links", path: "web.clicks.enabled",
                control: .toggle(config.webHandleClicks),
                detail: "Lodestar stands as the default browser and routes links clicked in any app. "
                    + machine.browserRole.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                isDefault: !config.webHandleClicks, group: "Clicked links"),
            Row(title: "Saved browser", path: "web.clicks.browser",
                control: .readout(machine.savedBrowser, sub: machine.savedBrowserID),
                detail: "Where a link no rule matches goes, and the browser handed back when Lodestar lets go",
                group: "Clicked links"),
        ], picture: "place-web",
           sentence: "Every link opens in the browser and profile it belongs to",
           status: "Links and browsers"))

        // 7 · Meetings
        let calendarEntries = config.meetingsCalendars.sorted { $0.key < $1.key }
            .map { TableEntry(key: $0.key, display: $0.key, sub: "→  \(shownReference($0.value))") }
        let calendarsGranted = granted(machine.calendars)
        sections.append(Section(name: "Meetings", rows: [
            Row(title: "Meetings", path: "meetings.enabled",
                control: .toggle(config.meetingsEnabled),
                detail: "A chip before each meeting with a link. Tap lode twice to join",
                isDefault: !config.meetingsEnabled, group: "Meetings",
                problem: problem(at: "meetings.enabled")),
            Row(title: "Lead time", path: "meetings.lead-minutes",
                control: .number(config.meetingsLeadMinutes, min: 0, max: 120, unit: "min"),
                detail: "Minutes before the start the chip appears",
                isDefault: config.meetingsLeadMinutes == 5, dimmed: !config.meetingsEnabled, group: "Meetings"),
            Row(title: "Calendars", path: "meetings.calendars",
                control: .table(kind: .calendars, entries: calendarEntries),
                detail: "Calendar → profile, for meetings joined in a browser. Outranks routes",
                isDefault: config.meetingsCalendars.isEmpty, group: "Calendars",
                problem: problem(at: "meetings.calendars")),
            permission("Calendar access", state: machine.calendars,
                       detail: "Reading your next meeting. Asked when meetings are turned on",
                       pane: "calendars", group: "Calendars"),
        ], picture: "place-meetings",
           sentence: "A chip before each meeting, and one tap to join",
           status: "Calendar and joining",
           attention: config.meetingsEnabled && !calendarsGranted && machine.calendars != "unknown"))

        // 8 · Keys
        let remapEntries = config.keyOverrides.sorted { $0.key < $1.key }
            .map { TableEntry(key: String($0.key), display: "Keycode \($0.key)", sub: "types \($0.value)") }
        sections.append(Section(name: "Keys", rows: [
            Row(title: "Lode key", path: "lode.trigger",
                control: .choice(options: ["right-command", "left-command"],
                                 labels: ["Right ⌘", "Left ⌘"], current: config.trigger.rawValue),
                detail: "The key every gesture starts from. A ⌘⌃⌥ hyper shim also works",
                isDefault: config.trigger == .rightCommand, group: "Lode"),
            Row(title: "Tap lode", path: "lode.tap",
                control: .toggle(config.lodeTap),
                detail: "A tap arms the next key as a gesture for one second. Holding still works",
                isDefault: config.lodeTap, group: "Lode"),
            gesture("settings", group: "Lode", detail: "Opens this window, at the place for what is in front of you"),
            Row(title: "Keyboards", path: "health.keyboards",
                control: .page(keyboardsPage),
                detail: keyboardsSummary(config: config, machine: machine),
                isDefault: config.fingerMap.isEmpty, group: "Keyboards"),
            Row(title: "Key remaps", path: "keys",
                control: .table(kind: .keyRemaps, entries: remapEntries),
                detail: "Keycode to key name, for keyboards the built-in table misreads",
                isDefault: config.keyOverrides.isEmpty, group: "Keyboards"),
        ], picture: "place-keys",
           sentence: "The key every gesture starts from, and the boards you type on",
           status: "Lode and keyboards"))

        // 9 · Observations: two records, each with its switch, its limit,
        // and what reads it. The coach reads the logbook; Born and
        // Dominant hand belong to health.
        sections.append(Section(name: "Observations", rows: [
            Row(title: "Logbook", path: "observations.logbook",
                control: .toggle(config.logbookEnabled),
                detail: "How you move between apps, windows and gestures. Sites by name, never their pages, titles or what you type",
                isDefault: config.logbookEnabled, group: "Logbook"),
            Row(title: "Limit", path: "observations.logbook-mb",
                control: .number(Int(config.logbookBytes >> 20), min: Retention.logbookMinimumMB, max: 4096, unit: "MB"),
                detail: config.logbookEnabled ? "The oldest months leave first once it is full. Their summaries stay" : "Needs the logbook",
                isDefault: config.logbookBytes == Retention.behavioralBytes,
                dimmed: !config.logbookEnabled, group: "Logbook"),
            Row(title: "Coach", path: "coach.enabled",
                control: .toggle(config.coachEnabled && config.logbookEnabled),
                detail: config.logbookEnabled ? "One shortcut worth learning, now and then, from the logbook" : "Needs the logbook",
                isDefault: config.coachEnabled || !config.logbookEnabled,
                dimmed: !config.logbookEnabled, group: "Logbook"),
            Row(title: "Health", path: "observations.health",
                control: .toggle(config.observationsHealth),
                detail: "The rhythm of your hands, by hand and finger, and how the pointer moves. Never which keys or what you type",
                isDefault: config.observationsHealth, group: "Health",
                problem: machine.healthWarning),
            Row(title: "Limit", path: "observations.health-mb",
                control: .number(Int(config.healthBytes >> 20), min: Retention.healthMinimumMB, max: 16_384, unit: "MB"),
                detail: config.observationsHealth ? "Lodestar tells you when the record nears this. Health is never deleted on its own" : "Needs health",
                isDefault: config.healthBytes == Retention.healthBytes,
                dimmed: !config.observationsHealth, group: "Health"),
            Row(title: "Born", path: "health.born",
                control: .text(config.healthBorn.map(String.init) ?? "", placeholder: "Year"),
                detail: config.observationsHealth ? "Age adjusts every reading of the hands" : "Needs health",
                isDefault: config.healthBorn == nil, dimmed: !config.observationsHealth, group: "About you"),
            Row(title: "Dominant hand", path: "health.hand",
                control: .choice(options: ["", "left", "right", "either"],
                                 labels: ["Not set", "Left", "Right", "Either"], current: config.healthHand),
                detail: config.observationsHealth ? "The hand you write with" : "Needs health",
                isDefault: config.healthHand.isEmpty, dimmed: !config.observationsHealth, group: "About you"),
            Row(title: "Walk", path: "coach.stand",
                control: .toggle(config.standEnabled),
                detail: "A cue to walk for two minutes, at the next stopping point after a stretch without a break",
                isDefault: config.standEnabled, group: "Walk"),
            Row(title: "After", path: "coach.stand-after",
                control: .number(config.standAfterMinutes, min: 15, max: 120, unit: "min"),
                detail: config.standEnabled ? "Thirty is what the research supports" : "Needs the walk",
                isDefault: config.standAfterMinutes == 30, dimmed: !config.standEnabled, group: "Walk"),
            Row(title: "Delete the logbook", control: .readout("", sub: nil),
                detail: "Everything the coach reads, gone from this Mac", group: "Delete")
                .doing(Action(id: "delete-logbook", label: "Delete", destructive: true,
                              confirm: "Press the letter again to delete the logbook. It cannot be undone")),
            Row(title: "Delete health", control: .readout("", sub: nil),
                detail: "Years of baseline nothing can rebuild, gone from this Mac", group: "Delete")
                .doing(Action(id: "delete-health", label: "Delete", destructive: true,
                              confirm: "Press the letter again to delete the health record. It cannot be undone")),
        ], picture: "place-observations",
           sentence: "Everything Lodestar observes stays on this Mac",
           status: "Logbook and health",
           note: "The coach reads the logbook. Health is its own record, kept whatever the logbook is set to"))

        return sections
    }

    // MARK: - Pages

    /// The ten places, in their digits' order.
    public static let placeNames = ["General", "Write", "Switch", "Keep", "Speak",
                                    "Operate", "Web", "Meetings", "Keys", "Observations"]
    public static func placeIndex(_ name: String) -> Int? { placeNames.firstIndex(of: name) }

    public static let keyboardsPage = "Keyboards"
    public static let wordsPage = "Words"
    public static let historyPage = "History"

    /// The Health row's one line: which boards differ, and by how much.
    static func keyboardsSummary(config: Config, machine: MachineState) -> String {
        let named = machine.keyboards.filter { !$0.builtIn }
        guard !named.isEmpty else {
            return "Where each key sits on a split or custom keyboard, so the record "
                + "charges it to the right finger"
        }
        return named.map { keyboard in
            let n = config.fingerMap.differing(on: keyboard.id)
            let state = n == 0 ? "standard" : (n == 1 ? "1 key differs" : "\(n) keys differ")
            return "\(keyboard.name) · \(state)"
        }.joined(separator: ". ")
    }

    /// The pages behind the panes: reached from a row, never from the
    /// rail. One today — the Keyboards page, opened to one keyboard.
    public static func pages(config: Config, machine: MachineState,
                             view: ViewState = ViewState()) -> [Section] {
        [keyboardsSection(config: config, machine: machine, view: view),
         Section(name: wordsPage, rows: [
            Row(title: "Words", path: "draft.words",
                control: .table(kind: .draftWords, entries: config.draftWords.map { TableEntry(key: $0, display: $0) }),
                detail: "Names and terms speech gets wrong and the editor should never mark. "
                    + "A spoken word that sounds like one of these becomes it, case and all",
                isDefault: config.draftWords.isEmpty, group: "Words"),
         ], parent: "Write", picture: "door-write",
            sentence: "The words you use, written the way you write them",
            note: "Shared by Write and Speak. A word the editor learns when you keep it lands here"),
         historySection(machine.history)]
    }

    /// The name a changed path goes by: its row's title in the catalog
    /// (the longest row path it falls under), Letters for the graph, and
    /// the dotted path for anything with no row.
    public static func historyTitle(_ path: [String]) -> String {
        if path.first == "graph" { return "Letters" }
        let dotted = path.joined(separator: ".")
        let rows = (catalog(config: Config(), machine: .init()) + pages(config: Config(), machine: .init()))
            .flatMap(\.rows).filter { !$0.path.isEmpty }
        let best = rows.filter { dotted == $0.path || dotted.hasPrefix($0.path + ".") }
            .max { $0.path.count < $1.path.count }
        return best?.title ?? dotted
    }

    /// The History page's lines, newest first: what changed, in words,
    /// who changed it, and when.
    public static func historyItems(_ entries: [ConfigHistory.Entry], now: Date = Date(),
                                    calendar: Calendar = .current) -> [HistoryItem] {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.dateFormat = "d MMM"
        func shown(_ value: ConfigValue?) -> String {
            switch value {
            case nil: return "Default"
            case .bool(let on)?: return on ? "On" : "Off"
            case .string(let text)?: return text.isEmpty ? "Automatic" : String(text.prefix(28))
            case .int(let n)?: return "\(n)"
            case .double(let n)?: return n.rounded() == n ? "\(Int(n))" : "\(n)"
            case .table?: return "a list"
            }
        }
        return entries.reversed().map { entry in
            let title = historyTitle(entry.path)
            let rowDepth = entry.path.first == "graph" ? 1 : (title == entry.path.joined(separator: ".") ? entry.path.count
                : rowPathDepth(entry.path))
            var what: String
            if entry.path.count > rowDepth {
                let key = entry.path.first == "graph"
                    ? "lode " + entry.path.dropFirst().map { $0.uppercased() }.joined(separator: " ")
                    : entry.path.dropFirst(rowDepth).joined(separator: ".")
                if entry.old == nil { what = "Added \(key)" }
                else if entry.new == nil { what = "Removed \(key)" }
                else { what = "\(key) changed" }
            } else {
                what = "\(shown(entry.old)) → \(shown(entry.new))"
            }
            let today = calendar.isDate(entry.at, inSameDayAs: now)
            let when = today ? time.string(from: entry.at) : day.string(from: entry.at)
            return HistoryItem(id: entry.id, title: title,
                               detail: "\(what) · \(entry.source) · \(when)", today: today)
        }
    }

    private static func rowPathDepth(_ path: [String]) -> Int {
        let dotted = path.joined(separator: ".")
        let rows = (catalog(config: Config(), machine: .init()) + pages(config: Config(), machine: .init()))
            .flatMap(\.rows).filter { !$0.path.isEmpty }
        let best = rows.filter { dotted == $0.path || dotted.hasPrefix($0.path + ".") }
            .max { $0.path.count < $1.path.count }
        return best.map { $0.path.split(separator: ".").count } ?? path.count
    }

    /// The recent changes, newest first, each with the way back. Twenty-six
    /// at most: one letter each.
    static func historySection(_ items: [HistoryItem]) -> Section {
        var rows: [Row] = items.prefix(labelAlphabet.count).map { item in
            Row(title: item.title, control: .readout("", sub: nil), detail: item.detail,
                group: item.today ? "Today" : "Earlier")
                .doing(Action(id: "undo:\(item.id)", label: "Undo"))
        }
        if rows.isEmpty {
            rows = [Row(title: "Nothing has changed yet", control: .readout("", sub: nil),
                        detail: "Changes from here, the file, the coach and the editor will be listed", group: "Today")]
        }
        return Section(name: historyPage, rows: rows, parent: "General", picture: "place-general",
                       sentence: "Every change, and the way back",
                       note: "Undo writes the old value back. A change undone is listed too")
    }

    /// One keyboard's fourteen keys and where each sits. The board is
    /// chosen at the top; every row below is one key, its standard
    /// placement labelled as such, and only a placement that differs is
    /// ever written.
    static func keyboardsSection(config: Config, machine: MachineState, view: ViewState) -> Section {
        let boards = machine.keyboards
        let shown = view.selectedKeyboard.flatMap { id in boards.first { $0.id == id } }
            ?? boards.first { !$0.builtIn } ?? boards.first
        var rows: [Row] = []
        if boards.isEmpty {
            rows.append(Row(title: "No keyboard found",
                            control: .readout("Attach one and reopen the page.", sub: nil)))
            return Section(name: keyboardsPage, rows: rows, parent: "Keys", picture: "place-keys", sentence: "Where each key sits on the boards you type on")
        }
        rows.append(Row(
            title: "Keyboard",
            control: .selector(options: boards.map(\.id),
                               labels: boards.map { $0.attached ? $0.name : "\($0.name) · not attached" },
                               current: shown?.id ?? ""),
            detail: shown.map {
                "\($0.id). Keys are named as the system reports them. A board that "
                    + "sends one code for both thumbs maps that key to Either."
            }))
        guard let shown else { return Section(name: keyboardsPage, rows: rows, parent: "Keys", picture: "place-keys", sentence: "Where each key sits on the boards you type on") }
        for key in Keys.SpecialKey.allCases {
            let placed = config.fingerMap.placement(of: key, keyboard: shown.id)
            let options = [""] + FingerMap.Placement.all.map(\.text)
            let labels = ["\(key.standard.label) · standard"] + FingerMap.Placement.all.map(\.label)
            rows.append(Row(
                title: key.label,
                path: "health.keyboards.\(shown.id).\(key.rawValue)",
                control: .choice(options: options, labels: labels, current: placed?.text ?? ""),
                isDefault: placed == nil,
                group: key == .leftShift ? "Keys" : nil))
        }
        return Section(name: keyboardsPage, rows: rows, parent: "Keys", picture: "place-keys", sentence: "Where each key sits on the boards you type on")
    }

    // MARK: - Labels

    /// Plain alphabetical, matching the reading order of the rows —
    /// settings is a page, not an instrument, and a page numbers its
    /// items in the order the eye meets them. No digits: those address
    /// panes.
    public static let labelAlphabet = "abcdefghijklmnopqrstuvwxyz".map(String.init)

    /// The key that addresses a place: its own digit. Ten places, the
    /// number row's ten keys, General first on 0; a new surface takes a
    /// place only by merging into one or retiring one.
    public static let paneKeys = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    public static func paneAddresses(count: Int) -> [String] {
        Array(paneKeys.prefix(max(0, count)))
    }

    public static func paneKey(_ index: Int, count: Int = 10) -> String? {
        let addresses = paneAddresses(count: count)
        return addresses.indices.contains(index) ? addresses[index] : nil
    }

    public static func pane(forKey key: String, count: Int) -> Int? {
        paneAddresses(count: count).firstIndex(of: key)
    }

    public static func labels(for count: Int) -> [String] {
        Array(labelAlphabet.prefix(count))
    }

    // MARK: - Search

    public struct Hit: Equatable {
        public let section: Int
        public let row: Int
        public let title: String
        public let sectionName: String
        /// The two keys that would have reached it: the place's digit and
        /// the row's letter.
        public let address: String

        public init(section: Int, row: Int, title: String, sectionName: String, address: String) {
            self.section = section
            self.row = row
            self.title = title
            self.sectionName = sectionName
            self.address = address
        }
    }

    /// The words people type for a place that is named by what it does.
    static let aliases: [String: String] = [
        "General": "login startup updates accent colour color dark night sound menu bar display accessibility permission",
        "Write": "editor grammar spelling typos proofread",
        "Switch": "windows launcher apps graph letters breaths layout maximize",
        "Keep": "clipboard copy paste history clips",
        "Speak": "dictation draft voice microphone mic speech",
        "Operate": "click hints scroll select commands menus interactions screen recording",
        "Web": "browser ask links routes profile search engine",
        "Meetings": "calendar meeting join zoom",
        "Keys": "keyboard lode trigger remap keycode",
        "Observations": "coach health logbook privacy data delete record",
    ]

    /// Flat and stable: a row's title, path and line, its entries, and its
    /// place's own words all match, place order breaks ties, and an empty
    /// query means no hits rather than all — search is a verb here, not a
    /// view.
    public static func search(_ query: String, in sections: [Section]) -> [Hit] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        // A row's own name first, then its line, path or entries, then a
        // place found by the words people use for it (its first row stands
        // for it); place order breaks ties.
        var scored: [(score: Int, hit: Hit)] = []
        for (sectionIndex, section) in sections.enumerated() {
            let placeWords = "\(section.name) \(aliases[section.name] ?? "")".lowercased()
            for (rowIndex, row) in section.rows.enumerated() {
                var entries = ""
                if case .table(_, let list) = row.control { entries = list.map(\.display).joined(separator: " ") }
                let rest = "\(row.path) \(row.detail ?? "") \(entries)".lowercased()
                let score: Int
                if row.title.lowercased().hasPrefix(needle) { score = 0 }
                else if row.title.lowercased().contains(needle) { score = 1 }
                else if rest.contains(needle) { score = 2 }
                else if placeWords.contains(needle) && rowIndex == 0 { score = 3 }
                else { continue }
                let address = "\(paneKey(sectionIndex, count: sections.count) ?? "") \(row.letter ?? "")"
                scored.append((score, Hit(section: sectionIndex, row: rowIndex, title: row.title,
                                          sectionName: section.name, address: address)))
            }
        }
        return scored.enumerated().sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }
            .map(\.element.hit)
    }

    /// Every row as one line for a language model to choose from: its two
    /// keys, its place, its name and what it does.
    public static func askCatalog(_ sections: [Section]) -> String {
        var lines: [String] = []
        for section in sections {
            lines.append("\(section.name), about \(aliases[section.name] ?? section.name):")
            for row in section.rows {
                lines.append("- \(askName(section, row))" + (row.detail.map { ": " + $0 } ?? ""))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A row as a model names it: its place and its title, unique.
    public static func askName(_ section: Section, _ row: Row) -> String {
        "\(section.name) › \(row.title)"
    }

    /// The names a model may answer with, in catalog order.
    public static func askChoices(_ sections: [Section]) -> [String] {
        var seen = Set<String>()
        return sections.flatMap { section in section.rows.map { askName(section, $0) } }
            .filter { seen.insert($0).inserted }
    }

    /// The row a model's answer names.
    public static func hit(forName name: String, in sections: [Section]) -> Hit? {
        for (index, section) in sections.enumerated() {
            if let row = section.rows.firstIndex(where: { askName(section, $0) == name }) {
                return Hit(section: index, row: row, title: section.rows[row].title, sectionName: section.name,
                           address: "\(paneKey(index, count: sections.count) ?? "") \(section.rows[row].letter ?? "")")
            }
        }
        return nil
    }

    // MARK: - The escape stack

    /// The window's three layers. Escape pops exactly one; popping the
    /// bottom closes the window. One rule, no cases to memorize.
    public enum Layer: Equatable {
        case browsing
        case searching
        case editing
    }

    /// What escape does from a layer: the layer to land on, or nil for
    /// "close the window".
    public static func popped(_ layer: Layer) -> Layer? {
        switch layer {
        case .browsing: return nil
        case .searching, .editing: return .browsing
        }
    }
}
