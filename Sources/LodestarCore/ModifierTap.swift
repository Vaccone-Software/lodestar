import CoreGraphics
import Foundation

/// Modifier keys addressable by double-tap bindings. Generic names match
/// either side; sided names match one physical key. Synthetic events may
/// carry no device bits — they resolve to the generic form.
public enum ModifierKey: String, CaseIterable, Equatable {
    case cmd, leftCmd = "left-cmd", rightCmd = "right-cmd"
    case shift, leftShift = "left-shift", rightShift = "right-shift"
    case option, leftOption = "left-option", rightOption = "right-option"
    case control, leftControl = "left-control", rightControl = "right-control"

    /// The sideless family name, for binding lookups.
    public var generic: ModifierKey {
        switch self {
        case .cmd, .leftCmd, .rightCmd: return .cmd
        case .shift, .leftShift, .rightShift: return .shift
        case .option, .leftOption, .rightOption: return .option
        case .control, .leftControl, .rightControl: return .control
        }
    }
}

/// The verbs a double-tap can fire, resolved to the lode keypress they
/// are equivalent to — a tap binding is a second door into the same room,
/// never a new room.
public enum TapVerb: String, CaseIterable {
    case searcher, web, menu, scroll, hints
    case stickyHints = "sticky-hints"
    case sweep, cheat

    public var keypress: (key: String, shift: Bool) {
        switch self {
        case .searcher: return ("space", false)
        case .web: return ("return", false)
        case .menu: return (".", false)
        case .scroll: return (",", false)
        case .hints: return (";", false)
        case .stickyHints: return (";", true)
        case .sweep: return ("0", false)
        case .cheat: return ("/", true)
        }
    }
}

/// Double-tap detection over the flagsChanged stream: a tap is one
/// modifier pressed alone and released quickly with no keystroke between;
/// two taps of the same physical key inside the window fire the binding.
/// Custom triggers only — defaults are untouched.
public struct ModifierTapDetector {
    public var bindings: [ModifierKey: TapVerb] = [:]

    public static let window: TimeInterval = 0.35
    public static let maxHold: TimeInterval = 0.5

    private var pressed: ModifierKey?
    private var pressedAt: TimeInterval = 0
    private var poisoned = false
    private var inChord = false
    private var lastTap: (modifier: ModifierKey, at: TimeInterval)?

    public init() {}

    /// Any real keypress while a modifier is down (⌘C…) or between taps
    /// poisons the gesture.
    public mutating func keyDown() {
        poisoned = true
        lastTap = nil
    }

    /// Feed every flagsChanged. Returns the verb when a double-tap lands.
    public mutating func flagsChanged(_ flags: CGEventFlags, at now: TimeInterval) -> TapVerb? {
        guard !bindings.isEmpty else { return nil }
        if let solo = Self.solo(flags) {
            // A chord releasing down to one modifier is still the chord —
            // nothing re-arms until every key is up.
            if inChord { return nil }
            if pressed != solo {
                if pressed != nil { lastTap = nil } // swapped keys mid-press
                pressed = solo
                pressedAt = now
                poisoned = false
            }
            return nil
        }
        let anyModifier = !flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty
        if anyModifier {
            inChord = true
            pressed = nil
            lastTap = nil
            return nil
        }
        if inChord {
            inChord = false
            return nil
        }
        guard let released = pressed else { return nil }
        pressed = nil
        guard !poisoned, now - pressedAt < Self.maxHold else {
            lastTap = nil
            return nil
        }
        if let last = lastTap, last.modifier == released, now - last.at < Self.window,
           let verb = binding(for: released) {
            lastTap = nil
            return verb
        }
        lastTap = (released, now)
        return nil
    }

    private func binding(for modifier: ModifierKey) -> TapVerb? {
        bindings[modifier] ?? bindings[modifier.generic]
    }

    // Device-dependent flag bits (NX_DEVICE…KEYMASK).
    private static let leftControlBit: UInt64 = 0x0001
    private static let leftShiftBit: UInt64 = 0x0002
    private static let rightShiftBit: UInt64 = 0x0004
    private static let leftCmdBit: UInt64 = 0x0008
    private static let rightCmdBit: UInt64 = 0x0010
    private static let leftOptionBit: UInt64 = 0x0020
    private static let rightOptionBit: UInt64 = 0x0040
    private static let rightControlBit: UInt64 = 0x2000

    /// Exactly one modifier family active → that modifier, sided when the
    /// device bit says so.
    static func solo(_ flags: CGEventFlags) -> ModifierKey? {
        let families: [(CGEventFlags, UInt64, UInt64, ModifierKey, ModifierKey, ModifierKey)] = [
            (.maskCommand, leftCmdBit, rightCmdBit, .cmd, .leftCmd, .rightCmd),
            (.maskShift, leftShiftBit, rightShiftBit, .shift, .leftShift, .rightShift),
            (.maskAlternate, leftOptionBit, rightOptionBit, .option, .leftOption, .rightOption),
            (.maskControl, leftControlBit, rightControlBit, .control, .leftControl, .rightControl),
        ]
        let active = families.filter { flags.contains($0.0) }
        guard active.count == 1, let family = active.first else { return nil }
        if flags.rawValue & family.2 != 0 { return family.5 }
        if flags.rawValue & family.1 != 0 { return family.4 }
        return family.3
    }
}
