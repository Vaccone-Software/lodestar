import CoreGraphics
import Foundation

public struct Config {
    public enum Trigger: String {
        case rightCommand = "right-command"
        case leftCommand = "left-command"
    }

    public struct WebLink {
        public let name: String
        public let url: String
        /// The pinned profile's canonical reference (`brave:xonar`), or nil
        /// for a link that resolves through the rules each time it opens.
        public let profileKey: String?

        public init(name: String, url: String, profileKey: String?) {
            self.name = name
            self.url = url
            self.profileKey = profileKey
        }
    }

    public var trigger: Trigger = .rightCommand
    /// Reload the config automatically when the file is saved.
    /// Keep Lodestar current: check daily, verify, apply when idle
    /// (installed app only).
    public var autoUpdate = true
    /// Keep the login LaunchAgent installed (installed app only).
    public var startAtLogin = true
    /// Show the status item permanently; false hides it (picking lodestar
    /// in the searcher reveals it for a minute).
    public var showMenuBar = true
    /// How the active display is chosen: pointer | focus.
    public var activeDisplayMode = ActivePolicy.Mode.pointer
    /// Pixels per j/k/h/l press in scroll mode when smooth is off.
    public var scrollStep: CGFloat = 60
    /// Constant velocity while a direction key is held; instant stop on release.
    public var scrollSmooth = true
    /// Smooth-scroll velocity in pixels per second.
    public var scrollSpeed: CGFloat = 1800
    /// A completed span copies itself the moment its second anchor lands.
    /// The second capital is the grammar's full stop — nothing follows it —
    /// so copying there arbitrates nothing; the config line is the arbiter,
    /// decided once, never at the moment of use.
    public var selectCopyOnComplete = false
    /// A select search narrowed to exactly one match picks it without the
    /// capital. The capital there could only confirm — a keystroke with
    /// one legal meaning carries no information, so the grammar stops
    /// charging for it. The word's unfinished tail is absorbed, not
    /// misread: letters that keep arriving extend nothing.
    public var selectCommitOnUnique = true
    /// Double-tap modifier bindings: modifier → verb. Custom triggers only.
    /// Keys freed by gestures: toggles — they pass through to the app.
    public var disabledGestures: Set<String> = []
    /// Every profile the config references, keyed by canonical reference
    /// (`brave:xonar`). Built from the references themselves as they
    /// parse — there is no registry to declare one in — and the shell
    /// merges in what the browsers actually have, so pickers can offer
    /// profiles nothing references yet.
    public var browserProfiles: [String: BrowserProfile] = [:]

    /// Meetings at the door. Off until asked for: the calendar permission
    /// has no gesture to hang a lazy prompt on, so intent is a config line
    /// and the subsystem reconciles.
    public var meetingsEnabled = false
    public var meetingsLeadMinutes = 5
    /// Calendar or account name → canonical profile reference. Outranks
    /// the domain route for meeting joins: the calendar is the only
    /// signal that can tell two meetings on the same host apart.
    public var meetingsCalendars: [String: String] = [:]
    /// Where an unrouted site opens: "most-recent" or a canonical
    /// profile reference.
    public var webFallback = "most-recent"
    /// Search template; %s is replaced with the encoded query (appended if absent).
    public var webSearchURL = "https://search.brave.com/search?q=%s"
    public var webLinks: [WebLink] = []
    /// Substring pattern → canonical profile reference; longest match wins.
    public var webRoutes: [String: String] = [:]
    /// Whether Lodestar is standing as the http handler and routing clicked
    /// links. Not a switch you are meant to find and flip: the menu-bar flow
    /// records it after macOS confirms the change. Setting it false while
    /// still registered makes Lodestar a transparent pass-through, which is
    /// the off switch that works from a text file.
    public var webHandleClicks = false
    /// The browser clicked links go to when no rule diverts them: the bundle
    /// id of whatever was your default before Lodestar took over. Recorded
    /// *before* the switch, because afterwards the answer is gone.
    public var webClickBrowser = ""
    /// Clipboard history: how much disk it may claim, and what it must
    /// never record.
    public var clipboardEnabled = true
    public var clipboardMaxBytes = 500_000_000
    public var clipboardExcludedApps: Set<String> = []
    public var clipboardExcludePatterns: [String] = []
    /// `draft.words`: the user's own vocabulary, repaired into speech.
    public var draftWords: [String] = []
    /// `draft.input`: the microphone by name; empty means the system's
    /// default input, whatever it is at the moment of use.
    public var draftInput = ""
    /// Watch how you reach things, locally, to make suggestions later. Off
    /// means nothing is recorded and no file is written.
    public var observationsEnabled = true
    /// The health pulse: input counts and rhythm moments over all typing
    /// and clicking, never key identities. Its own switch because it
    /// watches more than Lodestar's gestures.
    public var observationsHealth = true
    public var coachEnabled = true
    /// The chain guide fades as a subtree is learned: the map waits for
    /// recall before it appears. False paints it immediately, always.
    public var guideFade = true
    /// Keycode → key-name overlays on the built-in ANSI table.
    public var keyOverrides: [Int64: String] = [:]
    public var graph: GraphNode = GraphNode()

