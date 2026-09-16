import Foundation

/// One press, unkeyed: when it went down, how long it was held, which
/// hand and what kind of key, and the circumstances an analysis will
/// want to split on or exclude. The keycode is looked at exactly once, at
/// the tap, to produce the hand and the kind, and never leaves the
/// engine. Which keys were pressed are not kept on general typing because
/// no analysis in the literature wants them; which hand pressed is kept
/// because the literature does (DESIGN, the bouts paragraph).
public struct KeyPress: Codable, Equatable {
    public var down: Date
    /// Press to release, seconds. Nil when the release was never seen —
    /// the tap dropped it, or the press was still down when the tap
    /// reset — which the coverage line counts rather than hides.
    public var hold: Double?
    public var hand: Keys.Hand
    public var kind: Keys.Kind
    /// ⇧ was down. Capitals are typing; the flag lets the analyst decide.
    public var shift: Bool
    /// ⌘, ⌃ or ⌥ was down: a chord, a different motor act from the habit.
    public var chord: Bool
    /// Lodestar swallowed the press: it was a gesture aimed at a lens.
    public var gesture: Bool
    /// A lens stood when the press landed.
    public var lens: Bool
    /// The OS repeated the key while it was down; its hold is a held
    /// key's, not a keystroke's.
    public var repeated: Bool
    /// The event's keyboard-type code — a layout class, not a device.
    public var keyboardType: Int

    public init(down: Date, hold: Double?, hand: Keys.Hand, kind: Keys.Kind,
                shift: Bool = false, chord: Bool = false, gesture: Bool = false,
                lens: Bool = false, repeated: Bool = false, keyboardType: Int = 0) {
        self.down = down
        self.hold = hold
        self.hand = hand
        self.kind = kind
        self.shift = shift
        self.chord = chord
        self.gesture = gesture
        self.lens = lens
        self.repeated = repeated
        self.keyboardType = keyboardType
    }

    /// The typing habit, as the hold-time literature measures it:
    /// characters and the space bar, no chords, no gestures, no repeats.
    public var isTyping: Bool { kind.isTyping && !chord && !gesture && !repeated }
}

extension Keys {
    /// Which hand a physical position belongs to under touch typing. The
    /// keycodes are positions, so this survives Dvorak and Colemak; a
    /// split keyboard sends the same positions.
    public enum Hand: UInt8, Codable, CaseIterable {
        case other = 0
        case left = 1
        case right = 2
        /// The space bar.
        case thumb = 3
    }

    /// What kind of key a position is: enough to include or exclude a
    /// class, never enough to name a key.
    public enum Kind: UInt8, Codable, CaseIterable {
        case other = 0
        case letter = 1
        case digit = 2
        case space = 3
        case punctuation = 4
        case backspace = 5
        case enter = 6
        case tab = 7
        case escape = 8
        case navigation = 9
        case function = 10
        case keypad = 11

        public var isTyping: Bool {
            switch self {
            case .letter, .digit, .space, .punctuation: return true
            default: return false
            }
        }
    }

    static let leftHand: Set<Int64> = [
        18, 19, 20, 21, 23, // 1 2 3 4 5
        12, 13, 14, 15, 17, // q w e r t
        0, 1, 2, 3, 5, // a s d f g
        6, 7, 8, 9, 11, // z x c v b
        50, // `
    ]
    static let rightHand: Set<Int64> = [
        22, 26, 28, 25, 29, 27, 24, // 6 7 8 9 0 - =
        16, 32, 34, 31, 35, 33, 30, 42, // y u i o p [ ] \
        4, 38, 40, 37, 41, 39, // h j k l ; '
        45, 46, 43, 47, 44, // n m , . /
    ]
    static let letters: Set<Int64> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
        31, 32, 34, 35, 37, 38, 40, 45, 46,
    ]
    static let digits: Set<Int64> = [18, 19, 20, 21, 22, 23, 25, 26, 28, 29]
    static let punctuation: Set<Int64> = [50, 27, 24, 33, 30, 42, 41, 39, 43, 47, 44]
    static let navigation: Set<Int64> = [123, 124, 125, 126, 115, 116, 119, 121]
    static let function: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
        106, 64, 79, 80, 90,
    ]
    static let keypad: Set<Int64> = [
        65, 67, 69, 71, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
    ]

    public static func hand(for keycode: Int64) -> Hand {
        if keycode == 49 { return .thumb }
        if leftHand.contains(keycode) { return .left }
        if rightHand.contains(keycode) { return .right }
        return .other
    }

    public static func kind(for keycode: Int64) -> Kind {
        if letters.contains(keycode) { return .letter }
        if digits.contains(keycode) { return .digit }
        if keycode == 49 { return .space }
        if punctuation.contains(keycode) { return .punctuation }
        if keycode == 51 || keycode == 117 { return .backspace }
        if keycode == 36 || keycode == 76 { return .enter }
        if keycode == 48 { return .tab }
        if keycode == 53 { return .escape }
        if navigation.contains(keycode) { return .navigation }
        if function.contains(keycode) { return .function }
        if keypad.contains(keycode) { return .keypad }
        return .other
    }
}

/// This installation's name for itself: a random identifier written once
/// and kept, so records made here can be told from records made
/// elsewhere when a person's data is ever joined with anything. It names
/// the install, not the person, and nothing derives from it.
public enum Install {
    public static let file = "install-id"

    public static func id(in directory: URL = Paths.data) -> String {
        let url = directory.appendingPathComponent(file)
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fresh.write(to: url, atomically: true, encoding: .utf8)
        return fresh
    }
}
