import AppKit

/// The app in front, kept as the system announces it rather than asked for.
///
/// `NSWorkspace.frontmostApplication` answers through LaunchServices: the
/// pid, the bundle id and the name are each a synchronous round trip to
/// the service. The editor asked for them once a second on the main thread,
/// and under memory pressure the round trips took seconds: sampled on 26
/// October 2026, three of twenty seconds of main went to them, in two
/// stalls of 1.4 and 2.1 s. Activation is announced, so the answer is read
/// once per switch. Main thread.
final class FrontmostApp {
    struct App: Equatable {
        let pid: pid_t
        let bundleID: String?
        let name: String?
    }

    static let shared = FrontmostApp()

    private(set) var current: App?
    private var activation: NSObjectProtocol?

    private init() {
        current = NSWorkspace.shared.frontmostApplication.map(Self.app)
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.current = Self.app(app)
        }
    }

    private static func app(_ app: NSRunningApplication) -> App {
        App(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName)
    }
}
