import AppKit
import ApplicationServices

/// The cached window model — the resolver's ground truth.
///
/// Slice 0 proved polling cannot work: tab-hidden windows vanish from
/// kAXWindows, dead windows linger in CG lists app-dependently, and
/// synchronous scans stall on hung apps. So windows are discovered through
/// notifications, their AX elements are retained for life, and liveness comes
/// from kAXUIElementDestroyed — never from re-enumeration. Focus changes
/// self-heal the model: any window revealed from a tab arrives through the
/// focused-window notification and gets tracked then.
public final class WindowModel {
    public struct Window {
        public let id: CGWindowID
        public let element: AXUIElement
        public let pid: pid_t
        public let appName: String
        public let bundleID: String?
        public var title: String
        public var frame: CGRect
        public var isMinimized: Bool
        public var isAlive: Bool
        public var lastFocused: Date?
        /// When the window died — dead records are kept briefly for
        /// close-vs-hide judgment, then pruned.
        public var deadAt: Date?
    }

    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    public private(set) var windows: [CGWindowID: Window] = [:]
    public private(set) var focusedID: CGWindowID?

    public var onCreated: ((CGWindowID) -> Void)?
    public var onDestroyed: ((CGWindowID) -> Void)?
    public var onFocus: ((CGWindowID) -> Void)?
    public var onTitleChanged: ((CGWindowID) -> Void)?
    public var onTrace: ((String) -> Void)?

    private var observers: [pid_t: AppObserver] = [:]
    private var idByElement: [ElementKey: CGWindowID] = [:]
    private var workspaceTokens: [any NSObjectProtocol] = []

    public init() {}

    private var seeding = false

