import Carbon.HIToolbox
import Foundation
import LodestarCore

/// What the user's keyboard actually types, asked of macOS rather than
/// assumed. Keycodes are positions; the built-in table names them by what
/// they produce on ANSI QWERTY, so on any other layout a name made from
/// position lies — a Dvorak hint reading "s" wants the key that types "o".
/// This reads the active layout (falling back to the current ASCII-capable
/// one, so IMEs resolve to the latin layout beneath them) and feeds
/// `Keys.layoutOverlay`, which adopts what it can keep coherent. Labels
/// then come back out of `Keys.names`, so a label and the key that fires
/// it are the same table entry by construction.
enum KeyboardLayout {
    /// The letter rows' physical positions, ANSI keycodes, in the order
    /// labels spend them: home row, then the top row, then the bottom.
    /// The hand owns the home row outright, so it is never left for a
    /// second row while single letters remain; past it, reaching up beats
    /// reaching down — the top row is ten keys to the bottom's seven, and
    /// the fingers already travel there constantly for e, r, t, i, o, u,
    /// where the bottom row holds the letters English uses least and asks
    /// the fingers to curl under. The order is fixed and never sorted by
    /// anything else, because a chip that moved rows between windows
    /// would be a fresh decision every time.
    private static let homeRowCodes: [Int64] = [0, 1, 2, 3, 5, 4, 38, 40, 37]
    private static let topRowCodes: [Int64] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35]
    private static let bottomRowCodes: [Int64] = [6, 7, 8, 9, 11, 45, 46]

    /// Install the active layout's characters into the key-name table.
    /// Called at boot and on every input-source change.
    static func install() {
        Keys.apply(layout: Keys.layoutOverlay(translated: characterTranslations()))
    }

    /// The chip alphabet: every letter row the layout can answer for, in
    /// the fixed order above.
    ///
    /// Recomputed at each mode entry — cheap, and a layout switched at
    /// lunch is honored by the afternoon's first hint. Read from the live
    /// key-name table, never translated independently: the label alphabet
    /// and the pressed key's name must be one source of truth, whichever
    /// tier of layout adoption is in force. Each row is validated on its
    /// own, so a layout that parks punctuation on one row loses that row
    /// rather than the whole alphabet, and the home row's own failure
    /// still falls back to the row the product has always used.
    static func chipAlphabet() -> String {
        let rows = [row(homeRowCodes) ?? "asdfghjkl", row(topRowCodes), row(bottomRowCodes)]
        var seen = Set<Character>()
        var letters = ""
        for character in rows.compactMap({ $0 }).joined() where !seen.contains(character) {
            seen.insert(character)
            letters.append(character)
        }
        return letters
    }

    /// One row of keycodes as the letters it currently types, or nil when
    /// it does not read as distinct single ASCII letters.
    private static func row(_ codes: [Int64]) -> String? {
        let row = codes.compactMap { Keys.name(for: $0) }
        guard row.count == codes.count,
              Set(row).count == row.count,
              row.allSatisfy({ $0.count == 1 && $0.allSatisfy { $0.isLetter && $0.isASCII } })
        else { return nil }
        return row.joined().lowercased()
    }

    /// What each character position actually types under the active
    /// layout. Positions the layout cannot answer for (dead keys, multi
    /// unit output) are simply absent — the overlay's tiers decide what
    /// absence means.
    private static func characterTranslations() -> [Int64: String] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> [Int64: String] in
            guard let layout = bytes.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
            var translated: [Int64: String] = [:]
            for code in Keys.characterCodes {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let error = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                           UInt32(LMGetKbdType()),
                                           UInt32(kUCKeyTranslateNoDeadKeysMask),
                                           &deadKeys, 4, &length, &chars)
                guard error == noErr, length == 1 else { continue }
                translated[code] = String(utf16CodeUnits: chars, count: length)
            }
            return translated
        }
    }
}
