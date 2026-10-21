import CoreGraphics
import Foundation
import StoicJSON

public struct Config {
    public enum Trigger: String, CaseIterable, Sendable {
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
    /// `lode.tap`: a tap of lode arms the next key as a gesture, for one
    /// second, so the thumb need not hold through a key it covers alone.
    /// The hold is unchanged. On by default; a switch because the record
    /// showed what a tap can cost — a short empty press followed by a
    /// letter now becomes a gesture rather than that letter.
    public var lodeTap = true
    /// Reload the config automatically when the file is saved.
    /// Keep Lodestar current: check daily, verify, apply when idle
    /// (installed app only).
    public var autoUpdate = true
    /// Which releases those updates follow: stable, a build that has soaked
    /// on the preview Macs, or preview, every build as it ships.
    public var channel = Updater.Channel.stable
    /// Lodestar's own sounds, together. The alert sound is the Mac's.
    public var sounds = true
    /// Keep the login LaunchAgent installed (installed app only).
    public var startAtLogin = true
    /// Show the status item permanently; false hides it (picking lodestar
    /// in the searcher reveals it for a minute).
    public var showMenuBar = true
    /// How the active display is chosen: pointer | focus.
    public var activeDisplayMode = ActivePolicy.Mode.pointer
    /// "metric" or "imperial": the units a copied measurement is read
    /// into. Empty until chosen, and then the region's.
    public var units = ""
    /// Pixels per j/k/h/l press in scroll mode when smooth is off.
    public var scrollStep: CGFloat = 60
    /// Constant velocity while a direction key is held; instant stop on release.
    public var scrollSmooth = true
    /// Smooth-scroll velocity in pixels per second.
    public var scrollSpeed: CGFloat = 1800
    /// A completed span copies itself the moment its second anchor lands.
    /// The second capital is the grammar's full stop — nothing follows it —
    /// so copying there arbitrates nothing; the config line is the arbiter,
    /// decided once, never at the moment of use. Escape after the first
    /// anchor alone takes that word the same way.
    public var selectCopyOnComplete = false
    /// A select search narrowed to exactly one match picks it without the
    /// capital. The capital there could only confirm — a keystroke with
    /// one legal meaning carries no information, so the grammar stops
    /// charging for it. The word's unfinished tail is absorbed, not
    /// misread: letters that keep arriving extend nothing.
    /// A search narrowed to one match picks it: the doctrine since
    /// 0.27, and no longer a switch — a setting that asks a person to
    /// choose between two reads of the same screen is a fresh decision.
    public var selectCommitOnUnique: Bool { true }
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
    /// Zones a timestamp card also reads into, beside yours and UTC, as
    /// IANA identifiers ("Asia/Tokyo").
    public var clipboardTimeZones: [String] = []
    /// Where an image saved from the strip lands, unless the name typed
    /// says otherwise. `~` is the home folder.
    public var clipboardSaveFolder = "~/Downloads"
    /// `draft.words`: the user's own vocabulary, repaired into speech.
    public var draftWords: [String] = []
    /// `draft.input`: the microphone by name; empty means the system's
    /// default input, whatever it is at the moment of use.
    public var draftInput = ""
    /// `draft.model`: the dictation model's tier, or empty for the one this Mac
    /// suits.
    public var draftModel = ""
    /// The editor: marks mistakes in any field, fixed by `lode ⇥`.
    public var editorEnabled = false
    /// standard | full | apple, or empty for the engine this Mac's memory
    /// suits.
    public var editorModel = ""
    /// The spell checker's language: en_US or en_GB.
    /// Empty: the Mac's own English (EditorRegion.inferred).
    public var editorLanguage = ""
    /// Apps whose fields the editor never reads, by name, lowercased.
    public var editorSkipApps: Set<String> = []
    /// Watch how you reach things, locally, to make suggestions later. Off
    /// means nothing is recorded and no file is written.
    /// The logbook's bound and the health record's warning point, in
    /// bytes: `observations.logbook-mb` and `observations.health-mb`.
    public var logbookBytes = Retention.behavioralBytes
    public var healthBytes = Retention.healthBytes
    public var logbookEnabled = true
    /// The health record: per-press timing (hand, finger, hold, never the
    /// key), pointer motion, and the pulses and windows folded from them.
    /// Its own switch and its own log, independent of
    /// `logbookEnabled`: it watches all typing and clicking, and
    /// turning either record off leaves the other standing.
    public var observationsHealth = true
    /// `health.born`: the year, or nil when not given. Age is the first
    /// thing any reading of the hands is adjusted for.
    public var healthBorn: Int?
    /// `health.hand`: left, right, either, or empty when not given. Fine
    /// motor signs are often one-sided, and the record keeps the hands
    /// apart.
    public var healthHand = ""
    /// `health.keyboards`: per keyboard, the keys that sit somewhere other
    /// than the standard convention puts them — a split board's thumb
    /// clusters. Only the finger column reads it; the hand column is the
    /// windows' class and never moves.
    public var fingerMap = FingerMap()
    /// `health.exact-keyboards`: charge each press to the keyboard whose
    /// HID report matches it. Off by default; needs Input Monitoring.
    public var healthExactKeyboards = false
    public var coachEnabled = true
    /// The walk: a cue at a stopping point after `standAfterMinutes` of
    /// unbroken work.
    public var standEnabled = true
    public var standAfterMinutes = 30
    /// The chain guide fades as a subtree is learned: the map waits for
    /// recall before it appears. The coach's doctrine, not a switch.
    public var guideFade: Bool { true }
    /// Keycode → key-name overlays on the built-in ANSI table.
    public var keyOverrides: [Int64: String] = [:]
    public var graph: GraphNode = GraphNode()

