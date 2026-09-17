import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.ps
import LodestarCore

/// The hands' pulse, gathered: keystroke counts arrive from the main event
/// tap (which already sees every key), clicks, motion and scroll bursts
/// from a listen-only tap of its own. All accumulation happens in
/// `HealthPulse`, `ClickPulse` and `PointerTracker` (core, tested); this
/// class is the plumbing and the gate.
///
/// **No tap callback ever takes a lock.** Every entry point — the key
/// tap's on main, the mouse tap's on its own thread — copies the few
/// fields it needs off the event and hands them to one serial queue,
/// which owns every piece of mutable state here. There is nothing to
/// deadlock on because there is nothing to lock: the first click after
/// boot once took the monitor's lock and then asked the lid under the
/// same lock, and the tap thread waited on itself, the main thread on
/// the tap, and the system switched the key tap off for not answering.
/// A callback that only enqueues cannot do that, whatever is added to
/// the work behind it later. Events leave for the observation store on
/// the main thread, which is where that store lives.
///
/// Provenance discipline matches the coach's: only hardware-origin events
/// count as the hand's. Posted clicks — the click door's own pointer walk
/// first among them — are counted apart, as what the tool did.
final class HealthMonitor {
    /// Where pulses land. Set once at boot. Touched on main only.
    var observations: ObservationStore?

    /// What the shell knows at a window's close that the presses do not.
    struct WindowContext {
        var app: String?
        var dictation: Bool
    }
    var context: (() -> WindowContext)?
    /// A click is a road a focus change can take; the tracker hears
    /// about it here, from the same tap that prices it.
    var roads: RoadTracker?
    /// The harness turns the real mouse tap off: a test process listening
    /// to the person's actual mouse is not a test.
    var listensToTheMouse = true

    /// Owns the state below. Serial, utility: a keystroke never waits on
    /// it, and nothing on it ever waits on a tap.
    private let queue = DispatchQueue(label: "lodestar.health", qos: .utility)
    // MARK: Queue-owned state
    private var pulse = HealthPulse()
    private var clickPulse = ClickPulse()
    private var window = HoldWindow()
    private var tracker = PointerTracker()
    private var pendingClicks: [PendingClick] = []
    private var pendingPosted: [Date] = []
    private var pendingReleases: [PendingRelease] = []
    private var pendingReturns: [PendingReturn] = []
    private var pendingScrolls: [PendingScroll] = []
    private var lastKeyAt: Date?
    private var lastMouseAt: Date?
    private var lastDownAt: Date?
    private var lastDownButton = 0
    private var lastPressure: (stage: Int, pressure: Double, at: Date)?
    private var sampledRole: String?
    private var lidCached: Bool?
    private var lidAt = Date.distantPast
    private var pressureSamples = 0

