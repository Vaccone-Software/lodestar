import AppKit
import ApplicationServices

/// What the window model asks of accessibility: every one of these is a
/// message to another app, answered when that app's main thread gets to
/// it. The real reader asks; the tests' reader answers on a script, slowly
/// or never, to prove the model never waits on it.
public protocol WindowAXReader: AnyObject, Sendable {
    func windowID(of element: AXUIElement) -> CGWindowID?
    func reading(of element: AXUIElement) -> WindowModel.Reading?
    func title(of element: AXUIElement) -> String?
    func frame(of element: AXUIElement) -> CGRect?
    func windows(of pid: pid_t) -> [AXUIElement]?
    func focusedWindow(of pid: pid_t) -> AXUIElement?
}

/// The real reader: the accessibility API itself.
public final class LiveWindowAXReader: WindowAXReader, @unchecked Sendable {
    public init() {}
    public func windowID(of element: AXUIElement) -> CGWindowID? { LodestarCore.windowID(of: element) }
    public func reading(of element: AXUIElement) -> WindowModel.Reading? {
        guard let ax = AXWindow(element: element) else { return nil }
        return WindowModel.Reading(title: ax.title ?? "", frame: ax.frame ?? .zero,
                                   isMinimized: ax.isMinimized, subrole: ax.subrole)
    }
    public func title(of element: AXUIElement) -> String? { AX.string(element, kAXTitleAttribute) }
    public func frame(of element: AXUIElement) -> CGRect? {
        guard let p = AX.point(element, kAXPositionAttribute), let s = AX.size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }
    public func windows(of pid: pid_t) -> [AXUIElement]? {
        AX.elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute)
    }
    public func focusedWindow(of pid: pid_t) -> AXUIElement? {
        AX.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }
}

/// The cached window model — the resolver's ground truth.
///
/// Slice 0 proved polling cannot work: tab-hidden windows vanish from
/// kAXWindows, dead windows linger in CG lists app-dependently, and
/// synchronous scans stall on hung apps. So windows are discovered through
/// notifications, their AX elements are retained for life, and liveness comes
/// from kAXUIElementDestroyed — never from re-enumeration. Focus changes
/// self-heal the model: any window revealed from a tab arrives through the
/// focused-window notification and gets tracked then.
///
/// The model lives on the main thread, and what it learns by asking other
/// apps is asked on a queue per app. Tracking a window is about eleven
/// messages to its app — a bridge to the window-server id, title, frame,
/// minimized, subrole, six registrations — and these ran on the main
/// thread the key tap shares: at launch for every window of every app, and
/// all day for every window an app created (Brave's hover cards, about 180
/// a day), every title change and every move. A hung app answered each one
/// at the accessibility timeout, and the watchdog aborted the app five
/// times in three weeks. Now nothing the model hears about by notification
/// is read on main: the reading happens on the app's queue — one hung app
/// holds up only its own windows — and the record is applied on main, so
/// every read of `windows` stays where it always was. The reads a gesture
/// needs answered now (`bestWindow`, `refocusFrontmost`, `verify`) still
/// ask on main, bounded by the process-wide timeout.
public final class WindowModel {
    /// What one reading of a window says.
    public struct Reading: Sendable {
        public var title: String
        public var frame: CGRect
        public var isMinimized: Bool
        public var subrole: String?
        public init(title: String, frame: CGRect, isMinimized: Bool, subrole: String?) {
            self.title = title
            self.frame = frame
            self.isMinimized = isMinimized
            self.subrole = subrole
        }
    }

    /// Who an app is, without asking it: name and bundle come from the
    /// workspace, not from accessibility.
    public struct AppInfo: Sendable {
        public let pid: pid_t
        public let name: String
        public let bundleID: String?
        public init(pid: pid_t, name: String, bundleID: String?) {
            self.pid = pid
            self.name = name
            self.bundleID = bundleID
        }
        public init(_ app: NSRunningApplication) {
            self.init(pid: app.processIdentifier, name: app.localizedName ?? "pid \(app.processIdentifier)",
                      bundleID: app.bundleIdentifier)
        }
    }

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
    /// Who is in front, for a fresh ask. A closure so the scenario harness,
    /// whose world never touches a real window, can answer nobody.
    public var frontmostApp: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    /// The pid in front, for the focus checks. Its own seam, because a test
    /// cannot make an `NSRunningApplication` for a pid it chose.
    public lazy var frontmostPid: () -> pid_t? = { [unowned self] in self.frontmostApp()?.processIdentifier }

