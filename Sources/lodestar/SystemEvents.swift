import AppKit
import LodestarCore

/// The one way out of the process: an event posted to the system or to an
/// app, the general pasteboard, and focus taken or given. Under a test run
/// each is inert (nothing posted, no focus moved, a pasteboard of the
/// run's own), so a test that forgets its stand-in cannot type into, click
/// on or copy over whatever the person is doing. A design drift test keeps
/// every such call in this file.
enum SystemEvents {
    /// Events a test run held back, for a test that wants to know.
    private(set) static var heldBack = 0

    static func post(_ event: CGEvent?, tap: CGEventTapLocation) {
        guard let event else { return }
        if TestRun.active { heldBack += 1; return }
        event.post(tap: tap)
    }

    static func post(_ event: CGEvent?, toPid pid: pid_t) {
        guard let event else { return }
        if TestRun.active { heldBack += 1; return }
        event.postToPid(pid)
    }

    static let pasteboard: NSPasteboard = TestRun.active
        ? NSPasteboard(name: NSPasteboard.Name("lodestar.test.\(ProcessInfo.processInfo.processIdentifier)"))
        : .general

    /// Lodestar comes to the front, for a room that takes focus on purpose.
    static func activateLodestar() {
        if TestRun.active { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Another app comes to the front.
    static func activate(_ app: NSRunningApplication) {
        if TestRun.active { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
