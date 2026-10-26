import Foundation
import StoicJSON
import StoicSchema

/// What `lodestar.json` holds, as a typed value: the file's own sections and
/// keys, and nothing derived. `Config` is what the app runs on, built from
/// this (lossy: clamped, lowercased, resolved, with a graph that is a class);
/// this is what the file says, so it can be compared, written back and
/// diffed.
///
/// **`ConfigFile.schema` is the one declaration** of the file: every default
/// (the field initialisers below), what is accepted and what each problem is
/// called, the words each option is documented in, the JSON Schema an editor
/// reads (`lodestar schema`), how the old spellings are read, and the order
/// the file is written in. Nothing else says any of it.
///
/// **The layout is the byte compatibility.** The top-level sections are
/// declared in the order a person reads the file (the order every release
/// before this one wrote), and the fields of every section alphabetically
/// (`ConfigFileTests` holds the schema to that), so a file an earlier release
/// wrote is written back byte for byte.
///
/// **Sparse.** A write holds only what differs from the defaults here; the
/// store carries keys the schema does not declare, and what it could not read
/// (a value it repaired), back into the file untouched.
public struct ConfigFile: Sendable, Equatable {
    public var lode = Lode()
    public var app = App()
    public var gestures = GestureSwitches()
    public var web = Web()
    public var scroll = Scroll()
    public var select = Select()
    public var meetings = Meetings()
    public var clipboard = Clipboard()
    public var editor = Editor()
    public var observations = Observations()
    public var coach = Coach()
    public var keys: [String: String] = [:]
    public var graph: JSONValue = .object(JSONObject())
    public var appearance = Appearance()
    public var draft = Draft()
    public var health = Health()

    public init() {}

    public struct Lode: Sendable, Equatable {
        public var tap = true
        public var trigger = Config.Trigger.rightCommand
    }

    public struct App: Sendable, Equatable {
        public var activeDisplay = ActivePolicy.Mode.pointer
        public var autoUpdate = true
        public var channel = Updater.Channel.stable
        public var mouseScrolling = MouseScroll.Direction.system
        public var showMenuBar = true
        public var sounds = true
        public var startAtLogin = true
        public var units = ""
    }

    public struct Web: Sendable, Equatable {
        public var clicks = Clicks()
        public var fallback = "most-recent"
        public var links: [String: Link] = [:]
        public var routes: [String: String] = [:]
        public var searchURL = "https://search.brave.com/search?q=%s"

        public struct Clicks: Sendable, Equatable {
            public var browser = ""
            public var enabled = false
        }

        /// A named link. The url is empty until one is given, which `Config`
        /// reports as a link that needs one.
        public struct Link: Sendable, Equatable {
            public var profile: String?
            public var url = ""
        }
    }

    public struct Scroll: Sendable, Equatable {
        public var smooth = true
        public var speed = 1800.0
        public var step = 60.0
    }

    public struct Select: Sendable, Equatable {
        public var copyOnComplete = false
    }

    public struct Meetings: Sendable, Equatable {
        public var calendars: [String: String] = [:]
        public var enabled = false
        public var leadMinutes = 5
    }

    public struct Clipboard: Sendable, Equatable {
        public var enabled = true
        public var exclude: [String: Bool] = [:]
        public var excludeApps: [String: Bool] = [:]
        public var maxSizeMB = 500
        public var saveTo = "~/Downloads"
        public var timeZones: [String: Bool] = [:]
    }

    public struct Editor: Sendable, Equatable {
        public var enabled = false
        public var language = ""
        public var model = ""
        public var skipApps: [String: Bool] = [:]
    }

    public struct Observations: Sendable, Equatable {
        public var health = true
        public var healthMB = 1024
        public var logbook = true
        public var logbookMB = 256
    }

    public struct Coach: Sendable, Equatable {
        public var enabled = true
        public var stand = true
        public var standAfter = 30
    }

    public struct Appearance: Sendable, Equatable {
        public var eyeComfort = true
    }

    public struct Draft: Sendable, Equatable {
        public var editingStyle = LodestarCore.Draft.EditingStyle.standard
        public var input = ""
        public var model = ""
        public var words: [String: Bool] = [:]
    }

    public struct Health: Sendable, Equatable {
        /// The year, or none: a fact only the person can give.
        public var born: String?
        public var hand: String?
        public var keyboards: [String: [String: String]] = [:]
    }
}