    /// All-defaults, and inert: `build` overwrites every field from the
    /// `ConfigFile`, so this exists to make the type constructible, not to
    /// decide anything. `ConfigFile` is where a default is chosen.
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

    /// Every config write funnels here: the tree is read as a `ConfigFile`
    /// (strictly), and the store writes it sparse against the defaults, stamps
    /// the schema pointer and the writing release and lays it out
    /// canonically — every writer, the same bytes.
    /// `to:` exists so tests can exercise the write path without touching
    /// the config of whoever is running them; every caller uses the default.
    ///
    /// A file that exists and does not parse is never written over here: it
    /// throws `EditError.unparsed`, as `edit` does. (The one way to replace
    /// such a file is `reset`, which keeps the person's bytes first.)
    ///
    /// Runs on the calling thread and waits up to 2 s for another process's
    /// lock; see `edit`.
    public static func write(tree: [String: ConfigValue], to target: URL = Config.file) throws {
        try edit(in: target) { _ in tree }
        // An update that changes nothing writes nothing, and a first launch
        // with all defaults is exactly that: the file is still owed.
        try ConfigStore.materialize(at: target)
    }

    /// Why an edit could not happen. Every case means the same thing to a
    /// caller: the file on disk is the user's and must not be replaced.
    public enum EditError: Error, CustomStringConvertible {
        case unreadable(String)
        case unparsed(String)
        /// The edit would make the file say what the schema refuses; nothing
        /// was written. The detail is the problems, as `check` words them.
        case invalid(String)
        /// Another process (the app, the CLI) held the config's lock for
        /// the whole wait.
        case busy(String)
        /// The file was fine and the write failed (disk full, read-only
        /// volume): nothing changed.
        case storage(String)

