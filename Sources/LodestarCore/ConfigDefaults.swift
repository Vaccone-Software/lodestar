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
            "auto-reload": .bool(false),
            "auto-update": .bool(true),
            "start-at-login": .bool(true),
            "show-menu-bar": .bool(true),
            "active-display": .string("pointer"),
        ]),
        "profiles": .table([:]),
        "graph": .table([:]),
        "web": .table([
            "fallback": .string("most-recent"),
            "search-url": .string("https://search.brave.com/search?q=%s"),
            "links": .table([:]),
            "routes": .table([:]),
            "clicks": .table([
                "enabled": .bool(false),
                "browser": .string(""),
                "trace": .bool(false),
            ]),
        ]),
        "scroll": .table([
            "smooth": .bool(true),
            "speed": .int(1800),
            "step": .int(60),
        ]),
        "clipboard": .table([
            "enabled": .bool(true),
            "max-size-mb": .int(500),
            "exclude-apps": .table([:]),
            "exclude": .table([:]),
        ]),
        "you": .table([
            "name": .string(""),
        ]),
        "observations": .table([
            "enabled": .bool(true),
        ]),
        "coach": .table([
            "enabled": .bool(true),
        ]),
        "hints": .table([
            "letters": .string("asdfghjkl"),
            "rescan-delay": .double(0.4),
        ]),
        "double-tap": .table([:]),
        "keys": .table([:]),
    ]
}