/// One switch per gesture, by verb name. `false` frees the verb's keys to the
/// app.
///
/// The names come from `Gestures.roster` at run time, so the fields are
/// generated from it rather than listed: a verb added to the roster is a
/// gesture the file accepts, documents (`about`) and flags a typo against,
/// with no second list to keep in step. (A dictionary of booleans would
/// accept any name; this object does not, and the JSON Schema enumerates the
/// valid ones.) Held as the set of verbs that are off, so equality and the
/// sparse write are about what differs from the default of everything on.
public struct GestureSwitches: Sendable, Equatable {
    public var off: Set<String> = []

    public subscript(name: String) -> Bool {
        get { !off.contains(name) }
        set { if newValue { off.remove(name) } else { off.insert(name) } }
    }

    /// The idle-state keys the engine passes through to the app.
    public var disabledKeys: Set<String> {
        Gestures.disabledKeys(from: Dictionary(uniqueKeysWithValues: off.map { ($0, false) }))
    }
}

// MARK: - The schema

extension ConfigFile {
    private static let editorLanguages = [""] + EditorRegion.choices.map(\.code)

    /// A table of switches the person fills in: `true` keeps the entry.
    private static func switches(_ valueDoc: String) -> Schema<[String: Bool]> {
        .lossyDictionary(of: .bool, valueDoc: valueDoc)
    }

    /// Where a key sits on a keyboard: what `FingerMap.Placement` parses.
    private static let keyboardKeys = Schema<[String: [String: String]]>.lossyDictionary(
        of: .lossyDictionary(
            of: .string(),
            valueDoc: "Where the key sits on this keyboard, as a side and a finger: right thumb, either thumb, left pinky."),
        valueDoc: "One keyboard's keys that sit somewhere other than standard, by name: left-shift, right-shift, "
            + "left-control, right-control, left-option, right-option, left-command, right-command, fn, space, "
            + "enter, backspace, tab, escape.")

    /// Declared top level in the order a person reads the file, every
    /// section's fields alphabetically: see the type's documentation.
    public static let schema: Schema<ConfigFile> = section(ConfigFile.self, default: ConfigFile(), doc: "lodestar configuration") {
        Field("lode", \.lode, lodeSection, doc: "The lode key.")
        Field("app", \.app, appSection, doc: "App behavior.")
        Field("gestures", \.gestures, gesturesSection,
              doc: "Every gesture, one switch each; false frees its keys to the app.")
        Field("web", \.web, webSection, doc: "The web bar.")
        Field("scroll", \.scroll, scrollSection, doc: "Scroll mode.")
        Field("select", \.select, selectSection, doc: "Select mode.")
        Field("meetings", \.meetings, meetingsSection, doc: "Meetings at the door.")
        Field("clipboard", \.clipboard, clipboardSection, doc: "Clipboard history.")
        Field("editor", \.editor, editorSection, doc: "The editor: marks under mistakes, lode ⇥ to fix.")
        Field("observations", \.observations, observationsSection,
              doc: "What Lodestar observes, in two records with their own switches. Nothing leaves the machine.")
        Field("coach", \.coach, coachSection,
              doc: "The coach: rare, evidence-backed suggestions drawn from the observations.")
        Field("keys", \.keys,
              .lossyDictionary(of: .string(), valueDoc: "The key name this keycode produces."),
              doc: "Keycode → key-name overrides for non-ANSI layouts.")
        Field("graph", \.graph, .json(jsonSchema: graphShape),
              doc: "lode + letter chains → apps. Values: app name or <browser>:<profile name>.")
        Field("appearance", \.appearance, appearanceSection,
              doc: "How Lodestar looks. Never what it asks of you.")
        Field("draft", \.draft, draftSection, doc: "The draft: lode . speaks, lode ⇧. revises.")
        Field("health", \.health, healthSection,
              doc: "About you, for the health record. Local, optional, never sent.")
    }
    .normalizing(
        // A `null` has always meant "nothing here": the default file of an
        // earlier release left `"links": null` where a table was to go, and
        // a section emptied of its keys is left as `"scroll": null`. It reads
        // as absent (the default), silently, wherever it is, and the next
        // write does not carry it.
        .custom(id: "null-is-absent", description: "drop every null member",
                apply: { Self.withoutNulls(&$0) }),
        // hyper became lode, and the searcher became the launcher. Both are
        // the same switch under a new word, so a file written before the
        // rename keeps working rather than reporting an unknown key.
        .rename("hyper", to: "lode"),
        .rename("gestures.searcher", to: "launcher"),
        // Menu search became the commands bar: the same switch under the
        // register's new name, ahead of system commands joining as a second
        // feed.
        .rename("gestures.menu-search", to: "commands"),
        // 0.41 named the two records: the switch that was observations.enabled
        // gates the logbook alone.
        .rename("observations.enabled", to: "logbook"),
        // The old hyper trigger folds into the default, which has always
        // accepted the ⌘⌃⌥ chord a shim produces.
        .mapEnum("lode.trigger", ["raw-hyper": "right-command"]),
        // The profile registry retired in 0.22: a reference names its browser
        // and profile directly (`brave:Work`), validated against what the
        // browser actually has. Every reference written through the old
        // registry is translated through its table one last time, and the
        // section itself is dropped.
        .custom(id: "profile-registry",
                description: "rewrite references through the retired profiles registry, then drop it",
                apply: { Self.foldProfileRegistry(&$0) }),
        // A file written before a retirement keeps loading clean, rather than
        // reporting an unknown key for a switch the app's own Settings once
        // wrote:
        retired: [
            // the attention timeline (0.17), the cheat sheet (0.22) and the
            // tabs door (0.41)
            "gestures.back-forward", "gestures.cheat-sheet", "gestures.tabs",
            // The appearance section's two retired choices: Background (after
            // 0.43) because there is one night, and Accent (Ceramic) because
            // there is one colour, International Orange. A file that still
            // names either loads clean and the next write does not carry it;
            // the section itself lives on for Eye comfort.
            "appearance.background", "appearance.accent",
            // the name nothing read, the double-tap grammar, hand-set hint
            // letters and the rescan delay (the layout is detected now), and
            // the auto-reload toggle (watching is simply how the config works)
            "you", "double-tap", "hints", "web.clicks.trace", "app.auto-reload",
            // commit-on-unique and the guide's fade became the doctrine (0.30.9)
            "select.commit-on-unique", "guide",
            // the registry itself, which the operation above has read
            "profiles",
            // exact keyboard attribution, which is simply how health reads
            // the keys now, wherever Input Monitoring allows (0.55)
            "health.exact-keyboards",
        ])

