import CoreGraphics
import Foundation
import LodestarCore

struct Config {
    enum Trigger: String {
        case rightCommand = "right-command"
        case rawHyper = "raw-hyper"
    }

    struct WebLink {
        let name: String
        let url: String
        let profileKey: String?
    }

    var trigger: Trigger = .rightCommand
    /// Reload the config automatically when the file is saved.
    var autoReload = false
    /// Keep Lodestar current: check daily, verify, apply when idle
    /// (installed app only).
    var autoUpdate = true
    /// Keep the login LaunchAgent installed (installed app only).
    var startAtLogin = true
    /// Show the status item permanently; false hides it (picking lodestar
    /// in the searcher reveals it for a minute).
    var showMenuBar = true
    /// Adopt windows born outside Lodestar, summoning them full screen on
    /// the active display. Off by default: a window another tool opened
    /// (a certificate prompt, a file reveal) floats untouched, and never
    /// hides what you were reading.
    var adoptNewWindows = false
    /// How the active display is chosen: pointer | focus.
    var activeDisplayMode = ActivePolicy.Mode.pointer
    /// Pixels per j/k/h/l press in scroll mode when smooth is off.
    var scrollStep: CGFloat = 60
    /// Constant velocity while a direction key is held; instant stop on release.
    var scrollSmooth = true
    /// Smooth-scroll velocity in pixels per second.
    var scrollSpeed: CGFloat = 1800
    /// The hint label alphabet — the letters labels are built from.
    var hintLetters = "asdfghjkl"
    /// Sticky hints: seconds between a click and the relabel.
    var hintRescanDelay: TimeInterval = 0.4
    /// Double-tap modifier bindings: modifier → verb. Custom triggers only.
    var doubleTaps: [ModifierKey: TapVerb] = [:]
    /// Keys freed by gestures: toggles — they pass through to the app.
    var disabledGestures: Set<String> = []
    /// Profile registry: lodestar key → (browser, display name). Keys are
    /// global across browsers so web links and routes reference them bare.
    var browserProfiles: [String: BrowserProfile] = [:]
    /// Where an unrouted site opens: "most-recent" or a registry key.
    var webFallback = "most-recent"
    /// Search template; %s is replaced with the encoded query (appended if absent).
    var webSearchURL = "https://search.brave.com/search?q=%s"
    var webLinks: [WebLink] = []
    /// Substring pattern → registry key; longest match wins.
    var webRoutes: [String: String] = [:]
    /// Keycode → key-name overlays on the built-in ANSI table.
    var keyOverrides: [Int64: String] = [:]
    var graph: GraphNode = GraphNode()

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lodestar", isDirectory: true)
    /// The config: sparse canonical JSON — only what differs from
    /// defaults, documentation living in the schema, every writer
    /// producing the same bytes.
    static let file = directory.appendingPathComponent("lodestar.json")
    /// The pre-0.9.10 format, read-only: the migration source, kept on
    /// disk through the rollback window so an auto-updated install that
    /// rolls back still finds its config. Retired at 1.0.
    static let yamlFile = directory.appendingPathComponent("lodestar.yaml")
    static let legacyTomlFile = directory.appendingPathComponent("lodestar.toml")

    /// Top-level chain letters the primitives own; the graph may not use them.
    static let reservedTopLevel: Set<String> = ["o", "z", "x"]

