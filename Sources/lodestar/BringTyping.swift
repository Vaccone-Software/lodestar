import AppKit

/// Bring's last step: the chosen text typed into an app the way a hand
/// would, so it lands at the caret in whatever kind of field holds it and
/// the pasteboard never changes. An app takes a typed string of a few
/// dozen characters and quietly drops the rest, so the text goes in
/// short pieces, never cutting a character in two, off the main thread
/// and marked so the tap lets it through.
enum BringTyping {
    static let piece = 16

    static func pieces(of text: String) -> [[UInt16]] {
        var out: [[UInt16]] = []
        var current: [UInt16] = []
        for character in text {
            let units = Array(String(character).utf16)
            if current.count + units.count > piece, !current.isEmpty {
                out.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func type(_ text: String, to pid: pid_t) {
        let chunks = pieces(of: text)
        DispatchQueue.global(qos: .userInteractive).async {
            for units in chunks {
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event.flags = []
                    event.setIntegerValueField(.eventSourceUserData, value: SelectController.ownMark)
                    event.postToPid(pid)
                    usleep(4_000)
                }
            }
        }
    }
}