    /// All-defaults, and inert: `build` overwrites every field from the
    /// merge, so this exists to make the type constructible, not to decide
    /// anything. `ConfigDefaults.tree` is where a default is chosen.
    public init() {}

    /// Merge in the profiles the machine actually has, so pickers and
    /// most-recent resolution can see profiles nothing references yet.
    /// Detection overwrites a reference's casing — the browser's own
    /// spelling is ground truth for what a label shows.
    public mutating func registerDetected(_ profiles: [BrowserProfile]) {
        for profile in profiles {
            browserProfiles[profile.canonical] = profile
        }
    }

    public static let directory = Paths.config
    /// The config: sparse canonical JSON — only what differs from
    /// defaults, documentation living in the schema, every writer
    /// producing the same bytes.
    public static let file = directory.appendingPathComponent("lodestar.json")

    /// Top-level chain letters the primitives own; the graph may not use
    /// them. Defined once in `Gestures` so a key move cannot leave a stale
    /// copy here — which is exactly what happened twice.
    public static let reservedTopLevel: Set<String> = Gestures.reservedLetters

    /// The schema: one table driving reload validation and the JSON Schema
    /// editors read. Keep in lockstep with `parse` below.
    public static let schema: SchemaNode = .table([
        "$schema": .string(allowed: nil, description: "Editor affordance — points at the emitted lodestar-schema.json so LSP-aware editors validate and complete."),
        "version": .string(allowed: nil, description: "The Lodestar release this config was written for."),
        "lode": .table([
            "trigger": .string(allowed: ["right-command", "left-command"],
                               description: "The physical trigger for every gesture."),
        ], description: "The lode key."),
        "app": .table([
            "auto-update": .boolean(description: "Keep Lodestar current: check daily, verify the download, apply quietly when idle (installed app only)."),
            "start-at-login": .boolean(description: "Keep the login LaunchAgent installed (installed app only)."),
            "show-menu-bar": .boolean(description: "Show the status item permanently; false hides it until lodestar is picked in the launcher."),
            "active-display": .string(allowed: ["pointer", "focus"], description: "How the active display is chosen."),
        ], description: "App behavior."),
        "gestures": .table(
            Dictionary(uniqueKeysWithValues: Gestures.roster.map {
                ($0.name, SchemaNode.boolean(description: $0.about))
            }),
            description: "Every gesture, one switch each; false frees its keys to the app."),
        "web": .table([
            "fallback": .string(allowed: nil, description: "most-recent, or a profile as browser:name (brave:Work)."),
            "search-url": .string(allowed: nil, description: "Search template; %s becomes the encoded query."),
            "links": .freeTable(value: .table([
                "url": .string(allowed: nil, description: "The site."),
                "profile": .string(allowed: nil, description: "A profile as browser:name (omit to route)."),
            ], description: "A named link."), description: "Named links."),
            "routes": .freeTable(value: .string(allowed: nil, description: "A profile as browser:name (brave:Work)."),
                                 description: "Substring pattern → profile; longest match wins."),
            "clicks": .table([
                "enabled": .boolean(description: "Route links clicked in other apps. Set by the menu-bar flow."),
                "browser": .string(allowed: nil, description: "Bundle id links go to when no route matches (your previous default browser)."),
            ], description: "Links clicked in other apps."),
        ], description: "The web bar."),
        "scroll": .table([
            "smooth": .boolean(description: "Constant velocity while held; instant stop on release."),
            "speed": .number(min: 200, max: 4000, description: "Smooth velocity, pixels per second."),
            "step": .number(min: 10, max: 400, description: "Pixels per press when smooth is off."),
        ], description: "Scroll mode."),
        "select": .table([
            "copy-on-complete": .boolean(description: "Copy a completed span to the clipboard the moment its second anchor lands."),
            "commit-on-unique": .boolean(description: "A search narrowed to one match picks it without the capital."),
        ], description: "Select mode."),
        "meetings": .table([
            "enabled": .boolean(description: "Offer the calendar's next meeting as a chip."),
            "lead-minutes": .number(min: 0, max: 120,
                                    description: "Minutes before the start the chip appears."),
            "calendars": .freeTable(value: .string(allowed: nil,
                                                   description: "The browser:name profile this calendar's meetings join in."),
                                    description: "Calendar or account name → profile. Outranks web.routes for meetings."),
        ], description: "Meetings at the door."),
        "draft": .table([
            "input": .string(allowed: nil, description: "The microphone the draft listens to, by its name in Sound settings. Empty follows the system default input."),
            "words": .freeTable(value: .boolean(description: "true to keep this word in the draft's vocabulary."),
                                description: "Word → true. Names and terms speech gets wrong; a settled result within a letter or two of one is repaired to it, case and all."),
        ], description: "The draft: lode . speaks, lode ⇧. edits."),
        "clipboard": .table([
            "enabled": .boolean(description: "⇧⌘V opens the clipboard strip. The one Lodestar binding outside the lode key, so it is also the one that can collide with an app; false gives ⇧⌘V back."),
            "max-size-mb": .number(min: 10, max: 20_000, description: "Disk the clipboard history may claim; the oldest clips are dropped to stay under it. Pins are never dropped."),
            "exclude-apps": .freeTable(value: .boolean(description: "true to never record clips copied from this app."),
                                       description: "Bundle id → true. Nothing copied in these apps is ever written to disk."),
            "exclude": .freeTable(value: .boolean(description: "true to never record clips containing this text."),
                                  description: "Substring → true, matched case-insensitively against the clip. The same shape web.routes uses."),
        ], description: "Clipboard history."),
        "observations": .table([
            "enabled": .boolean(description: "Watch how you reach things, on this machine only, to suggest improvements later."),
            "health": .boolean(description: "Also keep the hands' pulse: input counts, typing rhythm moments, active minutes. Counts only, never which keys or what was typed."),
        ], description: "Local observations. How you got places, never what you were doing there; nothing leaves the machine."),
        "guide": .table([
            "fade": .boolean(description: "The chain guide waits longer to appear as a subtree is learned, so recall gets its chance first. False paints it immediately."),
        ], description: "The chain guide."),
        "coach": .table([
            "enabled": .boolean(description: "Let Lodestar offer one improvement at a time, in quiet moments, priced in seconds."),
        ], description: "The coach: rare, evidence-backed suggestions drawn from the observations."),
        "keys": .freeTable(value: .string(allowed: nil, description: "The key name this keycode produces."),
                           description: "Keycode → key-name overrides for non-ANSI layouts."),
        "graph": .graph(description: "lode + letter chains → apps. Values: app name or <browser>:<profile name>."),
    ], description: "lodestar configuration")

