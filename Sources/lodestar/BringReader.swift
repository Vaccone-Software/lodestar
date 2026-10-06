import AppKit
import LodestarCore

/// Bring's reading of every window but the one being typed into: in front
/// on another display or covered, the same app's other windows included.
///
/// Read by accessibility, which answers for a covered window as readily as
/// for one in front, one app at a time on a queue of its own, never the
/// main thread, each app bounded by a short timeout and each window by a
/// node budget and a deadline. Apps come in the order the window server
/// stacks their windows, which is the order they were last in front, and
/// each window's lines reach the main thread as soon as that window is
/// read, so a slow app never holds the rest back. Nothing is kept once
/// Bring closes.
final class BringReader {
    struct Window {
        let source: Bring.Source
        let pid: pid_t
        let lines: [String]
    }

    private let queue = DispatchQueue(label: "com.vaccone.lodestar.bring", qos: .userInitiated)
    private var generation = 0
    private(set) var windows: [Window] = []
    /// Still reading: apps not yet answered.
    private(set) var reading = false
    var onUpdate: (() -> Void)?

    private static let textRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell",
    ]
    private static let skipRoles: Set<String> = ["AXMenuBar", "AXMenu", "AXScrollBar"]
    private static let nodeBudget = 20_000
    private static let windowSeconds = 1.2
    /// A terminal's scrollback can be years long; the recent end is what
    /// anyone brings from.
    private static let tailLines = 3_000

    /// Read every window but the focused one of `front`. A password
    /// manager is never read, nor any app excluded from Keep: what may
    /// not be recorded may not be read either.
    func start(front: pid_t, excluded: Set<String> = []) {
        generation += 1
        let expected = generation
        lock.withLock { live = expected }
        windows = []
        reading = true
        let order = Self.appOrder(excluding: getpid(), apps: Clipboard.passwordApps.union(excluded))
        queue.async { [weak self] in
            let app = AXUIElementCreateApplication(front)
            AXUIElementSetMessagingTimeout(app, 0.25)
            let focused = AX.element(app, kAXFocusedWindowAttribute as String)
            for (rank, pid) in order.enumerated() {
                guard let self, self.isCurrent(expected) else { return }
                let read = Self.read(pid: pid, rank: rank, skipping: focused)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == expected, !read.isEmpty else { return }
                    self.windows.append(contentsOf: read)
                    self.onUpdate?()
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                self.reading = false
                self.onUpdate?()
            }
        }
    }

    func stop() {
        generation += 1
        lock.withLock { live = generation }
        windows = []
        reading = false
    }

    /// The generation the walk checks between apps, behind a lock: the
    /// main thread bumps it when Bring closes, and the walk stops at the
    /// next app without ever waiting on the main thread.
    private let lock = NSLock()
    private var live = 0
    private func isCurrent(_ expected: Int) -> Bool { lock.withLock { live == expected } }

    /// Regular apps in the order their frontmost windows are stacked, the
    /// most recently used first. Apps with no window on screen follow.
    static func appOrder(excluding own: pid_t, apps: Set<String>) -> [pid_t] {
        let regular = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }
            .filter { !apps.contains($0.bundleIdentifier?.lowercased() ?? "") }
            .map(\.processIdentifier))
        var order: [pid_t] = []
        let stacked = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        for info in stacked {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  regular.contains(pid), !order.contains(pid) else { continue }
            order.append(pid)
        }
        for pid in regular where !order.contains(pid) { order.append(pid) }
        return order
    }

    private static func read(pid: pid_t, rank: Int, skipping focused: AXUIElement?) -> [Window] {
        let running = NSRunningApplication(processIdentifier: pid)
        let name = running?.localizedName ?? "App"
        // A Chromium browser builds its tree only when asked to; the first
        // Bring after it wakes may find less than the next.
        if let bundle = running?.bundleURL, AXWarmer.isChromiumBrowser(bundle) { _ = AXWarmer.warm(pid) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var out: [Window] = []
        for window in AX.elements(app, kAXWindowsAttribute as String) ?? [] {
            if let focused, CFEqual(window, focused) { continue }
            if AX.bool(window, kAXMinimizedAttribute as String) == true { continue }
            var texts: [String] = []
            var nodes = 0
            let deadline = Date().addingTimeInterval(windowSeconds)
            walk(window, into: &texts, nodes: &nodes, depth: 0, deadline: deadline)
            var lines = Bring.lines(of: texts.joined(separator: "\n"))
            if lines.count > tailLines { lines = Array(lines.suffix(tailLines)) }
            guard !lines.isEmpty else { continue }
            let title = AX.string(window, kAXTitleAttribute as String) ?? ""
            out.append(Window(source: Bring.Source(app: name, window: title, rank: rank), pid: pid, lines: lines))
        }
        return out
    }

    private static func walk(_ element: AXUIElement, into texts: inout [String], nodes: inout Int,
                             depth: Int, deadline: Date) {
        guard nodes < nodeBudget, depth < 60, Date() < deadline else { return }
        nodes += 1
        let role = AX.string(element, kAXRoleAttribute as String) ?? ""
        if skipRoles.contains(role) { return }
        // A password field is never read, whatever it holds.
        if AX.string(element, kAXSubroleAttribute as String) == "AXSecureTextField" { return }
        if textRoles.contains(role) {
            if let value = AX.string(element, kAXValueAttribute as String), !value.isEmpty {
                texts.append(value)
                // A text area's value is all of it; its children repeat it.
                if role == "AXTextArea" || role == "AXTextField" { return }
            } else if let title = AX.string(element, kAXTitleAttribute as String), !title.isEmpty {
                texts.append(title)
            }
        }
        for child in AX.elements(element, kAXChildrenAttribute as String) ?? [] {
            walk(child, into: &texts, nodes: &nodes, depth: depth + 1, deadline: deadline)
        }
    }
}
