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

    /// The Finder comes to the front with these files selected.
    static func reveal(_ urls: [URL]) {
        guard !held() else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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

/// The keys under a test run. A panel that takes the keys takes keyboard
/// focus from whatever app is in front, without bringing Lodestar forward
/// (a non-activating panel), and the suite took the person's that way:
/// every key they typed while a test held a panel went to the panel. So a
/// test run's keys are this process's own: a panel is told it has them,
/// draws its caret, and is sent the notices a key window is sent, and the
/// window server is never asked. The guard watches the rest: a window that
/// takes the keys for real during a test run is written to the log with
/// `marker`, and scripts/test.sh fails the run on it, naming the test.
enum TestKeys {
    /// The line the guard writes, which scripts/test.sh looks for.
    static let marker = "LODESTAR-TOOK-THE-KEYS"
    private static var watching = false

    /// Starts the guard, once, under a test run.
    @MainActor static func watch() {
        guard TestRun.active, !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                               queue: nil) { note in
            // A real key window is AppKit's own: the run's keys are told to
            // a panel alone, and NSApp never hears of them.
            guard let window = note.object as? NSWindow, NSApp.keyWindow === window else { return }
            let line = "\(marker) \(type(of: window)) \"\(window.title)\"\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
