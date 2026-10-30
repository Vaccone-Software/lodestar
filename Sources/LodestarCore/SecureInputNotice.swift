import Foundation

/// When to say that secure input has been left on, and by whom.
///
/// Secure input lets no key reach the tap, so a gesture made under it is
/// never seen, and a notice cannot wait for one: it has to come on its own.
/// It is only worth saying when secure input is stuck. While the app that
/// holds it is in front, someone is typing a password and the silence is
/// the point; while the screen is locked, the login window holds it. Stuck
/// is the other case: the holder has gone to the back and kept it, which
/// Chromium does when a password field keeps its focus in a window you
/// left. Two samples in a row say stuck before the notice comes, so a
/// switch away from a password field that lets go a moment later says
/// nothing.
///
/// The notice names the app on the glass and nowhere else: the record
/// says only that secure input was on (`BlindKind.secureInput`), never who
/// held it, because that would log where passwords were typed.
public struct SecureInputNotice: Sendable {
    /// The app holding secure input, as the session names it.
    public struct Holder: Equatable, Sendable {
        public let pid: Int32
        public let name: String
        public let bundleID: String?

        public init(pid: Int32, name: String, bundleID: String?) {
            self.pid = pid
            self.name = name
            self.bundleID = bundleID
        }
    }

    /// One look at the machine.
    public struct Sample: Sendable {
        public let on: Bool
        /// Nil when secure input is off, or on and its holder unknown.
        public let holder: Holder?
        public let frontPID: Int32?
        public let screenLocked: Bool

        public init(on: Bool, holder: Holder?, frontPID: Int32?, screenLocked: Bool) {
            self.on = on
            self.holder = holder
            self.frontPID = frontPID
            self.screenLocked = screenLocked
        }
    }

    public enum Change: Equatable, Sendable {
        case none
        case show(Holder)
        /// The notice goes. `keysBack` when secure input itself ended, so
        /// the hand learns lode works again; false when it went for another
        /// reason (the holder came to the front, the screen locked) and
        /// the keys are still not back.
        case hide(keysBack: Bool)
    }

    /// Stuck samples in a row before the notice comes. At the two-second
    /// sampling interval, two to four seconds.
    public static let samplesToShow = 2

    /// The holder named on the glass now.
    public private(set) var showing: Holder?
    private var stuckPID: Int32?
    private var stuckRun = 0
    /// Lodestar's own pid: if Lodestar held secure input it would not be
    /// stuck in another app, and telling you so would be noise.
    private let ownPID: Int32

    public init(ownPID: Int32) {
        self.ownPID = ownPID
    }

    public mutating func sample(_ sample: Sample) -> Change {
        guard sample.on, !sample.screenLocked, let holder = sample.holder,
              holder.pid != ownPID, holder.pid != sample.frontPID else {
            stuckPID = nil
            stuckRun = 0
            guard showing != nil else { return .none }
            showing = nil
            return .hide(keysBack: !sample.on)
        }
        stuckRun = stuckPID == holder.pid ? stuckRun + 1 : 1
        stuckPID = holder.pid
        guard stuckRun >= Self.samplesToShow, showing != holder else { return .none }
        showing = holder
        return .show(holder)
    }

    /// The fact: who holds it, in the flash grammar (a needs-you mark).
    public static func fact(_ holder: Holder) -> String {
        "⚠ \(holder.name) is holding Secure Input"
    }

    /// The way forward, which depends on what kind of app is holding it. A
    /// terminal turns secure input on at a password prompt (`sudo`), and
    /// quitting one would take its sessions with it; anything else gets
    /// the field and the quit, quitting being the one sure release.
    public static func way(_ holder: Holder) -> String {
        if let bundleID = holder.bundleID, terminals.contains(bundleID) {
            return "Lodestar hears no keys until you finish or cancel its password prompt"
        }
        return "Lodestar hears no keys until you leave its password field or quit it"
    }

    /// The flash when secure input ends after a notice stood.
    public static let keysBack = "✓ Lodestar hears your keys again"

    static let terminals: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "dev.warp.Warp-Stable",
    ]
}
