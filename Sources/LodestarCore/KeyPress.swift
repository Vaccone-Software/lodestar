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
    /// Which digit the position belongs to under touch typing — the unit
    /// a layout is changed in, one step finer than the hand.
    public var finger: Keys.Finger
    /// For a key: the modifiers that were down when it was struck. For a
    /// modifier's own record (`kind == .modifier`): which modifier it is.
    public var modifiers: Keys.Modifiers
    /// For a modifier's record: how many keys were struck while it was
    /// held — the chord's size. Zero for anything else.
    public var struck: Int
    /// Which attached keyboard sent it, as a one-based index into the
    /// roster the day file's header names; zero when the roster could
    /// not say (two candidates, or none).
    public var keyboard: Int
    /// The lid was closed: the built-in keyboard could not have been the
    /// one, and the posture is a desk's.
    public var lid: Bool

    public init(down: Date, hold: Double?, hand: Keys.Hand, kind: Keys.Kind,
                shift: Bool = false, chord: Bool = false, gesture: Bool = false,
                lens: Bool = false, repeated: Bool = false, keyboardType: Int = 0,
                finger: Keys.Finger = .unknown, modifiers: Keys.Modifiers = [],
                struck: Int = 0, keyboard: Int = 0, lid: Bool = false) {
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
        self.finger = finger
        self.modifiers = modifiers
        self.struck = struck
        self.keyboard = keyboard
        self.lid = lid
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
        /// A modifier's own press — ⌘ ⇧ ⌥ ⌃ fn — recorded as a press in
        /// its own right, because a modifier held through a chord is the
        /// sustained load the letters' records cannot show.
        case modifier = 12

        public var isTyping: Bool {
            switch self {
            case .letter, .digit, .space, .punctuation: return true
            default: return false
            }
        }
    }

    /// The digit a position is struck with under touch typing. A
    /// convention, stated once: the home-row columns as every typing
    /// course teaches them, the space bar to the thumb, the bottom-row
    /// modifiers to the digit that reaches them on a Mac keyboard —
    /// ⌃ and ⇧ to the pinky, ⌥ to the ring finger, ⌘ to the thumb.
    /// Positions the convention does not cover (arrows, function keys)
    /// stay unknown rather than guessed.
    public enum Finger: UInt8, Codable, CaseIterable {
        case unknown = 0
        case thumb = 1
        case index = 2
        case middle = 3
        case ring = 4
        case pinky = 5
    }

    /// The modifier keys, as a set: which were down when a key was
    /// struck, or which one a modifier's own record is.
    public struct Modifiers: OptionSet, Codable, Equatable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
        public static let fn = Modifiers(rawValue: 16)
        /// The three that make a chord — everything but shift and fn.
        public static let chording: Modifiers = [.command, .option, .control]
    }

    static let modifierKeys: [Int64: Modifiers] = [
        54: .command, 55: .command,
        56: .shift, 60: .shift,
        58: .option, 61: .option,
        59: .control, 62: .control,
        63: .fn,
    ]

    /// The modifier a keycode is, or nil for a key that is not one.
    public static func modifier(for keycode: Int64) -> Modifiers? { modifierKeys[keycode] }

    static let pinkyLeft: Set<Int64> = [50, 18, 12, 0, 6, 48, 53, 56, 59, 63]
    static let ringLeft: Set<Int64> = [19, 13, 1, 7, 58]
    static let middleLeft: Set<Int64> = [20, 14, 2, 8]
    static let indexLeft: Set<Int64> = [21, 23, 15, 17, 3, 5, 9, 11]
    static let indexRight: Set<Int64> = [22, 26, 16, 32, 4, 38, 45, 46]
    static let middleRight: Set<Int64> = [28, 34, 40, 43]
    static let ringRight: Set<Int64> = [25, 31, 37, 47, 61]
    static let pinkyRight: Set<Int64> = [29, 27, 24, 35, 33, 30, 42, 41, 39, 44, 36, 51, 60, 62]

    public static func finger(for keycode: Int64) -> Finger {
        if keycode == 49 || keycode == 54 || keycode == 55 { return .thumb }
        if pinkyLeft.contains(keycode) || pinkyRight.contains(keycode) { return .pinky }
        if ringLeft.contains(keycode) || ringRight.contains(keycode) { return .ring }
        if middleLeft.contains(keycode) || middleRight.contains(keycode) { return .middle }
        if indexLeft.contains(keycode) || indexRight.contains(keycode) { return .index }
        return .unknown
    }

    static let leftHand: Set<Int64> = [
        18, 19, 20, 21, 23, // 1 2 3 4 5
        12, 13, 14, 15, 17, // q w e r t
        0, 1, 2, 3, 5, // a s d f g
        6, 7, 8, 9, 11, // z x c v b
        50, // `
        55, 56, 58, 59, 63, // left ⌘ ⇧ ⌥ ⌃ and fn
    ]
    static let rightHand: Set<Int64> = [
        22, 26, 28, 25, 29, 27, 24, // 6 7 8 9 0 - =
        16, 32, 34, 31, 35, 33, 30, 42, // y u i o p [ ] \
        4, 38, 40, 37, 41, 39, // h j k l ; '
        45, 46, 43, 47, 44, // n m , . /
        54, 60, 61, 62, // right ⌘ ⇧ ⌥ ⌃
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
        if modifierKeys[keycode] != nil { return .modifier }
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