    /// The schema: one table driving reload validation and the JSON Schema
    /// editors read. Keep in lockstep with `parse` below.
    static let schema: SchemaNode = .table([
        "$schema": .string(allowed: nil, description: "Editor affordance — points at the emitted lodestar-schema.json so LSP-aware editors validate and complete."),
        "version": .string(allowed: nil, description: "The Lodestar release this config was written for."),
        "lode": .table([
            "trigger": .string(allowed: ["right-command", "raw-hyper"],
                               description: "The physical trigger for every gesture."),
        ], description: "The lode key."),
        "app": .table([
            "auto-reload": .boolean(description: "Reload automatically when the config file is saved."),
            "auto-update": .boolean(description: "Keep Lodestar current: check daily, verify the download, apply quietly when idle (installed app only)."),
            "start-at-login": .boolean(description: "Keep the login LaunchAgent installed (installed app only)."),
            "show-menu-bar": .boolean(description: "Show the status item permanently; false hides it until lodestar is picked in the searcher."),
            "adopt-new-windows": .boolean(description: "Adopt windows opened outside Lodestar, summoning them full screen; off by default so external windows float untouched."),
            "active-display": .string(allowed: ["pointer", "focus"], description: "How the active display is chosen."),
        ], description: "App behavior."),
        "gestures": .table(
            Dictionary(uniqueKeysWithValues: Gestures.roster.map {
                ($0.name, SchemaNode.boolean(description: $0.about))
            }),
            description: "Every gesture, one switch each; false frees its keys to the app."),
        "profiles": .table(
            Dictionary(uniqueKeysWithValues: ChromiumBrowser.allCases.map { browser in
                (browser.rawValue,
                 SchemaNode.freeTable(value: .string(allowed: nil, description: "The browser's profile display name."),
                                      description: "lodestar name → \(browser.label) profile display name."))
            }),
            description: "Chromium profile registry; keys are global across browsers."),
        "web": .table([
            "fallback": .string(allowed: nil, description: "most-recent, or a profiles key."),
            "search-url": .string(allowed: nil, description: "Search template; %s becomes the encoded query."),
            "links": .freeTable(value: .table([
                "url": .string(allowed: nil, description: "The site."),
                "profile": .string(allowed: nil, description: "A profiles key (omit to route)."),
            ], description: "A quick link."), description: "Named quick links."),
            "routes": .freeTable(value: .string(allowed: nil, description: "A profiles key."),
                                 description: "Substring pattern → profile; longest match wins."),
        ], description: "The web bar."),
        "scroll": .table([
            "smooth": .boolean(description: "Constant velocity while held; instant stop on release."),
            "speed": .number(min: 200, max: 4000, description: "Smooth velocity, pixels per second."),
            "step": .number(min: 10, max: 400, description: "Pixels per press when smooth is off."),
        ], description: "Scroll mode."),
        "double-tap": .freeTable(value: .string(allowed: TapVerb.allCases.map(\.rawValue),
                                                description: "The verb this double-tap fires."),
                                 description: "Double-tap a modifier alone to fire a verb — additional triggers; defaults untouched. Keys: cmd, shift, option, control, or sided forms like right-cmd."),
        "hints": .table([
            "letters": .string(allowed: nil, description: "The label alphabet, home row by default; labels are built only from these letters."),
            "rescan-delay": .number(min: 0.1, max: 2.0, description: "Sticky hints: seconds between a click and the relabel."),
        ], description: "Click hints."),
        "keys": .freeTable(value: .string(allowed: nil, description: "The key name this keycode produces."),
                           description: "Keycode → key-name overrides for non-ANSI layouts."),
        "graph": .graph(description: "lode + letter chains → apps. Values: app name or <browser>:<registry key>."),
    ], description: "lodestar configuration")

    /// Every config write funnels here: the tree is pruned sparse against
    /// the defaults, stamped with the schema pointer and the writing
    /// release, and emitted canonically — every writer, the same bytes.
    static func write(tree: [String: ConfigValue]) throws {
        var clean = ConfigDefaults.normalized(tree)
        clean.removeValue(forKey: "$schema")
        clean.removeValue(forKey: "version")
        var out = Json.pruned(clean, defaults: ConfigDefaults.tree)
        out["$schema"] = .string("lodestar-schema.json")
        out["version"] = .string(Lodestar.version)
        try Json.emit(out).write(to: file, atomically: true, encoding: .utf8)
    }

