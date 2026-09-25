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
            return row
        }
    }

    public struct Section: Equatable {
        public let name: String
        public let rows: [Row]
        /// A page rather than a pane: reached from a row of the named
        /// pane, never listed on the rail, and escape returns to its
        /// parent. Nil for the panes the number row addresses.
        public let parent: String?

        public init(name: String, rows: [Row], parent: String? = nil) {
            self.name = name
            self.rows = rows
            self.parent = parent
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
        public var editorModelStatus = ""
        /// Engines this Mac cannot run (too little memory, no Apple
        /// Intelligence): listed, greyed.
        public var editorEnginesUnavailable: Set<String> = []
        /// The English the Mac's own languages point to, for Automatic.
        public var editorRegionInferred = "en_US"
        /// The units the Mac's region measures in, for Units until one is chosen.
        public var unitsInferred = ClipQuantity.System.imperial.rawValue

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
        "graph": ("Graph", ["lode", "a…z"],
                  "Letters that lead straight to apps. Hold lode and press one."),
        "tabs": ("Tabs", ["lode", "⇥"], "A letter on every tab of the window. ⇧⇥ lists its windows."),
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

        // 1 · General
        sections.append(Section(name: "General", rows: [
            Row(title: "Lode key", path: "lode.trigger",
                control: .choice(options: ["right-command", "left-command"],
                                 labels: ["Right ⌘", "Left ⌘"],
                                 current: config.trigger.rawValue),
                detail: "A ⌘⌃⌥ hyper shim also works without changing this.",
                isDefault: config.trigger == .rightCommand),
            Row(title: "Tap lode", path: "lode.tap",
                control: .toggle(config.lodeTap),
                detail: "A tap arms the next key as a gesture, for one second. "
                    + "Holding still works and is how the map appears.",
                isDefault: config.lodeTap),
            Row(title: "Start at login", path: "app.start-at-login",
                control: .toggle(config.startAtLogin), isDefault: config.startAtLogin),
            Row(title: "Automatic updates", path: "app.auto-update",
                control: .toggle(config.autoUpdate), isDefault: config.autoUpdate),
            Row(title: "Sounds", path: "app.sounds",
                control: .toggle(config.sounds),
                detail: "Lodestar's own sounds: the draft's note when the microphone is live and when the words land. The alert sound is the Mac's own.",
                isDefault: config.sounds),
            Row(title: "Menu bar icon", path: "app.show-menu-bar",
                control: .toggle(config.showMenuBar), isDefault: config.showMenuBar),
            Row(title: "Active display", path: "app.active-display",
                control: .choice(options: ["pointer", "focus"],
                                 labels: ["Under the pointer", "With the focused window"],
                                 current: config.activeDisplayMode == .focus ? "focus" : "pointer"),
                detail: "Which display summoned windows land on.",
                isDefault: config.activeDisplayMode == .pointer),
            Row(title: "Accent", path: "appearance.accent",
                control: .choice(options: ["system", "orange"],
                                 labels: ["System", "International Orange"],
                                 current: config.accent.rawValue),
                detail: "The cursor, lit letters, and the echoed query. Orange "
                    + "is set deeper in light mode so it stays readable.",
                isDefault: config.accent == .system),
        ]))

        // 2 · Permissions — reads the machine, never the config.
        sections.append(Section(name: "Permissions", rows: [
            Row(title: "Accessibility", control: .readout(machine.accessibility, sub: nil),
                detail: "Seeing windows, moving them, reading menus. The one "
                    + "permission the app cannot work without."),
            Row(title: "Screen Recording", control: .readout(machine.screenRecording, sub: nil),
                detail: "Selecting text you can see. Asked the first time "
                    + "you use lode /."),
            Row(title: "Calendars", control: .readout(machine.calendars, sub: nil),
                detail: "Offering your next meeting. Asked when meetings "
                    + "are turned on."),
        ]))

        // 3 · Gestures — is the feature on, named plainly, wearing its
        // keys, in four short lists instead of one long one.
        let gestureGroups: [(group: String, verbs: [String])] = [
            ("Navigation", ["launcher", "graph", "tabs", "index-jump"]),
            ("Windows", ["maximize", "flip-orientation", "layout-undo",
                         "display-move", "breaths"]),
            ("Interactions", ["hints", "scroll", "select", "commands", "draft"]),
            ("Panels", ["web-bar", "settings"]),
        ]
        var gestureRows: [Row] = []
        for (group, verbs) in gestureGroups {
            for name in verbs {
                guard let verb = Gestures.roster.first(where: { $0.name == name })
                else { continue }
                let named = Self.gestureNames[verb.name] ?? (verb.name, [], nil)
                let enabled = !config.disabledGestures.isSuperset(of: Set(verb.keys))
                gestureRows.append(Row(title: named.name, path: "gestures.\(verb.name)",
                                       control: .toggle(enabled), detail: named.detail,
                                       keycaps: named.caps,
                                       isDefault: enabled, group: group))
            }
        }
        gestureRows.append(Row(title: "Clipboard", path: "clipboard.enabled",
                               control: .toggle(config.clipboardEnabled),
                               keycaps: ["⇧⌘V"],
                               isDefault: config.clipboardEnabled, group: "Panels"))
        sections.append(Section(name: "Gestures", rows: gestureRows))

        // 4b · The draft
        let inputOptions = [""] + machine.inputDevices
        let inputLabels = ["System default" + (machine.defaultInput.map { " (\($0))" } ?? "")]
            + machine.inputDevices
        let draftRows: [Row] = [
            Row(title: "Microphone", path: "draft.input",
                control: .choice(options: inputOptions, labels: inputLabels,
                                 current: inputOptions.contains(config.draftInput) ? config.draftInput : ""),
                detail: "What the draft listens to. The register line names it while listening.",
                isDefault: config.draftInput.isEmpty),
            Row(title: "Words", path: "draft.words",
                control: .table(kind: .draftWords, entries: config.draftWords
                    .map { TableEntry(key: $0, display: $0) }),
                detail: "Names and terms speech gets wrong. A spoken word within a letter "
                    + "or two of one of these becomes it, case and all.",
                isDefault: config.draftWords.isEmpty),
        ]

        // 9 · The editor, its own pane, above Advanced: the last pane is
        // the one most people never open, and it keeps the end of the row.
        var editorRows: [Row] = [
            Row(title: "Enable editor", path: "editor.enabled",
                control: .toggle(config.editorEnabled),
                detail: "Marks mistakes as you write, in every app. Your text never leaves "
                    + "this Mac and is never kept.",
                keycaps: ["lode", "⇥"],
                isDefault: !config.editorEnabled,
                problem: problem(at: "editor.enabled")),
        ]
        if !machine.editorEngines.isEmpty {
            var model = Row(title: "Model", path: "editor.model",
                control: .choice(options: machine.editorEngines, labels: machine.editorEngineLabels,
                                 current: machine.editorEngineCurrent),
                detail: machine.editorModelStatus + ". Spelling reads typos without a model; the others "
                    + "read grammar too. A model loads when you write and lets its memory go two minutes "
                    + "after you stop.",
                isDefault: config.editorModel.isEmpty)
            model.disabledChoices = machine.editorEnginesUnavailable
            editorRows.append(model)
        } else {
            editorRows.append(Row(title: "Model", path: "editor.model",
                control: .readout(machine.editorModelStatus, sub: nil),
                detail: "Loads when you start writing and lets go of its memory two minutes after you stop.",
                isDefault: config.editorModel.isEmpty))
        }
        editorRows += [
            Row(title: "Spelling", path: "editor.language",
                control: .choice(options: [""] + EditorRegion.choices.map(\.code),
                                 labels: ["Automatic · \(EditorRegion.name(of: machine.editorRegionInferred))"]
                                    + EditorRegion.choices.map(\.name),
                                 current: config.editorLanguage),
                detail: "Automatic follows your Mac's language and region.",
                isDefault: config.editorLanguage.isEmpty),
            Row(title: "Words", path: "draft.words",
                control: .table(kind: .draftWords, entries: config.draftWords.map { TableEntry(key: $0, display: $0) }),
                detail: "Shared with the draft. Names and terms that are never marked.",
                isDefault: config.draftWords.isEmpty),
            Row(title: "Skip in", path: "editor.skip-apps",
                control: .table(kind: .editorSkipApps, entries: config.editorSkipApps.sorted().map {
                    TableEntry(key: $0, display: $0) }),
                detail: "Fields in these apps are never read.",
                isDefault: config.editorSkipApps.isEmpty),
        ]
        // 4 · Interaction
        sections.append(Section(name: "Interaction", rows: [
            Row(title: "Smooth scrolling", path: "scroll.smooth",
                control: .toggle(config.scrollSmooth), isDefault: config.scrollSmooth),
            Row(title: "Scroll speed", path: "scroll.speed",
                control: .number(Int(config.scrollSpeed), min: 200, max: 4000, unit: "px/s"),
                detail: "How fast smooth scrolling moves.",
                isDefault: isDefault(["scroll", "speed"], .int(Int(config.scrollSpeed))),
                dimmed: !config.scrollSmooth),
            Row(title: "Scroll step", path: "scroll.step",
                control: .number(Int(config.scrollStep), min: 10, max: 400, unit: "px"),
                detail: "How far each keypress moves when smooth scrolling "
                    + "is off.",
                isDefault: isDefault(["scroll", "step"], .int(Int(config.scrollStep))),
                dimmed: config.scrollSmooth),
            Row(title: "Copy on select", path: "select.copy-on-complete",
                control: .toggle(config.selectCopyOnComplete),
                detail: "A completed span is copied the moment its second "
                    + "anchor lands.",
                isDefault: !config.selectCopyOnComplete),
        ] + draftRows))


        // 5 · Clipboard
        var clipboardRows: [Row] = []
        if !config.clipboardEnabled {
            clipboardRows.append(Row(title: "Clipboard is off",
                                     control: .readout("Turn it on under Gestures.", sub: nil)))
        }
        clipboardRows.append(contentsOf: [
            Row(title: "Size limit", path: "clipboard.max-size-mb",
                control: .number(config.clipboardMaxBytes / 1_000_000, min: 10, max: 20_000, unit: "MB"),
                detail: "Clips past the limit are never recorded.",
                isDefault: config.clipboardMaxBytes == 500_000_000),
            Row(title: "Save images to", path: "clipboard.save-to",
                control: .text(config.clipboardSaveFolder, placeholder: "~/Downloads"),
                detail: "Where an image saved from the strip lands. A name typed "
                    + "with a slash, or starting with / or ~, chooses another place "
                    + "for that one save.",
                isDefault: config.clipboardSaveFolder == "~/Downloads"),
            Row(title: "Excluded apps", path: "clipboard.exclude-apps",
                control: .table(kind: .excludeApps, entries: config.clipboardExcludedApps
                    .sorted().map { TableEntry(key: $0, display: $0) }),
                detail: "Nothing copied in these apps is ever recorded.",
                isDefault: config.clipboardExcludedApps.isEmpty),
            Row(title: "Excluded patterns", path: "clipboard.exclude",
                control: .table(kind: .excludePatterns, entries: config.clipboardExcludePatterns
                    .sorted().map { TableEntry(key: $0, display: $0) }),
                detail: "A clip whose text contains one of these is never "
                    + "recorded. Matching ignores case.",
                isDefault: config.clipboardExcludePatterns.isEmpty),
            Row(title: "Time zones", path: "clipboard.time-zones",
                control: .table(kind: .clipboardTimeZones, entries: config.clipboardTimeZones.compactMap { id in
                    TimeZone(identifier: id).map { TableEntry(key: id, display: ClipTime.label($0)) }
                }),
                detail: "A timestamp on a card is read into your zone, UTC, and these.",
                isDefault: config.clipboardTimeZones.isEmpty),
        ])
        sections.append(Section(name: "Clipboard", rows: clipboardRows))

        // 6 · Web. No profile inventory to manage: the pickers list what
        // the browsers actually have, references store `browser:Name`
        // directly, and the doctor says so when one names a profile the
        // machine no longer holds.
        /// A stored reference, shown with the profile's own casing.
        func shownReference(_ key: String) -> String {
            config.browserProfiles[key]?.reference ?? key
        }
        var fallbackOptions = ["most-recent"]
        var fallbackLabels = ["the browser you were last in"]
        for detected in machine.detectedProfiles {
            fallbackOptions.append(Self.profileReference(browser: detected.browser,
                                                         name: detected.name))
            fallbackLabels.append("\(detected.browserLabel) · \(detected.name)")
        }
        var fallbackCurrent = "most-recent"
        if config.webFallback != "most-recent" {
            if let index = fallbackOptions.firstIndex(where: {
                $0.lowercased() == config.webFallback
            }) {
                fallbackCurrent = fallbackOptions[index]
            } else if let profile = config.browserProfiles[config.webFallback] {
                // Referenced but not on this machine: shown honestly, and
                // still one pick away from something that exists.
                fallbackOptions.append(profile.reference)
                fallbackLabels.append("\(profile.browser.label) · \(profile.display) (not found)")
                fallbackCurrent = profile.reference
            }
        }
        let linkEntries = config.webLinks.sorted { $0.name < $1.name }
            .map { link -> TableEntry in
                let pin = link.profileKey.map { "  →  \(shownReference($0))" } ?? ""
                return TableEntry(key: link.name, display: link.name,
                                  sub: "\(link.url)\(pin)")
            }
        let routeEntries = config.webRoutes.sorted { $0.key < $1.key }
            .map { TableEntry(key: $0.key, display: $0.key,
                              sub: "→  \(shownReference($0.value))") }
        sections.append(Section(name: "Web", rows: [
            Row(title: "Fallback profile", path: "web.fallback",
                control: .choice(options: fallbackOptions, labels: fallbackLabels,
                                 current: fallbackCurrent),
                detail: "Where a destination opens when no rule decides.",
                isDefault: config.webFallback == "most-recent",
                problem: problem(at: "web.fallback")),
            Row(title: "Search engine", path: "web.search-url",
                control: .text(config.webSearchURL, placeholder: "https://…?q=%s"),
                detail: "Where a query goes when what you typed is not a "
                    + "link. Lodestar puts your words where the %s is.",
                isDefault: isDefault(["web", "search-url"], .string(config.webSearchURL)),
                presets: [
                    Preset(label: "Brave Search",
                           value: "https://search.brave.com/search?q=%s"),
                    Preset(label: "Google",
                           value: "https://www.google.com/search?q=%s"),
                ]),
            Row(title: "Links", path: "web.links",
                control: .table(kind: .links, entries: linkEntries),
                detail: "A short name you type in Ask, and the page it "
                    + "opens. A pinned profile overrides every other rule.",
                isDefault: config.webLinks.isEmpty,
                problem: problem(at: "web.links")),
            Row(title: "Routes", path: "web.routes",
                control: .table(kind: .routes, entries: routeEntries),
                detail: "Pattern → profile. Matched against anything you "
                    + "type or click, so one line replaces a habit.",
                isDefault: config.webRoutes.isEmpty,
                problem: problem(at: "web.routes")),
            Row(title: "Route clicked links", path: "web.clicks.enabled",
                control: .toggle(config.webHandleClicks),
                detail: "Lodestar stands as the default browser and applies "
                    + "your routes to links clicked in any app. A link that "
                    + "matches no rule goes to your saved browser untouched. "
                    + machine.browserRole,
                isDefault: !config.webHandleClicks),
            Row(title: "Saved browser", path: "web.clicks.browser",
                control: .readout(machine.savedBrowser, sub: machine.savedBrowserID),
                detail: "Recorded when Lodestar takes the browser role, and "
                    + "restored when it gives the role back."),
        ]))

        // 7 · Meetings
        let calendarEntries = config.meetingsCalendars.sorted { $0.key < $1.key }
            .map { TableEntry(key: $0.key, display: $0.key,
                              sub: "→  \(shownReference($0.value))") }
        sections.append(Section(name: "Meetings", rows: [
            Row(title: "Enable meetings", path: "meetings.enabled",
                control: .toggle(config.meetingsEnabled),
                detail: "A chip before each meeting with a link. Tap lode "
                    + "twice to join.",
                isDefault: !config.meetingsEnabled,
                problem: problem(at: "meetings.enabled")),
            Row(title: "Lead time", path: "meetings.lead-minutes",
                control: .number(config.meetingsLeadMinutes, min: 0, max: 120, unit: "min"),
                detail: "Minutes before the start the chip appears.",
                isDefault: config.meetingsLeadMinutes == 5),
            Row(title: "Calendars", path: "meetings.calendars",
                control: .table(kind: .calendars, entries: calendarEntries),
                detail: "Calendar → profile, for meetings joined in a "
                    + "browser. Outranks routes, because the calendar is "
                    + "the only signal that can tell two meetings on the "
                    + "same host apart. Calendars are picked from your "
                    + "machine, never typed.",
                isDefault: config.meetingsCalendars.isEmpty,
                problem: problem(at: "meetings.calendars")),
        ]))

        // 8 · Coach
        sections.append(Section(name: "Coach", rows: [
            Row(title: "Observations", path: "observations.enabled",
                control: .toggle(config.observationsEnabled),
                detail: "Notice how you navigate, on this machine only. "
                    + "Never titles, URLs, or content. Feeds the coach and "
                    + "the retrospective.",
                isDefault: config.observationsEnabled),
            Row(title: "Health pulse", path: "observations.health",
                control: .toggle(config.observationsHealth && config.observationsEnabled),
                detail: config.observationsEnabled
                    ? "Also keep input counts and typing rhythm, for the "
                        + "quarterly mirror. Counts only, never which keys "
                        + "or what was typed."
                    : "Needs observations.",
                isDefault: config.observationsHealth,
                dimmed: !config.observationsEnabled),
            Row(title: "Coach", path: "coach.enabled",
                control: .toggle(config.coachEnabled && config.observationsEnabled),
                detail: config.observationsEnabled
                    ? "Occasionally suggests one shortcut worth learning, "
                        + "based on how you actually navigate. Tap lode "
                        + "twice on the chip and it is set up for you."
                    : "Needs observations.",
                isDefault: config.coachEnabled,
                dimmed: !config.observationsEnabled),
            // About you, for the health record. Two facts every reading
            // of the hands is adjusted for, and nothing that names you.
            Row(title: "Born", path: "health.born",
                control: .text(config.healthBorn.map(String.init) ?? "", placeholder: "Year"),
                detail: "The year. Age is the first thing a reading of the hands "
                    + "is adjusted for. Optional, local, never sent.",
                isDefault: config.healthBorn == nil,
                group: "Health"),
            Row(title: "Dominant hand", path: "health.hand",
                control: .choice(options: ["", "left", "right", "either"],
                                 labels: ["Not set", "Left", "Right", "Either"],
                                 current: config.healthHand),
                detail: "The hand you write with. Fine motor signs are often "
                    + "one sided and the record keeps each hand apart.",
                isDefault: config.healthHand.isEmpty,
                group: "Health"),
            Row(title: "Keyboards", path: "health.keyboards",
                control: .page(keyboardsPage),
                detail: keyboardsSummary(config: config, machine: machine),
                isDefault: config.fingerMap.isEmpty,
                group: "Health"),
        ]))

        sections.append(Section(name: "Editor", rows: editorRows))

        // 10 · Advanced, on 0
        let remapEntries = config.keyOverrides.sorted { $0.key < $1.key }
            .map { TableEntry(key: String($0.key), display: "keycode \($0.key)",
                              sub: "types \($0.value)") }
        sections.append(Section(name: "Advanced", rows: [
            Row(title: "Units", path: "app.units",
                control: .choice(options: ClipQuantity.System.allCases.reversed().map(\.rawValue),
                                 labels: ["Imperial", "Metric"],
                                 current: config.units.isEmpty ? machine.unitsInferred : config.units),
                detail: "What a copied measurement is read into on its clipboard card. "
                    + "Your region's until you choose.",
                isDefault: config.units.isEmpty),
            Row(title: "Key remaps", path: "keys",
                control: .table(kind: .keyRemaps, entries: remapEntries),
                detail: "Keycode to key name, for keyboards the built-in "
                    + "table misreads. Most people never need one.",
                isDefault: config.keyOverrides.isEmpty),
        ]))
        return sections
    }

    // MARK: - Pages

    public static let keyboardsPage = "Keyboards"

    /// The Health row's one line: which boards differ, and by how much.
    static func keyboardsSummary(config: Config, machine: MachineState) -> String {
        let named = machine.keyboards.filter { !$0.builtIn }
        guard !named.isEmpty else {
            return "Where each key sits on a split or custom keyboard, so the record "
                + "charges it to the right finger. Letters keep their columns everywhere."
        }
        return named.map { keyboard in
            let n = config.fingerMap.differing(on: keyboard.id)
            let state = n == 0 ? "standard" : (n == 1 ? "1 key differs" : "\(n) keys differ")
            return "\(keyboard.name) · \(state)"
        }.joined(separator: ". ") + "."
    }

    /// The pages behind the panes: reached from a row, never from the
    /// rail. One today — the Keyboards page, opened to one keyboard.
    public static func pages(config: Config, machine: MachineState,
                             view: ViewState = ViewState()) -> [Section] {
        [keyboardsSection(config: config, machine: machine, view: view)]
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
            return Section(name: keyboardsPage, rows: rows, parent: "Coach")
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
        guard let shown else { return Section(name: keyboardsPage, rows: rows, parent: "Coach") }
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
        return Section(name: keyboardsPage, rows: rows, parent: "Coach")
    }

    // MARK: - Labels

    /// Plain alphabetical, matching the reading order of the rows —
    /// settings is a page, not an instrument, and a page numbers its
    /// items in the order the eye meets them. No digits: those address
    /// panes.
    public static let labelAlphabet = "abcdefghijklmnopqrstuvwxyz".map(String.init)

    /// The key that addresses a pane: 1 through 9, then 0 for the tenth —
    /// the number row's own order, one key each.
    public static let paneKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    public static func paneKey(_ index: Int) -> String? {
        paneKeys.indices.contains(index) ? paneKeys[index] : nil
    }

    public static func pane(forKey key: String, count: Int) -> Int? {
        guard let index = paneKeys.firstIndex(of: key), index < count else { return nil }
        return index
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
    }

    /// Flat, fuzzy-ish, and stable: title and path both match, pane order
    /// breaks ties, and an empty query means no hits rather than all —
    /// search is a verb here, not a view.
    public static func search(_ query: String, in sections: [Section]) -> [Hit] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var hits: [Hit] = []
        for (sectionIndex, section) in sections.enumerated() {
            for (rowIndex, row) in section.rows.enumerated() {
                let haystack = "\(row.title) \(row.path) \(section.name)".lowercased()
                if haystack.contains(needle) {
                    hits.append(Hit(section: sectionIndex, row: rowIndex,
                                    title: row.title, sectionName: section.name))
                }
            }
        }
        return hits
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
