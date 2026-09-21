import Foundation

/// Where a key sits on one particular keyboard: which side, which finger.
///
/// The record keeps a finger per press, one step finer than the hand,
/// because the finger is the unit a layout is changed in. It was a
/// convention applied to the keycode — the touch-typing columns for the
/// letter rows, and for everything else the digit that reaches it on a
/// Mac keyboard — and a convention is wrong on exactly the boards whose
/// owners care: a split board puts enter, backspace, space and half the
/// modifiers under the thumbs. The columns survive every board that keeps
/// columns, so a letter is never remapped and needs no identity the
/// record does not keep. The keys that move are the ones the record *can*
/// name without a keycode — a kind, a modifier bit, a side — and this is
/// the declaration, per keyboard, of where those sit. Empty means the
/// convention; only the keys that differ are written down.
///
/// The hand column is never touched. It is the windows' class — left,
/// right, the space bar, other — and feeds the side statistics and the
/// hand-direction pairs the published index was defined on. A declared
/// side lives beside it for the load view, and the pairs stay put.
public struct FingerMap: Equatable {
    /// A key that exists on both sides of a board and sends one code is
    /// `either`: the finger is known, the side is honestly not.
    public enum Side: String, CaseIterable, Codable {
        case left, right, either

        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    public struct Placement: Equatable, Codable {
        public var side: Side
        public var finger: Keys.Finger

        public init(_ side: Side, _ finger: Keys.Finger) {
            self.side = side
            self.finger = finger
        }

        /// As the file writes it and the page reads it: `right thumb`.
        public var text: String { "\(side.rawValue) \(finger.name)" }

        public var label: String { "\(side.label) \(finger.name)" }

        public init?(parsing text: String) {
            let words = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            guard words.count == 2, let side = Side(rawValue: words[0]),
                  let finger = Keys.Finger(name: words[1]), finger != .unknown else { return nil }
            self.init(side, finger)
        }

        /// Every placement a key can be given, sides then fingers.
        public static let all: [Placement] = Side.allCases.flatMap { side in
            Keys.Finger.allCases.filter { $0 != .unknown }.map { Placement(side, $0) }
        }
    }

    /// Keyboard id (`vendor:product:hash`, as the roster names it) → the
    /// keys that sit somewhere other than standard.
    public var keyboards: [String: [Keys.SpecialKey: Placement]]

    public init(_ keyboards: [String: [Keys.SpecialKey: Placement]] = [:]) {
        self.keyboards = keyboards
    }

    public var isEmpty: Bool { keyboards.values.allSatisfy(\.isEmpty) }

    /// How many keys differ from standard on one keyboard.
    public func differing(on keyboard: String) -> Int { keyboards[keyboard]?.count ?? 0 }

    public func placement(of key: Keys.SpecialKey, keyboard: String) -> Placement? {
        keyboards[keyboard]?[key]
    }

    /// The declared placement, or the convention's, for a key on a board.
    public func effective(of key: Keys.SpecialKey, keyboard: String) -> Placement {
        placement(of: key, keyboard: keyboard) ?? key.standard
    }

    /// The press with its finger declared. The hand is left exactly as it
    /// was: a press this map has nothing to say about comes back
    /// unchanged, and so does one from a keyboard it has never heard of.
    public func apply(to press: KeyPress, keyboard: String) -> KeyPress {
        guard let key = Keys.SpecialKey(press: press),
              let placement = keyboards[keyboard]?[key] else { return press }
        var out = press
        out.finger = placement.finger
        return out
    }

    /// The physical side a press was made on, for the load view: the
    /// declaration when there is one, the hand column when it already is
    /// a side, and nothing when neither can say.
    public func side(of press: KeyPress, keyboard: String) -> Side? {
        if let key = Keys.SpecialKey(press: press), let placement = keyboards[keyboard]?[key] {
            return placement.side
        }
        switch press.hand {
        case .left: return .left
        case .right: return .right
        case .thumb, .other: return nil
        }
    }

