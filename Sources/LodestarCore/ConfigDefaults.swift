import Foundation

/// Every option's default, as the tree the sparse file is diffed against.
/// This is the source of every default that reaches the running app: Config
/// builds itself from the user's deviations merged over this tree, pruning
/// writes back against it, and `config get` reads the merge.
///
/// Config's own stored-property initializers repeat some of these values,
/// but they are inert — `Config.build` reads through the merge, so every
/// binding fires and this table always wins. Add an option here whenever
/// you add one to `Config.schema`, or the field silently keeps whatever
/// its declaration said and the config file can never change it.
public enum ConfigDefaults {
    /// Parse-time adapter: pre-0.9.11 configs named the lode key "hyper".
    /// The old name reads as the new; the next write emits "lode".
    public static func normalized(_ root: [String: ConfigValue]) -> [String: ConfigValue] {
        var out = root
        // hyper became lode, and the searcher became the launcher. Both are the
        // same switch under a new word, so a file written before the rename
        // keeps working rather than reporting an unknown key.
        if out["lode"] == nil, let legacy = out["hyper"] {
            out.removeValue(forKey: "hyper")
            out["lode"] = legacy
        }
        if case .table(var gestures)? = out["gestures"],
           let searcher = gestures.removeValue(forKey: "searcher") {
            if gestures["launcher"] == nil { gestures["launcher"] = searcher }
            out["gestures"] = .table(gestures)
        }
        // The attention timeline was retired in 0.17. Every config written
        // before then carries its switch, and a verb that no longer exists
        // must not make an otherwise-valid file report an unknown key.
        if case .table(var gestures)? = out["gestures"],
           gestures.removeValue(forKey: "back-forward") != nil {
            out["gestures"] = .table(gestures)
        }
        // Menu search became the commands bar: the same switch under the
        // register's new name, ahead of system commands joining as a
        // second feed.
        if case .table(var gestures)? = out["gestures"],
           let legacy = gestures.removeValue(forKey: "menu-search") {
            if gestures["commands"] == nil { gestures["commands"] = legacy }
            out["gestures"] = .table(gestures)
        }
        // The cheat sheet stopped being a toggle in 0.22: help is not a
        // feature you turn off. Select took its key's toggle instead.
        if case .table(var gestures)? = out["gestures"],
           gestures.removeValue(forKey: "cheat-sheet") != nil {
            out["gestures"] = .table(gestures)
        }
        // Retired in 0.22: the name nothing read, the double-tap grammar,
        // hand-set hint letters (the layout is detected now), and the
        // auto-reload toggle (watching is simply how the config works).
        // The old hyper trigger folds into the default, which has always
        // accepted the ⌘⌃⌥ chord a shim produces.
        out.removeValue(forKey: "you")
        if case .table(var web)? = out["web"],
           case .table(var clicks)? = web["clicks"],
           clicks.removeValue(forKey: "trace") != nil {
            web["clicks"] = .table(clicks)
            out["web"] = .table(web)
        }
        out.removeValue(forKey: "double-tap")
        // The whole hints section is retired: letters became layout
        // detection, and rescan-delay stopped being a knob — a delay
        // someone reaches for is a delay to tune once, for everyone.
        out.removeValue(forKey: "hints")
        if case .table(var app)? = out["app"],
           app.removeValue(forKey: "auto-reload") != nil {
            out["app"] = .table(app)
        }
        if case .table(var lode)? = out["lode"],
           lode["trigger"]?.string == "raw-hyper" {
            lode["trigger"] = .string("right-command")
            out["lode"] = .table(lode)
        }
        out = withoutProfileRegistry(out)
        return out
    }

