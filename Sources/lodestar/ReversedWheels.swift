import AppKit
import LodestarCore

/// The Reversed wheels setting's owner: it starts the pieces that turn a
/// ticked source's wheel (`MouseScrollTap`, `WheelListener`) and stops them,
/// by `WheelPlan`, and it tells the Settings page which sources it has
/// heard. Off is off: with nothing ticked and the page closed neither piece
/// runs, and the active tap exists only for a ticked source.
///
/// A scroll is turned only when it is vouched for as a ticked source's, so
/// what this keeps current for the tap is small and exact: the roster ids of
/// the ticked mice, and the pids the ticked apps are running as now. The pids
/// are kept by the workspace's launch and terminate notifications, never read
/// from the callback, which does not know what an app is.
///
/// Main thread, except where a method says it is not.
final class ReversedWheels {
    let tap: MouseScrollTap
    private lazy var listener = WheelListener { [weak self] id, name, stamp in
        self?.heard(device: id, name: name, stamp: stamp)
    }

    /// The page's list or the permission changed: the Settings window draws
    /// again if it is showing.
    var changed: () -> Void = {}
    /// Whether Input Monitoring is granted: a question to the privacy
    /// service, asked off the main thread (`refreshPermission`). Replaced by
    /// the tests, and never asked from a test run.
    var canListen: () -> Bool = TestRun.active ? { false } : { Permissions.canListenToKeyboards }
    /// Asks macOS for Input Monitoring, once a launch: it shows its prompt
    /// only while the question is unanswered, and without the prompt
    /// Lodestar is not on the list the person grants it from. Never asked
    /// from a test run.
    var requestListening: () -> Void = TestRun.active ? {} : { Permissions.requestKeyboardListening() }
    var trusted: () -> Bool = { Permissions.isTrusted }
    /// The ids of the pointing devices attached now, read afresh. A test run
    /// reads none.
    var attached: () -> [String]

    /// Input Monitoring as last read; nil before the first read.
    private(set) var listenGranted: Bool?
    /// What was last asked of the pieces.
    private(set) var applied = WheelPlan(listens: false, tap: .off)

    /// The sources ticked, by id, each with the name it is listed by.
    private var ticked: [String: String] = [:]
    private var discovering = false
    private var asked = false
    /// The apps that matter (ticked, or heard on the page) by the pid each is
    /// running as, read off the workspace's notifications.
    private var running: [pid_t: String] = [:]
    private var observers: [NSObjectProtocol] = []

    /// What has been heard since launch, by id: a mouse turning a wheel on
    /// the listener's thread, an app posting a scroll on the resolver's.
    private let heardLock = NSLock()
    private var heardDevices: [String: String] = [:]
    private var heardApps: [String: String] = [:]

    /// Where the permission is asked and a posting pid is made into an app:
    /// both are service calls, and neither is the main thread's or the tap's.
    private let queue = DispatchQueue(label: "lodestar.mice.resolve", qos: .utility)
    private let news: DispatchSourceUserDataAdd

    init() {
        let roster = PointerRoster()
        attached = TestRun.active ? { [] } : { roster.refresh().map(\.id) }
        let news = DispatchSource.makeUserDataAddSource(queue: queue)
        self.news = news
        tap = MouseScrollTap(noticed: { news.add(data: 1) })
        news.setEventHandler { [weak self] in self?.resolvePosted() }
        news.resume()
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                self?.launched(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                self?.terminated(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            },
        ]
    }