    /// An object of the file, read exactly: a spelling that is not the
    /// declared key (`auto_update`, `Auto-Update`) is an unknown key, with the
    /// declared one suggested, as it has always been, and the JSON Schema an
    /// editor reads says the same.
    private static func section<V: Sendable>(
        _ type: V.Type, default defaultValue: V, doc: String? = nil,
        @FieldsBuilder<V> fields: () -> [Field<V>]
    ) -> Schema<V> {
        Schema.object(type, default: defaultValue, spellings: .exact, doc: doc, fields: fields)
    }

    private static let lodeSection = section(Lode.self, default: Lode()) {
        Field("tap", \.tap, .bool,
              doc: "A tap of lode arms the next key as a gesture, for one second, as if lode were held. Holding still works and is how the map appears.")
        Field("trigger", \.trigger, .enumeration(Config.Trigger.self), doc: "The physical trigger for every gesture.")
    }
    .readingNullAsEmpty()

    private static let appSection = section(App.self, default: App()) {
        Field("active-display", \.activeDisplay, .enumeration(ActivePolicy.Mode.self),
              doc: "How the active display is chosen.")
        Field("auto-update", \.autoUpdate, .bool,
              doc: "Keep Lodestar current: check daily, verify the download, apply quietly when idle (installed app only).")
        Field("channel", \.channel, .enumeration(Updater.Channel.self),
              doc: "Which releases updates follow. Stable takes a build once it has run on preview Macs for a few days. Preview takes every build as it ships.")
        Field("mouse-scrolling", \.mouseScrolling, .enumeration(MouseScroll.Direction.self),
              doc: "Which way a mouse wheel scrolls, apart from the trackpad: natural, standard, or system to follow the Mac's one setting for both.")
        Field("show-menu-bar", \.showMenuBar, .bool,
              doc: "Show the status item permanently; false hides it until lodestar is picked in the launcher.")
        Field("sounds", \.sounds, .bool,
              doc: "Lodestar's own sounds, together: today the draft's note when the microphone is live and when the words land. The alert sound is the Mac's own setting.")
        Field("start-at-login", \.startAtLogin, .bool, doc: "Keep the login LaunchAgent installed (installed app only).")
        Field("units", \.units, .string(oneOf: ["", "metric", "imperial"]),
              doc: "The units a copied measurement is read into on its card. Empty follows your region.")
    }
    .readingNullAsEmpty()

