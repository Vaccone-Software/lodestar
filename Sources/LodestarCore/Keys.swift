import CoreGraphics

/// ANSI virtual keycode table — the classic kVK_ANSI_* values, which are
/// layout-position codes, not characters. Good enough for a US-style board.
public enum Keys {
    /// The built-in ANSI-layout table.
    public static let ansi: [Int64: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c",
        9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
        28: "8", 29: "0", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j",
        40: "k", 41: ";", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
        36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
        50: "`", 33: "[", 30: "]", 39: "'", 24: "=", 27: "-", 42: "\\",
        123: "left", 124: "right", 125: "down", 126: "up",
    ]

    /// The live table: ANSI overlaid with config `keys:` overrides.
    public private(set) static var names: [Int64: String] = ansi

    /// Reverse lookup, cached — the scroll dead-man guard reads it at 120Hz.
    public private(set) static var codes: [String: Int64] = reverse(ansi)

    /// Overlay config overrides (reload-safe: always rebuilds from ANSI).
    public static func apply(overrides: [Int64: String]) {
        names = ansi.merging(overrides) { _, override in override }
        codes = reverse(names)
    }

    private static func reverse(_ table: [Int64: String]) -> [String: Int64] {
        var reversed: [String: Int64] = [:]
        for (code, name) in table { reversed[name] = code }
        return reversed
    }

    public static func isValidName(_ name: String) -> Bool {
        ansi.values.contains(name)
    }

    public static func name(for keycode: Int64) -> String? { names[keycode] }
}
