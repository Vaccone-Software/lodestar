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
    static let file = directory.appendingPathComponent("lodestar.yaml")
    static let legacyTomlFile = directory.appendingPathComponent("lodestar.toml")

    /// Top-level chain letters the primitives own; the graph may not use them.
    static let reservedTopLevel: Set<String> = ["o", "z", "x"]

    /// The schema: one table driving reload validation and the JSON Schema
    /// editors read. Keep in lockstep with `parse` below.
    static let schema: SchemaNode = .table([
        "version": .string(allowed: nil, description: "The Lodestar release this config was written for."),
        "hyper": .table([
            "trigger": .string(allowed: ["right-command", "raw-hyper"],
                               description: "The physical trigger for every gesture."),
        ], description: "The hyper key."),
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
        "graph": .graph(description: "hyper + letter chains → apps. Values: app name or <browser>:<registry key>."),
    ], description: "lodestar configuration")

    static let defaultYaml = """
    # yaml-language-server: $schema=lodestar-schema.json
    # Lodestar. Edit anything, then menu bar > Reload Config.
    # Lodestar only writes to this file when you add or remove graph
    # entries with ⌘K in the searcher. Everything else is yours.
    # version is the Lodestar release that wrote this file.
    version: "\(Lodestar.version)"

    hyper:
      # The trigger for every gesture.
      # right-command: the right ⌘ key. Also accepts a hyper shim's
      # ⌘⌃⌥ output; configure shims to exclude shift.
      # raw-hyper: the literal ⌘⌃⌥⇧ chord.
      trigger: right-command

    gestures:
      # Every gesture, one switch each. false frees its keys: they pass
      # through to the app. Also fixed: esc clears a chain, holding
      # hyper peeks the graph, ⇧ on any summon opens beside.
      searcher: true          # hyper space
      graph: true             # hyper letter chains
      window-chooser: true    # hyper tab
      web-bar: true           # hyper ⏎
      menu-search: true       # hyper .
      scroll: true            # hyper ,
      hints: true             # hyper ; (⇧; sticky)
      claim: true             # hyper = (⇧= beside)
      marks: true             # hyper `
      breaths: true           # hyper '
      sweep: true             # hyper 0
      index-jump: true        # hyper 1…9 (⇧ slides)
      flip-orientation: true  # hyper O
      layout-undo: true       # hyper Z (⇧Z redo)
      back-forward: true      # hyper X (⇧X forward)
      display-move: true      # hyper [ ] (⇧ beside)
      cheat-sheet: true       # hyper ?

    app:
      # Reload when this file is saved.
      auto-reload: false
      # Keep Lodestar current: check daily, verify the download,
      # apply quietly when nothing is in flight.
      auto-update: true
      # Keep the login LaunchAgent installed (installed app only).
      start-at-login: true
      # Show the menu bar star. When false, pick "lodestar" in the
      # searcher to reveal it for a minute.
      show-menu-bar: true
      # Summon windows opened outside Lodestar full screen. When false
      # they float untouched.
      adopt-new-windows: false
      # Which display summons land on: pointer or focus.
      active-display: pointer

    profiles:
      # Chromium profile registry: lodestar name to the browser's
      # profile name, used as <browser>:<name> in the graph and
      # profile: <name> in web links. Browsers: brave, chrome, edge;
      # keys are global across them. For example:
      #   brave:
      #     personal: Personal
      #     work: Work
      brave:

    # The graph: hyper plus a letter chain opens an app.
    # One letter for the apps you live in:
    #   g: Ghostty
    # Nest letters to group (hyper E O, hyper E P):
    #   e:
    #     o: Microsoft Outlook
    #     p: Proton Mail
    # Values are an app name as spelled in Applications (list them with
    # `lodestar apps`) or <browser>:<name> from profiles, like
    # brave:personal or chrome:work. The first letters
    # o, x, and z are reserved.
    # ⌘K on any searcher row edits this section for you.
    graph:

    web:
      # hyper ⏎ opens the web bar: quick links, domains, or a search.
      # Where an unrouted destination opens: most-recent (the profile
      # of your last focused Chromium window) or a profiles key.
      fallback: most-recent
      # Search template; %s becomes the query.
      search-url: https://search.brave.com/search?q=%s
      # Typed name to site, optionally pinned to a profile. For example:
      #   yt:
      #     url: youtube.com
      #     profile: personal
      links:
      # Substring pattern to profile; longest match wins. For example:
      #   youtube: personal
      routes:

    scroll:
      # hyper , scrolls: j/k down/up, h/l left/right, d/u half page,
      # gg top, ⇧G bottom, tab cycles panes, esc closes.
      # Hold a key for constant velocity; false steps once per press.
      smooth: true
      # Velocity in pixels per second (200 to 4000).
      speed: 1800
      # Pixels per press when smooth is false (10 to 400).
      step: 60

    hints:
      # hyper ; labels everything clickable: type a label to press it,
      # ⇧label to right click. hyper ⇧; relabels after every click.
      # The label alphabet; capacity is its length squared.
      letters: asdfghjkl
      # Seconds between a sticky click and the relabel.
      rescan-delay: 0.4

    double-tap:
      # Double tap a modifier alone to fire a verb. Modifiers: cmd
      # shift option control, or sided forms like right-cmd. Verbs:
      # searcher web menu scroll hints sticky-hints sweep cheat.
      # cmd: scroll

    keys:
      # Keycode to key name overrides for non-ANSI layouts, e.g. 10: s
    """

    /// Load the config, writing the default file first if none exists.
    static func load() -> (Config, [String]) {
        var problems: [String] = []
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: legacyTomlFile.path) {
            try? FileManager.default.removeItem(at: legacyTomlFile)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            try? defaultYaml.write(to: file, atomically: true, encoding: .utf8)
            Log.info("config: wrote default \(file.path)")
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            problems.append("could not read \(file.path); using built-in defaults")
            return (parse(defaultYaml, problems: &problems), problems)
        }
        return (parse(text, problems: &problems), problems)
    }

    private static func parse(_ text: String, problems: inout [String]) -> Config {
        var config = Config()
        let root: [String: ConfigValue]
        do {
            root = try Yaml.parse(text)
        } catch {
            problems.append("config parse failed (\(error)); using defaults")
            root = (try? Yaml.parse(defaultYaml)) ?? [:]
        }

        problems.append(contentsOf: ConfigSchema.validate(root, against: schema))

        if let autoReload = Yaml.value(at: ["app", "auto-reload"], in: root)?.bool {
            config.autoReload = autoReload
        }
        if let autoUpdate = Yaml.value(at: ["app", "auto-update"], in: root)?.bool {
            config.autoUpdate = autoUpdate
        }
        if let startAtLogin = Yaml.value(at: ["app", "start-at-login"], in: root)?.bool {
            config.startAtLogin = startAtLogin
        }
        if let showMenuBar = Yaml.value(at: ["app", "show-menu-bar"], in: root)?.bool {
            config.showMenuBar = showMenuBar
        }
        if let adopt = Yaml.value(at: ["app", "adopt-new-windows"], in: root)?.bool {
            config.adoptNewWindows = adopt
        }
        if let active = Yaml.value(at: ["app", "active-display"], in: root)?.string {
            if let mode = ActivePolicy.Mode(rawValue: active) {
                config.activeDisplayMode = mode
            } else {
                problems.append("unknown app.active-display '\(active)' — using pointer")
            }
        }
        if let raw = Yaml.value(at: ["hyper", "trigger"], in: root)?.string {
            if let trigger = Trigger(rawValue: raw) {
                config.trigger = trigger
            } else {
                problems.append("unknown hyper.trigger '\(raw)' — using right-command")
            }
        }
        if let step = Yaml.value(at: ["scroll", "step"], in: root)?.double {
            config.scrollStep = CGFloat(max(10, min(400, step)))
        }
        if let smooth = Yaml.value(at: ["scroll", "smooth"], in: root)?.bool {
            config.scrollSmooth = smooth
        }
        if let speed = Yaml.value(at: ["scroll", "speed"], in: root)?.double {
            config.scrollSpeed = CGFloat(max(200, min(4000, speed)))
        }
        if let letters = Yaml.value(at: ["hints", "letters"], in: root)?.string {
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
        if let delay = Yaml.value(at: ["hints", "rescan-delay"], in: root)?.double {
            config.hintRescanDelay = max(0.1, min(2.0, delay))
        }
        if let gestures = Yaml.value(at: ["gestures"], in: root)?.table {
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
            guard let registry = Yaml.value(at: ["profiles", browser.rawValue], in: root)?.table else {
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

        if let fallback = Yaml.value(at: ["web", "fallback"], in: root)?.string {
            let lowered = fallback.lowercased()
            if lowered == "most-recent" || config.browserProfiles[lowered] != nil {
                config.webFallback = lowered
            } else {
                problems.append("web.fallback '\(fallback)' is neither most-recent nor a profiles key")
            }
        }
        if let searchURL = Yaml.value(at: ["web", "search-url"], in: root)?.string {
            config.webSearchURL = searchURL
        }
        if let links = Yaml.value(at: ["web", "links"], in: root)?.table {
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
        if let keys = Yaml.value(at: ["keys"], in: root)?.table {
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
        if let routes = Yaml.value(at: ["web", "routes"], in: root)?.table {
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

        if let graphTable = Yaml.value(at: ["graph"], in: root)?.table {
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