    private static let gesturesSection: Schema<GestureSwitches> = section(GestureSwitches.self, default: GestureSwitches()) {
        Gestures.roster.sorted { $0.name < $1.name }.map { verb in
            Field(verb.name, \.[verb.name], .bool, doc: verb.about)
        }
    }
    .readingNullAsEmpty()

    private static let webSection = section(Web.self, default: Web()) {
        Field("clicks", \.clicks, clicksSection, doc: "Links clicked in other apps.")
        Field("fallback", \.fallback, .string(), doc: "most-recent, or a profile as browser:name (brave:Work).")
        Field("links", \.links, .lossyDictionary(of: linkSection), doc: "Named links.")
        Field("routes", \.routes,
              .lossyDictionary(of: .string(), valueDoc: "A profile as browser:name (brave:Work)."),
              doc: "Substring pattern → profile; longest match wins.")
        Field("search-url", \.searchURL, .string(), doc: "Search template; %s becomes the encoded query.")
    }
    .readingNullAsEmpty()

    private static let clicksSection = section(Web.Clicks.self, default: Web.Clicks()) {
        Field("browser", \.browser, .string(),
              doc: "Bundle id links go to when no route matches (your previous default browser).")
        Field("enabled", \.enabled, .bool, doc: "Route links clicked in other apps. Set by the menu-bar flow.")
    }
    .readingNullAsEmpty()

    private static let linkSection = section(Web.Link.self, default: Web.Link(), doc: "A named link.") {
        Field("profile", \.profile, .optional(.string()), doc: "A profile as browser:name (omit to route).")
        Field("url", \.url, .string(), doc: "The site.")
    }

    private static let scrollSection = section(Scroll.self, default: Scroll()) {
        Field("smooth", \.smooth, .bool, doc: "Constant velocity while held; instant stop on release.")
        Field("speed", \.speed, .double(.range(200...4000)).clampingToRange(),
              doc: "Smooth velocity, pixels per second.", unit: "px/s")
        Field("step", \.step, .double(.range(10...400)).clampingToRange(),
              doc: "Pixels per press when smooth is off.", unit: "px")
    }
    .readingNullAsEmpty()

    private static let selectSection = section(Select.self, default: Select()) {
        Field("copy-on-complete", \.copyOnComplete, .bool,
              doc: "Copy a completed span to the clipboard the moment its second anchor lands. Escape after only the first anchor copies that word.")
    }
    .readingNullAsEmpty()

    private static let meetingsSection = section(Meetings.self, default: Meetings()) {
        Field("calendars", \.calendars,
              .lossyDictionary(of: .string(), valueDoc: "The browser:name profile this calendar's meetings join in."),
              doc: "Calendar or account name → profile. Outranks web.routes for meetings.")
        Field("enabled", \.enabled, .bool, doc: "Offer the calendar's next meeting as a chip.")
        Field("lead-minutes", \.leadMinutes, .int(.range(0...120)).clampingToRange(),
              doc: "Minutes before the start the chip appears.", unit: "min")
    }
    .readingNullAsEmpty()

    private static let clipboardSection = section(Clipboard.self, default: Clipboard()) {
        Field("enabled", \.enabled, .bool,
              doc: "⇧⌘V opens the clipboard strip. The one Lodestar binding outside the lode key, so it is also the one that can collide with an app; false gives ⇧⌘V back.")
        Field("exclude", \.exclude, switches("true to never record clips containing this text."),
              doc: "Substring → true, matched case-insensitively against the clip. The same shape web.routes uses.")
        Field("exclude-apps", \.excludeApps, switches("true to never record clips copied from this app."),
              doc: "Bundle id → true. Nothing copied in these apps is ever written to disk.")
        Field("max-size-mb", \.maxSizeMB, .int(.range(10...20_000)).clampingToRange(),
              doc: "Disk the clipboard history may claim; the oldest clips are dropped to stay under it. Pins are never dropped.",
              unit: "MB")
        Field("save-to", \.saveTo, .string(),
              doc: "The folder an image saved from the clipboard strip lands in. A name typed with a slash in it, or starting with / or ~, chooses another place for that save.")
        Field("time-zones", \.timeZones, switches("true to read timestamps into this zone too."),
              doc: "Zone identifier (Asia/Tokyo) → true. A clip that is only a timestamp is read into your zone, UTC, and these.")
    }
    .readingNullAsEmpty()

