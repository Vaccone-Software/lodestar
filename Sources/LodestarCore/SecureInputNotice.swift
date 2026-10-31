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
/// left. Two seconds of stuck samples come before the notice, so a switch
/// away from a password field that lets go a moment later says nothing.
///
/// Who holds it is remembered, not asked again. The session names the
/// holder truly only while the holder is in front: once it goes to the
/// back, the session names whatever app came forward (measured on macOS
/// 27 with an app that turned secure input on, hid, and kept it). So the
/// holder is the app the session named in the first sample after secure
/// input was off, when the app that turned it on is still the one in
/// front, and it stays the holder until secure input ends. When secure
/// input was already on at launch, or came on behind a locked screen,
/// nobody is named until it has been off again.
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
        /// The app the session names as holding secure input: the true
        /// holder only while it is in front, and otherwise the app in
        /// front. Nil when secure input is off, or the session names none.
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

    /// Stuck samples in a row before the notice comes. At the half-second
    /// sampling interval, two seconds.
    public static let samplesToShow = 4

    /// The holder named on the glass now.
    public private(set) var showing: Holder?
    /// The app that turned secure input on, as named in the first sample
    /// after it was off. Nil while it is off, or when nobody saw it begin.
    public private(set) var enabler: Holder?
    /// Whether the last sample had secure input on. True before the first,
    /// so secure input already on at launch is never put on whoever is in
    /// front.
    private var wasOn = true
    private var stuckPID: Int32?
    private var stuckRun = 0
    /// Lodestar's own pid: if Lodestar held secure input it would not be
    /// stuck in another app, and telling you so would be noise.
    private let ownPID: Int32

    public init(ownPID: Int32) {
        self.ownPID = ownPID
    }

    public mutating func sample(_ sample: Sample) -> Change {
        if !sample.on {
            enabler = nil
        } else if !wasOn, !sample.screenLocked {
            enabler = sample.holder
        }
        wasOn = sample.on
        guard sample.on, !sample.screenLocked, let holder = enabler,
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

    /// The line beside the held key, from the hand's side: its keys, not
    /// the system's name for the lock.
    public static func sentence(_ holder: Holder) -> String {
        "\(holder.name) is holding your keys"
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

    /// The line beside the lit key when secure input ends after a notice stood.
    public static let keysBack = "Your keys are back"

    static let terminals: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "dev.warp.Warp-Stable",
    ]
}
