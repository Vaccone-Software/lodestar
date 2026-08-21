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
    /// The home row's physical positions, ANSI keycodes a…l.
    private static let homeRowCodes: [Int64] = [0, 1, 2, 3, 5, 4, 38, 40, 37]

    /// Install the active layout's characters into the key-name table.
    /// Called at boot and on every input-source change.
    static func install() {
        Keys.apply(layout: Keys.layoutOverlay(translated: characterTranslations()))
    }

    /// Recomputed at each mode entry — cheap, and a layout switched at
    /// lunch is honored by the afternoon's first hint. Read from the live
    /// key-name table, never translated independently: the label alphabet
    /// and the pressed key's name must be one source of truth, whichever
    /// tier of layout adoption is in force.
    static func homeRow() -> String {
        let row = homeRowCodes.compactMap { Keys.name(for: $0) }
        guard row.count == homeRowCodes.count,
              Set(row).count == row.count,
              row.allSatisfy({ $0.count == 1 && $0.allSatisfy { $0.isLetter && $0.isASCII } })
        else {
            // A config override parked punctuation on a home key, or the
            // row is otherwise unusable — fall back to the row the
            // product has always used.
            return "asdfghjkl"
        }
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