    private static let editorSection = section(Editor.self, default: Editor()) {
        Field("enabled", \.enabled, .bool, doc: "Mark mistakes as you write; lode ⇥ letters the marks.")
        Field("language", \.language, .string(oneOf: editorLanguages),
              doc: "The spelling the editor holds you to. Empty follows the Mac's language and region.")
        Field("model", \.model, .string(oneOf: ["", "spelling", "minimal", "standard", "full"]),
              doc: "How the editor reads: spelling (no model, any Mac), minimal (Apple's own model), standard (16 GB Macs and up) or full (64 GB and up). Empty picks the one this Mac suits; one this Mac cannot run falls back the same way.")
        Field("skip-apps", \.skipApps, switches("true to never read fields in this app."),
              doc: "App name → true. Fields in these apps are never read.")
    }
    .readingNullAsEmpty()

    private static let observationsSection = section(Observations.self, default: Observations()) {
        Field("health", \.health, .bool,
              doc: "Keep the health record: when each key goes down and how long it is held, by hand, finger and kind of key, and how the pointer moves. No key is stored, but the pattern can partly show what you typed, so it stays on this machine and is included in backups. Independent of the logbook.")
        Field("health-mb", \.healthMB, .int(.range(Retention.healthMinimumMB...16_384)).clampingToRange(),
              doc: "The size Lodestar tells you the health record is nearing. Health is never deleted on its own.",
              unit: "MB")
        Field("logbook", \.logbook, .bool,
              doc: "Keep the logbook: how you move between apps, windows and gestures, on this machine only. Sites by name, never their pages, titles or what you type. The coach reads it.")
        Field("logbook-mb", \.logbookMB, .int(.range(Retention.logbookMinimumMB...4096)).clampingToRange(),
              doc: "Disk the logbook may claim. Once it is full the oldest months leave first; their monthly summaries stay.",
              unit: "MB")
    }
    .readingNullAsEmpty()

    private static let coachSection = section(Coach.self, default: Coach()) {
        Field("enabled", \.enabled, .bool,
              doc: "Let Lodestar offer one improvement at a time, in quiet moments, priced in seconds.")
        Field("stand", \.stand, .bool,
              doc: "After a stretch of work with no break, a cue to walk for two minutes, at the next natural stopping point. Twice at most in a stretch.")
        Field("stand-after", \.standAfter, .int(.range(15...120)).clampingToRange(),
              doc: "Minutes of unbroken work before the walk is due. The research supports thirty: two minutes of walking every twenty to thirty minutes.",
              unit: "min")
    }
    .readingNullAsEmpty()

    private static let appearanceSection = section(Appearance.self, default: Appearance()) {
        Field("eye-comfort", \.eyeComfort, .bool,
              doc: "Lodestar adjusts its own surfaces through the day to be easier on your eyes: dimmer and softer after sunset, dimmer still late at night, and quieter when you're not using them. What you copy and view is never changed.")
    }
    .readingNullAsEmpty()

    private static let draftSection = section(Draft.self, default: Draft()) {
        Field("editing-style", \.editingStyle, .enumeration(LodestarCore.Draft.EditingStyle.self),
              doc: "How the draft is edited: standard, as in any Mac text field, or vim, the modal editor (esc leaves typing for normal mode).")
        Field("input", \.input, .string(),
              doc: "The microphone the draft listens to, by its name in Sound settings. Empty follows the system default input.")
        Field("model", \.model, .string(oneOf: ["", "apple", "standard", "full", "max"]),
              doc: "The models that hear what you said again and take out the words you take back: apple (Apple's recognizer only), standard (Parakeet and Gemma 4 E2B, 16 GB Macs and up), full (Qwen3-ASR and Gemma 4 E2B, 24 GB and up), max (Qwen3-ASR and Qwen3.6 35B, 64 GB and up). Empty picks the one this Mac suits and fetches it the first time you dictate.")
        Field("words", \.words, switches("true to keep this word in the draft's vocabulary."),
              doc: "Word → true. Names and terms speech gets wrong; a settled result that sounds like one is written as it, case and all.")
    }
    .readingNullAsEmpty()

