import CoreGraphics

/// The key-name table: what each physical key should be called. Three
/// layers, each overlaying the last — the classic kVK_ANSI_* position
/// table as the floor, the active layout's own characters where they can
/// be adopted coherently (see `layoutOverlay`), and the config's `keys:`
/// overrides as the user's last word. Labels, gesture matching, and key
/// synthesis all read this one table, which is what keeps a hint's chip
/// and the key that fires it the same character on every layout.
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

    /// The positions a layout may rename: every key whose ANSI name is the
    /// single character it types. Named keys (return, space, arrows…) are
    /// positions forever.
    public static let characterCodes: Set<Int64> =
        Set(ansi.filter { $0.value.count == 1 }.keys)

    /// The live table.
    public private(set) static var names: [Int64: String] = ansi

    /// Reverse lookup, cached — the scroll dead-man guard reads it at 120Hz.
    public private(set) static var codes: [String: Int64] = reverse(ansi)

    private static var layout: [Int64: String] = [:]
    private static var overrides: [Int64: String] = [:]

    /// Overlay config overrides (reload-safe: always rebuilds from the floor).
    public static func apply(overrides: [Int64: String]) {
        self.overrides = overrides
        rebuild()
    }

    /// Overlay the active layout's characters, as `layoutOverlay` vetted
    /// them. Installed at boot and again whenever the input source changes.
    public static func apply(layout: [Int64: String]) {
        self.layout = layout
        rebuild()
    }

    private static func rebuild() {
        names = ansi
            .merging(layout) { _, adopted in adopted }
            .merging(overrides) { _, override in override }
        var reversed = reverse(names)
        // An override that renames a keycode onto a name the built-in
        // table already owns is a deliberate act, and it has to win the
        // reverse lookup too — otherwise the lowest-keycode rule below
        // hands the name straight back to the ANSI entry and the override
        // does nothing. Descending, so the lowest keycode is written last
        // and wins among overrides, matching `reverse`.
        for (code, name) in overrides.sorted(by: { $0.key > $1.key }) where names[code] == name {
            reversed[name] = code
        }
        codes = reversed
    }

    /// The layout's character table, vetted for coherence. `translated`
    /// carries what each character position actually types (positions the
    /// layout cannot answer for are simply absent). Adoption is judged
    /// whole, never key by key: the result must keep every ANSI name
    /// alive on exactly one key, because a half-adopted table strands
    /// gestures — a layout that moves "s" onto the ";" position while the
    /// old "s" position keeps its stale name has two keys called s and no
    /// key called ; at all.
    ///
    /// Two tiers, then the floor. A fully ASCII layout (Dvorak, Colemak)
    /// adopts wholesale — every label, chain letter, and gesture then
    /// follows the printed keycap. A layout with a few non-ASCII keys
    /// (QWERTZ umlauts) adopts its letters and digits, its punctuation
    /// staying positional exactly as before. Anything that cannot keep
    /// the name set intact (AZERTY's shifted digits) adopts nothing, and
    /// behaves as it always has.
    public static func layoutOverlay(translated: [Int64: String]) -> [Int64: String] {
        let usable = translated.filter { code, char in
            guard characterCodes.contains(code), char.count == 1,
                  let first = char.first else { return false }
            return first.isASCII && !first.isWhitespace && first.asciiValue.map { $0 > 32 } == true
        }.mapValues { $0.lowercased() }

        let ansiNames = ansi.filter { characterCodes.contains($0.key) }.values.sorted()
        func keepsEveryName(_ overlay: [Int64: String]) -> Bool {
            var table = ansi
            for (code, char) in overlay { table[code] = char }
            let names = table.filter { characterCodes.contains($0.key) }.values.sorted()
            return names == ansiNames
        }

        if keepsEveryName(usable) {
            return usable
        }
        let lettersAndDigits = usable.filter { _, char in
            let first = char.first!
            return first.isLetter || first.isNumber
        }
        if keepsEveryName(lettersAndDigits) {
            return lettersAndDigits
        }
        return [:]
    }

    /// Two keycodes can carry one name once a config override renames a
    /// key onto a name the ANSI table already owns. Iterating the
    /// dictionary let whichever entry came last win, and Swift's ordering
    /// is not stable across launches — so ⌘V synthesis and the scroll
    /// guard could address a different keycode on the next boot. Lowest
    /// keycode wins, every time.
    private static func reverse(_ table: [Int64: String]) -> [String: Int64] {
        var reversed: [String: Int64] = [:]
        for (code, name) in table.sorted(by: { $0.key < $1.key }) {
            if reversed[name] == nil { reversed[name] = code }
        }
        return reversed
    }

    // MARK: - What a key types

    /// The shifted half of the character table: what a US keyboard prints
    /// above each character key. Positional, like the ANSI floor it
    /// extends — a layout that renames its character keys carries the
    /// unshifted half (see `layoutOverlay`), while the shifted half stays
    /// what the position types on ANSI.
    public static let shifted: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&",
        "8": "*", "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}",
        "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]

    /// The character a key name puts on the screen, or nil for a key that
    /// types nothing (return, escape, an arrow).
    ///
    /// Every incremental search in the product reads this one function, so
    /// the two of them agree about what a keyboard produces: text people
    /// search for is full of hyphens, underscores, slashes and dots, and a
    /// band that took letters and digits alone could not be typed the name
    /// of the file it was looking for. Callers that give letters another
    /// job under shift — select's chips are letters, so a capital there is
    /// a pick — decide that themselves and delegate the rest here.
    public static func character(for key: String, shift: Bool) -> String? {
        if key == "space" { return " " }
        guard key.count == 1, let first = key.first else { return nil }
        if first.isLetter { return shift ? key.uppercased() : key }
        return shift ? shifted[key] : key
    }

    public static func isValidName(_ name: String) -> Bool {
        ansi.values.contains(name)
    }

    public static func name(for keycode: Int64) -> String? { names[keycode] }
}