    /// Every config write funnels here: the tree is pruned sparse against
    /// the defaults, stamped with the schema pointer and the writing
    /// release, and emitted canonically — every writer, the same bytes.
    /// `to:` exists so tests can exercise the write path without touching
    /// the config of whoever is running them; every caller uses the default.
    public static func write(tree: [String: ConfigValue], to target: URL = Config.file) throws {
        var clean = ConfigDefaults.normalized(tree)
        clean.removeValue(forKey: "$schema")
        clean.removeValue(forKey: "version")
        var out = Json.pruned(clean, defaults: ConfigDefaults.tree)
        out["$schema"] = .string("lodestar-schema.json")
        out["version"] = .string(Lodestar.version)
        try Json.emit(out).write(to: target, atomically: true, encoding: .utf8)
    }

    /// Why an edit could not happen. Both cases mean the same thing to a
    /// caller: the file on disk is the user's and must not be replaced.
    public enum EditError: Error, CustomStringConvertible {
        case unreadable(String)
        case unparsed(String)

        public var description: String {
            switch self {
            case .unreadable(let name): return "could not read \(name)"
            case .unparsed(let detail): return "the config does not parse — \(detail)"
            }
        }
    }

    /// The one read-modify-write over the config file.
    ///
    /// Every writer used to open with its own read, and they disagreed:
    /// two of the four collapsed a parse failure to an empty tree, so one
    /// hand-edit typo plus one menu-bar toggle replaced the whole config —
    /// graph, profiles, links, routes, key overrides — with the single key
    /// being set. Nothing was backed up and nothing was said. The rule is
    /// simple enough to have exactly one implementation: a file that
    /// exists and does not parse is never written over.
    ///
    /// An absent file is not a failure — that is a genuine first write,
    /// and it starts from an empty tree.
    @discardableResult
    public static func edit(
        in target: URL = Config.file,
        _ transform: ([String: ConfigValue]) throws -> [String: ConfigValue]
    ) throws -> [String: ConfigValue] {
        var tree: [String: ConfigValue] = [:]
        if FileManager.default.fileExists(atPath: target.path) {
            guard let text = try? String(contentsOf: target, encoding: .utf8) else {
                throw EditError.unreadable(target.lastPathComponent)
            }
            do {
                tree = try Json.parse(text)
            } catch {
                throw EditError.unparsed("\(error)")
            }
        }
        let updated = try transform(tree)
        try write(tree: updated, to: target)
        return updated
    }