    /// The profile registry retired in 0.22: a reference names its browser
    /// and profile directly (`brave:Work`), validated against what the
    /// browser actually has. Every reference written through the old
    /// registry is translated through its table one last time, and the
    /// section itself is dropped.
    private static func withoutProfileRegistry(_ root: [String: ConfigValue]) -> [String: ConfigValue] {
        var out = root
        // Registry key (lowercased) → the reference it stood for, with the
        // display name's own casing.
        var references: [String: String] = [:]
        if case .table(let byBrowser)? = out["profiles"] {
            for (browser, entries) in byBrowser {
                guard case .table(let registry) = entries else { continue }
                for (key, value) in registry {
                    guard let display = value.string, !display.isEmpty else { continue }
                    references[key.lowercased()] = "\(browser.lowercased()):\(display)"
                }
            }
        }
        out.removeValue(forKey: "profiles")

        func rewritten(_ value: String) -> String {
            references[value.lowercased()] ?? value
        }

        if case .table(var web)? = out["web"] {
            if let fallback = web["fallback"]?.string, fallback != "most-recent" {
                web["fallback"] = .string(rewritten(fallback))
            }
            if case .table(var routes)? = web["routes"] {
                for (pattern, value) in routes {
                    guard let profile = value.string else { continue }
                    routes[pattern] = .string(rewritten(profile))
                }
                web["routes"] = .table(routes)
            }
            if case .table(var links)? = web["links"] {
                for (name, value) in links {
                    guard case .table(var link) = value,
                          let profile = link["profile"]?.string else { continue }
                    link["profile"] = .string(rewritten(profile))
                    links[name] = .table(link)
                }
                web["links"] = .table(links)
            }
            out["web"] = .table(web)
        }
        if case .table(var meetings)? = out["meetings"],
           case .table(var calendars)? = meetings["calendars"] {
            for (name, value) in calendars {
                guard let profile = value.string else { continue }
                calendars[name] = .string(rewritten(profile))
            }
            meetings["calendars"] = .table(calendars)
            out["meetings"] = .table(meetings)
        }
        // Graph values wrote `browser:key`; the key half goes through the
        // table so `brave:xonar` becomes `brave:Xonar`. A suffix the
        // registry never held is already a name and stays as written.
        func rewriteGraph(_ value: ConfigValue) -> ConfigValue {
            switch value {
            case .string(let raw):
                for browser in ChromiumBrowser.allCases
                where raw.lowercased().hasPrefix("\(browser.rawValue):") {
                    let suffix = String(raw.dropFirst(browser.rawValue.count + 1))
                    guard let reference = references[suffix.lowercased()],
                          reference.lowercased().hasPrefix("\(browser.rawValue):") else { return value }
                    return .string(reference)
                }
                return value
            case .table(let children):
                return .table(children.mapValues(rewriteGraph))
            default:
                return value
            }
        }
        if case .table(let graph)? = out["graph"] {
            out["graph"] = .table(graph.mapValues(rewriteGraph))
        }
        return out
    }

    public static let tree: [String: ConfigValue] = [
        "lode": .table([
            "trigger": .string("right-command"),
        ]),
        "gestures": .table(
            Dictionary(uniqueKeysWithValues: Gestures.roster.map { ($0.name, ConfigValue.bool(true)) })
        ),
        "app": .table([
            "auto-update": .bool(true),
            "start-at-login": .bool(true),
            "show-menu-bar": .bool(true),
            "active-display": .string("pointer"),
        ]),
        "graph": .table([:]),
        "web": .table([
            "fallback": .string("most-recent"),
            "search-url": .string("https://search.brave.com/search?q=%s"),
            "links": .table([:]),
            "routes": .table([:]),
            "clicks": .table([
                "enabled": .bool(false),
                "browser": .string(""),
            ]),
        ]),
        "scroll": .table([
            "smooth": .bool(true),
            "speed": .int(1800),
            "step": .int(60),
        ]),
        "select": .table([
            "copy-on-complete": .bool(false),
        ]),
        "draft": .table([
            "input": .string(""),
            "words": .table([:]),
        ]),
        "clipboard": .table([
            "enabled": .bool(true),
            "max-size-mb": .int(500),
            "exclude-apps": .table([:]),
            "exclude": .table([:]),
        ]),
        "observations": .table([
            "enabled": .bool(true),
            "health": .bool(true),
        ]),
        "guide": .table([
            "fade": .bool(true),
        ]),
        "meetings": .table([
            "enabled": .bool(false),
            "lead-minutes": .int(5),
            "calendars": .table([:]),
        ]),
        "coach": .table([
            "enabled": .bool(true),
        ]),
        "keys": .table([:]),
    ]
}
