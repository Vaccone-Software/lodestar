import AppKit
import LodestarCore

/// The one way out of the process: an event posted to the system or to an
/// app, the pointer warped, a URL or an app opened, the general
/// pasteboard, and focus taken or given. Under a test run each is inert
/// (nothing posted, moved, opened or focused, a pasteboard of the run's
/// own), so a test that forgets its stand-in cannot type into, click on,
/// launch over or copy over whatever the person is doing. A design drift
/// test keeps every such call in this file.
enum SystemEvents {
    private static let lock = NSLock()
    private static var _heldBack = 0
    /// What a test run held back, for a test that wants to know. Posts
    /// come from background queues too (Bring's typing, the editor).
    static var heldBack: Int { lock.withLock { _heldBack } }
    /// True when the call must not leave the process.
    private static func held() -> Bool {
        guard TestRun.active else { return false }
        lock.withLock { _heldBack += 1 }
        return true
    }

    static func post(_ event: CGEvent?, tap: CGEventTapLocation) {
        guard let event, !held() else { return }
        event.post(tap: tap)
    }

    static func post(_ event: CGEvent?, toPid pid: pid_t) {
        guard let event, !held() else { return }
        event.postToPid(pid)
    }

    /// The pointer moves, with no event: a pick that lands under the hand.
    static func warp(_ point: CGPoint) {
        guard !held() else { return }
        CGWarpMouseCursorPosition(point)
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard !held() else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func open(_ urls: [URL], withApplicationAt application: URL,
                     configuration: NSWorkspace.OpenConfiguration,
                     completionHandler: ((NSRunningApplication?, Error?) -> Void)? = nil) {
        guard !held() else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration,
                                completionHandler: completionHandler)
    }

    static func openApplication(at application: URL, configuration: NSWorkspace.OpenConfiguration,
                                completionHandler: ((NSRunningApplication?, Error?) -> Void)? = nil) {
        guard !held() else { return }
        NSWorkspace.shared.openApplication(at: application, configuration: configuration,
                                           completionHandler: completionHandler)
    }

    static let pasteboard: NSPasteboard = TestRun.active
        ? NSPasteboard(name: NSPasteboard.Name("lodestar.test.\(ProcessInfo.processInfo.processIdentifier)"))
        : .general

    /// Under a test run, a process that changes something outside (a
    /// browser opened, launchctl, an uninstall step) is not started.
    struct Held: Error {}

    /// Start a process that acts on the Mac. Throws `Held` under a test
    /// run, so a caller's "could not start" path is the one taken.
    static func run(_ process: Process) throws {
        if held() { throw Held() }
        try process.run()
    }

    /// Lodestar comes to the front, for a room that takes focus on purpose.
    static func activateLodestar() {
        guard !held() else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Another app comes to the front.
    static func activate(_ app: NSRunningApplication) {
        guard !held() else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
