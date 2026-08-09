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
    /// Fixed verbs turned off — their keys pass through to the app.
    var disabledGestures: Set<String> = []
    /// Profile registry: lodestar key → Brave display name. Chromium only.
    var braveProfiles: [String: String] = [:]
    /// Where an unrouted site opens: "most-recent" or a registry key.
    var webFallback = "most-recent"
    /// Search template; %s is replaced with the encoded query (appended if absent).
    var webSearchURL = "https://www.google.com/search?q=%s"
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
        "version": .number(min: 1, max: 999, description: "Config format version; older formats are read automatically."),
        "hyper": .table([
            "trigger": .string(allowed: ["right-command", "raw-hyper"],
                               description: "The physical trigger for every gesture."),
        ], description: "The hyper key."),
        "app": .table([
            "auto-reload": .boolean(description: "Reload automatically when the config file is saved."),
            "start-at-login": .boolean(description: "Keep the login LaunchAgent installed (installed app only)."),
            "show-menu-bar": .boolean(description: "Show the status item permanently; false hides it until lodestar is picked in the searcher."),
            "disabled-gestures": .string(allowed: nil, description: "Space-separated fixed-verb keys to turn off (e.g. \"o x [\"); disabled keys pass through to the app."),
            "adopt-new-windows": .boolean(description: "Adopt windows opened outside Lodestar, summoning them full screen; off by default so external windows float untouched."),
            "active-display": .string(allowed: ["pointer", "focus"], description: "How the active display is chosen."),
        ], description: "App behavior."),
        "profiles": .table([
            "brave": .freeTable(value: .string(allowed: nil, description: "The browser's profile display name."),
                                description: "lodestar name → Brave profile display name. Chromium only."),
        ], description: "Browser profile registry."),
        "web": .table([
            "fallback": .string(allowed: nil, description: "most-recent, or a profiles.brave key."),
            "search-url": .string(allowed: nil, description: "Search template; %s becomes the encoded query."),
            "links": .freeTable(value: .table([
                "url": .string(allowed: nil, description: "The site."),
                "profile": .string(allowed: nil, description: "A profiles.brave key (omit to route)."),
            ], description: "A quick link."), description: "Named quick links."),
            "routes": .freeTable(value: .string(allowed: nil, description: "A profiles.brave key."),
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
        "graph": .graph(description: "hyper + letter chains → apps. Values: app name or brave:<registry key>."),
    ], description: "lodestar configuration")

    static let defaultYaml = """
    # yaml-language-server: $schema=lodestar-schema.json
    # Config format version — Lodestar reads older formats automatically
    # and never rewrites this file itself.
    version: \(Lodestar.configVersion)
    # ═══ Lodestar ═══════════════════════════════════════════════════════
    # Keyboard-driven navigation: destination over process.
    # Every option Lodestar understands is listed below with its default —
    # edit anything, then menu bar → Reload Config.
    #
    # The fixed gestures (not configurable):
    #   hyper space      searcher               hyper tab    window chooser
    #   hyper ⏎          web bar                hyper .      menu search
    #   hyper <letters>  graph chains           hyper ,      scroll mode
    #   hyper ;          click hints (⇧; sticky)   double-tap: see below
    #   hyper =          claim the focused window (⇧= beside)
    #   hyper `          marks                  hyper '      breaths
    #   hyper 0          sweep background       hyper O      flip orientation
    #   hyper Z / ⇧Z     undo / redo layout     hyper ?      cheat sheet
    #   hold hyper       peek the graph         hyper 1…9    index jump
    #   hyper [ / ]      move window to prev/next display (⇧ = beside)
    #   ⇧ on a summon    beside (equal split)   esc          clear a chain
    #
    #   hyper X / ⇧X     back / forward — walk the attention timeline
    #   hyper ⇧1…9       slide the focused window to that position
    # Reserved first letters (unusable in the graph): O X Z.

    hyper:
      # The physical trigger for every gesture.
      #   right-command — the right ⌘ key. Also accepts a hyper shim's ⌘⌃⌥
      #                   output; configure any shim to EXCLUDE shift.
      #   raw-hyper     — the literal ⌘⌃⌥⇧ chord.
      # default: right-command
      trigger: right-command

    app:
      # Reload automatically whenever this file is saved.
      # default: false
      auto-reload: false
      # Keep the login LaunchAgent installed so Lodestar survives reboots.
      # Only the installed app (~/Applications/lodestar.app) manages this.
      # default: true
      start-at-login: true
      # Show the menu bar star permanently. When false, picking "lodestar"
      # in the searcher reveals it (menu open) for 60 seconds.
      # default: true
      show-menu-bar: true
      # Windows opened outside Lodestar (a launcher, the Dock, ⌘N, a
      # certificate prompt, a file reveal …) float untouched by default —
      # they never hide what you were reading. Set true to adopt them:
      # summoned full screen on the active display, the rest parked, and
      # closing an adopted window restores what it displaced.
      # default: false
      adopt-new-windows: false
      # Turn off fixed verbs you never use — space-separated keys from:
      # space return tab o z x 0 , . ; ` ' [ ] /
      # A disabled key passes through to the focused app (⇧ variants too).
      # default: (none)
      # disabled-gestures: "o ["
      # Which monitor is "here" — where summons land and panels appear.
      #   pointer — the display under the mouse pointer
      #   focus   — the display of the focused window
      # default: pointer
      active-display: pointer

    profiles:
      # Browser profile registry: lodestar name → the browser's own profile
      # name. Referenced everywhere else as brave:<name> (graph) or
      # profile: <name> (web). Validated at load against the browser's real
      # profile list. CHROMIUM ONLY for now — the browser key namespaces
      # future engines (firefox:, safari: …).
      brave:
        personal: Personal
        work: Work

    web:
      # hyper ⏎ — the web bar. Quick links resolve to their profile; bare
      # domains route by the rules below; anything else is a web search.
      #
      # Where an unrouted destination opens:
      #   most-recent — the profile of your most recently focused Brave window
      #   <name>      — a registry key from profiles.brave
      # default: most-recent
      fallback: most-recent
      # Search template; %s becomes the encoded query (appended if absent).
      # default: https://www.google.com/search?q=%s
      search-url: https://www.google.com/search?q=%s
      # Quick links: typed name → site, pinned to a profile (omit profile
      # to use routes/fallback).
      links:
        yt:
          url: youtube.com
          profile: personal
      # Routing rules for typed domains and link URLs: substring pattern →
      # registry key, longest match wins.
      routes:
        youtube: personal
        yourcompany: work

    scroll:
      # hyper , enters scroll mode: j/k down/up · h/l left/right ·
      # d/u half-page · gg top / ⇧G bottom · tab cycles panes · esc closes.
      #
      # smooth — hold a direction key for constant-velocity scrolling that
      # stops the instant you release; off = one step per key repeat.
      # default: true
      smooth: true
      # Smooth velocity, pixels per second. Range 200–4000.
      # default: 1800
      speed: 1800
      # Pixels per j/k/h/l press when smooth is off. Range 10–400.
      # default: 60
      step: 60

    double-tap:
      # Double-tap a modifier key ALONE (no chord, no keystroke between)
      # to fire a verb — additional custom triggers; every default stays.
      # Modifiers: cmd shift option control, or sided: left-cmd right-cmd
      # left-shift right-shift left-option right-option left-control
      # right-control. Verbs: searcher web menu scroll hints sticky-hints
      # sweep cheat.
      # default: (none)
      # cmd: scroll

    hints:
      # hyper ; labels every pressable element of the focused window —
      # type a label to press it, ⇧label to right-click it, esc closes.
      # hyper ⇧; is sticky: each click relabels after a beat (chain clicks).
      #
      # The label alphabet. Labels use only these letters — home row by
      # default; add more for busier windows (capacity is length²).
      # default: asdfghjkl
      letters: asdfghjkl
      # Sticky hints: seconds between a click and the relabel.
      # default: 0.4
      rescan-delay: 0.4

    keys:
      # Keycode → key-name overrides for non-ANSI keyboard layouts. The
      # built-in table assumes ANSI; overlay any keycode here, e.g.:
      #   10: s
      # Names: a–z, 0–9, space, tab, return, delete, escape, and the
      # punctuation Lodestar binds (` ' , . / ; [ ]).

    # ── The graph ──────────────────────────────────────────────────────
    # hyper + letter chain -> app. A letter with a value is a leaf; a
    # letter opening an indented block subdivides (hyper E O -> Outlook).
    # Values: an app name as it appears in Applications (list them
    # with `lodestar apps`), or brave:<profile> from the registry above.

    graph:
      s: Slack
      f: Finder
      m: Messages
      t: Terminal
      e:                           # email — hyper E M
        m: Mail
      eo: Microsoft Outlook        # multi-letter sugar: hyper E O
      w:                           # web — browser profiles
        p: brave:personal
        w: brave:work
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

        // Profiles first — the graph and web sections reference them.
        if let registry = Yaml.value(at: ["profiles", "brave"], in: root)?.table {
            for (key, value) in registry {
                if let display = value.string, !display.isEmpty {
                    config.braveProfiles[key.lowercased()] = display
                } else {
                    problems.append("profiles.brave.\(key) must be a profile name string")
                }
            }
        }

        if let fallback = Yaml.value(at: ["web", "fallback"], in: root)?.string {
            let lowered = fallback.lowercased()
            if lowered == "most-recent" || config.braveProfiles[lowered] != nil {
                config.webFallback = lowered
            } else {
                problems.append("web.fallback '\(fallback)' is neither most-recent nor a profiles.brave key")
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
                    if config.braveProfiles[lowered] != nil {
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
                if config.braveProfiles[lowered] != nil {
                    config.webRoutes[pattern.lowercased()] = lowered
                } else {
                    problems.append("web.routes.\(pattern) references unknown profile '\(profile)'")
                }
            }
        }

        if let graphTable = Yaml.value(at: ["graph"], in: root)?.table {
            config.graph = GraphNode.build(from: graphTable, path: "",
                                           registry: config.braveProfiles, problems: &problems)
            for key in config.graph.children.keys where reservedTopLevel.contains(key) {
                problems.append("graph uses reserved first letter '\(key)' — ignored")
                config.graph.children.removeValue(forKey: key)
            }
        }
        return config
    }
}