    /// The one-way move at app boot: lodestar.yaml → sparse lodestar.json.
    /// The yaml stays on disk untouched — a watchdog-restored 0.9.9 must
    /// still find its config — and a later release retires it. A yaml
    /// that fails to parse is never converted: nothing is written, load()
    /// surfaces the problem, and the human keeps their file.
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: file.path), fm.fileExists(atPath: yamlFile.path) else { return false }
        guard let text = try? String(contentsOf: yamlFile, encoding: .utf8),
              let root = try? Yaml.parse(text) else {
            Log.error("config: lodestar.yaml is unreadable — migration skipped, nothing written")
            return false
        }
        do {
            try write(tree: root)
            Log.info("config: migrated lodestar.yaml → lodestar.json (yaml kept through the rollback window)")
            return true
        } catch {
            Log.error("config: migration write failed (\(error)) — still reading lodestar.yaml")
            return false
        }
    }

    /// Load the config: JSON when it exists, the legacy YAML read-only
    /// otherwise (so `check` before migration sees the same truth the
    /// migration will write), a fresh minimal file when neither does.
    static func load() -> (Config, [String]) {
        var problems: [String] = []
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: legacyTomlFile.path) {
            try? FileManager.default.removeItem(at: legacyTomlFile)
        }
        var root: [String: ConfigValue] = [:]
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            do {
                root = try Json.parse(text)
            } catch {
                problems.append("config parse failed (\(error)); using defaults")
            }
        } else if let text = try? String(contentsOf: yamlFile, encoding: .utf8) {
            do {
                root = try Yaml.parse(text)
            } catch {
                problems.append("config parse failed (\(error)); using defaults")
            }
        } else {
            try? write(tree: [:])
            Log.info("config: wrote default \(file.path)")
        }
        return (build(from: root, problems: &problems), problems)
    }

    /// Build a Config from a parsed tree: the user's deviations are
    /// validated as written, then read merged over ConfigDefaults.tree —
    /// the single home of every default value.
    static func build(from root: [String: ConfigValue], problems: inout [String]) -> Config {
        var config = Config()
        let root = ConfigDefaults.normalized(root)
        problems.append(contentsOf: ConfigSchema.validate(root, against: schema))
        let effective = Json.merged(defaults: ConfigDefaults.tree, overlay: root)

        if let autoReload = Yaml.value(at: ["app", "auto-reload"], in: effective)?.bool {
            config.autoReload = autoReload
        }
        if let autoUpdate = Yaml.value(at: ["app", "auto-update"], in: effective)?.bool {
            config.autoUpdate = autoUpdate
        }
        if let startAtLogin = Yaml.value(at: ["app", "start-at-login"], in: effective)?.bool {
            config.startAtLogin = startAtLogin
        }
        if let showMenuBar = Yaml.value(at: ["app", "show-menu-bar"], in: effective)?.bool {
            config.showMenuBar = showMenuBar
        }
        if let adopt = Yaml.value(at: ["app", "adopt-new-windows"], in: effective)?.bool {
            config.adoptNewWindows = adopt
        }
        if let active = Yaml.value(at: ["app", "active-display"], in: effective)?.string {
            if let mode = ActivePolicy.Mode(rawValue: active) {
                config.activeDisplayMode = mode
            } else {
                problems.append("unknown app.active-display '\(active)' — using pointer")
            }
        }
        if let raw = Yaml.value(at: ["lode", "trigger"], in: effective)?.string {
            if let trigger = Trigger(rawValue: raw) {
                config.trigger = trigger
            } else {
                problems.append("unknown lode.trigger '\(raw)' — using right-command")
            }
        }
        if let step = Yaml.value(at: ["scroll", "step"], in: effective)?.double {
            config.scrollStep = CGFloat(max(10, min(400, step)))
        }
        if let smooth = Yaml.value(at: ["scroll", "smooth"], in: effective)?.bool {
            config.scrollSmooth = smooth
        }
        if let speed = Yaml.value(at: ["scroll", "speed"], in: effective)?.double {
            config.scrollSpeed = CGFloat(max(200, min(4000, speed)))
        }
        if let letters = Yaml.value(at: ["hints", "letters"], in: effective)?.string {
            // Lowercased ASCII letters, first occurrence wins — duplicate
            // letters would mint colliding labels.
            var seen = Set<Character>()
            let cleaned = String(letters.lowercased()
                .filter { $0.isASCII && $0.isLetter && seen.insert($0).inserted })
            if cleaned.count >= 2 {
                config.hintLetters = cleaned
            } else {
                problems.append("hints.letters needs at least two distinct letters — using \(config.hintLetters)")
            }
        }
        if let delay = Yaml.value(at: ["hints", "rescan-delay"], in: effective)?.double {
            config.hintRescanDelay = max(0.1, min(2.0, delay))
        }
        if let gestures = Yaml.value(at: ["gestures"], in: effective)?.table {
            // Unknown names and non-boolean values are the schema walk's
            // to report; here false just frees the verb's keys.
            var toggles: [String: Bool] = [:]
            for (name, value) in gestures {
                if let enabled = value.bool { toggles[name] = enabled }
            }
            config.disabledGestures = Gestures.disabledKeys(from: toggles)
        }

        // Profiles first — the graph and web sections reference them.
        for browser in ChromiumBrowser.allCases {
            guard let registry = Yaml.value(at: ["profiles", browser.rawValue], in: effective)?.table else {
                continue
            }
            for (key, value) in registry.sorted(by: { $0.key < $1.key }) {
                let lowered = key.lowercased()
                guard let display = value.string, !display.isEmpty else {
                    problems.append("profiles.\(browser.rawValue).\(key) must be a profile name string")
                    continue
                }
                if let taken = config.browserProfiles[lowered] {
                    problems.append("profiles.\(browser.rawValue).\(key) collides with profiles.\(taken.browser.rawValue).\(key) — keys are global, keeping the first")
                    continue
                }
                config.browserProfiles[lowered] = BrowserProfile(browser: browser, display: display)
            }
        }

        if let fallback = Yaml.value(at: ["web", "fallback"], in: effective)?.string {
            let lowered = fallback.lowercased()
            if lowered == "most-recent" || config.browserProfiles[lowered] != nil {
                config.webFallback = lowered
            } else {
                problems.append("web.fallback '\(fallback)' is neither most-recent nor a profiles key")
            }
        }
        if let searchURL = Yaml.value(at: ["web", "search-url"], in: effective)?.string {
            config.webSearchURL = searchURL
        }
        if let links = Yaml.value(at: ["web", "links"], in: effective)?.table {
            for (name, value) in links.sorted(by: { $0.key < $1.key }) {
                guard let table = value.table, let url = table["url"]?.string, !url.isEmpty else {
                    problems.append("web.links.\(name) needs a url")
                    continue
                }
                var profileKey: String?
                if let profile = table["profile"]?.string {
                    let lowered = profile.lowercased()
                    if config.browserProfiles[lowered] != nil {
                        profileKey = lowered
                    } else {
                        problems.append("web.links.\(name) references unknown profile '\(profile)'")
                    }
                }
                config.webLinks.append(WebLink(name: name.lowercased(), url: url, profileKey: profileKey))
            }
        }
        if let keys = Yaml.value(at: ["keys"], in: effective)?.table {
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
        if let routes = Yaml.value(at: ["web", "routes"], in: effective)?.table {
            for (pattern, value) in routes {
                guard let profile = value.string else { continue }
                let lowered = profile.lowercased()
                if config.browserProfiles[lowered] != nil {
                    config.webRoutes[pattern.lowercased()] = lowered
                } else {
                    problems.append("web.routes.\(pattern) references unknown profile '\(profile)'")
                }
            }
        }

        if let graphTable = Yaml.value(at: ["graph"], in: effective)?.table {
            config.graph = GraphNode.build(from: graphTable, path: "",
                                           registry: config.browserProfiles, problems: &problems)
            for key in config.graph.children.keys where reservedTopLevel.contains(key) {
                problems.append("graph uses reserved first letter '\(key)' — ignored")
                config.graph.children.removeValue(forKey: key)
            }
        }
        return config
    }
}