    /// Deterministic, order-free; a change to it is a change to what the
    /// stored finger column means, and joins the era fingerprint.
    public var fingerprint: String {
        keyboards.keys.sorted().compactMap { id -> String? in
            guard let keys = keyboards[id], !keys.isEmpty else { return nil }
            let body = keys.map { "\($0.key.rawValue):\($0.value.text)" }.sorted().joined(separator: ",")
            return "\(id)=\(body)"
        }.joined(separator: "|")
    }
}

extension Keys {
    /// The keys a board moves, named the way the record can name them
    /// without a keycode: a kind, or a modifier with its side. Letters,
    /// digits and punctuation keep their columns and are not here.
    public enum SpecialKey: String, CaseIterable, Codable {
        case leftShift = "left-shift"
        case rightShift = "right-shift"
        case leftControl = "left-control"
        case rightControl = "right-control"
        case leftOption = "left-option"
        case rightOption = "right-option"
        case leftCommand = "left-command"
        case rightCommand = "right-command"
        case fn
        case space
        case enter
        case backspace
        case tab
        case escape

        /// From a stored press: the modifier records carry which modifier
        /// and which side, and the other kinds are their own name.
        public init?(press: KeyPress) {
            switch press.kind {
            case .modifier:
                let right = press.hand == .right
                switch press.modifiers {
                case .shift: self = right ? .rightShift : .leftShift
                case .control: self = right ? .rightControl : .leftControl
                case .option: self = right ? .rightOption : .leftOption
                case .command: self = right ? .rightCommand : .leftCommand
                case .fn: self = .fn
                default: return nil
                }
            case .space: self = .space
            case .enter: self = .enter
            case .backspace: self = .backspace
            case .tab: self = .tab
            case .escape: self = .escape
            default: return nil
            }
        }

        /// From the tap, where the keycode is still in hand. Forward
        /// delete is backspace here, as it is in the record.
        public init?(keycode: Int64) {
            switch keycode {
            case 56: self = .leftShift
            case 60: self = .rightShift
            case 59: self = .leftControl
            case 62: self = .rightControl
            case 58: self = .leftOption
            case 61: self = .rightOption
            case 55: self = .leftCommand
            case 54: self = .rightCommand
            case 63: self = .fn
            case 49: self = .space
            case 36, 76: self = .enter
            case 51, 117: self = .backspace
            case 48: self = .tab
            case 53: self = .escape
            default: return nil
            }
        }

        /// The ANSI keycode the convention is read from.
        public var keycode: Int64 {
            switch self {
            case .leftShift: return 56
            case .rightShift: return 60
            case .leftControl: return 59
            case .rightControl: return 62
            case .leftOption: return 58
            case .rightOption: return 61
            case .leftCommand: return 55
            case .rightCommand: return 54
            case .fn: return 63
            case .space: return 49
            case .enter: return 36
            case .backspace: return 51
            case .tab: return 48
            case .escape: return 53
            }
        }

        /// The row's name on the page, as the keycaps are drawn.
        public var label: String {
            switch self {
            case .leftShift: return "Left ⇧"
            case .rightShift: return "Right ⇧"
            case .leftControl: return "Left ⌃"
            case .rightControl: return "Right ⌃"
            case .leftOption: return "Left ⌥"
            case .rightOption: return "Right ⌥"
            case .leftCommand: return "Left ⌘"
            case .rightCommand: return "Right ⌘"
            case .fn: return "fn"
            case .space: return "Space"
            case .enter: return "Enter"
            case .backspace: return "Backspace"
            case .tab: return "Tab"
            case .escape: return "Escape"
            }
        }

        /// Where the convention puts it: the finger the keycode table
        /// names, and the side the hand table names — or, for the keys
        /// the hand table calls neither, the side a Mac keyboard has them
        /// on. A space bar spans both hands, so its side is either.
        public var standard: FingerMap.Placement {
            let finger = Keys.finger(for: keycode)
            let side: FingerMap.Side
            switch Keys.hand(for: keycode) {
            case .left: side = .left
            case .right: side = .right
            case .thumb: side = .either
            case .other:
                switch self {
                case .tab, .escape: side = .left
                default: side = .right
                }
            }
            return FingerMap.Placement(side, finger)
        }
    }
}

extension Keys.Finger {
    /// The plain word, as the file and the page use it.
    public var name: String {
        switch self {
        case .unknown: return "unknown"
        case .thumb: return "thumb"
        case .index: return "index"
        case .middle: return "middle"
        case .ring: return "ring"
        case .pinky: return "pinky"
        }
    }

    public init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = match
    }
}

extension KeyPress {
    /// A stored row read under today's declaration. The finger written at
    /// the tap is a cache of the map that stood then; the record keeps
    /// enough — a kind, a modifier bit, a side, a keyboard — to relabel
    /// every past press under the map that stands now.
    public func relabeled(by map: FingerMap, keyboard: String) -> KeyPress {
        map.apply(to: self, keyboard: keyboard)
    }
}