    private static let healthSection = section(Health.self, default: Health()) {
        Field("born", \.born, .optional(.string()),
              doc: "Moved to the health record, sealed. A year written here is moved there at launch and taken out of this file.")
        Field("hand", \.hand, .optional(.string(oneOf: ["left", "right", "either"])),
              doc: "Moved to the health record, sealed. A hand written here is moved there at launch and taken out of this file.")
        Field("keyboards", \.keyboards, keyboardKeys,
              doc: "Keyboard id (vendor:product:hash, as the Keyboards page shows it) → the keys a split or custom board moves. Letters keep their columns everywhere and are never here.")
    }
    .readingNullAsEmpty()
}

// MARK: - What the person is told

extension ConfigFile {
    /// One line for one issue: where it is (dotted, as `config get` takes it),
    /// what is wrong, and the nearest thing that would be right. The one
    /// string a problem is everywhere (the flash, `check`, `check --json`,
    /// the settings row).
    public static func sentence(for issue: Issue) -> String {
        var text = "\(dotted(issue.path)): \(issue.message)"
        if let suggestion = issue.suggestion { text += " (did you mean '\(suggestion)'?)" }
        return text
    }

    /// The issues as problems. A parse error is the file's
    /// (`ConfigStore.sentence(for:)` of its `SettingsFileProblem`) and a
    /// repeated key has its own wording (`ConfigStore.repeatedKeys`).
    public static func sentences(_ issues: [Issue]) -> [String] {
        issues.filter { $0.code != .parseError && $0.code != .repeatedKey }.map(sentence(for:))
    }

    /// Every problem the schema finds in a tree, as the person is told: what
    /// the file would be read as, leniently, so the whole list is there.
    public static func problems(in tree: [String: ConfigValue]) -> [String] {
        var root = tree
        root.removeValue(forKey: "$schema")
        root.removeValue(forKey: "version")
        return sentences(schema.decode(ConfigStore.json(root), options: .lenient).issues)
    }

    private static func dotted(_ path: JSONPath) -> String {
        var text = ""
        for component in path {
            switch component {
            case .key(let key): text += text.isEmpty ? key : ".\(key)"
            case .index(let index): text += "[\(index)]"
            }
        }
        return text.isEmpty ? "top level" : text
    }
}

// MARK: - For an editor

extension ConfigFile {
    /// The JSON Schema an editor reads (`lodestar schema`, and the
    /// `lodestar-schema.json` beside the file): Draft-07, which every editor
    /// reads, with every object closed so a typo is underlined whatever the
    /// app does with it, and the header's keys (`$schema`, `version`)
    /// admitted at the top, so the file the app writes is not itself flagged.
    ///
    /// The graph is the one value the schema holds as JSON (`GraphNode` checks
    /// it, with the problems that go with it), so the editor is told its shape:
    /// a block of letters, each an app name or a block of its own, to any
    /// depth. The reference is written the Draft-07 way (`#/definitions/`),
    /// and the definition it names is added to the document below.
    private static let graphShape: JSONObject = [
        "type": ["object", "null"],
        "additionalProperties": ["$ref": "#/definitions/graphNode"],
    ]

    private static let graphNode: JSONValue = [
        "oneOf": [
            ["type": "string", "description": "An app name, or a profile as browser:name (brave:Work)"],
            ["type": "object", "additionalProperties": ["$ref": "#/definitions/graphNode"]],
        ],
    ]

    public static func jsonSchema() -> JSONValue {
        let document = schema.jsonSchema(options: JSONSchemaOptions(
            draft: .draft07, closesObjects: true, extraRootProperties: ConfigStore.header.jsonSchemaProperties))
        let titled = try? document.setting("lodestar configuration", at: JSONPath([.key("title")]))
            .setting(graphNode, at: JSONPath([.key("definitions"), .key("graphNode")]))
        return titled ?? document
    }

    /// `jsonSchema()` as the text written to disk and printed.
    public static func jsonSchemaText() -> String {
        jsonSchema().encodedString(style: .pretty())
    }