    /// The raw records beneath every summary, and the era file, beside
    /// the directory the monitor is given — the real one in the app, a
    /// scratch one in a test — never at a global default.
    private let keys: KeyStore
    private let pointerStore: PointerStore
    private let roster = KeyboardRoster()
    private let pointers = PointerRoster()
    private let eras: EraTracker
    private let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)

    init(directory: URL = Paths.data) {
        let install = Install.id(in: directory)
        keys = KeyStore(directory: directory.appendingPathComponent(KeyStore.subdirectory, isDirectory: true),
                        installID: install)
        pointerStore = PointerStore(directory: directory.appendingPathComponent(PointerStore.subdirectory, isDirectory: true),
                                    installID: install)
        eras = EraTracker(file: directory.appendingPathComponent("era.json"))
    }

    // Main-thread state.
    private var enabled = false
    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var flushTimer: Timer?
    private var pressureMonitor: Any?

    /// A click with its target's class resolved: the pid the element
    /// belongs to and its accessibility role. Nothing else about the
    /// target is ever read. The act is the reach that ended in it.
    private struct PendingClick {
        let at: Date
        let trip: Bool
        let pid: pid_t?
        let role: String?
        let act: PointerTracker.Click
    }

    private struct PendingRelease {
        let downAt: Date
        let release: PointerTracker.Release
    }

    private struct PendingReturn {
        let downAt: Date
        let seconds: Double
    }

    /// One wheel burst: opened by its first event, extended by each one
    /// inside the gap, closed by the drain once the gap has passed.
    private struct PendingScroll {
        let start: Date
        var last: Date
        var pid: pid_t?
        var precise: Bool
        var momentum: Bool
        let device: PointerStore.DeviceKind
        let index: Int
    }

    /// What a tap callback copies off the event before it returns.
    struct MouseReport {
        var type: CGEventType
        var at: Date
        var location: CGPoint
        var human: Bool
        var postingPID: Int64
        var button: Int
        var dx: Double
        var dy: Double
        var precise: Bool
        var momentum: Bool

        init(type: CGEventType, event: CGEvent, now: Date = Date()) {
            self.type = type
            at = EventTime.date(of: event) ?? now
            location = event.location
            postingPID = event.getIntegerValueField(.eventSourceUnixProcessID)
            human = Coach.isHumanOrigin(sourceStateID: event.getIntegerValueField(.eventSourceStateID),
                                        postingPID: postingPID)
            button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        }
    }

    /// Where a click's target is asked for. Off every tap: the
    /// accessibility call blocks on the clicked app's event loop.
    private let lookup = DispatchQueue(label: "lodestar.health.lookup", qos: .utility)
    private lazy var systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    // MARK: - Switch

    /// Config's word: `observations.health`, joined with the master
    /// switch by the caller. Main thread.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            if listensToTheMouse {
                startMouseTap()
                startPressureMonitor()
            }
            startFlushTimer()
            checkEra()
        } else {
            stopMouseTap()
            stopPressureMonitor()
            flushTimer?.invalidate()
            flushTimer = nil
            flush()
        }
    }

    /// Shutdown, and the switch going off: everything in flight lands
    /// before this returns. Main thread. The queue is asked once,
    /// synchronously; nothing on it ever waits on main, so this cannot
    /// deadlock either.
    func flush() {
        var events: [ObservationEvent] = []
        var windows: [WindowStats] = []
        queue.sync {
            events.append(contentsOf: drainPendingLocked(all: true))
            if let final = pulse.flush() { events.append(dressedLocked(final)) }
            events.append(contentsOf: clickPulse.flush())
            if let closed = window.close() { windows.append(closed) }
            keys.flushSync()
            pointerStore.flushSync()
        }
        for event in events { deliver(event) }
        for stats in windows { deliverWindow(stats) }
    }

    // MARK: - The key side (entry points on main, work on the queue)

    /// A hardware keystroke, from the main tap. An autorepeat keydown
    /// counts as the hand being present and nothing more.
    func noteKey(backspace: Bool, autorepeat: Bool = false, at now: Date = Date()) {
        guard enabled else { return }
        queue.async { [self] in
            if !autorepeat {
                lastKeyAt = now
                if let seconds = tracker.keyed(at: now), let down = lastDownAt {
                    pendingReturns.append(PendingReturn(downAt: down, seconds: seconds))
                }
            }
            if let flushed = pulse.key(at: now, backspace: backspace, autorepeat: autorepeat) {
                emitPulse(flushed)
            }
        }
    }

    /// A hardware press, complete: the raw store keeps it, the window
    /// describes it. The shell adds which keyboard, by the roster and
    /// the lid, before either sees it.
    func notePress(_ press: KeyPress) {
        guard enabled else { return }
        queue.async { [self] in
            var press = press
            let lid = lidClosedLocked(now: press.down)
            press.lid = lid ?? false
            press.keyboard = roster.attribute(lidClosed: lid)
            keys.append(press, roster: roster.ids)
            if let closed = window.add(press) { emitWindow(closed) }
            if window.count == 1 { sampleRole() }
        }
    }

    /// A press released, and how long it was held.
    func noteHold(_ seconds: Double, at now: Date = Date()) {
        guard enabled else { return }
        queue.async { [self] in
            if let flushed = pulse.hold(seconds, at: now) { emitPulse(flushed) }
        }
    }

    /// How late the tap ran after the event's stamp.
    func noteJitter(_ seconds: Double, at now: Date = Date()) {
        guard enabled else { return }
        queue.async { [self] in
            if let flushed = pulse.jitter(seconds, at: now) { emitPulse(flushed) }
        }
    }

    func noteTapReset(at now: Date = Date()) {
        guard enabled else { return }
        queue.async { [self] in
            if let flushed = pulse.tapReset(at: now) { emitPulse(flushed) }
        }
    }

    // MARK: - The mouse side (entry point on the tap thread, work on the queue)

    /// Tap thread. Copies the fields and returns; nothing here can block.
    /// Internal so the harness can drive it.
    func sawMouse(type: CGEventType, event: CGEvent) {
        let report = MouseReport(type: type, event: event)
        queue.async { [self] in process(report) }
    }

    /// The harness's door: the same report a tap would have made.
    func saw(_ report: MouseReport) {
        queue.async { [self] in process(report) }
    }

    /// Wait for everything queued so far — tests only.
    func drainForTesting() {
        queue.sync {}
    }

    private static let downTypes: Set<CGEventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// Queue.
    private func process(_ r: MouseReport) {
        guard r.human else {
            // Not the hand's. A posted press is still counted — as the
            // tool's, apart from the hand's — and written down with who
            // posted it, so the pointer load can be read either way.
            guard Self.downTypes.contains(r.type) else { return }
            pendingPosted.append(r.at)
            pointerStore.append(.click(at: r.at, button: r.button,
                                       source: r.postingPID == ownPID ? .lodestar : .posted,
                                       device: .unknown, index: 0, stage: 0, pressure: 0),
                                roster: pointers.ids)
            return
        }
        switch r.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // The device's own counts, before the acceleration curve.
            tracker.moved(to: r.location, dx: r.dx, dy: r.dy, at: r.at)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let release = tracker.up(at: r.location, at: r.at), let down = lastDownAt {
                pendingReleases.append(PendingRelease(downAt: down, release: release))
                pointerStore.append(.release(at: r.at, button: lastDownButton, press: release.press),
                                    roster: pointers.ids)
            }
        case .scrollWheel:
            lastMouseAt = r.at
            // Coalesced here: hundreds of wheel events per flick, one
            // burst is all the pulse counts; its length is what it times.
            if let open = pendingScrolls.last,
               r.at.timeIntervalSince(open.last) <= HealthPulse.scrollBurstGap {
                let index = pendingScrolls.count - 1
                pendingScrolls[index].last = r.at
                pendingScrolls[index].precise = pendingScrolls[index].precise || r.precise
                pendingScrolls[index].momentum = pendingScrolls[index].momentum || r.momentum
            } else {
                let on = deviceLocked(pressureAt: r.precise ? r.at : nil, now: r.at)
                pendingScrolls.append(PendingScroll(start: r.at, last: r.at, pid: nil,
                                                    precise: r.precise, momentum: r.momentum,
                                                    device: on.kind, index: on.index))
                let start = r.at
                let location = r.location
                lookup.async { [weak self] in
                    guard let self else { return }
                    let pid = self.pid(at: location)
                    self.queue.async {
                        if let index = self.pendingScrolls.firstIndex(where: { $0.start == start }) {
                            self.pendingScrolls[index].pid = pid
                        }
                    }
                }
            }
        default:
            let trip: Bool
            if let key = lastKeyAt { trip = key > (lastMouseAt ?? .distantPast) } else { trip = false }
            lastMouseAt = r.at
            lastDownAt = r.at
            lastDownButton = r.button
            let act = tracker.down(at: r.location, at: r.at)
            roads?.clicked(at: r.at)
            // The raw record: the reach that ended here, then the press.
            if let motion = act.motion, let start = motion.origin, motion.count > 0 {
                pointerStore.append(.reach(start: start, screen: Environment.screenIndex(of: r.location),
                                           samples: motion.samples, end: r.at),
                                    roster: pointers.ids)
            }
            let pressure = lastPressure
            let on = deviceLocked(pressureAt: pressure?.at, now: r.at)
            let staged = pressure.map { r.at.timeIntervalSince($0.at) <= 0.5 } ?? false
            pointerStore.append(.click(at: r.at, button: r.button, source: .human,
                                       device: on.kind, index: on.index,
                                       stage: staged ? (pressure?.stage ?? 0) : 0,
                                       pressure: staged ? (pressure?.pressure ?? 0) : 0),
                                roster: pointers.ids)
            let location = r.location
            let at = r.at
            lookup.async { [weak self] in
                guard let self else { return }
                var element: AXUIElement?
                var pid: pid_t = 0
                var role: String?
                if AXUIElementCopyElementAtPosition(self.systemWide, Float(location.x),
                                                    Float(location.y), &element) == .success,
                   let element {
                    if AXUIElementGetPid(element, &pid) != .success { pid = 0 }
                    role = AX.string(element, kAXRoleAttribute)
                }
                self.queue.async {
                    self.pendingClicks.append(PendingClick(at: at, trip: trip,
                                                           pid: pid > 0 ? pid : nil, role: role,
                                                           act: act))
                }
            }
        }
    }

    /// Queue. The pointing device a press was on, and which roster
    /// entry: the trackpad when a pressure stage preceded it or nothing
    /// external is attached; the one external device when there is
    /// exactly one; otherwise unknown, said plainly.
    private func deviceLocked(pressureAt: Date?, now: Date) -> (kind: PointerStore.DeviceKind, index: Int) {
        let lid = lidClosedLocked(now: now)
        if let pressureAt, now.timeIntervalSince(pressureAt) <= 0.5 {
            return (.trackpad, pointers.attribute(lidClosed: lid, builtIn: true))
        }
        let devices = pointers.current(now: now)
        let external = devices.filter { !$0.builtIn }
        if external.isEmpty, !devices.isEmpty {
            return (.trackpad, pointers.attribute(lidClosed: lid, builtIn: true))
        }
        if external.count == 1 {
            return (.mouse, pointers.attribute(lidClosed: lid, builtIn: false))
        }
        return (.unknown, 0)
    }

    /// Queue. The lid, cached for half a minute.
    private func lidClosedLocked(now: Date) -> Bool? {
        if now.timeIntervalSince(lidAt) < DeviceRoster.cacheSeconds { return lidCached }
        lidCached = Lid.isClosed()
        lidAt = now
        return lidCached
    }

    /// Queue. Ferry the pending mouse acts into the pulses; a click
    /// younger than the return ceiling stays pending so the key that
    /// follows it can still join; a wheel burst stays open until its gap
    /// has passed. Returns the events to deliver.
    private func drainPendingLocked(all: Bool = false, now: Date = Date()) -> [ObservationEvent] {
        var out: [ObservationEvent] = []
        let holdClicks = all ? Date.distantFuture : now.addingTimeInterval(-PointerTracker.returnCeiling)
        let clicks = pendingClicks.filter { $0.at < holdClicks }
        pendingClicks.removeAll { $0.at < holdClicks }
        let releases = pendingReleases.filter { $0.downAt < holdClicks }
        pendingReleases.removeAll { $0.downAt < holdClicks }
        let returns = pendingReturns.filter { $0.downAt < holdClicks }
        pendingReturns.removeAll { $0.downAt < holdClicks }
        let posted = pendingPosted
        pendingPosted.removeAll()
        let scrollClose = all ? Date.distantFuture : now.addingTimeInterval(-HealthPulse.scrollBurstGap)
        let scrolls = pendingScrolls.filter { $0.last < scrollClose }
        pendingScrolls.removeAll { $0.last < scrollClose }
        let releaseByStamp = Dictionary(releases.map { ($0.downAt, $0.release) }, uniquingKeysWith: { a, _ in a })
        let returnByStamp = Dictionary(returns.map { ($0.downAt, $0.seconds) }, uniquingKeysWith: { a, _ in a })
        for at in posted {
            if let flushed = pulse.postedClick(at: at) { out.append(dressedLocked(flushed)) }
        }
        for click in clicks {
            if let flushed = pulse.click(at: click.at) { out.append(dressedLocked(flushed)) }
            let app = Self.appName(click.pid)
            out.append(contentsOf: clickPulse.click(app: app, role: click.role, trip: click.trip,
                                                    act: click.act, at: click.at))
            if let release = releaseByStamp[click.at] {
                out.append(contentsOf: clickPulse.released(app: app, release, at: click.at))
            }
            if let seconds = returnByStamp[click.at] {
                out.append(contentsOf: clickPulse.returned(app: app, seconds: seconds, at: click.at))
            }
        }
        for burst in scrolls {
            if let flushed = pulse.scroll(from: burst.start, to: burst.last,
                                          precise: burst.precise, momentum: burst.momentum) {
                out.append(dressedLocked(flushed))
            }
            out.append(contentsOf: clickPulse.scroll(app: Self.appName(burst.pid),
                                                     seconds: burst.last.timeIntervalSince(burst.start),
                                                     at: burst.start))
            pointerStore.append(.scroll(start: burst.start,
                                        seconds: burst.last.timeIntervalSince(burst.start),
                                        precise: burst.precise, momentum: burst.momentum,
                                        device: burst.device, index: burst.index),
                                roster: pointers.ids)
        }
        return out
    }

    // MARK: - Leaving the queue

    /// Queue. A pulse closed: it leaves wearing the devices that were
    /// attached and whether the lid was down.
    private func dressedLocked(_ event: ObservationEvent) -> ObservationEvent {
        var event = event
        event.keyboards = roster.ids
        event.pointers = pointers.ids
        event.lid = lidClosedLocked(now: event.t)
        return event
    }

    private func emitPulse(_ event: ObservationEvent) {
        deliverAsync(dressedLocked(event))
    }

    private func emitWindow(_ stats: WindowStats) {
        let lid = lidClosedLocked(now: stats.start)
        let role = sampledRole
        sampledRole = nil
        var stats = stats
        stats.lid = lid
        stats.role = role
        stats.keyboards = roster.ids
        stats.pointers = pointers.ids
        DispatchQueue.main.async { [weak self] in self?.deliverWindow(stats) }
    }

    private func deliverAsync(_ event: ObservationEvent) {
        DispatchQueue.main.async { [weak self] in self?.deliver(event) }
    }

    /// Main. The store lives here.
    private func deliver(_ event: ObservationEvent) {
        switch event.kind {
        case .pulse: observations?.healthPulse(event)
        case .clicks: observations?.clickPulse(event)
        case .window: observations?.healthWindow(event)
        default: break
        }
    }

    /// Main. A window closed: the shell adds what only main can know —
    /// the app in front, the screens, the layout — and the store keeps
    /// it. The presses are already in the raw store; only their
    /// description travels.
    private func deliverWindow(_ stats: WindowStats) {
        var stats = stats
        let context = context?()
        stats.app = context?.app
        stats.dictation = context?.dictation
        stats.power = Self.powerSource()
        stats.screens = NSScreen.screens.count
        stats.displays = Environment.displays()
        stats.layout = Environment.layoutID()
        stats.tz = TimeZone.current.secondsFromGMT(for: stats.start)
        var event = ObservationEvent(t: stats.start, kind: .window)
        event.window = stats
        observations?.healthWindow(event)
    }

    /// Main. The instrument's own state, written down when it differs
    /// from the last time it was: at enable and once a minute.
    private func checkEra() {
        let info = EraInfo(appVersion: Lodestar.version, keySchema: Int(KeyStore.version),
                           pointerSchema: Int(PointerStore.version), layout: Environment.layoutID(),
                           keyboards: roster.ids, pointers: pointers.ids,
                           displays: Environment.displays(), settings: Environment.inputSettings(),
                           lid: Lid.isClosed())
        if let event = eras.check(info) {
            Log.info("health: era", ["reason": event.era?.reason ?? "?", "version": info.appVersion])
            observations?.era(event)
        }
    }

    /// The focused element's role class, asked with a short leash on the
    /// lookup queue. A role, never a title or a value.
    private func sampleRole() {
        lookup.async { [weak self] in
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.1)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let element = focused else { return }
            let axElement = element as! AXUIElement
            AXUIElementSetMessagingTimeout(axElement, 0.1)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role) == .success,
                  let name = role as? String else { return }
            guard let self else { return }
            self.queue.async { self.sampledRole = name }
        }
    }

    /// Mains, battery or a UPS: a laptop on the couch is a different
    /// posture, and often a different keyboard, from the desk.
    private static func powerSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? else { return nil }
        switch type {
        case kIOPMACPowerKey: return "ac"
        case kIOPMBatteryPowerKey: return "battery"
        case kIOPMUPSPowerKey: return "ups"
        default: return type.lowercased()
        }
    }

    private static func appName(_ pid: pid_t?) -> String {
        pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "unknown"
    }

    /// Lookup queue. The app under a point, and nothing else about it.
    private func pid(at location: CGPoint) -> pid_t? {
        var element: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x),
                                               Float(location.y), &element) == .success,
              let element, AXUIElementGetPid(element, &pid) == .success, pid > 0
        else { return nil }
        return pid
    }

    // MARK: - Timers and taps (main)

    private func startFlushTimer() {
        flushTimer?.invalidate()
        // A minute's cadence: pulses close on their own quarter-hour; this
        // ferries the mouse side over, closes idle windows, and is the
        // self-heal for a mouse tap the first boot could not create.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick()
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    /// Main. One minute's housekeeping; the harness calls it directly.
    func tick(now: Date = Date()) {
        queue.async { [self] in
            let events = drainPendingLocked(now: now)
            for event in events { deliverAsync(event) }
            if let closed = window.closeIfStale(now: now) { emitWindow(closed) }
            keys.flush()
            pointerStore.flush()
        }
        checkEra()
        if enabled, listensToTheMouse, tap == nil, Permissions.isTrusted {
            tapThread = nil
            startMouseTap()
        }
    }

    private func startMouseTap() {
        guard tapThread == nil else { return }
        let thread = Thread { [weak self] in
            guard let self else { return }
            let mask = (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
                | (1 << CGEventType.leftMouseUp.rawValue)
                | (1 << CGEventType.rightMouseUp.rawValue)
                | (1 << CGEventType.otherMouseUp.rawValue)
                | (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDragged.rawValue)
                | (1 << CGEventType.rightMouseDragged.rawValue)
                | (1 << CGEventType.otherMouseDragged.rawValue)
                | (1 << CGEventType.scrollWheel.rawValue)
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HealthMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.sawMouse(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                Log.error("health: could not create the mouse tap")
                return
            }
            self.tap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "lodestar.health.tap"
        thread.qualityOfService = .utility
        thread.start()
        tapThread = thread
    }

    private func stopMouseTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapThread = nil
    }

    /// Main. Whether a global monitor hears pressure events at all is
    /// not documented; the first one that arrives says so in the log.
    private func startPressureMonitor() {
        guard pressureMonitor == nil else { return }
        pressureMonitor = NSEvent.addGlobalMonitorForEvents(matching: .pressure) { [weak self] event in
            guard let self else { return }
            let sample = (Int(event.stage), Double(event.pressure),
                          event.cgEvent.flatMap(EventTime.date(of:)) ?? Date())
            self.queue.async {
                self.lastPressure = sample
                self.pressureSamples += 1
                if self.pressureSamples == 1 { Log.info("health: force touch samples arriving") }
            }
        }
    }

    private func stopPressureMonitor() {
        if let pressureMonitor { NSEvent.removeMonitor(pressureMonitor) }
        pressureMonitor = nil
    }
}