    /// Load the config, or a fresh minimal file on a genuine first run.
    ///
    /// The branch is on the file *existing*, never on it reading cleanly.
    /// `String(contentsOf:encoding:)` returns nil both for "no such file"
    /// and for "exists but is not valid UTF-8", and treating those alike
    /// once meant an undecodable byte cost the user their whole config:
    /// the default write landed on top of it, and `check` and `diagnose`
    /// reached the same path, so the diagnostic destroyed the evidence.
    /// A file that exists is never written over here — it becomes a
    /// problem the human can see, and defaults are used in memory only.
    public static func load(from source: URL = Config.file) -> (Config, [String]) {
        var problems: [String] = []
        try? FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var root: [String: ConfigValue] = [:]
        if FileManager.default.fileExists(atPath: source.path) {
            do {
                guard let text = try? String(contentsOf: source, encoding: .utf8) else {
                    throw Json.ParseError(message: "\(source.lastPathComponent) is not valid UTF-8")
                }
                root = try Json.parse(text, problems: &problems)
            } catch {
                problems.append("config parse failed (\(error)); using defaults — "
                                + "\(source.lastPathComponent) left untouched")
            }
        } else {
            try? write(tree: [:], to: source)
            Log.info("config: wrote default \(source.path)")
        }
        return (build(from: root, problems: &problems), problems)
    }