    public func start() {
        // The initial scan is discovery, not creation — onCreated stays
        // quiet so nothing treats the existing world as newly arrived.
        seeding = true
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app)
        }
        seeding = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            // A freshly launched app needs a moment to stand up its AX tree.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.attach(app)
            }
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.detach(app.processIdentifier)
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.syncFocus(of: app)
        })
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            syncFocus(of: frontmost)
        }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        for observer in observers.values { observer.invalidate() }
        observers.removeAll()
    }

    // MARK: - Queries

    public func window(_ id: CGWindowID) -> Window? { windows[id] }

    public var focusedWindow: Window? { focusedID.flatMap { windows[$0] } }

    public func aliveWindows(bundleID: String) -> [Window] {
        aliveWindows { $0.bundleID == bundleID }
    }

    public func aliveWindows(appNamed name: String) -> [Window] {
        let lowered = name.lowercased()
        return aliveWindows { $0.appName.lowercased() == lowered }
    }

    /// Sweep first, then verify each survivor: the two-tier liveness check
    /// every destination lookup runs (FINDINGS §8). Ids are collected before
    /// verifying because `verify` buries, which mutates `windows`.
    private func aliveWindows(_ matches: (Window) -> Bool) -> [Window] {
        sweepAgainstWindowServer()
        let ids = windows.values.filter { $0.isAlive && matches($0) }.map(\.id)
        return ids.filter { verify($0) }.compactMap { windows[$0] }
    }

    /// The best of several candidate destinations: the most recently focused
    /// wins; never-focused falls back to newest — ids are monotonic within a
    /// login session (FINDINGS §4), so the highest id is the youngest window.
    public static func mostCurrent(_ candidates: [Window]) -> Window? {
        candidates.max {
            ($0.lastFocused ?? .distantPast, $0.id) < ($1.lastFocused ?? .distantPast, $1.id)
        }
    }

    // MARK: - Liveness verification

    /// Chromium never posts kAXUIElementDestroyed — registration succeeds
    /// and the notification simply never fires (measured 2026-08-10,
    /// FINDINGS §8) — so a closed Brave window would stay alive here
    /// forever. The element itself is the truth: a destroyed element
    /// answers .invalidUIElement. Nothing else kills — a hung app's
    /// .cannotComplete timeout must read as alive.
    @discardableResult
    public func verify(_ id: CGWindowID) -> Bool {
        guard let w = windows[id], w.isAlive else { return false }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(w.element, kAXRoleAttribute as CFString, &value)
        guard error == .invalidUIElement else { return true }
        onTrace?("ghost id=\(id) \(w.appName) — element dead")
        bury(id)
        return false
    }

    /// The cheap, hang-immune complement: one window-server call, and any
    /// alive record the server no longer lists is dead. Absence is sound —
    /// minimized, parked, tab-hidden, and other-Space windows all stay in
    /// the all-windows list — but presence proves nothing (dead windows
    /// linger server-side app-dependently, FINDINGS §3), so this never
    /// resurrects. A failed or empty read touches nothing.
    public func sweepAgainstWindowServer() {
        let extant = CGWindows.liveIDs(onScreenOnly: false)
        guard !extant.isEmpty else { return }
        let ghosts = windows.values.filter { $0.isAlive && !extant.contains($0.id) }
        for w in ghosts {
            onTrace?("ghost id=\(w.id) \(w.appName) — gone from window server")
            bury(w.id)
        }
    }

    /// The app's own idea of its focused window, tracked and returned; falls
    /// back to any alive window we know for it.
    public func bestWindow(pid: pid_t) -> Window? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let ax = AXApplication(app)
            if let focused = ax.focusedWindow(), let id = track(element: focused.element, app: app) {
                return windows[id]
            }
        }
        return windows.values.first { $0.isAlive && $0.pid == pid }
    }

    /// Re-read a window's frame right now (AX events can lag a beat).
    public func refreshFrame(_ id: CGWindowID) {
        guard var w = windows[id], w.isAlive else { return }
        if let frame = AXWindow(element: w.element)?.frame {
            w.frame = frame
            windows[id] = w
        }
    }

    // MARK: - Attach / detach

    private func attach(_ app: NSRunningApplication) {
        _ = observer(for: app)
        scanWindows(of: app)
    }

    /// The app's observer, made on first need.
    ///
    /// Attachment used to happen only from the launch and seed paths, both
    /// of which skip `.accessory` apps and the second of which waits 0.6s
    /// after launch. A window tracked before that — an accessory app with
    /// a real window, or any app that activates inside the delay — found
    /// no observer, so its six per-window notifications were never
    /// registered and its frame was captured once and never refreshed
    /// again. Hints then sized themselves to a stale rect, and parking
    /// remembered the wrong frame to restore.
    @discardableResult
    private func observer(for app: NSRunningApplication) -> AppObserver? {
        let pid = app.processIdentifier
        if let existing = observers[pid] { return existing }
        guard let observer = AppObserver(pid: pid, handler: { [weak self] notification, element in
            self?.handle(notification, element: element, pid: pid)
        }) else { return nil }
        observers[pid] = observer
        let axApp = AXApplication(app)
        observer.watch(kAXWindowCreatedNotification, on: axApp.element)
        observer.watch(kAXFocusedWindowChangedNotification, on: axApp.element)
        return observer
    }

    private func detach(_ pid: pid_t) {
        observers[pid]?.invalidate()
        observers.removeValue(forKey: pid)
        for id in windows.values.filter({ $0.pid == pid && $0.isAlive }).map(\.id) {
            bury(id)
        }
    }

    /// Mark a window dead and tell the world — the single path every death
    /// signal funnels into: the destroy notification, app termination,
    /// failed verification, and the window-server sweep.
    private func bury(_ id: CGWindowID) {
        guard var w = windows[id], w.isAlive else { return }
        w.isAlive = false
        w.deadAt = Date()
        windows[id] = w
        // The record keeps its element for life, so the reverse key is
        // derivable — one removal, not a rebuild of the whole map.
        idByElement.removeValue(forKey: ElementKey(element: w.element))
        if focusedID == id { focusedID = nil }
        onDestroyed?(id)
    }

    private func scanWindows(of app: NSRunningApplication) {
        let axApp = AXApplication(app)
        for w in axApp.windows() ?? [] {
            track(element: w.element, app: app)
        }
    }

    @discardableResult
    private func track(element: AXUIElement, app: NSRunningApplication) -> CGWindowID? {
        guard let id = windowID(of: element) else { return nil }
        if windows[id] != nil { return id }
        let ax = AXWindow(element: element)
        let window = Window(
            id: id,
            element: element,
            pid: app.processIdentifier,
            appName: app.localizedName ?? "pid \(app.processIdentifier)",
            bundleID: app.bundleIdentifier,
            title: ax?.title ?? "",
            frame: ax?.frame ?? .zero,
            isMinimized: ax?.isMinimized ?? false,
            isAlive: true,
            lastFocused: nil
        )
        windows[id] = window
        idByElement[ElementKey(element: element)] = id
        onTrace?("track id=\(id) \(window.appName) '\(window.title.prefix(30))' bundle=\(window.bundleID ?? "nil")")
        if let observer = observer(for: app) {
            observer.watch(kAXUIElementDestroyedNotification, on: element)
            observer.watch(kAXTitleChangedNotification, on: element)
            observer.watch(kAXMovedNotification, on: element)
            observer.watch(kAXResizedNotification, on: element)
            observer.watch(kAXWindowMiniaturizedNotification, on: element)
            observer.watch(kAXWindowDeminiaturizedNotification, on: element)
        } else {
            onTrace?("track id=\(id) has no observer — frame will not refresh")
        }
        if !seeding { onCreated?(id) }
        return id
    }

    /// Dead records serve close-vs-hide judgment and history skipping for
    /// a few minutes, then leave — an always-on process must not accumulate
    /// a retained AXUIElement per window ever closed.
    private func pruneDead(olderThan interval: TimeInterval = 300) {
        let cutoff = Date().addingTimeInterval(-interval)
        let expired = windows.filter { !$0.value.isAlive && ($0.value.deadAt ?? .distantPast) < cutoff }
        guard !expired.isEmpty else { return }
        for (id, w) in expired {
            windows.removeValue(forKey: id)
            idByElement.removeValue(forKey: ElementKey(element: w.element))
        }
        onTrace?("pruned \(expired.count) dead record\(expired.count == 1 ? "" : "s")")
    }

    private func syncFocus(of app: NSRunningApplication) {
        pruneDead()
        sweepAgainstWindowServer()
        // No `.regular` filter here, unlike every other attach path, and
        // that is deliberate: Raycast, Tailscale and the system's own auth
        // panels are `.accessory` apps with real windows, and this is the
        // only road by which any of them enters the model.
        //
        // The one app that must never come in by it is this one. Lodestar
        // turns `.regular` and activates itself for the length of a
        // default-browser handover, so its own panel could answer as the
        // focused window, become `focusedWindow`, and from there a layout
        // member — something `lode 0` would tile. Never observed, because a
        // non-activating panel does not answer the application-level focused
        // window query; that is a reason it has not happened, not a reason it
        // cannot. Asked by pid rather than by bundle id on purpose: a
        // `swift build` binary has no bundle identifier at all, and an
        // identity check that answers nil for half the runs we make is the
        // shape of bug that put a loop in the click path.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let ax = AXApplication(app)
        guard let focused = ax.focusedWindow(),
              let id = track(element: focused.element, app: app) else { return }
        setFocus(id)
    }

    private func setFocus(_ id: CGWindowID) {
        if var w = windows[id] {
            w.lastFocused = Date()
            windows[id] = w
        }
        guard focusedID != id else { return }
        focusedID = id
        onFocus?(id)
    }

    // MARK: - Notification handling

    private func handle(_ notification: String, element: AXUIElement, pid: pid_t) {
        switch notification {
        case kAXWindowCreatedNotification:
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            track(element: element, app: app)
        case kAXFocusedWindowChangedNotification:
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            // Track always (this is how tab-revealed windows self-heal into
            // the model), but only a frontmost app's focus is global focus.
            if let id = track(element: element, app: app),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                setFocus(id)
            }
        case kAXUIElementDestroyedNotification:
            guard let id = idByElement[ElementKey(element: element)] else { return }
            onTrace?("destroyed id=\(id) \(windows[id]?.appName ?? "?")")
            bury(id)
        case kAXTitleChangedNotification:
            mutate(element) { w in
                if let title = AXWindow(element: element)?.title { w.title = title }
            }
            if let id = idByElement[ElementKey(element: element)] { onTitleChanged?(id) }
        case kAXMovedNotification, kAXResizedNotification:
            mutate(element) { w in
                if let frame = AXWindow(element: element)?.frame { w.frame = frame }
            }
        case kAXWindowMiniaturizedNotification:
            mutate(element) { $0.isMinimized = true }
        case kAXWindowDeminiaturizedNotification:
            mutate(element) { $0.isMinimized = false }
        default:
            break
        }
    }

    private func mutate(_ element: AXUIElement, _ change: (inout Window) -> Void) {
        guard let id = idByElement[ElementKey(element: element)], var w = windows[id] else { return }
        change(&w)
        windows[id] = w
    }
}
