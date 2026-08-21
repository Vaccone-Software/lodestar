import Carbon.HIToolbox
import Foundation

/// What the user's keyboard actually types, asked of macOS rather than
/// assumed. Keycodes are positions; the built-in table names them by what
/// they produce on ANSI QWERTY, so on any other layout a label made from
/// position names lies — a Dvorak hint reading "s" wants the key that
/// types "o". This reads the active layout (falling back to the current
/// ASCII-capable one, so IMEs resolve to the latin layout beneath them)
/// and answers with characters, making label and key the same thing again.
enum KeyboardLayout {
    /// The home row's physical positions, ANSI keycodes a…l.
    private static let homeRowCodes: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37]

    /// Recomputed at each mode entry — cheap, and a layout switched at
    /// lunch is honored by the afternoon's first hint.
    static func homeRow() -> String {
        guard let row = translate(homeRowCodes),
              row.count == homeRowCodes.count,
              Set(row).count == row.count,
              row.allSatisfy({ $0.isLetter && $0.isASCII }) else {
            // Anything unreadable or exotic falls back to the row the
            // product has always used.
            return "asdfghjkl"
        }
        return row.lowercased()
    }

    private static func translate(_ codes: [UInt16]) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var letters = ""
            for code in codes {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let error = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
                                           UInt32(LMGetKbdType()),
                                           UInt32(kUCKeyTranslateNoDeadKeysMask),
                                           &deadKeys, 4, &length, &chars)
                guard error == noErr, length == 1 else { return nil }
                letters += String(utf16CodeUnits: chars, count: length)
            }
            return letters
        }
    }
}