    /// Build a Config from a parsed tree: the user's deviations are
    /// validated as written, then read merged over ConfigDefaults.tree —
    /// the single home of every default value.
    public static func build(from root: [String: ConfigValue], problems: inout [String]) -> Config {
        var config = Config()
        let root = ConfigDefaults.normalized(root)
        problems.append(contentsOf: ConfigSchema.validate(root, against: schema))
        let effective = Json.merged(defaults: ConfigDefaults.tree, overlay: root)

        if let autoUpdate = effective.value(at: ["app", "auto-update"])?.bool {
            config.autoUpdate = autoUpdate
        }
        if let startAtLogin = effective.value(at: ["app", "start-at-login"])?.bool {
            config.startAtLogin = startAtLogin
        }
        if let showMenuBar = effective.value(at: ["app", "show-menu-bar"])?.bool {
            config.showMenuBar = showMenuBar
        }
        if let active = effective.value(at: ["app", "active-display"])?.string {
            if let mode = ActivePolicy.Mode(rawValue: active) {
                config.activeDisplayMode = mode
            } else {
                problems.append("unknown app.active-display '\(active)' — using pointer")
            }
        }
        if let raw = effective.value(at: ["lode", "trigger"])?.string {
            if let trigger = Trigger(rawValue: raw) {
                config.trigger = trigger
            } else {
                problems.append("unknown lode.trigger '\(raw)' — using right-command")
            }
        }
        if let step = effective.value(at: ["scroll", "step"])?.double {
            config.scrollStep = CGFloat(max(10, min(400, step)))
        }
        if let smooth = effective.value(at: ["scroll", "smooth"])?.bool {
            config.scrollSmooth = smooth
        }
        if let speed = effective.value(at: ["scroll", "speed"])?.double {
            config.scrollSpeed = CGFloat(max(200, min(4000, speed)))
        }
        if let copy = effective.value(at: ["select", "copy-on-complete"])?.bool {
            config.selectCopyOnComplete = copy
        }
        if let commit = effective.value(at: ["select", "commit-on-unique"])?.bool {
            config.selectCommitOnUnique = commit
        }
        if let enabled = effective.value(at: ["clipboard", "enabled"])?.bool {
            config.clipboardEnabled = enabled
        }
        if let megabytes = effective.value(at: ["clipboard", "max-size-mb"])?.double {
            config.clipboardMaxBytes = Int(max(10, min(20_000, megabytes)) * 1_000_000)
        }
        if let apps = effective.value(at: ["clipboard", "exclude-apps"])?.table {
            config.clipboardExcludedApps = Set(apps.filter { $0.value.bool == true }.keys.map { $0.lowercased() })
        }
        if let patterns = effective.value(at: ["clipboard", "exclude"])?.table {
            config.clipboardExcludePatterns = patterns.filter { $0.value.bool == true }.keys.sorted()
        }
        if let words = effective.value(at: ["draft", "words"])?.table {
            config.draftWords = words.filter { $0.value.bool == true }.keys.sorted()
        }
        if let input = effective.value(at: ["draft", "input"])?.string {
            config.draftInput = input.trimmingCharacters(in: .whitespaces)
        }
        if let gestures = effective.value(at: ["gestures"])?.table {
            // Unknown names and non-boolean values are the schema walk's
            // to report; here false just frees the verb's keys.
            var toggles: [String: Bool] = [:]
            for (name, value) in gestures {
                if let enabled = value.bool { toggles[name] = enabled }
            }
            config.disabledGestures = Gestures.disabledKeys(from: toggles)
        }

        /// A reference as written (`brave:Xonar`) becomes its canonical
        /// key, and the profile it names joins `browserProfiles` — the
        /// reference carries everything, so parsing is the whole of
        /// resolution. Whether the browser actually has the profile is
        /// the doctor's question, asked against ground truth.
        func profileReference(_ raw: String, at path: String) -> String? {
            guard let profile = BrowserProfile.parse(reference: raw) else {
                problems.append("\(path) '\(raw)' is not browser:name — write it like brave:Work")
                return nil
            }
            let key = profile.canonical
            if config.browserProfiles[key] == nil {
                config.browserProfiles[key] = profile
            }
            return key
        }

        if let fallback = effective.value(at: ["web", "fallback"])?.string {
            if fallback.lowercased() == "most-recent" {
                config.webFallback = "most-recent"
            } else if let key = profileReference(fallback, at: "web.fallback") {
                config.webFallback = key
            }
        }
        if let searchURL = effective.value(at: ["web", "search-url"])?.string {
            config.webSearchURL = searchURL
        }
        if let links = effective.value(at: ["web", "links"])?.table {
            for (name, value) in links.sorted(by: { $0.key < $1.key }) {
                guard let table = value.table, let url = table["url"]?.string, !url.isEmpty else {
                    problems.append("web.links.\(name) needs a url")
                    continue
                }
                var profileKey: String?
                if let profile = table["profile"]?.string {
                    profileKey = profileReference(profile, at: "web.links.\(name).profile")
                }
                config.webLinks.append(WebLink(name: name.lowercased(), url: url, profileKey: profileKey))
            }
        }
        if let keys = effective.value(at: ["keys"])?.table {
            for (code, value) in keys {
                guard let keycode = Int64(code) else {
                    problems.append("keys.\(code): keycodes are numbers")
                    continue
                }
                guard let name = value.string, Keys.isValidName(name) else {
                    problems.append("keys.\(code): unknown key name '\(value.string ?? "?")'")
                    continue
                }
                config.keyOverrides[keycode] = name
            }
        }
        if let enabled = effective.value(at: ["meetings", "enabled"])?.bool {
            config.meetingsEnabled = enabled
        }
        if let lead = effective.value(at: ["meetings", "lead-minutes"])?.double {
            config.meetingsLeadMinutes = Int(max(0, min(120, lead)))
        }
        if let calendars = effective.value(at: ["meetings", "calendars"])?.table {
            for (name, value) in calendars {
                guard let profile = value.string else { continue }
                if let key = profileReference(profile, at: "meetings.calendars.\(name)") {
                    config.meetingsCalendars[name] = key
                }
            }
        }
        if let routes = effective.value(at: ["web", "routes"])?.table {
            for (pattern, value) in routes {
                guard let profile = value.string else { continue }
                if let key = profileReference(profile, at: "web.routes.\(pattern)") {
                    config.webRoutes[pattern.lowercased()] = key
                }
            }
        }
        if let enabled = effective.value(at: ["observations", "enabled"])?.bool {
            config.observationsEnabled = enabled
        }
        if let enabled = effective.value(at: ["observations", "health"])?.bool {
            config.observationsHealth = enabled
        }
        if let enabled = effective.value(at: ["coach", "enabled"])?.bool {
            config.coachEnabled = enabled
        }
        if let fade = effective.value(at: ["guide", "fade"])?.bool {
            config.guideFade = fade
        }
        if let enabled = effective.value(at: ["web", "clicks", "enabled"])?.bool {
            config.webHandleClicks = enabled
        }
        if let browser = effective.value(at: ["web", "clicks", "browser"])?.string {
            config.webClickBrowser = browser
        }
        // Naming ourselves is the one answer that cannot be obeyed: macOS
        // hands us the link because we hold the http role, so handing it back
        // to ourselves is a closed circuit that re-activates Lodestar every
        // lap until the process is quit. Dropped to "nothing recorded" — a
        // state the click path already survives by discovery, then Safari —
        // and reported, so the file gets fixed by you rather than silently
        // rewritten by us. Reported whether or not clicks are enabled: a
        // Lodestar standing down still receives the link.
        if config.webClickBrowser == Lodestar.bundleID {
            config.webClickBrowser = ""
            problems.append("web.clicks.browser names Lodestar itself — a clicked link would be handed straight back to us, forever; set it to your browser")
        } else if config.webHandleClicks, config.webClickBrowser.isEmpty {
            // Standing as the handler with nowhere to hand a link back to
            // would strand every link that matches no rule. Say so at reload
            // rather than at the moment a link vanishes.
            problems.append("web.clicks.enabled is on but web.clicks.browser is empty — unrouted links have nowhere to go")
        }

        if let graphTable = effective.value(at: ["graph"])?.table {
            config.graph = GraphNode.build(from: graphTable, path: "", problems: &problems)
            for key in config.graph.children.keys where reservedTopLevel.contains(key) {
                problems.append("graph uses reserved first letter '\(key)' — ignored")
                config.graph.children.removeValue(forKey: key)
            }
            // The graph's profile targets join the referenced set like
            // every other reference.
            for (_, target) in config.graph.leaves() {
                if case .browserProfile(let profile) = target,
                   config.browserProfiles[profile.canonical] == nil {
                    config.browserProfiles[profile.canonical] = profile
                }
            }
        }
        return config
    }
}
