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
    }

    public struct Section: Equatable {
        public let name: String
        public let rows: [Row]

        public init(name: String, rows: [Row]) {
            self.name = name
            self.rows = rows
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
        "window-chooser": ("Window list", ["lode", "⇥"], nil),
        "web-bar": ("Ask", ["lode", "⏎"],
                    "Type a destination or a question. It opens in the "
                    + "right browser profile."),
        "commands": ("Commands", ["lode", "-"], nil),
        "draft": ("Draft", ["lode", "."], "Speak into it and ⏎ pastes where your cursor was. ⇧. edits the field."),
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
                                 labels: ["right ⌘", "left ⌘"],
                                 current: config.trigger.rawValue),
                detail: "A ⌘⌃⌥ hyper shim also works without changing this.",
                isDefault: config.trigger == .rightCommand),
            Row(title: "Start at login", path: "app.start-at-login",
                control: .toggle(config.startAtLogin), isDefault: config.startAtLogin),
            Row(title: "Automatic updates", path: "app.auto-update",
                control: .toggle(config.autoUpdate), isDefault: config.autoUpdate),
            Row(title: "Menu bar icon", path: "app.show-menu-bar",
                control: .toggle(config.showMenuBar), isDefault: config.showMenuBar),
            Row(title: "Active display", path: "app.active-display",
                control: .choice(options: ["pointer", "focus"],
                                 labels: ["under the pointer", "with the focused window"],
                                 current: config.activeDisplayMode == .focus ? "focus" : "pointer"),
                detail: "Which display summoned windows land on.",
                isDefault: config.activeDisplayMode == .pointer),
            Row(title: "Accent", path: "appearance.accent",
                control: .choice(options: ["system", "orange"],
                                 labels: ["the Mac's accent", "international orange"],
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
            ("Navigation", ["launcher", "graph", "window-chooser", "index-jump"]),
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
        ]))

        // 9 · Advanced
        let remapEntries = config.keyOverrides.sorted { $0.key < $1.key }
            .map { TableEntry(key: String($0.key), display: "keycode \($0.key)",
                              sub: "types \($0.value)") }
        sections.append(Section(name: "Advanced", rows: [
            Row(title: "Key remaps", path: "keys",
                control: .table(kind: .keyRemaps, entries: remapEntries),
                detail: "Keycode to key name, for keyboards the built-in "
                    + "table misreads. Most people never need one.",
                isDefault: config.keyOverrides.isEmpty),
        ]))

        return sections
    }

    // MARK: - Labels

    /// Plain alphabetical, matching the reading order of the rows —
    /// settings is a page, not an instrument, and a page numbers its
    /// items in the order the eye meets them. No digits: those address
    /// panes.
    public static let labelAlphabet = "abcdefghijklmnopqrstuvwxyz".map(String.init)

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