        public var description: String {
            switch self {
            case .unreadable(let name): return "could not read \(name)"
            case .unparsed(let detail): return "the config does not parse — \(detail)"
            case .invalid(let detail): return "that would make the config invalid — \(detail)"
            case .busy(let detail): return "the config is being written by another process — \(detail)"
            case .storage(let detail): return "could not write the config — \(detail)"
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
    /// It is now Stoic's: `blockingUpdate` on the process's one store for the
    /// file. An absent file is not a failure — that is a genuine first
    /// write, and it starts from an empty tree.
    ///
    /// The read and the write are one step under a lock on a sidecar file
    /// (`lodestar.json.lock`) that the CLI and the app both take, and that
    /// every earlier build took the same way, so old and new builds keep each
    /// other out. Without it `lodestar config set` and a settings toggle
    /// could each read the old tree, each change one key, and the second to
    /// write silently undid the first. The wait is bounded (`lockTimeout`,
    /// 2 s): a holder that never lets go is reported, not waited on forever,
    /// and the lock dies with its process.
    ///
    /// **It blocks the calling thread while it waits**, for as long as the
    /// other writer holds the lock (one small write) and never longer than
    /// `lockTimeout`; that is what the main thread's callers have always
    /// done. Nothing on a path that can run for long should call it there.
    ///
    /// `transform` runs under the lock, on the calling thread, on the tree
    /// the file holds *now*: sparse, as the schema reads it (`hyper` is `lode`,
    /// a value equal to its default is not there). What it returns is read
    /// strictly, and refused (`EditError.invalid`, nothing written) if the
    /// schema would not accept it. What the file holds that the schema does not
    /// declare, and what it could not read, is not in the tree and is not lost:
    /// the store puts it back. An edit that changes nothing writes nothing.
    ///
    /// `source` names who is writing, for the history (`ConfigHistoryRecorder`):
    /// "Settings", "Lodestar", "The coach"; nothing is recorded for an edit
    /// that changes nothing, and a writer that does not say is "Lodestar".
    @discardableResult
    public static func edit(
        in target: URL = Config.file,
        lockTimeout: TimeInterval = 2,
        source: String? = nil,
        _ transform: ([String: ConfigValue]) throws -> [String: ConfigValue]
    ) throws -> [String: ConfigValue] {
        let name = target.lastPathComponent
        let store: ConfigStore.Store
        do {
            store = try ConfigStore.store(at: target)
        } catch {
            throw EditError.unreadable(name)
        }
        var result: [String: ConfigValue] = [:]
        do {
            // `source` rides on the change the store announces (and only for
            // an update that changes the value), which is how the history
            // knows who wrote it.
            try store.blockingUpdate(waitingUpTo: .seconds(lockTimeout), source: source ?? "Lodestar") { value in
                let updated = try transform(ConfigStore.tree(of: value))
                value = try ConfigStore.file(from: updated)
                result = updated
            }
        } catch let error as ConfigStore.Store.UpdateError {
            if case .durabilityUnknown(let failure) = error {
                // The new value is in the file and published; only a power
                // loss could bring the old one back. Said, not thrown, as it
                // was when the write was Stoic's `DurableFile`.
                Log.error("config: written, but not known to be durable", ["error": "\(failure)"])
                return result
            }
            throw ConfigStore.editError(error, file: name, waited: lockTimeout)
        } catch {
            // The transform threw: nothing was written.
            throw error
        }
        return result
    }

    /// The tree the file holds now, read through the store: nil when the
    /// file exists and cannot be used, and an empty tree when there is none.
    /// What `config get/set/unset` start from; they refuse to write on nil.
    public static func userTree(from source: URL = Config.file) -> [String: ConfigValue]? {
        guard let store = try? ConfigStore.store(at: source) else { return nil }
        try? store.reload()
        guard store.fileProblem == nil else { return nil }
        return ConfigStore.tree(of: store.value)
    }

    /// Load the config, or a fresh minimal file on a genuine first run.
    ///
    /// The branch is on the file *existing*, never on it reading cleanly: a
    /// file that exists is never written over here — it becomes a problem the
    /// human can see, and defaults are used in memory only (or, in a running
    /// app, the last good config, which is what the store keeps and the
    /// problem says). `check` and `diagnose` reach this path, so getting it
    /// wrong once meant the diagnostic destroyed the evidence.
    ///
    /// Reads the file on the calling thread (a re-read of a few kilobytes,
    /// which finds nothing to do when it is as the store last saw it), and
    /// creates it on a first run.
    public static func load(from source: URL = Config.file) -> (Config, [String]) {
        let loaded = loadSnapshot(from: source)
        return (loaded.config, loaded.problems)
    }

    /// `load`, with the store's value and problem the config was built from,
    /// taken together so that the caller knows exactly what it applied (the
    /// app's reload remembers it: see `ConfigApplyLedger`).
    ///
    /// - Parameter reload: Whether to re-read the file first. The app's own
    ///   reload passes false when it knows the store is current (the app wrote
    ///   it, the watcher reloaded it, or `reload()` ran just before on another
    ///   thread): then nothing on the calling thread touches the file.
    public static func loadSnapshot(from source: URL = Config.file, reload: Bool = true)
        -> (config: Config, problems: [String], snapshot: ConfigStore.Snapshot?) {
        var problems: [String] = []
        let name = source.lastPathComponent
        let store: ConfigStore.Store
        do {
            store = try ConfigStore.store(at: source)
        } catch {
            problems.append("config could not be opened (\(error)); using defaults — \(name) left untouched")
            return (build(from: [:], problems: &problems), problems, nil)
        }
        if reload, !FileManager.default.fileExists(atPath: source.path) {
            do {
                if try ConfigStore.materialize(at: source) { Log.info("config: wrote default \(source.path)") }
            } catch {
                Log.error("config: could not write the default file", ["error": "\(error)"])
            }
        }
        if reload { try? store.reload() }
        // The problem first, then the value: whatever lands between the two
        // reads makes the pair older than the store, never newer, so the app
        // can only apply once too often, never miss an arrival.
        let problem = store.fileProblem
        let value = store.value
        let issues = store.issues
        if let problem {
            problems.append(ConfigStore.sentence(for: problem, file: name,
                                                 keepingLastGood: store.source == .file))
        }
        problems.append(contentsOf: ConfigStore.repeatedKeys(in: issues, file: name))
        problems.append(contentsOf: ConfigFile.sentences(issues))
        return (build(from: value, problems: &problems), problems,
                ConfigStore.Snapshot(value: value, problem: problem))
    }

    /// Build a Config from a parsed tree, read as the schema reads a file:
    /// leniently, its problems (what the store would have reported) added to
    /// `problems`. The way a file's text that is not the config's own (a
    /// preview's, a test's) becomes a `Config`.
    public static func build(from root: [String: ConfigValue], problems: inout [String]) -> Config {
        var root = root
        root.removeValue(forKey: "$schema")
        root.removeValue(forKey: "version")
        let decoded = ConfigStore.schema.decode(ConfigStore.json(root), options: .lenient)
        problems.append(contentsOf: ConfigFile.sentences(decoded.issues))
        return build(from: decoded.value ?? ConfigFile(), problems: &problems)
    }

    /// Build a Config from the file's value: the one place every option in the
    /// file becomes behavior. What the schema decides (what is allowed, the
    /// ranges, the defaults) is already decided; what is left is what only the
    /// running app can say (a profile reference that must be one, a link that
    /// needs its url, a browser that must not be us) and the shapes `Config`
    /// holds (lowercased sets, canonical references, the graph).
    public static func build(from file: ConfigFile, problems: inout [String]) -> Config {
        var config = Config()
        config.sounds = file.app.sounds
        config.autoUpdate = file.app.autoUpdate
        config.channel = file.app.channel
        config.startAtLogin = file.app.startAtLogin
        config.showMenuBar = file.app.showMenuBar
        config.units = file.app.units
        config.activeDisplayMode = file.app.activeDisplay
        config.trigger = file.lode.trigger
        config.lodeTap = file.lode.tap
        config.scrollStep = CGFloat(file.scroll.step)
        config.scrollSmooth = file.scroll.smooth
        config.scrollSpeed = CGFloat(file.scroll.speed)
        config.selectCopyOnComplete = file.select.copyOnComplete
        config.clipboardEnabled = file.clipboard.enabled
        config.clipboardMaxBytes = file.clipboard.maxSizeMB * 1_000_000
        config.clipboardExcludedApps = Set(file.clipboard.excludeApps.filter(\.value).keys.map { $0.lowercased() })
        let folder = file.clipboard.saveTo.trimmingCharacters(in: .whitespaces)
        if !folder.isEmpty { config.clipboardSaveFolder = folder }
        config.clipboardExcludePatterns = file.clipboard.exclude.filter(\.value).keys.sorted()
        config.clipboardTimeZones = file.clipboard.timeZones
            .filter { $0.value && TimeZone(identifier: $0.key) != nil }.keys.sorted()
        config.draftWords = file.draft.words.filter(\.value).keys.sorted()
        config.draftInput = file.draft.input.trimmingCharacters(in: .whitespaces)
        config.draftModel = file.draft.model
        config.editorEnabled = file.editor.enabled
        config.editorModel = file.editor.model
        config.editorLanguage = file.editor.language
        config.editorSkipApps = Set(file.editor.skipApps.filter(\.value).keys.map { $0.lowercased() })
        config.disabledGestures = file.gestures.disabledKeys

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

        if file.web.fallback.lowercased() == "most-recent" {
            config.webFallback = "most-recent"
        } else if let key = profileReference(file.web.fallback, at: "web.fallback") {
            config.webFallback = key
        }
        config.webSearchURL = file.web.searchURL
        for (name, link) in file.web.links.sorted(by: { $0.key < $1.key }) {
            guard !link.url.isEmpty else {
                problems.append("web.links.\(name) needs a url")
                continue
            }
            let profileKey = link.profile.flatMap { profileReference($0, at: "web.links.\(name).profile") }
            config.webLinks.append(WebLink(name: name.lowercased(), url: link.url, profileKey: profileKey))
        }
        for (code, name) in file.keys {
            guard let keycode = Int64(code) else {
                problems.append("keys.\(code): keycodes are numbers")
                continue
            }
            guard Keys.isValidName(name) else {
                problems.append("keys.\(code): unknown key name '\(name)'")
                continue
            }
            config.keyOverrides[keycode] = name
        }
        config.meetingsEnabled = file.meetings.enabled
        config.meetingsLeadMinutes = file.meetings.leadMinutes
        for (name, profile) in file.meetings.calendars {
            if let key = profileReference(profile, at: "meetings.calendars.\(name)") {
                config.meetingsCalendars[name] = key
            }
        }
        for (pattern, profile) in file.web.routes {
            if let key = profileReference(profile, at: "web.routes.\(pattern)") {
                config.webRoutes[pattern.lowercased()] = key
            }
        }
        config.logbookBytes = Int64(file.observations.logbookMB) << 20
        config.healthBytes = Int64(file.observations.healthMB) << 20
        config.logbookEnabled = file.observations.logbook
        config.observationsHealth = file.observations.health
        config.healthExactKeyboards = file.health.exactKeyboards
        config.coachEnabled = file.coach.enabled
        config.standEnabled = file.coach.stand
        config.standAfterMinutes = file.coach.standAfter
        if let born = file.health.born {
            let digits = born.trimmingCharacters(in: .whitespaces)
            if digits.count == 4, let year = Int(digits), (1900...2100).contains(year) {
                config.healthBorn = year
            }
        }
        config.healthHand = file.health.hand ?? ""
        for (id, keys) in file.health.keyboards {
            for (name, placed) in keys {
                guard let key = Keys.SpecialKey(rawValue: name) else {
                    let known = Keys.SpecialKey.allCases.map(\.rawValue).joined(separator: ", ")
                    problems.append("health.keyboards.\(id).\(name): unknown key — one of \(known)")
                    continue
                }
                guard let placement = FingerMap.Placement(parsing: placed) else {
                    problems.append("health.keyboards.\(id).\(name): a side and a finger, like 'right thumb'")
                    continue
                }
                config.fingerMap.keyboards[id, default: [:]][key] = placement
            }
        }
        config.webHandleClicks = file.web.clicks.enabled
        config.webClickBrowser = file.web.clicks.browser
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

        // The graph is the file's own JSON, checked here: its problems are the
        // graph's (a list, a value that is neither an app nor a block).
        let graph = JSONValue.object(JSONObject([JSONObject.Member(key: "graph", value: file.graph)]))
        if file.graph.object == nil {
            problems.append("graph should be a block of letters, each an app name or a block of its own")
        } else if let graphTable = Json.tree(of: graph, problems: &problems)?["graph"]?.table {
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