    /// Where an address a person types (`web.routes.github.com`) points in
    /// the file, as keys: a free-form key keeps its dots, so that is the
    /// `routes` entry `github.com`. An address the schema does not describe is
    /// read as plain keys, for the problem to say it is not one.
    public static func path(forAddress address: String) -> [String]? {
        schema.path(forAddress: address)?.components.compactMap {
            if case .key(let key) = $0 { key } else { nil }
        }
    }

    /// Every default, as the tree the file is read against: what `lodestar
    /// config` merges the file's deviations over, and what the settings window
    /// resets a row to. A fact only the person can give (`health.born`) has
    /// none.
    public static let defaultTree: [String: ConfigValue] = {
        var ignored: [String] = []
        return Json.tree(of: schema.encode(ConfigFile(), style: .full), problems: &ignored) ?? [:]
    }()
}

extension ConfigFile {
    /// `value` without its `null` members, at every depth of its objects.
    fileprivate static func withoutNulls(_ value: inout JSONValue) {
        guard case .object(let object) = value else { return }
        value = .object(JSONObject(object.compactMap { member in
            guard !member.value.isNull else { return nil }
            var kept = member.value
            withoutNulls(&kept)
            return JSONObject.Member(key: member.key, value: kept)
        }))
    }

    /// The profile registry retired in 0.22: each reference written through
    /// it (a fallback, a route, a link, a calendar, a graph target) is
    /// translated through its table, once, and the registry is dropped.
    ///
    /// Idempotent because the registry is gone after it runs: with nothing to
    /// translate through, it changes nothing.
    fileprivate static func foldProfileRegistry(_ root: inout JSONValue) {
        guard case .object(var object) = root else { return }
        // Registry key (lowercased) → the reference it stood for, with the
        // display name's own casing.
        var table: [String: String] = [:]
        if case .object(let byBrowser)? = object["profiles"] {
            for browser in byBrowser {
                guard case .object(let registry) = browser.value else { continue }
                for entry in registry {
                    guard let display = entry.value.string, !display.isEmpty else { continue }
                    table[entry.key.lowercased()] = "\(browser.key.lowercased()):\(display)"
                }
            }
        }
        object["profiles"] = nil
        defer { root = .object(object) }
        let references = table
        guard !references.isEmpty else { return }

        func rewritten(_ value: String) -> String { references[value.lowercased()] ?? value }
        func mapped(_ value: JSONValue?, _ transform: (JSONValue) -> JSONValue) -> JSONValue? {
            guard case .object(let members)? = value else { return value }
            return .object(JSONObject(members.map { JSONObject.Member(key: $0.key, value: transform($0.value)) }))
        }
        func reference(_ value: JSONValue) -> JSONValue {
            value.string.map { .string(rewritten($0)) } ?? value
        }

        if case .object(var web)? = object["web"] {
            if let fallback = web["fallback"]?.string, fallback != "most-recent" {
                web["fallback"] = .string(rewritten(fallback))
            }
            web["routes"] = mapped(web["routes"], reference)
            web["links"] = mapped(web["links"]) { link in
                guard case .object(var entry) = link, let profile = entry["profile"]?.string else { return link }
                entry["profile"] = .string(rewritten(profile))
                return .object(entry)
            }
            object["web"] = .object(web)
        }
        if case .object(var meetings)? = object["meetings"] {
            meetings["calendars"] = mapped(meetings["calendars"], reference)
            object["meetings"] = .object(meetings)
        }
        // Graph values wrote `browser:key`; the key half goes through the
        // table so `brave:xonar` becomes `brave:Xonar`. A suffix the registry
        // never held is already a name and stays as written.
        func graph(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let raw):
                for browser in ChromiumBrowser.allCases
                where raw.lowercased().hasPrefix("\(browser.rawValue):") {
                    let suffix = String(raw.dropFirst(browser.rawValue.count + 1))
                    guard let found = references[suffix.lowercased()],
                          found.lowercased().hasPrefix("\(browser.rawValue):") else { return value }
                    return .string(found)
                }
                return value
            case .object:
                return mapped(value, graph) ?? value
            default:
                return value
            }
        }
        object["graph"] = mapped(object["graph"], graph)
    }
}

private extension Schema where Value == String {
    /// A string that is one of `cases`, the empty string being a case where
    /// the choice is the app's.
    static func string(oneOf cases: [String]) -> Schema<String> {
        .string(.oneOf(cases.map { JSONValue.string($0) }))
    }
}
