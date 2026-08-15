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
        guard root["lode"] == nil, let legacy = root["hyper"] else { return root }
        var out = root
        out.removeValue(forKey: "hyper")
        out["lode"] = legacy
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
            "adopt-new-windows": .bool(false),
            "active-display": .string("pointer"),
        ]),
        "profiles": .table([:]),
        "graph": .table([:]),
        "web": .table([
            "fallback": .string("most-recent"),
            "search-url": .string("https://search.brave.com/search?q=%s"),
            "links": .table([:]),
            "routes": .table([:]),
        ]),
        "scroll": .table([
            "smooth": .bool(true),
            "speed": .int(1800),
            "step": .int(60),
        ]),
        "hints": .table([
            "letters": .string("asdfghjkl"),
            "rescan-delay": .double(0.4),
        ]),
        "double-tap": .table([:]),
        "keys": .table([:]),
    ]
}
