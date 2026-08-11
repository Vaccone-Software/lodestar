import Foundation

/// The gesture roster behind the config's gestures: section. One toggle
/// per verb family, named by what it does, not by its key — the engine
/// disables by key, so each name maps to the idle-state keys the verb
/// owns and shifted variants ride along with their key.
public enum Gestures {
    public struct Verb {
        public let name: String
        public let keys: [String]
        public let about: String
    }

    /// All letters a graph chain can start on: the alphabet minus the
    /// reserved verbs o, x, and z.
    public static let graphLetters: [String] =
        "abcdefghijklmnopqrstuvwxyz".map(String.init).filter { !["o", "x", "z"].contains($0) }

    /// Ordered as the config template lists them.
    public static let roster: [Verb] = [
        Verb(name: "searcher", keys: ["space"], about: "hyper space, the app searcher"),
        Verb(name: "graph", keys: graphLetters, about: "hyper letter chains to your apps"),
        Verb(name: "window-chooser", keys: ["tab"], about: "hyper tab, the focused app's windows"),
        Verb(name: "web-bar", keys: ["return"], about: "hyper ⏎, links and search"),
        Verb(name: "menu-search", keys: ["."], about: "hyper . , the focused app's menus"),
        Verb(name: "scroll", keys: [","], about: "hyper , , keyboard scrolling"),
        Verb(name: "hints", keys: [";"], about: "hyper ; click hints, ⇧; sticky"),
        Verb(name: "claim", keys: ["="], about: "hyper = claim the focused window, ⇧= beside"),
        Verb(name: "marks", keys: ["`"], about: "hyper `, window marks"),
        Verb(name: "breaths", keys: ["'"], about: "hyper ', saved layouts"),
        Verb(name: "sweep", keys: ["0"], about: "hyper 0, park background windows"),
        Verb(name: "index-jump", keys: (1...9).map(String.init), about: "hyper 1…9 jump, ⇧1…9 slide"),
        Verb(name: "flip-orientation", keys: ["o"], about: "hyper O, flip the layout axis"),
        Verb(name: "layout-undo", keys: ["z"], about: "hyper Z undo, ⇧Z redo"),
        Verb(name: "back-forward", keys: ["x"], about: "hyper X back, ⇧X forward"),
        Verb(name: "display-move", keys: ["[", "]"], about: "hyper [ and ], move across displays"),
        Verb(name: "cheat-sheet", keys: ["/"], about: "hyper ?, the gesture reference"),
    ]

    public static let keysByName: [String: [String]] =
        Dictionary(uniqueKeysWithValues: roster.map { ($0.name, $0.keys) })

    /// The engine's disabled-key set for a name → enabled map; unknown
    /// names contribute nothing (the schema walk reports them).
    public static func disabledKeys(from toggles: [String: Bool]) -> Set<String> {
        var keys = Set<String>()
        for (name, enabled) in toggles where !enabled {
            keys.formUnion(keysByName[name] ?? [])
        }
        return keys
    }
}