    private var observers: [pid_t: AppObserver] = [:]

    /// The per-window registrations, named once so the watch at track time
    /// and the unwatch at burial can never drift apart.
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXMovedNotification,
        kAXResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]
    private var idByElement: [ElementKey: CGWindowID] = [:]
    private var workspaceTokens: [any NSObjectProtocol] = []

    private let reader: WindowAXReader
    /// The app behind a pid, for a notification that names only the pid.
    private let appLookup: (pid_t) -> AppInfo?
    /// One serial queue per app: its reads keep their order, and a hung
    /// app delays nobody else's.
    private var queues: [pid_t: DispatchQueue] = [:]
    /// Elements being read, with what to do once each is tracked.
    private var pendingTracks: [ElementKey: [(CGWindowID) -> Void]] = [:]
    /// Elements destroyed while their reading was out: never tracked.
    private var destroyedWhilePending: Set<ElementKey> = []
    /// Windows whose frame is being read: a burst of moves reads once.
    /// Windows whose frame is being read, and whether another move came
    /// in while it was: that one is read again when the first lands, or a
    /// drag that ended during the read left the frame where the read found
    /// it — hints sized to the old rect, parking keeping the wrong one.
    private var pendingFrames: [CGWindowID: Bool] = [:]
    /// Focus notices, numbered. A reading applies focus only if no newer
    /// notice came while it was out: a known window's focus applies at
    /// once and a new one's when its reading lands, so A, then a new N,
    /// then A again used to end on N.
    private var focusSerial = 0
    /// The launch scan: apps still being read, and when it began.
    private var seedsOutstanding = 0
    private var seedStarted = Date()

    public init(reader: WindowAXReader = LiveWindowAXReader(),
                appLookup: @escaping (pid_t) -> AppInfo? = { pid in
                    NSRunningApplication(processIdentifier: pid).map(AppInfo.init)
                }) {
        self.reader = reader
        self.appLookup = appLookup
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "lodestar.model.\(pid)", qos: .userInitiated)
        queues[pid] = queue
        return queue
    }

    public func start() {
        // The initial scan is discovery, not creation — onCreated stays
        // quiet so nothing treats the existing world as newly arrived. It
        // runs on the apps' queues: launch no longer waits on every window
        // of every app before the key tap can answer.
        seedStarted = Date()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            seedsOutstanding += 1
            attach(AppInfo(app), seeding: true)
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            // A freshly launched app needs a moment to stand up its AX tree.
            let info = AppInfo(app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.attach(info, seeding: false)
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
        if let app = appLookup(pid), let focused = reader.focusedWindow(of: pid),
           let id = trackNow(element: focused, app: app) {
            return windows[id]
        }
        // Last-focused, then newest — never dictionary order: a hung app
        // that cannot answer for its focused window must still summon the
        // same window every time (FINDINGS §8).
        return Self.mostCurrent(windows.values.filter { $0.isAlive && $0.pid == pid })
    }

    /// A window put in front by hand: the scenario harness's, whose world
    /// never touches a real one. Tracked as alive and focused, nothing
    /// watched.
    public func stand(_ window: Window) {
        windows[window.id] = window
        setFocus(window.id)
    }

    /// The focused window for an action about to use it: the model's, if
    /// its handle still answers; otherwise asked of the frontmost app
    /// afresh. The model hears about focus by notification, and a window
    /// whose element dies under it (Zoom, mid-meeting) never sends one.
    public func focusedWindowNow() -> Window? {
        if let w = focusedWindow, verify(w.id) { return w }
        return refocusFrontmost()
    }

    /// Ask the frontmost app, right now, which window is focused, and
    /// track it: first by its own answer, then — when it names none,
    /// which Zoom also does mid-meeting — by walking its AX windows and
    /// taking the one the window server lists on top. Both routes bridge
    /// through the same private call and come back with the same id, so
    /// breaths, index jumps and undo keep the window they knew.
    public func refocusFrontmost() -> Window? {
        guard let running = frontmostApp(),
              running.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AppInfo(running)
        let ax = AXApplication(running)
        if let focused = ax.focusedWindow(), let id = trackNow(element: focused.element, app: app), verify(id) {
            onTrace?("refocus id=\(id) \(windows[id]?.appName ?? "?") via=focused")
            setFocus(id)
            return windows[id]
        }
        guard let axWindows = ax.windows(), !axWindows.isEmpty else { return nil }
        let pid = app.pid
        let onTop = CGWindows.list(onScreenOnly: true).filter { $0.pid == pid && $0.layer == 0 }.map(\.id)
        let bridged = axWindows.compactMap { w in windowID(of: w.element).map { ($0, w.element) } }
        for id in onTop {
            guard let (_, element) = bridged.first(where: { $0.0 == id }),
                  let tracked = trackNow(element: element, app: app), verify(tracked) else { continue }
            onTrace?("refocus id=\(tracked) \(windows[tracked]?.appName ?? "?") via=top")
            setFocus(tracked)
            return windows[tracked]
        }
        return nil
    }

    /// Re-read one app's windows now, on its queue, and take what is true
    /// into the model: each title as it stands, a fresh element for a known
    /// window (so its title notifications reach the model again), and any
    /// window never tracked. Titles arrive by notification, and a window
    /// whose element the app replaced keeps the title it had when the old
    /// element stopped speaking: a browser profile matched by its title
    /// then looked absent, and a new window was opened beside the old one.
    /// `completion` runs on main when every running instance has answered.
    public func refreshWindows(bundleID: String, completion: @escaping () -> Void) {
        refreshWindows(pids: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier), completion: completion)
    }

    func refreshWindows(pids: [pid_t], completion: @escaping () -> Void) {
        guard !pids.isEmpty else { completion(); return }
        var remaining = pids.count
        let reader = self.reader
        for pid in pids {
            queue(for: pid).async { [weak self] in
                let read: [(CGWindowID, AXUIElement, Reading?)] = (reader.windows(of: pid) ?? []).compactMap {
                    guard let id = reader.windowID(of: $0) else { return nil }
                    return (id, $0, reader.reading(of: $0))
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let app = self.appLookup(pid) {
                        for (id, element, reading) in read { self.adopt(id: id, element: element, app: app, reading: reading) }
                    }
                    remaining -= 1
                    if remaining == 0 { completion() }
                }
            }
        }
    }

    /// One fresh reading of a window taken in. Main only.
    private func adopt(id: CGWindowID, element: AXUIElement, app: AppInfo, reading: Reading?) {
        guard let known = windows[id], known.isAlive else {
            _ = record(id: id, element: element, app: app, reading: reading, seeding: false)
            return
        }
        if ElementKey(element: known.element) != ElementKey(element: element) {
            revive(id, element: element, app: app, reading: reading, lastFocused: known.lastFocused)
            return
        }
        if let title = reading?.title, title != known.title {
            var updated = known
            updated.title = title
            windows[id] = updated
        }
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

    /// The app's observer made, its app-level notifications registered and
    /// its windows read — all on the app's queue; each window found is
    /// tracked as its reading lands.
    private func attach(_ app: AppInfo, seeding: Bool) {
        let observer = observer(for: app)
        let reader = self.reader
        queue(for: app.pid).async { [weak self] in
            if let observer {
                let appElement = AXUIElementCreateApplication(app.pid)
                observer.watch(kAXWindowCreatedNotification, on: appElement)
                observer.watch(kAXFocusedWindowChangedNotification, on: appElement)
            }
            let elements = reader.windows(of: app.pid) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                for element in elements { self.track(element: element, app: app, seeding: seeding) }
                if seeding { self.seedFinished(app) }
            }
        }
    }

    /// One app's launch scan is in; when the last is, say how long it took.
    private func seedFinished(_ app: AppInfo) {
        seedsOutstanding -= 1
        guard seedsOutstanding == 0 else { return }
        // The windows found are still being read; the count is of those
        // tracked by now plus those on their way.
        let tracked = windows.values.filter(\.isAlive).count
        onTrace?("seeded \(tracked) windows, \(pendingTracks.count) reading, ms=\(Int(Date().timeIntervalSince(seedStarted) * 1000))")
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
    ///
    /// Made on main (making one asks nothing of the app); what it watches
    /// is registered on the app's queue by whoever asked for it.
    @discardableResult
    private func observer(for app: AppInfo) -> AppObserver? {
        let pid = app.pid
        if let existing = observers[pid] { return existing }
        guard let observer = AppObserver(pid: pid, handler: { [weak self] notification, element in
            self?.handle(notification, element: element, pid: pid)
        }) else { return nil }
        observers[pid] = observer
        let appElement = AXUIElementCreateApplication(pid)
        queue(for: pid).async {
            observer.watch(kAXWindowCreatedNotification, on: appElement)
            observer.watch(kAXFocusedWindowChangedNotification, on: appElement)
        }
        return observer
    }

    private func detach(_ pid: pid_t) {
        observers[pid]?.invalidate()
        observers.removeValue(forKey: pid)
        for id in windows.values.filter({ $0.pid == pid && $0.isAlive }).map(\.id) {
            bury(id)
        }
        queues.removeValue(forKey: pid)
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
        // derivable — one removal, not a rebuild of the whole map. The
        // observer registrations do NOT keep theirs: six per window ever
        // created, held in the observer's own table, is the accumulation
        // pruneDead exists to prevent, one layer down. Dropping them is a
        // message to the app, so it goes on the app's queue.
        if let observer = observers[w.pid] {
            let element = w.element
            queue(for: w.pid).async {
                for notification in Self.windowNotifications {
                    observer.unwatch(notification, on: element)
                }
            }
        }
        idByElement.removeValue(forKey: ElementKey(element: w.element))
        if focusedID == id { focusedID = nil }
        onDestroyed?(id)
    }

    /// Track a window heard about by notification: read on the app's
    /// queue, recorded here when the reading lands. `then` runs with the
    /// id once it is tracked — at once, when it already is.
    private func track(element: AXUIElement, app: AppInfo, seeding: Bool = false,
                       then: ((CGWindowID) -> Void)? = nil) {
        let key = ElementKey(element: element)
        if let id = idByElement[key], windows[id]?.isAlive == true {
            then?(id)
            return
        }
        if pendingTracks[key] != nil {
            if let then { pendingTracks[key]?.append(then) }
            return
        }
        pendingTracks[key] = then.map { [$0] } ?? []
        let reader = self.reader
        queue(for: app.pid).async { [weak self] in
            let id = reader.windowID(of: element)
            let reading = id == nil ? nil : reader.reading(of: element)
            DispatchQueue.main.async {
                guard let self else { return }
                let waiting = self.pendingTracks.removeValue(forKey: key) ?? []
                // Destroyed while it was being read: it never existed here.
                if self.destroyedWhilePending.remove(key) != nil { return }
                guard let id, let tracked = self.record(id: id, element: element, app: app,
                                                        reading: reading, seeding: seeding) else { return }
                for callback in waiting { callback(tracked) }
            }
        }
    }

    /// Track a window a gesture needs now: read here, on main.
    @discardableResult
    private func trackNow(element: AXUIElement, app: AppInfo) -> CGWindowID? {
        guard let id = reader.windowID(of: element) else { return nil }
        if let known = windows[id], known.isAlive { return id }
        return record(id: id, element: element, app: app, reading: reader.reading(of: element), seeding: false)
    }

    /// A reading made into a record: a new window, or a known id taken
    /// over by a fresh element (`revive`). Main only.
    private func record(id: CGWindowID, element: AXUIElement, app: AppInfo, reading: Reading?,
                        seeding: Bool) -> CGWindowID? {
        if let known = windows[id] {
            if known.isAlive { return id }
            revive(id, element: element, app: app, reading: reading, lastFocused: known.lastFocused)
            return id
        }
        let window = Window(
            id: id,
            element: element,
            pid: app.pid,
            appName: app.name,
            bundleID: app.bundleID,
            title: reading?.title ?? "",
            frame: reading?.frame ?? .zero,
            isMinimized: reading?.isMinimized ?? false,
            isAlive: true,
            lastFocused: nil
        )
        windows[id] = window
        idByElement[ElementKey(element: element)] = id
        // Subrole and layer ride along so the log can say which of the
        // windows the model counts a person would call one — the picker,
        // the toast and the toolbar carry other subroles and other layers.
        onTrace?("track id=\(id) \(window.appName) '\(window.title.prefix(30))' bundle=\(window.bundleID ?? "nil") subrole=\((reading?.subrole ?? "?").replacingOccurrences(of: "AX", with: "")) layer=\(CGWindows.layer(of: id).map(String.init) ?? "?")")
        watch(element, app: app, id: id)
        if !seeding { onCreated?(id) }
        return id
    }

    /// The six per-window registrations, on the app's queue.
    private func watch(_ element: AXUIElement, app: AppInfo, id: CGWindowID) {
        guard let observer = observer(for: app) else {
            onTrace?("track id=\(id) has no observer — frame will not refresh")
            return
        }
        queue(for: app.pid).async {
            for notification in Self.windowNotifications {
                observer.watch(notification, on: element)
            }
        }
    }

    /// A window that outlived its handle. Zoom rebuilds its accessibility
    /// tree during a meeting: the meeting window keeps its window-server
    /// id while the element the model holds for it goes dead, `verify`
    /// buries the record, and no focus-changed notification ever fires,
    /// because from Zoom's side focus never moved. A buried record keeps
    /// its id until pruneDead, so a fresh element for a known id was
    /// ignored for minutes (seven, in the log of 2026-09-14's 11:00
    /// meeting); now it takes the record over, alive.
    private func revive(_ id: CGWindowID, element: AXUIElement, app: AppInfo, reading: Reading?,
                        lastFocused: Date?) {
        let window = Window(
            id: id,
            element: element,
            pid: app.pid,
            appName: app.name,
            bundleID: app.bundleID,
            title: reading?.title ?? "",
            frame: reading?.frame ?? .zero,
            isMinimized: reading?.isMinimized ?? false,
            isAlive: true,
            lastFocused: lastFocused
        )
        windows[id] = window
        idByElement[ElementKey(element: element)] = id
        onTrace?("revive id=\(id) \(window.appName) '\(window.title.prefix(30))' — a fresh element for a known window")
        watch(element, app: app, id: id)
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
        let info = AppInfo(app)
        let reader = self.reader
        focusSerial += 1
        let serial = focusSerial
        queue(for: info.pid).async { [weak self] in
            let focused = reader.focusedWindow(of: info.pid)
            DispatchQueue.main.async {
                guard let self, let focused else { return }
                self.track(element: focused, app: info) { [weak self] id in
                    // Still the app in front, and still the latest word on
                    // focus, when the answer lands.
                    guard let self, serial == self.focusSerial,
                          self.frontmostPid() == info.pid else { return }
                    self.setFocus(id)
                }
            }
        }
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
            guard let app = appLookup(pid) else { return }
            track(element: element, app: app)
        case kAXFocusedWindowChangedNotification:
            guard let app = appLookup(pid) else { return }
            // Track always (this is how tab-revealed windows self-heal into
            // the model), but only a frontmost app's focus is global focus —
            // asked when the reading lands, not when the news came — and only
            // if no later notice has spoken since.
            focusSerial += 1
            let serial = focusSerial
            track(element: element, app: app) { [weak self] id in
                guard let self, serial == self.focusSerial,
                      self.frontmostPid() == pid else { return }
                self.setFocus(id)
            }
        case kAXUIElementDestroyedNotification:
            let key = ElementKey(element: element)
            if let id = idByElement[key] {
                onTrace?("destroyed id=\(id) \(windows[id]?.appName ?? "?")")
                bury(id)
            } else if pendingTracks[key] != nil {
                destroyedWhilePending.insert(key)
            }
        case kAXTitleChangedNotification:
            guard let id = idByElement[ElementKey(element: element)] else { return }
            let reader = self.reader
            queue(for: pid).async { [weak self] in
                let title = reader.title(of: element)
                DispatchQueue.main.async {
                    guard let self, var w = self.windows[id], w.isAlive else { return }
                    if let title { w.title = title }
                    self.windows[id] = w
                    self.onTitleChanged?(id)
                }
            }
        case kAXMovedNotification, kAXResizedNotification:
            guard let id = idByElement[ElementKey(element: element)] else { return }
            if pendingFrames[id] != nil {
                pendingFrames[id] = true
                return
            }
            readFrame(id, element: element, pid: pid)
        case kAXWindowMiniaturizedNotification:
            mutate(element) { $0.isMinimized = true }
        case kAXWindowDeminiaturizedNotification:
            mutate(element) { $0.isMinimized = false }
        default:
            break
        }
    }

    /// A window's frame, read on its app's queue. A move that came in while
    /// the read was out marks it dirty, and it is read once more.
    private func readFrame(_ id: CGWindowID, element: AXUIElement, pid: pid_t) {
        pendingFrames[id] = false
        let reader = self.reader
        queue(for: pid).async { [weak self] in
            let frame = reader.frame(of: element)
            DispatchQueue.main.async {
                guard let self else { return }
                let dirty = self.pendingFrames.removeValue(forKey: id) ?? false
                if let frame, var w = self.windows[id], w.isAlive {
                    w.frame = frame
                    self.windows[id] = w
                }
                if dirty, self.windows[id]?.isAlive == true { self.readFrame(id, element: element, pid: pid) }
            }
        }
    }

    /// Tests: a notification as the observer would deliver it.
    public func receiveForTesting(_ notification: String, element: AXUIElement, pid: pid_t) {
        handle(notification, element: element, pid: pid)
    }

    private func mutate(_ element: AXUIElement, _ change: (inout Window) -> Void) {
        guard let id = idByElement[ElementKey(element: element)], var w = windows[id] else { return }
        change(&w)
        windows[id] = w
    }
}
