import Carbon.HIToolbox
import Foundation

/// What a key types through the keyboard layout in force, ⌥ and dead keys
/// included, the way any Mac text field takes it. The key tables everything
/// else reads (`Keys`) name a position by the one character it types, which
/// is the right thing for a gesture and the wrong one for text: ⌥e is no
/// letter e, it is the acute accent waiting for the letter it belongs on,
/// and ⌥⇧- is the em dash.
///
/// A dead key types nothing at once. The layout's own state is kept across
/// presses, so the next key completes it (a dead ´ and an e type é) or, when
/// nothing composes with it, types the accent and the key as they stand (a
/// dead ´ and a space type ´).
final class LayoutTyper {
    private let source: () -> Data?
    /// The layout's own dead-key state; 0 when no dead key is waiting.
    private var dead: UInt32 = 0

    /// `source` answers the layout's data (`uchr`), and is asked at every
    /// press: the layout is the person's to change, and the change is one
    /// they expect to take effect on the next key.
    init(source: @escaping () -> Data? = LayoutTyper.currentLayout) {
        self.source = source
    }

    /// Whether a dead key is waiting for the key that completes it.
    var pending: Bool { dead != 0 }

    /// The waiting dead key is dropped: a move, a mode change or a new draft
    /// is not the key it was waiting for.
    func reset() { dead = 0 }

    /// What the layout types for a character key, or nil when the layout is
    /// not asked: the key is an ordinary one, ⌥ is not held and no dead key
    /// is waiting, so the caller's own table types it. The empty string is a
    /// dead key struck (nothing is typed, the next key completes it) or a
    /// combination the layout types nothing for.
    func type(keycode: Int64, shift: Bool, option: Bool) -> String? {
        guard let data = source() else { return nil }
        var next = dead
        let text = data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var modifiers = 0
            if shift { modifiers |= shiftKey }
            if option { modifiers |= optionKey }
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, UInt16(keycode), UInt16(kUCKeyActionDown),
                                        UInt32(modifiers >> 8), UInt32(LMGetKbdType()), 0,
                                        &next, chars.count, &length, &chars)
            guard status == noErr else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
        guard let text else { return nil }
        // A key that types anything ends the sequence it was part of; the
        // layout leaves the state it was given standing.
        if !text.isEmpty { next = 0 }
        // A key that starts a dead sequence on its own (the apostrophe of an
        // international layout) is the layout's even without ⌥.
        let startsDead = next != 0 && text.isEmpty
        guard option || dead != 0 || startsDead else { return nil }
        dead = next
        // Control characters are not text.
        return text.unicodeScalars.contains { $0.properties.generalCategory == .control } ? "" : text
    }

    /// The layout the person types with: the current keyboard layout, or the
    /// ASCII-capable one beneath an input method, which carries no layout of
    /// its own. Asked of the text services on the main thread, as they
    /// require.
    static func currentLayout() -> Data? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for case let source? in sources {
            if let data = layout(of: source.takeRetainedValue()) { return data }
        }
        return nil
    }

    /// A named layout's data, installed or not, for the tests and for a
    /// layout the person picks by name.
    static func layout(id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        return layout(of: source)
    }

    private static func layout(of source: TISInputSource) -> Data? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }
}