    deinit {
        news.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// The config's word, at launch and on every reload.
    func configure(_ reversed: [String: String]) {
        let changed = reversed != ticked
        ticked = reversed
        if changed { rescan() }
        publish()
        refreshPermission()
    }

    /// The Reversed wheels page is on screen, or it is not: the mice are
    /// listened for while it is, so that it can list them.
    func setDiscovering(_ on: Bool) {
        guard on != discovering else { return }
        discovering = on
        refreshPermission()
        apply()
    }

    /// Run again: Accessibility may have been granted since, and the tap
    /// needs it to turn anything.
    func reconcile() {
        refreshPermission()
    }

    /// The sources the page lists: every one ticked and every one heard
    /// since launch, each with whether it is here now. Asked from the page's
    /// render and its watch; reads the device list afresh, as the Keyboards
    /// page does, and rereads the permission while it is not granted, so that
    /// a grant made in System Settings shows without a relaunch.
    func sources() -> [SettingsModel.Wheel] {
        if listenGranted != true { refreshPermission() }
        let here = Set(attached())
        let live = Set(running.values)
        let (devices, apps) = heardLock.withLock { (heardDevices, heardApps) }
        var names = ticked
        names.merge(devices) { _, heard in heard }
        names.merge(apps) { _, heard in heard }
        return names.map { id, name in
            let present = WheelSource.bundleID(of: id).map(live.contains) ?? here.contains(id)
            return SettingsModel.Wheel(id: id, name: name, present: present)
        }
    }

    // MARK: - The plan

    private func apply() {
        let plan = WheelPlan(ticked: !ticked.isEmpty, discovering: discovering,
                             inputMonitoring: listenGranted == true, accessibility: trusted())
        if plan.listens {
            _ = listener.start()
        } else {
            listener.stop()
        }
        tap.run(plan.tap)
        if plan != applied {
            Log.info("mice: reversed wheels", ["ticked": ticked.count, "listening": listener.isListening,
                                               "tap": tap.isRunning ? (plan.tap == .turn ? "turning" : "listening") : "none"])
        }
        applied = plan
    }

    /// Reads Input Monitoring off the main thread and applies the answer
    /// there (`applyPermission`).
    private func refreshPermission() {
        let canListen = canListen
        queue.async { [weak self] in
            let granted = canListen()
            DispatchQueue.main.async { self?.applyPermission(granted) }
        }
    }

    /// Main. The first time the page is open without the permission macOS is
    /// asked, once a launch; until it is granted nothing is opened.
    func applyPermission(_ granted: Bool) {
        let before = listenGranted
        listenGranted = granted
        if !granted, discovering, !asked {
            asked = true
            let request = requestListening
            queue.async { request() }
        }
        apply()
        if before != granted { changed() }
    }

    /// Tests: every read asked for has been answered.
    func drainForTesting() {
        queue.sync {}
    }

    // MARK: - Who is ticked

    /// The tap's view of the ticked sources: the mice by id and the apps by
    /// the pids they run as. Main.
    private func publish() {
        let apps = Set(ticked.keys.compactMap { WheelSource.bundleID(of: $0) })
        tap.set(devices: Set(ticked.keys.filter { WheelSource.bundleID(of: $0) == nil }),
                pids: Set(running.filter { apps.contains($0.value) }.keys.map(Int64.init)))
    }

    /// The ticked apps already running, found once when the set changes; the
    /// notifications keep them after that.
    private func rescan() {
        let apps = Set(ticked.keys.compactMap { WheelSource.bundleID(of: $0) })
        guard !apps.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            if let bundle = app.bundleIdentifier, apps.contains(bundle) { running[app.processIdentifier] = bundle }
        }
    }

    private func interesting(_ bundle: String) -> Bool {
        let id = WheelSource.app(bundleID: bundle)
        return ticked[id] != nil || heardLock.withLock { heardApps[id] != nil }
    }

    private func launched(_ app: NSRunningApplication?) {
        guard let app, let bundle = app.bundleIdentifier, interesting(bundle) else { return }
        running[app.processIdentifier] = bundle
        publish()
        changed()
    }

    private func terminated(_ app: NSRunningApplication?) {
        guard let app, running.removeValue(forKey: app.processIdentifier) != nil else { return }
        publish()
        changed()
    }

    // MARK: - Who is heard

    /// The listener's thread: a wheel of this device turned. The tap is
    /// told first, with nothing between the report and the lock; the page is
    /// told only the first time a device is heard.
    func heard(device id: String, name: String, stamp: UInt64) {
        tap.hear(device: id, stamp: stamp)
        guard heardLock.withLock({ heardDevices.updateValue(name, forKey: id) == nil }) else { return }
        DispatchQueue.main.async { [weak self] in self?.changed() }
    }

    /// The resolver's queue: apps that posted a scroll no wheel vouched for.
    /// Which app a pid is, is asked here and never in the callback.
    private func resolvePosted() {
        for pid in tap.takePosted() {
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                  let bundle = app.bundleIdentifier else { continue }
            let found = (app.processIdentifier, bundle, app.localizedName ?? bundle)
            DispatchQueue.main.async { [weak self] in self?.heard(app: found.0, bundleID: found.1, name: found.2) }
        }
    }

    /// Main. An app has posted a scroll. Internal so a test can say so.
    func heard(app pid: pid_t, bundleID: String, name: String) {
        let isNew = heardLock.withLock { heardApps.updateValue(name, forKey: WheelSource.app(bundleID: bundleID)) == nil }
        running[pid] = bundleID
        publish()
        if isNew { changed() }
    }
}
