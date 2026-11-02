import Foundation

extension Draft {
    /// The Standard editing style is insert mode and nothing else, so what
    /// it adds to the buffer is the selection every Mac field has: the
    /// keys that make one and the ones that move without it.
    public enum Standard {
        /// ⇧ with an arrow selects: by character, by word with ⌥, to the
        /// line's ends with ⌘ on ← and →, and by line, or to the text's
        /// ends with ⌘, on ↑ and ↓. ⌘↑ and ⌘↓ move to the text's ends. A
        /// line is the one the eye sees, as `lines` draws it, and the
        /// file's own where it has none. False for any other key, which
        /// is left to the caller.
        public static func move(_ key: String, shift: Bool, option: Bool, command: Bool,
                                lines: Lines? = nil, in buffer: inout Buffer) -> Bool {
            guard shift || (command && (key == "up" || key == "down")) else { return false }
            let move: (inout Buffer) -> Void
            switch key {
            case "left": move = command ? { $0.moveVisualLineStart(lines) } : option ? { $0.moveWordLeft() } : { $0.moveLeft() }
            case "right": move = command ? { $0.moveVisualLineEnd(lines) } : option ? { $0.moveWordRight() } : { $0.moveRight() }
            case "up": move = command ? { $0.moveStart() } : { $0.moveVisualUp(lines) }
            case "down": move = command ? { $0.moveEnd() } : { $0.moveVisualDown(lines) }
            default: return false
            }
            if shift { buffer.select(move) } else { move(&buffer) }
            return true
        }
    }
}
